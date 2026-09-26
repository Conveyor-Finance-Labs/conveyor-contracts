// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {PositionVault} from "../../src/PositionVault.sol";
import {MockSwapPool} from "../../src/mocks/MockSwapPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// MockSwapPool unit tests (docs/15 §7): SW-U1 slippage, SW-U2 debt isolation, SW-U3 quote==out.
contract MockSwapPoolTest is BaseTest {
    MockSwapPool pool;

    function setUp() public override {
        super.setUp();
        pool = new MockSwapPool(IPriceOracle(address(oracle)), IERC20(address(rToken)), IERC20(address(usdc)));
        usdc.mint(address(pool), 1_000_000e6); // seed USDC float
    }

    /// SW-U3 (+ quote formula): 0.05 rBTC at $60k = $3000 = 3000e6 USDC.
    function test_quote_matchesOracleFormula() public view {
        assertEq(pool.quoteRBtcToUsdc(0.05e18), 3000e6);
        assertEq(pool.quoteRBtcToUsdc(0.02e18), 1200e6);
    }

    /// SW-U2: swap does not change Vault.debt — rBTC is EOA-held asset only.
    function test_swap_doesNotChangeVaultDebt() public {
        PositionVault v = _openFor(alice, 10_000e6);
        vm.prank(alice);
        v.mint(0.05e18); // debt 0.05, alice EOA gets 0.05 rBTC

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        rToken.approve(address(pool), 0.02e18);
        uint256 out = pool.swapRBtcForUsdc(0.02e18, 1200e6, alice);
        vm.stopPrank();

        assertEq(out, 1200e6);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, 1200e6); // USDC received
        assertEq(rToken.balanceOf(alice), 0.03e18); // rBTC balance decreased
        assertEq(v.debt(), 0.05e18); // S2: debt unchanged
    }

    /// SW-U3: return value out == quote.
    function test_swap_returnsQuotedAmount() public {
        PositionVault v = _openFor(alice, 10_000e6);
        vm.prank(alice);
        v.mint(0.05e18);

        uint256 q = pool.quoteRBtcToUsdc(0.05e18);
        vm.startPrank(alice);
        rToken.approve(address(pool), 0.05e18);
        uint256 out = pool.swapRBtcForUsdc(0.05e18, 0, alice);
        vm.stopPrank();

        assertEq(out, q);
    }

    /// SW-U1: usdcOut < minUsdcOut → Slippage revert.
    function test_swap_belowMinOut_reverts() public {
        PositionVault v = _openFor(alice, 10_000e6);
        vm.prank(alice);
        v.mint(0.05e18);

        vm.startPrank(alice);
        rToken.approve(address(pool), 0.05e18);
        vm.expectRevert(MockSwapPool.Slippage.selector);
        pool.swapRBtcForUsdc(0.05e18, 3001e6, alice); // expected 3000e6 < min 3001e6
        vm.stopPrank();
    }
}
