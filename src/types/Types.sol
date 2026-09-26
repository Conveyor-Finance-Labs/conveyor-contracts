// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @notice Vault lifecycle state (absorbs GMX 2-step async) — docs/10 §6
enum VaultState {
    Empty, // Created, no position
    SettlingOpen, // Awaiting GMX open order callback
    Active, // Position active
    SettlingLiquidate, // Awaiting GMX close (liquidation) order callback
    Liquidated // Liquidation complete

}

/// @notice Pending GMX order kind
enum OrderKind {
    None,
    Open,
    Close,
    Liquidate
}

/// @notice Order awaiting callback
struct PendingOrder {
    OrderKind kind;
    bytes32 orderKey;
    uint256 createdAt; // For Settling timeout recovery — docs/60 OQ-6
}

/// @notice GMX integration config — injected per environment (no hardcoding) docs/40 §3
struct GmxConfig {
    address exchangeRouter;
    address orderHandler; // Callback permission verification
    address reader;
    address dataStore;
    address market; // BTC market token
    address collateralToken; // USDC
}

/// @notice Per-asset market config — VaultFactory registry (Wave 1 multi-asset). Per-asset oracle·rToken·LTV.
struct Market {
    bool active;
    address oracle; // IPriceOracle (asset price feed)
    address rToken; // IRToken (per-asset debt token: rBTC, rETH, …)
    uint16 maxLtvBps; // Mint limit
    uint16 lltvBps; // Liquidation threshold
}
