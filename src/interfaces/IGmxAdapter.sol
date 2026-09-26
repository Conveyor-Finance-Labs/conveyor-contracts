// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IGmxAdapter — Vault's single entry point to GMX (docs/50 §2)
/// @notice Swap LocalGmxMock (local/instant) ↔ GmxV2Adapter (fork/devnet/mainnet) behind the same interface.
///         This boundary absorbs GMX encoding, key derivation, and 2-step async (ACL) → Vault core unchanged.
interface IGmxAdapter {
    /// @notice Create 2x long open order (per market). exec fee via msg.value. caller=Vault. Returns orderKey.
    function createOpenOrder(bytes32 marketId, uint256 collateralUsdc, uint256 indexPrice8)
        external
        payable
        returns (bytes32 orderKey);

    /// @notice Create full position close (liquidation) order. Returns orderKey.
    function createCloseOrder(bytes32 positionKey) external payable returns (bytes32 orderKey);

    /// @notice Position net value (USD WAD). Collateral value source for HF calculation (docs/60 OQ-2 hybrid).
    /// @dev LocalGmxMock uses MockPriceOracle linear model; GmxV2Adapter uses GMX Reader.
    function getPositionValueUsd(bytes32 positionKey) external view returns (uint256 valueWad);

    /// @notice Long position key for account in the given market.
    function positionKey(address account, bytes32 marketId) external view returns (bytes32);
}
