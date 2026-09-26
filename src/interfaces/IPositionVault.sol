// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {VaultState, GmxConfig} from "../types/Types.sol";
import {IPriceOracle} from "./IPriceOracle.sol";
import {IGmxAdapter} from "./IGmxAdapter.sol";

/// @title IPositionVault — per-user isolated Vault (docs/10)
interface IPositionVault {
    // ── Initialization (factory calls right after clone, Initializable guard) ──
    function initialize(
        address owner_,
        address factory_,
        IGmxAdapter gmx_,
        IPriceOracle oracle_,
        address usdc_,
        address rToken_,
        bytes32 marketId_,
        uint16 maxLtvBps_,
        uint16 lltvBps_
    ) external;

    // ── User actions (onlyOwner) ──
    function deposit(uint256 usdcAmount) external;
    function openPosition() external payable; // payable: GMX exec fee
    function mint(uint256 rBtcAmount) external; // LTV limit check
    function repay(uint256 rBtcAmount) external; // rBTC burn → debt reduction (inverse of mint)
    function closePosition() external payable;

    // ── Liquidation (public, when conditions met) ──
    function liquidate() external payable;

    // ── Settling timeout recovery (public, docs/60 OQ-6) ──
    function cancelStuckOrder() external;

    // ── GMX callbacks (onlyGmx) ──
    function afterOrderExecution(bytes32 orderKey) external;
    function afterOrderCancellation(bytes32 orderKey) external;

    // ── Views ──
    function owner() external view returns (address);
    function collateral() external view returns (uint256); // USDC (6dec)
    function debt() external view returns (uint256); // rBTC (18dec)
    function state() external view returns (VaultState);
    function collateralValueUsdWad() external view returns (uint256);
    function debtValueUsdWad() external view returns (uint256);
    function currentLTV() external view returns (uint256); // bps
    function healthFactor() external view returns (uint256); // 1e18
}
