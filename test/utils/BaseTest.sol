// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {PositionVault} from "../../src/PositionVault.sol";
import {RToken} from "../../src/RToken.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {LocalGmxMock} from "../../src/mocks/LocalGmxMock.sol";
import {IGmxAdapter} from "../../src/interfaces/IGmxAdapter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {IPositionVault} from "../../src/interfaces/IPositionVault.sol";

/// Shared fixture (docs/41 §3). local-mock stack: MockUSDC + MockOracle + LocalGmxMock.
abstract contract BaseTest is Test {
    MockUSDC usdc;
    MockPriceOracle oracle;
    LocalGmxMock gmx;
    VaultFactory factory;
    RToken rToken;
    PositionVault impl;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant FEE = 0.0003 ether;
    uint256 constant START_PRICE = 60_000e8;

    bytes32 internal constant BTC = keccak256("BTC");
    uint16 internal constant BTC_MAX_LTV = 4_500;
    uint16 internal constant BTC_LLTV = 6_500;

    function setUp() public virtual {
        usdc = new MockUSDC();
        oracle = new MockPriceOracle(START_PRICE);
        gmx = new LocalGmxMock(usdc);
        impl = new PositionVault();
        vm.prank(admin);
        factory = new VaultFactory(address(impl), IGmxAdapter(address(gmx)), address(usdc), admin);
        vm.prank(admin);
        address rt = factory.addMarket(BTC, IPriceOracle(address(oracle)), "RYex BTC", "rBTC", BTC_MAX_LTV, BTC_LLTV);
        rToken = RToken(rt);
        gmx.registerMarket(BTC, IPriceOracle(address(oracle))); // register mock price feed

        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 5_000e6);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
    }

    /// Create Vault (BTC market) + deposit + open + GMX callback (executor) → Active
    function _openFor(address user, uint256 amount) internal returns (PositionVault v) {
        vm.startPrank(user);
        address vaddr = factory.createVault(BTC);
        v = PositionVault(payable(vaddr));
        usdc.approve(vaddr, amount);
        v.deposit(amount);
        v.openPosition{value: FEE}();
        vm.stopPrank();
        gmx.executeOrder(gmx.lastOrderKey()); // simulate GMX fill
    }
}
