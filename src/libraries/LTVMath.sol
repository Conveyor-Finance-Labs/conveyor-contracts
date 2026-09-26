// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title LTVMath — LTV / Health Factor (FROZEN formula, docs/12)
/// @notice Single source of truth for mint allowance and liquidation thresholds. Pure functions (no price oracle dependency).
///         Go `internal/domain/risk` mirrors the same formulas and enforces via differential tests (docs/12 R3).
/// @dev HF = LLTV / currentLTV  →  HF<=1 ⟺ liquidatable. (docs/61 confirmed)
///      Wave 1: thresholds (maxLtv/lltv) are per-market config, passed as parameters.
///      Constants (MAX_LTV/LLTV) preserved as BTC defaults (default overload = BTC market).
library LTVMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_LTV = 4_500; // 45% — BTC mint limit (default)
    uint256 internal constant LLTV = 6_500; // 65% — BTC liquidation threshold (default)

    /// @notice currentLTV (bps). collateralValueUsd==0 → revert (undefined, docs/12 R1)
    /// @dev collateral/debt values must share the same scale (Units WAD recommended). Scale cancels in the ratio.
    function currentLTV(uint256 collateralValueUsd, uint256 debtValueUsd) internal pure returns (uint256) {
        require(collateralValueUsd > 0, "LTV: no collateral");
        return (debtValueUsd * BPS) / collateralValueUsd;
    }

    // ── Per-market threshold variants (Wave 1, used by core path) ──

    /// @notice Health Factor scaled by 1e18 at given lltv. debt==0(ltv==0) → max.
    function healthFactor(uint256 ltvBps, uint256 lltvBps) internal pure returns (uint256) {
        if (ltvBps == 0) return type(uint256).max;
        return (lltvBps * 1e18) / ltvBps;
    }

    /// @notice Liquidatable? currentLTV >= lltv (⟺ HF <= 1, docs/12 R4)
    function isLiquidatable(uint256 ltvBps, uint256 lltvBps) internal pure returns (bool) {
        return ltvBps >= lltvBps;
    }

    /// @notice Mint allowed? currentLTV <= maxLtv (docs/12 R4)
    function isMintAllowed(uint256 ltvBps, uint256 maxLtvBps) internal pure returns (bool) {
        return ltvBps <= maxLtvBps;
    }

    // ── BTC default overloads (frozen tests · default market reference) ──

    function healthFactor(uint256 ltvBps) internal pure returns (uint256) {
        return healthFactor(ltvBps, LLTV);
    }

    function isLiquidatable(uint256 ltvBps) internal pure returns (bool) {
        return isLiquidatable(ltvBps, LLTV);
    }

    function isMintAllowed(uint256 ltvBps) internal pure returns (bool) {
        return isMintAllowed(ltvBps, MAX_LTV);
    }
}
