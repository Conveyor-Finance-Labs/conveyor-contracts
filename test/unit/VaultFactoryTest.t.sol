// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {IGmxAdapter} from "../../src/interfaces/IGmxAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// VaultFactory unit tests (Wave 1 multi-asset): one vault per user per market (I1), market registry, pause, onlyOwner.
contract VaultFactoryTest is BaseTest {
    bytes32 internal constant ETHID = keccak256("ETH");

    function _addEth() internal returns (address rt) {
        vm.prank(admin);
        rt = factory.addMarket(ETHID, IPriceOracle(address(oracle)), "RYex ETH", "rETH", 5_000, 7_000);
    }

    // ── createVault / mapping ──

    function test_createVault_setsMappings() public {
        vm.prank(alice);
        address vault = factory.createVault(BTC);

        assertTrue(vault != address(0), "vault deployed");
        assertEq(factory.vaultOf(alice, BTC), vault, "vaultOf maps (owner,market) -> vault");
        assertTrue(factory.isVault(vault), "isVault true");
    }

    function test_createVault_twice_sameMarket_reverts_VaultExists() public {
        vm.startPrank(alice);
        factory.createVault(BTC);
        vm.expectRevert(VaultFactory.VaultExists.selector);
        factory.createVault(BTC); // I1: one vault per user per market
        vm.stopPrank();
    }

    function test_createVault_distinctUsers_getDistinctVaults() public {
        vm.prank(alice);
        address av = factory.createVault(BTC);
        vm.prank(bob);
        address bv = factory.createVault(BTC);
        assertTrue(av != bv, "distinct vaults per user");
        assertEq(factory.vaultOf(alice, BTC), av);
        assertEq(factory.vaultOf(bob, BTC), bv);
    }

    function test_createVault_sameUser_differentMarkets_ok() public {
        _addEth();
        vm.startPrank(alice);
        address bvault = factory.createVault(BTC);
        address evault = factory.createVault(ETHID);
        vm.stopPrank();
        assertTrue(bvault != evault, "per-market vaults distinct");
        assertEq(factory.vaultOf(alice, BTC), bvault);
        assertEq(factory.vaultOf(alice, ETHID), evault);
    }

    function test_createVault_unknownMarket_reverts_NoMarket() public {
        vm.prank(alice);
        vm.expectRevert(VaultFactory.NoMarket.selector);
        factory.createVault(keccak256("NOPE"));
    }

    function test_mappings_defaultZero_forUnknownUser() public {
        assertEq(factory.vaultOf(alice, BTC), address(0), "no vault before create");
        assertFalse(factory.isVault(makeAddr("randomAddr")), "arbitrary addr not a vault");
    }

    // ── addMarket ──

    function test_addMarket_deploysRToken_andRegisters() public {
        address rt = _addEth();
        assertTrue(rt != address(0), "rToken deployed");
        (bool active, address oracle_, address rtok, uint16 maxLtv, uint16 lltv) = factory.markets(ETHID);
        assertTrue(active);
        assertEq(oracle_, address(oracle));
        assertEq(rtok, rt);
        assertEq(maxLtv, 5_000);
        assertEq(lltv, 7_000);
        assertEq(factory.marketCount(), 2); // BTC(BaseTest) + ETH
    }

    function test_addMarket_duplicate_reverts_MarketExists() public {
        vm.prank(admin);
        vm.expectRevert(VaultFactory.MarketExists.selector);
        factory.addMarket(BTC, IPriceOracle(address(oracle)), "RYex BTC", "rBTC", 4_500, 6_500);
    }

    function test_addMarket_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.addMarket(ETHID, IPriceOracle(address(oracle)), "RYex ETH", "rETH", 5_000, 7_000);
    }

    // ── pause ──

    function test_pause_blocksCreateVault() public {
        vm.prank(admin);
        factory.pause();
        assertTrue(factory.paused());

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createVault(BTC);
    }

    function test_unpause_restoresCreateVault() public {
        vm.prank(admin);
        factory.pause();
        vm.prank(admin);
        factory.unpause();
        assertFalse(factory.paused());

        vm.prank(alice);
        address vault = factory.createVault(BTC);
        assertEq(factory.vaultOf(alice, BTC), vault);
    }

    // ── onlyOwner guard ──

    function test_setGmxAdapter_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setGmxAdapter(IGmxAdapter(makeAddr("newGmx")));
    }

    function test_pause_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.pause();
    }
}
