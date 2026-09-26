// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {PositionVault} from "../../src/PositionVault.sol";
import {RToken} from "../../src/RToken.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {VaultState} from "../../src/types/Types.sol";

/// @title MultiAsset — Wave 1: prove ETH market follows same code path as BTC.
/// @notice Per-market oracle·rToken·LTV injected; same user holds isolated BTC·ETH vaults.
contract MultiAssetTest is BaseTest {
    bytes32 internal constant ETHID = keccak256("ETH");
    uint16 internal constant ETH_MAX_LTV = 5_000; // 50%
    uint16 internal constant ETH_LLTV = 7_000; // 70%

    MockPriceOracle ethOracle;
    RToken rEth;

    function setUp() public override {
        super.setUp();
        ethOracle = new MockPriceOracle(3_000e8); // ETH $3,000
        vm.prank(admin);
        rEth = RToken(factory.addMarket(ETHID, IPriceOracle(address(ethOracle)), "RYex ETH", "rETH", ETH_MAX_LTV, ETH_LLTV));
        gmx.registerMarket(ETHID, IPriceOracle(address(ethOracle)));
    }

    function _openEth(address user, uint256 amount) internal returns (PositionVault v) {
        usdc.mint(user, amount);
        vm.startPrank(user);
        v = PositionVault(payable(factory.createVault(ETHID)));
        usdc.approve(address(v), amount);
        v.deposit(amount);
        v.openPosition{value: FEE}();
        vm.stopPrank();
        gmx.executeOrder(gmx.lastOrderKey());
    }

    /// Market config injected into vault + same open→mint→repay path at ETH price.
    function test_eth_openMintRepay_sameCodePath() public {
        PositionVault v = _openEth(alice, 10_000e6);
        assertEq(uint256(v.state()), uint256(VaultState.Active));
        assertEq(v.marketId(), ETHID);
        assertEq(v.maxLtvBps(), ETH_MAX_LTV);
        assertEq(v.lltvBps(), ETH_LLTV);

        vm.prank(alice);
        v.mint(1e18); // 1 rETH = $3,000 → LTV 30%
        assertEq(rEth.balanceOf(alice), 1e18);
        assertEq(v.debt(), 1e18);
        assertEq(v.currentLTV(), 3000);

        vm.prank(alice);
        v.repay(1e18);
        assertEq(v.debt(), 0);
        assertEq(rEth.balanceOf(alice), 0);
    }

    /// Mint limit per-market (ETH 50%): 48% allowed, 54% ExceedsMaxLTV.
    function test_eth_maxLtv_isMarketSpecific() public {
        PositionVault v = _openEth(alice, 10_000e6);
        vm.prank(alice);
        v.mint(1.6e18); // $4,800 → 48% < 50%
        assertLe(v.currentLTV(), ETH_MAX_LTV);

        vm.prank(alice);
        vm.expectRevert(PositionVault.ExceedsMaxLTV.selector);
        v.mint(0.2e18); // cumulative $5,400 → 54% > 50%
    }

    /// Liquidation threshold also per-market (ETH 70%): ETH price drop → LTV>=70% → liquidate.
    function test_eth_liquidation_atEthLltv() public {
        PositionVault v = _openEth(alice, 10_000e6);
        vm.prank(alice);
        v.mint(1.6e18); // LTV 48%

        ethOracle.setPrice(2_100e8); // -30%: equity $4,000, debt $3,360 → LTV 84% >= 70%
        assertTrue(v.currentLTV() >= ETH_LLTV, "eth liquidatable");

        vm.prank(bob);
        v.liquidate{value: FEE}();
        gmx.executeOrder(gmx.lastOrderKey());
        assertEq(uint256(v.state()), uint256(VaultState.Liquidated));
        assertEq(v.debt(), 0);
    }

    /// Same user's BTC·ETH vaults are independent (one per market, isolated).
    function test_btc_and_eth_vaults_isolated() public {
        PositionVault bv = _openFor(alice, 10_000e6); // BTC (BaseTest helper)
        PositionVault ev = _openEth(alice, 10_000e6); // ETH
        assertTrue(address(bv) != address(ev), "distinct vaults");
        assertEq(bv.marketId(), BTC);
        assertEq(ev.marketId(), ETHID);

        vm.prank(alice);
        bv.mint(0.05e18); // rBTC, $3,000 @ $60k → 30%
        vm.prank(alice);
        ev.mint(1e18); // rETH, $3,000 @ $3k → 30%

        assertEq(rToken.balanceOf(alice), 0.05e18); // rBTC
        assertEq(rEth.balanceOf(alice), 1e18); // rETH (separate token)
        assertEq(bv.debt(), 0.05e18);
        assertEq(ev.debt(), 1e18);
        assertEq(factory.vaultOf(alice, BTC), address(bv));
        assertEq(factory.vaultOf(alice, ETHID), address(ev));
    }
}
