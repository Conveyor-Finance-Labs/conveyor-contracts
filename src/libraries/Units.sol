// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title Units — unified units and precision (docs/60 OQ-3)
/// @notice All token/price decimal conversions live here. No contract performs raw division directly.
///         Internal USD representation is unified as WAD (1e18).
///         decimals: USDC=6, rBTC=18, Chainlink price=8, GMX price=30, USD(internal)=18(WAD).
library Units {
    uint256 internal constant USDC_DEC = 6;
    uint256 internal constant RBTC_DEC = 18;
    uint256 internal constant PRICE_DEC = 8; // Chainlink BTC/USD
    uint256 internal constant WAD = 18; // Internal USD scale
    uint256 internal constant GMX_PRICE_DEC = 30;

    uint256 internal constant USDC_TO_WAD = 1e12; // 1e18 / 1e6
    uint256 internal constant PRICE_ONE = 1e8; // Price 1.0 (8dec)
    uint256 internal constant GMX_TO_CL = 1e22; // 1e30 / 1e8

    /// @notice USDC(6dec) → USD WAD(1e18)
    function usdcToWad(uint256 usdc) internal pure returns (uint256) {
        return usdc * USDC_TO_WAD;
    }

    /// @notice USD WAD(1e18) → USDC(6dec) (floor)
    function wadToUsdc(uint256 wad) internal pure returns (uint256) {
        return wad / USDC_TO_WAD;
    }

    /// @notice rBTC amount(1e18) × price(8dec) → USD WAD(1e18)
    /// @dev btcWad * price8 / 1e8 — preserves 1e18 scale. Zero-price guard symmetric with usdWadToBtc.
    function btcToUsdWad(uint256 btcWad, uint256 price8) internal pure returns (uint256) {
        require(price8 > 0, "Units: zero price");
        return (btcWad * price8) / PRICE_ONE;
    }

    /// @notice USD WAD(1e18) → rBTC amount(1e18) at price(8dec)
    function usdWadToBtc(uint256 usdWad, uint256 price8) internal pure returns (uint256) {
        require(price8 > 0, "Units: zero price");
        return (usdWad * PRICE_ONE) / price8;
    }

    /// @notice GMX price(30dec) → Chainlink scale(8dec)
    function gmxPriceToChainlink(uint256 gmxPrice30) internal pure returns (uint256) {
        return gmxPrice30 / GMX_TO_CL;
    }
}
