// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {PositionVault} from "../../src/PositionVault.sol";
import {VaultState} from "../../src/types/Types.sol";

/// repay(rBtcAmount) unit tests — inverse of mint (docs/11 D4). rBTC burn → debt reduction.
/// Full repay enables closePosition (OQ-5). Does not return USDC (collateral is in the position).
contract RepayTest is BaseTest {
    function _openAndMint(address user, uint256 collateral, uint256 rbtc) internal returns (PositionVault v) {
        v = _openFor(user, collateral);
        vm.prank(user);
        v.mint(rbtc);
    }

    function test_repay_reducesDebtAndBurns() public {
        PositionVault v = _openAndMint(alice, 10_000e6, 0.05e18); // debt 0.05, LTV 30%
        assertEq(v.debt(), 0.05e18);
        assertEq(v.currentLTV(), 3000);

        vm.prank(alice);
        v.repay(0.02e18);

        assertEq(v.debt(), 0.03e18); // debt decreased
        assertEq(rToken.balanceOf(alice), 0.03e18); // owner balance burned
        assertEq(rToken.totalSupply(), 0.03e18); // D5
        assertEq(v.currentLTV(), 1800); // 0.03*60k=$1800 / $10k → 18%
        assertEq(uint256(v.state()), uint256(VaultState.Active));
    }

    function test_repay_fullDebt_thenCloseAllowed() public {
        PositionVault v = _openAndMint(alice, 10_000e6, 0.05e18);

        vm.prank(alice);
        v.repay(0.05e18);
        assertEq(v.debt(), 0); // full repay
        assertEq(rToken.balanceOf(alice), 0);

        // debt 0 so closePosition allowed (OQ-5) → collateral USDC returned after settlement.
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        v.closePosition{value: FEE}();
        gmx.executeOrder(gmx.lastOrderKey());

        assertEq(uint256(v.state()), uint256(VaultState.Empty));
        assertEq(usdc.balanceOf(alice) - before, 10_000e6); // same entry price → principal recovered
    }

    function test_repay_moreThanDebt_capsAtDebt() public {
        PositionVault v = _openAndMint(alice, 10_000e6, 0.05e18);

        vm.prank(alice);
        v.repay(1e18); // input larger than debt(0.05) → capped at debt

        assertEq(v.debt(), 0);
        assertEq(rToken.balanceOf(alice), 0); // only 0.05 burned (excess ignored)
    }

    function test_repay_withInsufficientBalance_reverts() public {
        PositionVault v = _openAndMint(alice, 10_000e6, 0.05e18);

        // assume alice swapped/transferred some rBTC → insufficient balance.
        vm.prank(alice);
        rToken.transfer(bob, 0.03e18); // alice balance 0.02, debt still 0.05 (S2 asymmetry)

        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance (burn from owner)
        v.repay(0.05e18);

        assertEq(v.debt(), 0.05e18); // failure → debt unchanged
    }

    function test_repay_zero_reverts() public {
        PositionVault v = _openAndMint(alice, 10_000e6, 0.05e18);
        vm.prank(alice);
        vm.expectRevert(bytes("nothing to repay"));
        v.repay(0);
    }

    function test_repay_whenNoDebt_reverts() public {
        PositionVault v = _openFor(alice, 10_000e6); // debt 0
        vm.prank(alice);
        vm.expectRevert(bytes("nothing to repay")); // amt = min(x, 0) = 0
        v.repay(0.01e18);
    }

    function test_repay_byNonOwner_reverts() public {
        PositionVault v = _openAndMint(alice, 10_000e6, 0.05e18);
        vm.prank(bob);
        vm.expectRevert(PositionVault.NotOwner.selector);
        v.repay(0.01e18);
    }
}
