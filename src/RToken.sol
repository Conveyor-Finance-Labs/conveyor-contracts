// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IRToken} from "./interfaces/IRToken.sol";

/// @title RToken — asset-denominated debt token (docs/11). Per-asset instances (rBTC, rETH, …).
/// @notice Only Vault mints/burns (D1). Mint recipient is owner EOA passed by Vault (D2).
///         Name/symbol injected by VaultFactory at market registration (Wave 1 multi-asset).
contract RToken is ERC20, IRToken {
    IVaultFactory public immutable factory;

    event RBTCMinted(address indexed vault, address indexed to, uint256 amount);
    event RBTCBurned(address indexed vault, address indexed from, uint256 amount);

    error NotVault();

    constructor(IVaultFactory factory_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        factory = factory_;
    }

    modifier onlyVault() {
        if (!factory.isVault(msg.sender)) revert NotVault(); // D1
        _;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
        emit RBTCMinted(msg.sender, to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
        emit RBTCBurned(msg.sender, from, amount);
    }

    // Resolve explicit override (IERC20 vs ERC20)
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
