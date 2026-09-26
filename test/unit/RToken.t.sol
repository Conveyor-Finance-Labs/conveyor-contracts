// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {RToken} from "../../src/RToken.sol";
import {PositionVault} from "../../src/PositionVault.sol";

/// RToken unit tests (docs/11): D1 (only Vault mint/burn), D2 (recipient=owner), D5 (totalSupply==Σbalances).
contract RTokenTest is BaseTest {
    /// D1: non-Vault EOA calling mint reverts NotVault.
    function test_mint_byNonVault_reverts() public {
        vm.prank(alice);
        vm.expectRevert(RToken.NotVault.selector);
        rToken.mint(alice, 1e18);
    }

    /// D1: non-Vault EOA calling burn reverts NotVault.
    function test_burn_byNonVault_reverts() public {
        vm.prank(bob);
        vm.expectRevert(RToken.NotVault.selector);
        rToken.burn(bob, 1e18);
    }

    /// D1: arbitrary contract (here factory itself) cannot mint if not Vault.
    function test_mint_byFactory_reverts() public {
        vm.prank(address(factory));
        vm.expectRevert(RToken.NotVault.selector);
        rToken.mint(alice, 1e18);
    }

    /// D1 + D2: PositionVault.mint path delivers to owner EOA (uses BaseTest _openFor).
    function test_mint_viaVault_sendsToOwner() public {
        PositionVault v = _openFor(alice, 10_000e6);
        vm.prank(alice);
        v.mint(0.05e18); // $3000 → LTV 30%, within maxLTV 45%

        assertEq(rToken.balanceOf(alice), 0.05e18); // D2: owner EOA receives
        assertEq(rToken.balanceOf(address(v)), 0); // Vault does not hold
        assertEq(rToken.totalSupply(), 0.05e18);
    }

    /// Registered Vault address calling mint directly works (onlyVault passes).
    function test_mint_byRegisteredVault_succeeds() public {
        address vault = _createVault(alice);

        vm.prank(vault);
        rToken.mint(alice, 7e18);

        assertEq(rToken.balanceOf(alice), 7e18);
        assertEq(rToken.totalSupply(), 7e18);
    }

    /// burn: registered Vault burning balance decreases balance·totalSupply.
    function test_burn_byRegisteredVault_succeeds() public {
        address vault = _createVault(alice);

        vm.startPrank(vault);
        rToken.mint(alice, 10e18);
        rToken.burn(alice, 4e18);
        vm.stopPrank();

        assertEq(rToken.balanceOf(alice), 6e18);
        assertEq(rToken.totalSupply(), 6e18);
    }

    /// D5: after mint/burn across Vaults·accounts totalSupply == Σ balances.
    function test_totalSupply_equalsSumOfBalances() public {
        address va = _createVault(alice);
        address vb = _createVault(bob);

        vm.prank(va);
        rToken.mint(alice, 3e18);
        vm.prank(vb);
        rToken.mint(bob, 5e18);
        // one Vault can mint to other accounts (no recipient restriction, D1 only).
        vm.prank(va);
        rToken.mint(bob, 2e18);

        assertEq(rToken.balanceOf(alice), 3e18);
        assertEq(rToken.balanceOf(bob), 7e18);
        assertEq(
            rToken.totalSupply(),
            rToken.balanceOf(alice) + rToken.balanceOf(bob)
        ); // D5

        // invariant preserved after partial burn.
        vm.prank(vb);
        rToken.burn(bob, 2e18);

        assertEq(rToken.totalSupply(), 8e18);
        assertEq(
            rToken.totalSupply(),
            rToken.balanceOf(alice) + rToken.balanceOf(bob)
        ); // D5
    }

    /// metadata sanity (decimals override 18).
    function test_decimals_is18() public view {
        assertEq(rToken.decimals(), 18);
    }

    /// create only registered Vault clone address (for onlyVault check without open/deposit).
    function _createVault(address user) internal returns (address vault) {
        vm.prank(user);
        vault = factory.createVault(BTC);
    }
}
