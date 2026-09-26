// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {PositionVault} from "../src/PositionVault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {LocalGmxMock} from "../src/mocks/LocalGmxMock.sol";

/// @title SeedDemo — seed Alice·Bob positions on live anvil (browser demo).
/// @dev Run after Deploy: forge script script/SeedDemo.s.sol --broadcast --rpc-url <anvil>
///      Alice=anvil[0](=oracle owner), Bob=anvil[1]. Addresses loaded from addresses/local-mock.json.
contract SeedDemo is Script {
    uint256 constant ALICE_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant BOB_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant FEE = 0.0003 ether;
    bytes32 constant BTC = keccak256("BTC");

    function run() external {
        string memory json = vm.readFile("addresses/local-mock.json");
        VaultFactory factory = VaultFactory(vm.parseJsonAddress(json, ".vaultFactory"));
        MockUSDC usdc = MockUSDC(vm.parseJsonAddress(json, ".usdc"));
        LocalGmxMock gmx = LocalGmxMock(vm.parseJsonAddress(json, ".gmxAdapter"));

        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // ── Alice: 10K → 2x long → mint 0.05 rBTC ──
        vm.startBroadcast(ALICE_PK);
        usdc.mint(alice, 10_000e6);
        PositionVault av = PositionVault(payable(factory.createVault(BTC)));
        usdc.approve(address(av), 10_000e6);
        av.deposit(10_000e6);
        av.openPosition{value: FEE}();
        vm.stopBroadcast();
        bytes32 aKey = gmx.lastOrderKey();
        vm.broadcast(ALICE_PK);
        gmx.executeOrder(aKey); // settle open → Active
        vm.broadcast(ALICE_PK);
        av.mint(0.05e18);

        // ── Bob: 5K → 2x long, no mint ──
        vm.startBroadcast(BOB_PK);
        usdc.mint(bob, 5_000e6);
        PositionVault bv = PositionVault(payable(factory.createVault(BTC)));
        usdc.approve(address(bv), 5_000e6);
        bv.deposit(5_000e6);
        bv.openPosition{value: FEE}();
        vm.stopBroadcast();
        bytes32 bKey = gmx.lastOrderKey();
        vm.broadcast(BOB_PK);
        gmx.executeOrder(bKey); // settle open → Active
    }
}
