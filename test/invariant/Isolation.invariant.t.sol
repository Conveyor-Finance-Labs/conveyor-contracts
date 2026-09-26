// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {PositionVault} from "../../src/PositionVault.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {LocalGmxMock} from "../../src/mocks/LocalGmxMock.sol";
import {VaultState} from "../../src/types/Types.sol";

/// @notice Handler that applies random actions only to Alice Vault. Never touches Bob Vault or owner.
/// @dev forge invariant fuzzer calls this contract's external functions in random order and with random args.
///      fail_on_revert=false so reverts from state mismatch (BadState etc.) are expected.
contract IsolationHandler is Test {
    MockUSDC internal usdc;
    MockPriceOracle internal oracle;
    LocalGmxMock internal gmx;
    PositionVault internal aliceVault;
    address internal aliceOwner;

    constructor(
        MockUSDC usdc_,
        MockPriceOracle oracle_,
        LocalGmxMock gmx_,
        PositionVault aliceVault_,
        address aliceOwner_
    ) {
        usdc = usdc_;
        oracle = oracle_;
        gmx = gmx_;
        aliceVault = aliceVault_;
        aliceOwner = aliceOwner_;
    }

    /// @notice Alice additional collateral deposit. Top up owner funds if insufficient.
    function deposit(uint256 amount) external {
        amount = bound(amount, 1e6, 50_000e6);
        usdc.mint(aliceOwner, amount);
        vm.startPrank(aliceOwner);
        usdc.approve(address(aliceVault), amount);
        aliceVault.deposit(amount);
        vm.stopPrank();
    }

    /// @notice Alice rBTC mint (ExceedsMaxLTV revert if over maxLTV → fuzzer absorbs).
    function mint(uint256 rBtcAmount) external {
        rBtcAmount = bound(rBtcAmount, 1, 1e18);
        vm.prank(aliceOwner);
        aliceVault.mint(rBtcAmount);
    }

    /// @notice Change BTC price. Shake global oracle to make Alice liquidatable.
    function setPrice(uint256 price8) external {
        price8 = bound(price8, 1e8, 200_000e8);
        vm.prank(oracle.owner());
        oracle.setPrice(price8);
    }

    /// @notice Arbitrary liquidator liquidates Alice Vault. NotLiquidatable revert if healthy → absorbed.
    ///         Execute through settlement (Liquidated) and refund paths.
    function liquidate() external {
        address liquidator = makeAddr("randomLiquidator");
        vm.deal(liquidator, 1 ether);
        vm.prank(liquidator);
        aliceVault.liquidate{value: 1e14}();
        gmx.executeOrder(gmx.lastOrderKey());
    }
}

/// @notice Invariant isolation (G2/I6): no action on one Vault may change another user Vault accounting or state.
///         Apply random handler actions only to Alice Vault; assert Bob Vault storage unchanged.
contract IsolationInvariantTest is BaseTest {
    IsolationHandler internal handler;
    PositionVault internal bobVault;

    // Bob Vault baseline before handler actions (storage snapshot)
    address internal bobInitOwner;
    uint256 internal bobInitCollateral;
    uint256 internal bobInitDebt;
    VaultState internal bobInitState;
    bytes32 internal bobInitPosKey;

    function setUp() public override {
        super.setUp();

        // Alice·Bob each open independent Vault → both Active.
        PositionVault aliceVault = _openFor(alice, 10_000e6);
        bobVault = _openFor(bob, 5_000e6);

        // Bob baseline snapshot.
        bobInitOwner = bobVault.owner();
        bobInitCollateral = bobVault.collateral();
        bobInitDebt = bobVault.debt();
        bobInitState = bobVault.state();
        bobInitPosKey = bobVault.posKey();

        // precondition: Bob is Active with no debt.
        assertEq(uint256(bobInitState), uint256(VaultState.Active), "bob starts Active");
        assertEq(bobInitDebt, 0, "bob starts debt-free");

        // only handler is fuzz target. Bob Vault·EOA not exposed to handler.
        handler = new IsolationHandler(usdc, oracle, gmx, aliceVault, alice);
        targetContract(address(handler));
    }

    /// @notice Bob Vault storage (owner·collateral·debt·state·posKey) unchanged regardless of Alice actions.
    /// @dev collateralValueUsdWad() depends on global oracle price (Bob also Active+posKey) so intentionally not asserted.
    ///      Price is a shared market variable, not an isolation violation (same logic as docs Demo bobValBefore capture).
    function invariant_bobVaultStateUntouched() public view {
        assertEq(bobVault.owner(), bobInitOwner, "bob owner changed");
        assertEq(bobVault.collateral(), bobInitCollateral, "bob collateral changed");
        assertEq(bobVault.debt(), bobInitDebt, "bob debt changed");
        assertEq(uint256(bobVault.state()), uint256(bobInitState), "bob state changed");
        assertEq(bobVault.posKey(), bobInitPosKey, "bob posKey changed");
    }

    /// @notice Bob never minted so debt·LTV always 0 (Alice liquidation must not corrupt Bob accounting).
    function invariant_bobHasNoDebtOrLtv() public view {
        assertEq(bobVault.debt(), 0, "bob accrued debt");
        assertEq(bobVault.currentLTV(), 0, "bob accrued LTV");
        assertEq(rToken.balanceOf(bob), 0, "bob received rToken");
    }
}
