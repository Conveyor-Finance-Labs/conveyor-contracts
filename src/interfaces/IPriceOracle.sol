// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IPriceOracle — BTC price abstraction (docs/14)
/// @notice Vault and Risk never touch Chainlink directly; they depend only on this interface.
///         Swap implementations per environment: MockPriceOracle ↔ ChainlinkPriceOracle (no code changes).
interface IPriceOracle {
    /// @return price BTC/USD, 8 decimals. Implementations reject 0/stale (fail-safe, docs/70 §4.1)
    function btcPrice() external view returns (uint256 price);
    function decimals() external view returns (uint8);
}
