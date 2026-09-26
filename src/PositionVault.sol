// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPositionVault} from "./interfaces/IPositionVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IGmxAdapter} from "./interfaces/IGmxAdapter.sol";
import {IRToken} from "./interfaces/IRToken.sol";
import {LTVMath} from "./libraries/LTVMath.sol";
import {Units} from "./libraries/Units.sol";
import {VaultState, OrderKind, PendingOrder} from "./types/Types.sol";

/// @title PositionVault — per-user isolated Vault (docs/10, safety design docs/70)
/// @notice EIP-1167 clone. Absorbs GMX 2-step async via state machine. No admin fund withdrawal functions (G5).
contract PositionVault is IPositionVault, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_EXEC_FEE = 1e14; // 0.0001 ETH (I7)
    uint256 internal constant MIN_COLLATERAL = 1e6; // 1 USDC (OQ-15)
    uint256 internal constant LIQ_PENALTY_BPS = 500; // 5% (OQ-12, default until CTO confirms)
    uint256 internal constant PENALTY_LIQ_SHARE_BPS = 6_000; // liquidator 60%
    uint256 internal constant SETTLING_TIMEOUT = 5 minutes; // OQ-6

    address public owner;
    address public factory;
    IGmxAdapter public gmx;
    IPriceOracle public oracle;
    IERC20 public usdc;
    IRToken public rToken;
    bytes32 public marketId; // Asset market identifier (Wave 1)
    uint16 public maxLtvBps; // Per-market mint limit
    uint16 public lltvBps; // Per-market liquidation threshold

    uint256 public collateral; // USDC accounting (6dec)
    uint256 public debt; // rBTC (18dec)
    VaultState public state;
    PendingOrder public pending;
    bytes32 public posKey;
    address public liquidator; // Liquidation reward recipient

    event CollateralDeposited(address indexed vault, uint256 amount);
    event PositionOpenRequested(address indexed vault, bytes32 orderKey);
    event PositionOpened(address indexed vault, bytes32 posKey);
    event PositionOpenFailed(address indexed vault, bytes32 orderKey);
    event PositionCloseRequested(address indexed vault, bytes32 orderKey, uint8 kind);
    event Closed(address indexed vault, uint256 returned);
    event RBTCMinted(address indexed vault, uint256 amount);
    event RBTCRepaid(address indexed vault, uint256 amount);
    event Liquidated(address indexed vault, uint256 debtRepaidUsdc, uint256 refundUsdc);
    event BadDebt(address indexed vault, uint256 shortfallUsdc);
    event StuckOrderRecovered(address indexed vault, bytes32 orderKey);

    error NotOwner();
    error NotGmx();
    error BadState();
    error BadKey();
    error InsufficientExecFee();
    error BelowMinCollateral();
    error ExceedsMaxLTV();
    error NotLiquidatable();
    error OutstandingDebt();
    error NotTimedOut();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyGmx() {
        if (msg.sender != address(gmx)) revert NotGmx();
        _;
    }

    modifier notPaused() {
        if (IVaultFactory(factory).paused()) revert BadState();
        _;
    }

    constructor() {
        _disableInitializers(); // Block logic contract initialization
    }

    function initialize(
        address owner_,
        address factory_,
        IGmxAdapter gmx_,
        IPriceOracle oracle_,
        address usdc_,
        address rToken_,
        bytes32 marketId_,
        uint16 maxLtvBps_,
        uint16 lltvBps_
    ) external initializer {
        owner = owner_;
        factory = factory_;
        gmx = gmx_;
        oracle = oracle_;
        usdc = IERC20(usdc_);
        rToken = IRToken(rToken_);
        marketId = marketId_;
        maxLtvBps = maxLtvBps_;
        lltvBps = lltvBps_;
        state = VaultState.Empty;
    }

    // ── User actions ──

    function deposit(uint256 usdcAmount) external onlyOwner notPaused nonReentrant {
        if (state != VaultState.Empty && state != VaultState.Active) revert BadState();
        usdc.safeTransferFrom(owner, address(this), usdcAmount);
        collateral += usdcAmount;
        emit CollateralDeposited(address(this), usdcAmount);
    }

    function openPosition() external payable onlyOwner notPaused nonReentrant {
        if (state != VaultState.Empty) revert BadState();
        if (collateral < MIN_COLLATERAL) revert BelowMinCollateral();
        if (msg.value < MIN_EXEC_FEE) revert InsufficientExecFee(); // I7
        usdc.forceApprove(address(gmx), collateral);
        bytes32 key = gmx.createOpenOrder{value: msg.value}(marketId, collateral, oracle.btcPrice());
        state = VaultState.SettlingOpen;
        pending = PendingOrder(OrderKind.Open, key, block.timestamp);
        emit PositionOpenRequested(address(this), key);
    }

    function mint(uint256 rBtcAmount) external onlyOwner notPaused nonReentrant {
        if (state != VaultState.Active) revert BadState();
        require(rBtcAmount > 0, "zero mint");
        uint256 newDebt = debt + rBtcAmount;
        uint256 ltv = LTVMath.currentLTV(collateralValueUsdWad(), Units.btcToUsdWad(newDebt, oracle.btcPrice()));
        if (!LTVMath.isMintAllowed(ltv, maxLtvBps)) revert ExceedsMaxLTV(); // I3/D3
        debt = newDebt;
        rToken.mint(owner, rBtcAmount); // D2: owner EOA
        emit RBTCMinted(address(this), rBtcAmount);
    }

    /// @notice Repay debt — burn owner's rBTC from EOA and reduce Vault.debt (inverse of mint, docs/11 D4).
    /// @dev rBtcAmount capped at debt. Full repayment enables closePosition (OQ-5).
    ///      Does not return USDC — collateral stays in the position; closePosition settles and returns after repay.
    function repay(uint256 rBtcAmount) external onlyOwner notPaused nonReentrant {
        if (state != VaultState.Active) revert BadState();
        uint256 amt = rBtcAmount > debt ? debt : rBtcAmount;
        require(amt > 0, "nothing to repay");
        debt -= amt;
        rToken.burn(owner, amt); // D1: only Vault burns. Reverts if owner balance insufficient.
        emit RBTCRepaid(address(this), amt);
    }

    function closePosition() external payable onlyOwner notPaused nonReentrant {
        if (state != VaultState.Active) revert BadState();
        if (debt != 0) revert OutstandingDebt(); // OQ-5: only after full debt repayment
        if (msg.value < MIN_EXEC_FEE) revert InsufficientExecFee();
        bytes32 key = gmx.createCloseOrder{value: msg.value}(posKey);
        state = VaultState.SettlingLiquidate;
        pending = PendingOrder(OrderKind.Close, key, block.timestamp);
        emit PositionCloseRequested(address(this), key, uint8(OrderKind.Close));
    }

    /// @notice Liquidate. Allowed even while paused (escape path, docs/70 §5).
    function liquidate() external payable nonReentrant {
        if (state != VaultState.Active) revert BadState();
        if (msg.value < MIN_EXEC_FEE) revert InsufficientExecFee();
        uint256 ltv = currentLTV();
        if (!LTVMath.isLiquidatable(ltv, lltvBps)) revert NotLiquidatable(); // L1/I4
        liquidator = msg.sender;
        bytes32 key = gmx.createCloseOrder{value: msg.value}(posKey);
        state = VaultState.SettlingLiquidate;
        pending = PendingOrder(OrderKind.Liquidate, key, block.timestamp);
        emit PositionCloseRequested(address(this), key, uint8(OrderKind.Liquidate));
    }

    /// @notice Recover stuck Settling (docs/60 OQ-6). Return to Active when close/liquidate callback never arrives.
    /// @dev Stuck open requires adapter cancel path since collateral is on GMX (OQ-6 final design pending).
    function cancelStuckOrder() external {
        if (state != VaultState.SettlingLiquidate) revert BadState();
        if (block.timestamp <= pending.createdAt + SETTLING_TIMEOUT) revert NotTimedOut();
        bytes32 key = pending.orderKey;
        delete pending;
        state = VaultState.Active;
        emit StuckOrderRecovered(address(this), key);
    }

    // ── GMX callbacks ──

    function afterOrderExecution(bytes32 orderKey) external onlyGmx nonReentrant {
        if (pending.orderKey != orderKey) revert BadKey();
        OrderKind kind = pending.kind;
        if (kind == OrderKind.Open) {
            posKey = gmx.positionKey(address(this), marketId);
            state = VaultState.Active;
            delete pending;
            emit PositionOpened(address(this), posKey);
        } else if (kind == OrderKind.Close) {
            _settleClose();
        } else {
            _settleLiquidation();
        }
    }

    function afterOrderCancellation(bytes32 orderKey) external onlyGmx nonReentrant {
        if (pending.orderKey != orderKey) revert BadKey();
        if (pending.kind == OrderKind.Open) {
            collateral = usdc.balanceOf(address(this)); // GMX returned collateral
            state = VaultState.Empty;
            delete pending;
            emit PositionOpenFailed(address(this), orderKey);
        } else {
            state = VaultState.Active; // close/liquidate cancel → revert to Active
            delete pending;
        }
    }

    // ── Settlement (CEI: effects first, external calls last) ──

    function _settleClose() internal {
        uint256 recovered = usdc.balanceOf(address(this));
        collateral = 0;
        posKey = bytes32(0);
        state = VaultState.Empty;
        delete pending;
        if (recovered > 0) usdc.safeTransfer(owner, recovered);
        emit Closed(address(this), recovered);
    }

    function _settleLiquidation() internal {
        uint256 recovered = usdc.balanceOf(address(this));
        uint256 debtUsdc = Units.wadToUsdc(debtValueUsdWad());
        uint256 repayUsdc = recovered >= debtUsdc ? debtUsdc : recovered;
        uint256 afterDebt = recovered - repayUsdc;
        uint256 penaltyTarget = (debtUsdc * LIQ_PENALTY_BPS) / BPS;
        uint256 penalty = penaltyTarget <= afterDebt ? penaltyTarget : afterDebt;
        uint256 refund = afterDebt - penalty;
        uint256 shortfall = debtUsdc - repayUsdc; // bad debt (OQ-4)

        address _owner = owner;
        address _liq = liquidator;
        // OQ-1: demo default (a) — debt ledger 0, no rToken burn (owner may have swapped).
        //       production (b): liquidator recovers and burns rBTC → totalSupply consistency (G4). Default until CTO confirms.
        debt = 0;
        collateral = 0;
        posKey = bytes32(0);
        state = VaultState.Liquidated;
        delete pending;

        if (penalty > 0) {
            uint256 toLiq = (penalty * PENALTY_LIQ_SHARE_BPS) / BPS;
            uint256 toProto = penalty - toLiq;
            if (toLiq > 0) usdc.safeTransfer(_liq, toLiq);
            if (toProto > 0) usdc.safeTransfer(factory, toProto); // treasury=factory
        }
        if (refund > 0) usdc.safeTransfer(_owner, refund); // I5
        emit Liquidated(address(this), repayUsdc, refund);
        if (shortfall > 0) emit BadDebt(address(this), shortfall);
    }

    // ── Views ──

    function collateralValueUsdWad() public view returns (uint256) {
        if ((state == VaultState.Active || state == VaultState.SettlingLiquidate) && posKey != bytes32(0)) {
            return gmx.getPositionValueUsd(posKey); // OQ-2 hybrid: position value = GMX
        }
        return Units.usdcToWad(collateral);
    }

    function debtValueUsdWad() public view returns (uint256) {
        return Units.btcToUsdWad(debt, oracle.btcPrice());
    }

    function currentLTV() public view returns (uint256) {
        if (debt == 0) return 0;
        uint256 col = collateralValueUsdWad();
        // Full wipeout (equity=0): maximum risk → liquidatable. Revert would leave underwater vault permanently stuck (G1/G6).
        if (col == 0) return type(uint256).max;
        return LTVMath.currentLTV(col, debtValueUsdWad());
    }

    function healthFactor() external view returns (uint256) {
        return LTVMath.healthFactor(currentLTV(), lltvBps);
    }

    receive() external payable {} // Receive GMX exec fee refunds
}
