// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Units} from "../../src/libraries/Units.sol";

/// docs/41 unit round-trip (OQ-3)
contract UnitsTest is Test {
    function test_usdcToWad_known() public pure {
        assertEq(Units.usdcToWad(10_000e6), 10_000e18);
    }

    function test_btcToUsdWad_known() public pure {
        // 0.05 BTC @ $60,000 → $3000 wad
        assertEq(Units.btcToUsdWad(0.05e18, 60_000e8), 3_000e18);
    }

    function test_usdWadToBtc_known() public pure {
        // $3000 @ $60,000 → 0.05 BTC
        assertEq(Units.usdWadToBtc(3_000e18, 60_000e8), 0.05e18);
    }

    function test_gmxPriceToChainlink() public pure {
        // GMX 30dec $60,000 → 8dec
        assertEq(Units.gmxPriceToChainlink(60_000e30), 60_000e8);
    }

    function extUsdWadToBtc(uint256 w, uint256 p) external pure returns (uint256) {
        return Units.usdWadToBtc(w, p);
    }

    function test_usdWadToBtc_zeroPrice_reverts() public {
        vm.expectRevert(bytes("Units: zero price"));
        this.extUsdWadToBtc(1e18, 0);
    }

    function testFuzz_usdc_roundtrip(uint256 usdc) public pure {
        usdc = bound(usdc, 0, 1e24);
        assertEq(Units.wadToUsdc(Units.usdcToWad(usdc)), usdc);
    }

    function testFuzz_btc_roundtrip(uint256 btcWad, uint256 price8) public pure {
        btcWad = bound(btcWad, 0, 1e27);
        price8 = bound(price8, 1e8, 1_000_000e8);
        uint256 usd = Units.btcToUsdWad(btcWad, price8);
        // reverse conversion allows ±1 wei from rounding
        uint256 back = Units.usdWadToBtc(usd, price8);
        assertApproxEqAbs(back, btcWad, 1e6);
    }
}
