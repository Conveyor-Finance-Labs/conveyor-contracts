// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {PositionVault} from "../../src/PositionVault.sol";
import {VaultState} from "../../src/types/Types.sol";

/// State machine unit tests (docs/10 §6, docs/60 OQ-6, docs/70).
/// Block actions during Settling (BadState), insufficient exec fee (I7), open cancel recovery,
/// closePosition debt guard (OQ-5), cancelStuckOrder timeout recovery.
contract PositionVaultStateTest is BaseTest {
    uint256 internal constant SETTLING_TIMEOUT = 5 minutes; // mirror PositionVault.SETTLING_TIMEOUT

    /// Create+deposit+open request only (callback not executed). Leave state SettlingOpen.
    function _openRequest(address user, uint256 amount) internal returns (PositionVault v) {
        vm.startPrank(user);
        address vaddr = factory.createVault(BTC);
        v = PositionVault(payable(vaddr));
        usdc.approve(vaddr, amount);
        v.deposit(amount);
        v.openPosition{value: FEE}();
        vm.stopPrank();
    }

    // ── Block actions during SettlingOpen ──

    function test_mint_whileSettlingOpen_reverts() public {
        PositionVault v = _openRequest(alice, 10_000e6);
        assertEq(uint256(v.state()), uint256(VaultState.SettlingOpen));

        vm.prank(alice);
        vm.expectRevert(PositionVault.BadState.selector); // mint is Active-only (I2)
        v.mint(0.01e18);
    }

    function test_openPosition_whileSettlingOpen_reverts() public {
        PositionVault v = _openRequest(alice, 10_000e6);
        assertEq(uint256(v.state()), uint256(VaultState.SettlingOpen));

        vm.prank(alice);
        vm.expectRevert(PositionVault.BadState.selector); // openPosition is Empty-only (I2)
        v.openPosition{value: FEE}();
    }

    // ── exec fee guard (I7) ──

    function test_openPosition_zeroExecFee_reverts() public {
        vm.startPrank(alice);
        address vaddr = factory.createVault(BTC);
        PositionVault v = PositionVault(payable(vaddr));
        usdc.approve(vaddr, 10_000e6);
        v.deposit(10_000e6);

        vm.expectRevert(PositionVault.InsufficientExecFee.selector); // msg.value=0 < MIN_EXEC_FEE
        v.openPosition{value: 0}();
        vm.stopPrank();

        // failed open does not change state.
        assertEq(uint256(v.state()), uint256(VaultState.Empty));
        assertEq(v.collateral(), 10_000e6);
    }

    // ── open callback cancel → Empty + collateral recovery ──

    function test_openCancel_restoresEmptyAndCollateral() public {
        PositionVault v = _openRequest(alice, 10_000e6);
        assertEq(uint256(v.state()), uint256(VaultState.SettlingOpen));
        // collateral moved to GMX, Vault USDC balance 0.
        assertEq(usdc.balanceOf(address(v)), 0);

        gmx.cancelOrder(gmx.lastOrderKey()); // simulate GMX open failure → afterOrderCancellation(Open)

        assertEq(uint256(v.state()), uint256(VaultState.Empty));
        assertEq(usdc.balanceOf(address(v)), 10_000e6); // collateral USDC returned
        assertEq(v.collateral(), 10_000e6); // accounting restored to balance
    }

    // ── closePosition debt guard (OQ-5) ──

    function test_closePosition_withOutstandingDebt_reverts() public {
        PositionVault v = _openFor(alice, 10_000e6); // Active
        vm.prank(alice);
        v.mint(0.05e18); // $3000 debt, LTV 30%
        assertEq(v.debt(), 0.05e18);

        vm.prank(alice);
        vm.expectRevert(PositionVault.OutstandingDebt.selector); // debt!=0 → close blocked
        v.closePosition{value: FEE}();

        // state unchanged after revert.
        assertEq(uint256(v.state()), uint256(VaultState.Active));
    }

    // ── cancelStuckOrder timeout recovery (OQ-6) ──

    function test_cancelStuckOrder_beforeTimeout_reverts() public {
        PositionVault v = _openFor(alice, 10_000e6); // Active, debt 0
        vm.prank(alice);
        v.closePosition{value: FEE}(); // debt 0 so allowed → SettlingLiquidate (callback pending)
        assertEq(uint256(v.state()), uint256(VaultState.SettlingLiquidate));

        vm.expectRevert(PositionVault.NotTimedOut.selector); // recovery before timeout not allowed
        v.cancelStuckOrder();
    }

    function test_cancelStuckOrder_afterTimeout_recoversToActive() public {
        PositionVault v = _openFor(alice, 10_000e6); // Active, debt 0
        vm.prank(alice);
        v.closePosition{value: FEE}(); // SettlingLiquidate (callback pending)
        assertEq(uint256(v.state()), uint256(VaultState.SettlingLiquidate));

        vm.warp(block.timestamp + SETTLING_TIMEOUT + 1); // timeout elapsed (check uses <= so +1 needed)
        v.cancelStuckOrder(); // permissionless recovery

        assertEq(uint256(v.state()), uint256(VaultState.Active)); // back to Active

        // verify pending cleared: re-execution with same key must reject with BadKey.
        bytes32 staleKey = gmx.lastOrderKey();
        vm.expectRevert(PositionVault.BadKey.selector);
        gmx.executeOrder(staleKey);
    }

    function test_cancelStuckOrder_wrongState_reverts() public {
        PositionVault v = _openFor(alice, 10_000e6); // Active, not SettlingLiquidate
        vm.warp(block.timestamp + SETTLING_TIMEOUT + 1);

        vm.expectRevert(PositionVault.BadState.selector); // no recovery target in Active
        v.cancelStuckOrder();
    }
}
