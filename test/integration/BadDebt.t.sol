// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {PositionVault} from "../../src/PositionVault.sol";
import {VaultState} from "../../src/types/Types.sol";

/// @title BadDebtTest — Bad debt settlement path (docs/60 OQ-4, docs/70 liquidation)
/// @notice Scenario where 2x long drops sharply so recovered USDC < debt.
///         _settleLiquidation: repay=recovered(<debt), penalty=0, refund=0, shortfall>0 → BadDebt.
///         Debt ledger zeroed (OQ-1 demo default a), state Liquidated.
contract BadDebtTest is BaseTest {
    // mirror _settleLiquidation event (for vm.expectEmit topic/data verification)
    event Liquidated(address indexed vault, uint256 debtRepaidUsdc, uint256 refundUsdc);
    event BadDebt(address indexed vault, uint256 shortfallUsdc);

    /// @notice Alice 10k open + mint 0.05 → price drops to $30,300 (near 2x liquidation price).
    ///         GMX recovery 100 USDC < debt 1,515 USDC → refund 0, BadDebt(1,415),
    ///         debt 0, state Liquidated.
    /// @dev Entry $60k 2x long: at exactly $30k price equity is 0 so not liquidatable
    ///      (collateralValueUsdWad()==0 → LTVMath.currentLTV revert). So use $30,300 (slightly above)
    ///      where recovery is positive but far below debt to clearly reproduce bad-debt path.
    function test_badDebt_recoveryBelowDebt_refundZero_emitsBadDebt() public {
        PositionVault av = _openFor(alice, 10_000e6);
        vm.prank(alice);
        av.mint(0.05e18); // at $60k: debt $3,000, LTV 30%

        // accounting check: after open collateral USDC on GMX, Vault balance 0
        assertEq(usdc.balanceOf(address(av)), 0, "vault holds no usdc pre-settle");

        // price $60k → $30,300: 2x equity recovery = 100 USDC, debt = 0.05*$30,300 = $1,515
        oracle.setPrice(30_300e8);

        // liquidatable (LTV >= LLTV 6500). recovery less than debt.
        assertTrue(av.currentLTV() >= 6500, "liquidatable");
        assertEq(av.debtValueUsdWad(), 1_515e18, "debt value $1,515");
        assertEq(av.collateralValueUsdWad(), 100e18, "position equity $100");

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 factoryBefore = usdc.balanceOf(address(factory));
        uint256 bobBefore = usdc.balanceOf(bob);

        // execute liquidation + GMX close fill
        vm.prank(bob); // arbitrary liquidator
        av.liquidate{value: FEE}();

        // declare expected settlement events (recovery 100 full debt repay, refund 0, shortfall 1,415)
        vm.expectEmit(true, false, false, true, address(av));
        emit Liquidated(address(av), 100e6, 0);
        vm.expectEmit(true, false, false, true, address(av));
        emit BadDebt(address(av), 1_415e6);
        gmx.executeOrder(gmx.lastOrderKey());

        // ── post-settlement invariants ──
        assertEq(uint256(av.state()), uint256(VaultState.Liquidated), "state Liquidated");
        assertEq(av.debt(), 0, "debt zeroed");
        assertEq(av.collateral(), 0, "collateral zeroed");

        // refund 0: owner(alice) USDC unchanged
        assertEq(usdc.balanceOf(alice), aliceBefore, "no refund to owner");
        // bad debt so no penalty distribution: liquidator/protocol share 0
        assertEq(usdc.balanceOf(bob), bobBefore, "no liquidator penalty");
        assertEq(usdc.balanceOf(address(factory)), factoryBefore, "no protocol penalty");
        // full 100 USDC recovery counted as repay; OQ-1(a) demo model does not burn rToken
        // so repay USDC stays in Vault, not sent out (=Liquidated event repay=100).
        // (normal liquidation demo also leaves repay 1950 USDC in Vault — same meaning.)
        assertEq(usdc.balanceOf(address(av)), 100e6, "repay USDC retained in vault (OQ-1(a): no rToken burn)");
    }

    /// @notice At exactly GMX liquidation price $30,000 with 2x equity 0, vault must still be **liquidatable** (full bad debt).
    /// @dev currentLTV() returns max on full wipeout → underwater vault not stuck (G1/G6).
    function test_atExactWipeoutPrice_isLiquidatable_fullBadDebt() public {
        PositionVault av = _openFor(alice, 10_000e6);
        vm.prank(alice);
        av.mint(0.05e18);

        oracle.setPrice(30_000e8); // 2x equity == 0
        assertEq(av.collateralValueUsdWad(), 0, "equity wiped to zero");
        assertEq(av.currentLTV(), type(uint256).max, "max risk, not revert");
        assertLt(av.healthFactor(), 1e18, "HF below 1");

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(bob);
        av.liquidate{value: FEE}();

        // recovery 0, full $1,500 debt bad debt, refund 0
        vm.expectEmit(true, false, false, true, address(av));
        emit Liquidated(address(av), 0, 0);
        vm.expectEmit(true, false, false, true, address(av));
        emit BadDebt(address(av), 1_500e6);
        gmx.executeOrder(gmx.lastOrderKey());

        assertEq(uint256(av.state()), uint256(VaultState.Liquidated), "Liquidated");
        assertEq(av.debt(), 0, "debt zeroed");
        assertEq(usdc.balanceOf(alice), aliceBefore, "no refund");
    }
}
