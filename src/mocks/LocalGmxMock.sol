// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGmxAdapter} from "../interfaces/IGmxAdapter.sol";
import {IPositionVault} from "../interfaces/IPositionVault.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {Units} from "../libraries/Units.sol";

/// @title LocalGmxMock — local/instant GMX substitute (docs/50 §3). Wave 1: per-market (per-asset) support.
/// @notice Implements only the GMX surface Vault uses. Replays 2-step async (createOrder→executeOrder).
///         PnL uses per-market oracle linear model (2x). Per-market oracle injected via registerMarket (mock only).
contract LocalGmxMock is IGmxAdapter {
    uint256 internal constant LEVERAGE = 2;

    IERC20 public immutable usdc;

    struct Position {
        address vault;
        uint256 collateral; // USDC(6dec) held
        uint256 entryPrice8;
        bytes32 marketId;
        bool active;
    }

    struct Order {
        address vault;
        uint8 kind; // 1=Open, 2=Close/Liquidate
        bytes32 positionKey;
        bool executed;
    }

    mapping(bytes32 => IPriceOracle) public marketOracle; // marketId => oracle (mock-only price lookup)
    mapping(bytes32 => Position) public positions; // positionKey => position
    mapping(bytes32 => Order) public orders; // orderKey => order
    uint256 private _nonce;
    bytes32 public lastOrderKey; // Convenience for tests/executor

    event MarketRegistered(bytes32 indexed marketId, address oracle);
    event OrderCreated(bytes32 indexed orderKey, address indexed vault, uint8 kind);
    event OrderExecuted(bytes32 indexed orderKey);
    event OrderCancelled(bytes32 indexed orderKey);

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    /// @notice Mock only: register market price feed (called by Deploy/tests). Not needed on real GMX adapter.
    function registerMarket(bytes32 marketId, IPriceOracle oracle) external {
        marketOracle[marketId] = oracle;
        emit MarketRegistered(marketId, address(oracle));
    }

    function positionKey(address account, bytes32 marketId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, marketId, true));
    }

    function _newOrderKey(address vault) internal returns (bytes32 k) {
        k = keccak256(abi.encodePacked(vault, _nonce, block.number));
        _nonce++;
        lastOrderKey = k;
    }

    /// @notice Called by Vault. Pulls collateral USDC from Vault (approve required).
    function createOpenOrder(bytes32 marketId, uint256 collateralUsdc, uint256 indexPrice8)
        external
        payable
        returns (bytes32 orderKey)
    {
        require(collateralUsdc > 0, "GMX: zero collateral");
        usdc.transferFrom(msg.sender, address(this), collateralUsdc);
        bytes32 pk = positionKey(msg.sender, marketId);
        positions[pk] = Position({
            vault: msg.sender,
            collateral: collateralUsdc,
            entryPrice8: indexPrice8,
            marketId: marketId,
            active: false
        });
        orderKey = _newOrderKey(msg.sender);
        orders[orderKey] = Order({vault: msg.sender, kind: 1, positionKey: pk, executed: false});
        emit OrderCreated(orderKey, msg.sender, 1);
    }

    function createCloseOrder(bytes32 pk) external payable returns (bytes32 orderKey) {
        require(positions[pk].active, "GMX: no position");
        orderKey = _newOrderKey(msg.sender);
        orders[orderKey] = Order({vault: msg.sender, kind: 2, positionKey: pk, executed: false});
        emit OrderCreated(orderKey, msg.sender, 2);
    }

    /// @notice Position net value (USD WAD). equity = collateral + 2x·pnl. Floors at 0 if negative. Uses market oracle.
    function getPositionValueUsd(bytes32 pk) public view returns (uint256) {
        Position memory p = positions[pk];
        if (!p.active || p.entryPrice8 == 0) return 0;
        int256 collatWad = int256(Units.usdcToWad(p.collateral));
        int256 cur = int256(marketOracle[p.marketId].btcPrice());
        int256 entry = int256(uint256(p.entryPrice8));
        int256 pnl = (collatWad * int256(LEVERAGE) * (cur - entry)) / entry;
        int256 value = collatWad + pnl;
        return value > 0 ? uint256(value) : 0;
    }

    // ── keeper / executor / test entry points ──

    /// @notice Execute order (GMX keeper role). Called by gmx-executor daemon or tests.
    function executeOrder(bytes32 orderKey) external {
        Order storage o = orders[orderKey];
        require(o.vault != address(0) && !o.executed, "GMX: bad order");
        o.executed = true;
        if (o.kind == 1) {
            positions[o.positionKey].active = true;
        } else {
            // close/liquidate: send recovered USDC to Vault
            uint256 recoveredWad = getPositionValueUsd(o.positionKey);
            uint256 recovered = Units.wadToUsdc(recoveredWad);
            uint256 bal = usdc.balanceOf(address(this));
            if (recovered > bal) recovered = bal; // mock fund limit (drop scenarios always have enough)
            positions[o.positionKey].active = false;
            if (recovered > 0) usdc.transfer(o.vault, recovered);
        }
        emit OrderExecuted(orderKey);
        IPositionVault(o.vault).afterOrderExecution(orderKey);
    }

    /// @notice Cancel order (simulate open failure). Return collateral USDC to Vault.
    function cancelOrder(bytes32 orderKey) external {
        Order storage o = orders[orderKey];
        require(o.vault != address(0) && !o.executed, "GMX: bad order");
        o.executed = true;
        if (o.kind == 1) {
            Position memory p = positions[o.positionKey];
            delete positions[o.positionKey];
            if (p.collateral > 0) usdc.transfer(o.vault, p.collateral);
        }
        emit OrderCancelled(orderKey);
        IPositionVault(o.vault).afterOrderCancellation(orderKey);
    }
}
