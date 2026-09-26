// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {PositionVault} from "../../src/PositionVault.sol";
import {VaultState} from "../../src/types/Types.sol";

/// Demo scenario end-to-end + isolation (docs/5, docs/41 e2e)
contract DemoTest is BaseTest {
    function test_open_movesToActive() public {
        PositionVault v = _openFor(alice, 10_000e6);
        assertEq(uint256(v.state()), uint256(VaultState.Active));
        assertEq(v.collateralValueUsdWad(), 10_000e18); // entry price pnl 0
    }

    function test_mint_withinMaxLtv_sendsToOwner() public {
        PositionVault v = _openFor(alice, 10_000e6);
        vm.prank(alice);
        v.mint(0.05e18); // $3000 → LTV 30%
        assertEq(rToken.balanceOf(alice), 0.05e18); // D2: owner EOA
        assertEq(rToken.balanceOf(address(v)), 0);
        assertEq(v.debt(), 0.05e18);
        assertEq(v.currentLTV(), 3000);
    }

    function test_mint_exceedingMaxLtv_reverts() public {
        PositionVault v = _openFor(alice, 10_000e6);
        vm.prank(alice);
        vm.expectRevert(PositionVault.ExceedsMaxLTV.selector);
        v.mint(0.16e18); // $9600 > maxLTV 45% ($9000)
    }

    function test_fullDemo_liquidation_and_isolation() public {
        // Alice: 10K → 2x long → mint 0.05 rBTC
        PositionVault av = _openFor(alice, 10_000e6);
        vm.prank(alice);
        av.mint(0.05e18);

        // Bob: 5K → 2x long, no mint (isolation comparison)
        PositionVault bv = _openFor(bob, 5_000e6);

        // price drop $60k → $39k → Alice HF ≤ 1
        oracle.setPrice(39_000e8);
        assertTrue(av.currentLTV() >= 6500, "alice liquidatable");
        assertEq(av.healthFactor(), 1e18); // LTV==LLTV → HF==1
        // isolation baseline: Bob state after price drop (market effect) · before Alice liquidation
        uint256 bobValBefore = bv.collateralValueUsdWad();

        // liquidation
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(bob); // arbitrary liquidator
        av.liquidate{value: FEE}();
        gmx.executeOrder(gmx.lastOrderKey()); // GMX close fill

        assertEq(uint256(av.state()), uint256(VaultState.Liquidated));
        assertEq(av.debt(), 0);
        // refund: recovery 3000 - debt 1950 - penalty 97.5 = 952.5 USDC
        assertEq(usdc.balanceOf(alice) - aliceBefore, 952.5e6);
        // penalty liquidator share 58.5, protocol (factory) 39
        assertEq(usdc.balanceOf(address(factory)), 39e6);

        // isolation: Bob Vault unaffected (I6)
        assertEq(uint256(bv.state()), uint256(VaultState.Active));
        assertEq(bv.debt(), 0);
        assertEq(bv.collateralValueUsdWad(), bobValBefore);
    }

    function test_liquidate_whenHealthy_reverts() public {
        PositionVault v = _openFor(alice, 10_000e6);
        vm.prank(alice);
        v.mint(0.05e18); // HF > 1 at $60k
        vm.expectRevert(PositionVault.NotLiquidatable.selector);
        v.liquidate{value: FEE}();
    }

    function test_createVault_twice_reverts() public {
        vm.startPrank(alice);
        factory.createVault(BTC);
        vm.expectRevert();
        factory.createVault(BTC); // I1
        vm.stopPrank();
    }
}
