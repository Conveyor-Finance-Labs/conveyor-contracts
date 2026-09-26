// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {PositionVault} from "../src/PositionVault.sol";
import {RToken} from "../src/RToken.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockPriceOracle} from "../src/oracles/MockPriceOracle.sol";
import {LocalGmxMock} from "../src/mocks/LocalGmxMock.sol";
import {IGmxAdapter} from "../src/interfaces/IGmxAdapter.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

/// @title DemoScenario — `make demo` end-to-end (docs/5, docs/40 §7)
/// @notice Step-by-step HF logging + user asset settlement table + Bob Vault isolation comparison.
/// @dev Simulation (no node required): forge script script/DemoScenario.s.sol
contract DemoScenario is Script {
    MockUSDC usdc;
    MockPriceOracle oracle;
    LocalGmxMock gmx;
    VaultFactory factory;
    RToken rToken;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0x4EE9E5);
    uint256 constant FEE = 0.0003 ether;
    bytes32 constant BTC = keccak256("BTC");

    function run() external {
        _deploy();
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 5_000e6);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(keeper, 1 ether);

        console2.log("================ RYex DEMO (local-mock) ================");
        console2.log("BTC entry price: $", oracle.btcPrice() / 1e8);

        // ── Step 1-2: Alice 10K → 2x long → mint 0.05 rBTC ──
        PositionVault av = _open(alice, 10_000e6);
        console2.log("\n[Alice] opened 2x long, collateral $10,000");
        _logHF("Alice", av);
        vm.prank(alice);
        av.mint(0.05e18);
        console2.log("[Alice] minted 0.05 rBTC (-> EOA balance):", rToken.balanceOf(alice));
        _logHF("Alice", av);

        // ── Step 3: Bob 5K → 2x long, no mint ──
        PositionVault bv = _open(bob, 5_000e6);
        console2.log("\n[Bob] opened 2x long, collateral $5,000 (no mint)");
        _logHF("Bob", bv);

        // ── Step 4: staged price drop → HF tracking ──
        console2.log("\n---------------- price drop ----------------");
        uint256[4] memory steps = [uint256(54_000), 48_000, 42_000, 39_000];
        for (uint256 i = 0; i < steps.length; i++) {
            oracle.setPrice(steps[i] * 1e8);
            console2.log("BTC $", steps[i]);
            _logHF("  Alice", av);
            _logHF("  Bob  ", bv);
        }

        // ── Step 5: Alice liquidation ──
        console2.log("\n---------------- liquidation ----------------");
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 factoryBefore = usdc.balanceOf(address(factory));
        vm.prank(keeper);
        av.liquidate{value: FEE}();
        gmx.executeOrder(gmx.lastOrderKey());

        // ── Settlement table ──
        console2.log("\n=============== SETTLEMENT TABLE ===============");
        console2.log("[Alice] state (4=Liquidated):", uint256(av.state()));
        console2.log("[Alice] debt after          :", av.debt());
        console2.log("[Alice] USDC refunded        :", usdc.balanceOf(alice) - aliceUsdcBefore);
        console2.log("[Alice] rBTC still in wallet :", rToken.balanceOf(alice));
        console2.log("[Proto] penalty to treasury  :", usdc.balanceOf(address(factory)) - factoryBefore);

        // ── Step 6: Bob isolation comparison ──
        console2.log("\n=============== ISOLATION (Bob) ===============");
        console2.log("[Bob] state (2=Active)       :", uint256(bv.state()));
        console2.log("[Bob] debt                   :", bv.debt());
        console2.log("[Bob] collateral (USDC acct) :", bv.collateral());
        console2.log("=> Bob UNAFFECTED by Alice's liquidation (fund isolation)");
        console2.log("===============================================");
    }

    function _deploy() internal {
        usdc = new MockUSDC();
        oracle = new MockPriceOracle(60_000e8);
        gmx = new LocalGmxMock(usdc);
        PositionVault impl = new PositionVault();
        factory =
            new VaultFactory(address(impl), IGmxAdapter(address(gmx)), address(usdc), address(0xADE));
        vm.prank(address(0xADE));
        rToken = RToken(factory.addMarket(BTC, IPriceOracle(address(oracle)), "RYex BTC", "rBTC", 4_500, 6_500));
        gmx.registerMarket(BTC, IPriceOracle(address(oracle)));
    }

    function _open(address user, uint256 amount) internal returns (PositionVault v) {
        vm.startPrank(user);
        v = PositionVault(payable(factory.createVault(BTC)));
        usdc.approve(address(v), amount);
        v.deposit(amount);
        v.openPosition{value: FEE}();
        vm.stopPrank();
        gmx.executeOrder(gmx.lastOrderKey());
    }

    function _logHF(string memory who, PositionVault v) internal view {
        uint256 hf = v.healthFactor();
        // HF is 1e18 scale. max (debt==0) shown as large number.
        if (hf == type(uint256).max) {
            console2.log(string.concat(who, " HF: inf (no debt), LTV bps:"), v.currentLTV());
        } else {
            console2.log(string.concat(who, " HF x1e3:"), (hf * 1000) / 1e18, "LTV bps:", v.currentLTV());
        }
    }
}
