// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IRyexSwapPool — rBTC↔USDC swap pool boundary (docs/15 §3)
/// @notice Demo uses MockSwapPool (oracle 1:1). RYEX team's real pool swaps in via same interface (no code changes).
interface IRyexSwapPool {
    event Swapped(address indexed user, uint256 rBtcIn, uint256 usdcOut);

    /// @notice rBTC in → USDC out. User EOA calls directly (rBTC approve required).
    function swapRBtcForUsdc(uint256 rBtcIn, uint256 minUsdcOut, address to) external returns (uint256 usdcOut);

    /// @notice Quote (view). Expected USDC output for given rBTC input.
    function quoteRBtcToUsdc(uint256 rBtcIn) external view returns (uint256 usdcOut);
}
