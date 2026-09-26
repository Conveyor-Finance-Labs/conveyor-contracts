// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRyexSwapPool} from "../interfaces/IRyexSwapPool.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {Units} from "../libraries/Units.sol";

/// @title MockSwapPool — demo rBTC→USDC oracle 1:1 swap (docs/15 §3)
/// @notice Convert at oracle price (0 fee, no slippage). Holds USDC float (seeded at deploy).
///         Swap does not change Vault.debt (docs/15 S2) — rBTC is EOA-held asset only.
contract MockSwapPool is IRyexSwapPool {
    using SafeERC20 for IERC20;

    IPriceOracle public immutable oracle;
    IERC20 public immutable rBtc;
    IERC20 public immutable usdc;

    error Slippage();

    constructor(IPriceOracle oracle_, IERC20 rBtc_, IERC20 usdc_) {
        oracle = oracle_;
        rBtc = rBtc_;
        usdc = usdc_;
    }

    /// @notice rBTC(18dec) → USDC(6dec) at oracle price. Precision unified via Units (OQ-3).
    function quoteRBtcToUsdc(uint256 rBtcIn) public view returns (uint256) {
        return Units.wadToUsdc(Units.btcToUsdWad(rBtcIn, oracle.btcPrice()));
    }

    function swapRBtcForUsdc(uint256 rBtcIn, uint256 minUsdcOut, address to) external returns (uint256 out) {
        out = quoteRBtcToUsdc(rBtcIn);
        if (out < minUsdcOut) revert Slippage(); // S3
        rBtc.safeTransferFrom(msg.sender, address(this), rBtcIn); // S1
        usdc.safeTransfer(to, out);
        emit Swapped(msg.sender, rBtcIn, out);
    }
}
