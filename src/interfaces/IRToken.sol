// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IRToken — rBTC debt token (docs/11)
interface IRToken is IERC20 {
    function mint(address to, uint256 amount) external; // onlyVault
    function burn(address from, uint256 amount) external; // onlyVault
}
