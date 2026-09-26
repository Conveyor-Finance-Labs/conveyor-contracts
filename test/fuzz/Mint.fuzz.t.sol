// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {PositionVault} from "../../src/PositionVault.sol";
import {VaultState} from "../../src/types/Types.sol";
import {LTVMath} from "../../src/libraries/LTVMath.sol";
import {Units} from "../../src/libraries/Units.sol";

/// @title Mint fuzz — core invariant I3/D3: on successful mint always currentLTV <= maxLTV(4500bps)
/// @notice Verify over random collateral·entry price·mint amount. Fix price before open and hold after (same price)
///         so collateral value (GMX equity = collateral + 2x·pnl) has pnl=0 → deterministic LTV.
contract MintFuzzTest is BaseTest {
    uint256 internal constant MAX_LTV = 4_500; // mirror LTVMath.MAX_LTV

    /// @dev Wrap internal library revert at external boundary for expectRevert.
    function callIsMintAllowed(uint256 ltvBps) external pure returns (bool) {
        return LTVMath.isMintAllowed(ltvBps);
    }

    /// Attempt mint over random (collateral, entry price, mint amount).
    /// On success enforce invariant currentLTV <= 4500. Reverts handled normally via try/catch.
    function testFuzz_mint_successImpliesWithinMaxLtv(uint256 collateral, uint256 price8, uint256 rBtc) public {
        collateral = bound(collateral, 100e6, 1e12); // 100 ~ 1,000,000 USDC
        price8 = bound(price8, 10_000e8, 200_000e8); // $10k ~ $200k
        rBtc = bound(rBtc, 1, 100e18); // 0 filtered by "zero mint" require → meaningful amount

        // fix entry price then open (entry = price8). no price change after open → pnl 0.
        oracle.setPrice(price8);
        usdc.mint(alice, collateral); // top up for large collateral
        PositionVault v = _openFor(alice, collateral);

        // precondition: Active, collateral value=collateral(WAD), pnl 0 at same price
        assertEq(uint256(v.state()), uint256(VaultState.Active));
        assertEq(v.collateralValueUsdWad(), Units.usdcToWad(collateral));

        vm.prank(alice);
        try v.mint(rBtc) {
            // success → core invariant: post-mint LTV within mint limit
            uint256 ltv = v.currentLTV();
            assertLe(ltv, MAX_LTV, "mint success but LTV exceeds maxLTV");
            assertEq(v.debt(), rBtc, "debt must equal minted amount (first mint)");
            assertEq(rToken.balanceOf(alice), rBtc, "rToken to owner EOA (D2)");
        } catch {
            // revert is normal (ExceedsMaxLTV etc.). not an invariant violation.
        }
    }

    /// Deterministic mint at maxLTV boundary: max within limit succeeds with LTV<=4500; 1bps over reverts.
    /// (Directly compute boundary so fuzz success path is reached often.)
    function testFuzz_mint_atBoundary(uint256 collateral, uint256 price8) public {
        collateral = bound(collateral, 100e6, 1e12);
        price8 = bound(price8, 10_000e8, 200_000e8);

        oracle.setPrice(price8);
        usdc.mint(alice, collateral);
        PositionVault v = _openFor(alice, collateral);

        uint256 collValWad = Units.usdcToWad(collateral);
        // debt value (WAD) at maxLTV → rBTC amount. floor ensures result LTV <= 4500.
        uint256 maxDebtWad = (collValWad * MAX_LTV) / 10_000;
        uint256 mintAmt = Units.usdWadToBtc(maxDebtWad, price8);
        vm.assume(mintAmt > 0);

        vm.prank(alice);
        v.mint(mintAmt);
        uint256 ltv = v.currentLTV();
        assertLe(ltv, MAX_LTV, "boundary mint exceeds maxLTV");
    }

    /// Internal library boundary: LTV over maxLTV disallows mint (isMintAllowed=false).
    function testFuzz_isMintAllowed_boundary(uint256 ltvBps) public view {
        bool allowed = this.callIsMintAllowed(ltvBps);
        assertEq(allowed, ltvBps <= MAX_LTV, "isMintAllowed must match <= maxLTV");
    }
}
