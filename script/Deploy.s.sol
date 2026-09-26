// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {PositionVault} from "../src/PositionVault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockPriceOracle} from "../src/oracles/MockPriceOracle.sol";
import {LocalGmxMock} from "../src/mocks/LocalGmxMock.sol";
import {MockSwapPool} from "../src/mocks/MockSwapPool.sol";
import {IGmxAdapter} from "../src/interfaces/IGmxAdapter.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Deploy — local-mock multi-asset deploy + addresses manifest (markets map) (docs/40 §7, Wave 1)
/// @dev RYEX_PROFILE=local-mock forge script script/Deploy.s.sol --broadcast --rpc-url <anvil>
contract Deploy is Script {
    bytes32 constant BTC = keccak256("BTC");
    bytes32 constant ETH = keccak256("ETH");

    // Deploy results (for serialization) — per market.
    struct Mkt {
        bytes32 id;
        address oracle;
        address rToken;
        address swapPool;
        uint16 maxLtvBps;
        uint16 lltvBps;
    }

    VaultFactory factory;
    PositionVault impl;
    MockUSDC usdc;
    LocalGmxMock gmx;
    Mkt btc;
    Mkt eth;

    function run() external {
        string memory profile = vm.envOr("RYEX_PROFILE", string("local-mock"));
        uint256 btcPrice = vm.envOr("BTC_PRICE", uint256(60_000e8));
        uint256 ethPrice = vm.envOr("ETH_PRICE", uint256(3_000e8));

        vm.startBroadcast();
        usdc = new MockUSDC();
        gmx = new LocalGmxMock(usdc);
        impl = new PositionVault();
        factory = new VaultFactory(address(impl), IGmxAdapter(address(gmx)), address(usdc), msg.sender);
        btc = _addMarket(BTC, "RYex BTC", "rBTC", btcPrice, 4_500, 6_500);
        eth = _addMarket(ETH, "RYex ETH", "rETH", ethPrice, 5_000, 7_000);
        vm.stopBroadcast();

        _write(profile);
        console2.log("Deployed profile:", profile);
        console2.log("  VaultFactory:", address(factory));
        console2.log("  USDC        :", address(usdc));
        console2.log("  GmxAdapter  :", address(gmx));
        console2.log("  BTC rToken  :", btc.rToken);
        console2.log("  BTC swapPool:", btc.swapPool);
        console2.log("  ETH rToken  :", eth.rToken);
        console2.log("  ETH swapPool:", eth.swapPool);
    }

    /// Register market: deploy oracle → factory.addMarket → gmx price register → swap pool (seed 2M USDC float).
    function _addMarket(bytes32 id, string memory name, string memory symbol, uint256 price8, uint16 maxLtv, uint16 lltv)
        internal
        returns (Mkt memory m)
    {
        MockPriceOracle oracle = new MockPriceOracle(price8);
        address rToken = factory.addMarket(id, IPriceOracle(address(oracle)), name, symbol, maxLtv, lltv);
        gmx.registerMarket(id, IPriceOracle(address(oracle)));
        MockSwapPool pool = new MockSwapPool(IPriceOracle(address(oracle)), IERC20(rToken), IERC20(address(usdc)));
        usdc.mint(address(pool), 2_000_000e6); // ensure rToken→USDC exit liquidity
        m = Mkt(id, address(oracle), rToken, address(pool), maxLtv, lltv);
    }

    function _marketJson(string memory key, Mkt memory m) internal returns (string memory) {
        vm.serializeBytes32(key, "marketId", m.id);
        vm.serializeAddress(key, "oracle", m.oracle);
        vm.serializeAddress(key, "rToken", m.rToken);
        vm.serializeAddress(key, "swapPool", m.swapPool);
        vm.serializeUint(key, "maxLtvBps", m.maxLtvBps);
        return vm.serializeUint(key, "lltvBps", m.lltvBps);
    }

    function _write(string memory profile) internal {
        string memory btcJson = _marketJson("btcMkt", btc);
        string memory ethJson = _marketJson("ethMkt", eth);
        vm.serializeString("markets", "BTC", btcJson);
        string memory marketsJson = vm.serializeString("markets", "ETH", ethJson);

        string memory root = "root";
        vm.serializeString(root, "profile", profile);
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "vaultFactory", address(factory));
        vm.serializeAddress(root, "positionVaultImpl", address(impl));
        vm.serializeAddress(root, "gmxAdapter", address(gmx));
        vm.serializeAddress(root, "usdc", address(usdc));
        string memory out = vm.serializeString(root, "markets", marketsJson);
        vm.writeJson(out, string.concat("addresses/", profile, ".json"));
    }
}
