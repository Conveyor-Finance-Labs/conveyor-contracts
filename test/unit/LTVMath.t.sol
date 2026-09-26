// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LTVMath} from "../../src/libraries/LTVMath.sol";

/// docs/41 R-U1..R-U4, R-FUZZ
contract LTVMathTest is Test {
    function extCurrentLTV(uint256 c, uint256 d) external pure returns (uint256) {
        return LTVMath.currentLTV(c, d);
    }

    function test_currentLTV_zeroCollateral_reverts() public {
        vm.expectRevert(bytes("LTV: no collateral"));
        this.extCurrentLTV(0, 1000e18);
    }

    function test_hf_zeroDebt_isMax() public pure {
        assertEq(LTVMath.healthFactor(0), type(uint256).max);
    }

    function test_hf_atLLTV_isOne() public pure {
        // currentLTV == LLTV(6500) → HF == 1e18
        assertEq(LTVMath.healthFactor(6500), 1e18);
        assertTrue(LTVMath.isLiquidatable(6500));
    }

    function test_maxLtv_boundary() public pure {
        assertTrue(LTVMath.isMintAllowed(4500)); // == maxLTV allowed
        assertFalse(LTVMath.isMintAllowed(4501));
    }

    function test_lltv_boundary() public pure {
        assertFalse(LTVMath.isLiquidatable(6499));
        assertTrue(LTVMath.isLiquidatable(6500));
    }

    function test_knownCase_30pct() public pure {
        // debt $3000, collateral $10000 → LTV 30%
        uint256 ltv = LTVMath.currentLTV(10_000e18, 3_000e18);
        assertEq(ltv, 3000);
        assertTrue(LTVMath.isMintAllowed(ltv));
        assertFalse(LTVMath.isLiquidatable(ltv));
    }

    function testFuzz_ltv_monotonic_and_safe(uint256 collat, uint256 debt) public pure {
        collat = bound(collat, 1, 1e30);
        debt = bound(debt, 0, 1e30);
        uint256 ltv = LTVMath.currentLTV(collat, debt);
        if (debt == 0) assertEq(LTVMath.healthFactor(ltv), type(uint256).max);
        // debt↑ ⇒ LTV monotonically increases
        uint256 ltv2 = LTVMath.currentLTV(collat, debt + 1e18);
        assertGe(ltv2, ltv);
    }
}
