// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IGmxAdapter} from "./interfaces/IGmxAdapter.sol";
import {IPositionVault} from "./interfaces/IPositionVault.sol";
import {RToken} from "./RToken.sol";
import {Market} from "./types/Types.sol";

/// @title VaultFactory — multi-asset market registry + per-user PositionVault clones (docs/10, Wave 1)
/// @notice Admin only registers markets, sets parameters, and pauses. No direct user fund withdrawal (G5).
///         Holds per-market asset oracle·rToken·LTV. createVault(marketId) yields isolated (user×market) vaults.
contract VaultFactory is IVaultFactory, Ownable, Pausable {
    address public immutable implementation; // PositionVault logic (immutable, D7)
    IGmxAdapter public gmxAdapter;
    address public usdc;

    mapping(bytes32 => Market) public markets; // marketId => config
    bytes32[] public marketIds; // Registration order (for enumeration)
    mapping(address => mapping(bytes32 => address)) public vaultOf; // owner => marketId => vault
    mapping(address => bool) public isVault;

    error VaultExists();
    error ZeroAddress();
    error MarketExists();
    error NoMarket();

    constructor(address implementation_, IGmxAdapter gmx_, address usdc_, address admin_) Ownable(admin_) {
        if (implementation_ == address(0) || usdc_ == address(0) || address(gmx_) == address(0)) {
            revert ZeroAddress();
        }
        implementation = implementation_;
        gmxAdapter = gmx_;
        usdc = usdc_;
    }

    /// @notice Register market. Factory deploys per-asset RToken (consistent isVault guard). marketId = keccak(symbol) recommended.
    /// @dev When using LocalGmxMock, deploy script must also call gmx.registerMarket(marketId, oracle) (mock prices).
    function addMarket(
        bytes32 marketId,
        IPriceOracle oracle,
        string calldata name,
        string calldata symbol,
        uint16 maxLtvBps_,
        uint16 lltvBps_
    ) external onlyOwner returns (address rToken) {
        if (markets[marketId].active) revert MarketExists();
        if (address(oracle) == address(0)) revert ZeroAddress();
        rToken = address(new RToken(this, name, symbol));
        markets[marketId] = Market({
            active: true,
            oracle: address(oracle),
            rToken: rToken,
            maxLtvBps: maxLtvBps_,
            lltvBps: lltvBps_
        });
        marketIds.push(marketId);
        emit MarketAdded(marketId, address(oracle), rToken);
    }

    function createVault(bytes32 marketId) external whenNotPaused returns (address vault) {
        Market memory m = markets[marketId];
        if (!m.active) revert NoMarket();
        if (vaultOf[msg.sender][marketId] != address(0)) revert VaultExists(); // I1: one vault per user per market
        vault = Clones.clone(implementation);
        vaultOf[msg.sender][marketId] = vault;
        isVault[vault] = true;
        IPositionVault(vault).initialize(
            msg.sender, address(this), gmxAdapter, IPriceOracle(m.oracle), usdc, m.rToken, marketId, m.maxLtvBps, m.lltvBps
        );
        emit VaultCreated(msg.sender, marketId, vault);
    }

    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    // ── admin (parameters and pause only; timelock recommended D5) ──

    function setGmxAdapter(IGmxAdapter gmx_) external onlyOwner {
        if (address(gmx_) == address(0)) revert ZeroAddress();
        gmxAdapter = gmx_;
    }

    /// @notice Block new risk. Repay, liquidation, and withdrawal (escape) remain allowed on Vault (docs/70 §5).
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function paused() public view override(IVaultFactory, Pausable) returns (bool) {
        return Pausable.paused();
    }
}
