// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";
import {IGmxAdapter} from "./IGmxAdapter.sol";

/// @title IVaultFactory — multi-asset market registry + per-user PositionVault clones (docs/10, Wave 1)
interface IVaultFactory {
    event VaultCreated(address indexed owner, bytes32 indexed marketId, address vault);
    event MarketAdded(bytes32 indexed marketId, address oracle, address rToken);

    /// @notice Create and initialize Vault clone for (msg.sender, marketId). One vault per user per market (I1).
    function createVault(bytes32 marketId) external returns (address vault);

    function vaultOf(address owner, bytes32 marketId) external view returns (address);
    function isVault(address vault) external view returns (bool);

    /// @notice Market config lookup.
    function markets(bytes32 marketId)
        external
        view
        returns (bool active, address oracle, address rToken, uint16 maxLtvBps, uint16 lltvBps);

    // Environment-injected dependencies (no hardcoding)
    function gmxAdapter() external view returns (IGmxAdapter);
    function usdc() external view returns (address);
    function paused() external view returns (bool);
}
