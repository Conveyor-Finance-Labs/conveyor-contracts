// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {PositionVault} from "../src/PositionVault.sol";
import {RToken} from "../src/RToken.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockPriceOracle} from "../src/oracles/MockPriceOracle.sol";
import {LocalGmxMock} from "../src/mocks/LocalGmxMock.sol";
import {MockSwapPool} from "../src/mocks/MockSwapPool.sol";
import {IGmxAdapter} from "../src/interfaces/IGmxAdapter.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultState} from "../src/types/Types.sol";

/// @title CapitalLifecycle — Wave 0 demo (open→mint→swap→repay→close), no node required.
/// @notice Validate and log new features (repay·MockSwapPool) end-to-end with numbers.
///         Alice = full capital lifecycle (repay→close→principal recovery).
///         Bob   = swap composability (rBTC→USDC, debt unchanged S2).
/// @dev Run: make demo-capital  (or forge script script/CapitalLifecycle.s.sol)
contract CapitalLifecycle is Script {
    MockUSDC usdc;
    MockPriceOracle oracle;
    LocalGmxMock gmx;
    VaultFactory factory;
    RToken rToken;
    MockSwapPool pool;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant FEE = 0.0003 ether;
    bytes32 constant BTC = keccak256("BTC");

    function run() external {
        _deploy();
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        usdc.mint(address(pool), 2_000_000e6); // pool USDC float
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);

        console2.log("============ RYex Wave 0 - Capital Lifecycle ============");
        console2.log("BTC price: $", oracle.btcPrice() / 1e8);

        // ───────── Alice: open -> mint -> repay -> close ─────────
        console2.log("\n[Alice] open 2x long, collateral $10,000");
        PositionVault av = _open(alice, 10_000e6);
        vm.prank(alice);
        av.mint(0.05e18);
        console2.log("  mint 0.05 rBTC -> debt(rBTC 1e18):", av.debt());
        console2.log("  wallet rBTC:", rToken.balanceOf(alice), " LTV bps:", av.currentLTV());

        vm.prank(alice);
        av.repay(0.05e18); // full repay (rBTC burn)
        console2.log("  [repay 0.05] debt now:", av.debt(), " wallet rBTC:", rToken.balanceOf(alice));
        require(av.debt() == 0, "debt should be 0 after full repay");

        uint256 beforeClose = usdc.balanceOf(alice);
        vm.prank(alice);
        av.closePosition{value: FEE}(); // allowed because debt is 0
        gmx.executeOrder(gmx.lastOrderKey());
        console2.log("  [close] state (0=Empty):", uint256(av.state()));
        console2.log("  USDC returned to Alice:", usdc.balanceOf(alice) - beforeClose);
        require(av.state() == VaultState.Empty, "vault should be Empty");

        // ───────── Bob: open -> mint -> swap (debt persists, S2) ─────────
        console2.log("\n[Bob] open 2x long, collateral $10,000, mint 0.05 rBTC");
        PositionVault bv = _open(bob, 10_000e6);
        vm.prank(bob);
        bv.mint(0.05e18);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        vm.startPrank(bob);
        rToken.approve(address(pool), 0.05e18);
        uint256 out = pool.swapRBtcForUsdc(0.05e18, 0, bob); // rBTC -> USDC at oracle
        vm.stopPrank();
        console2.log("  [swap 0.05 rBTC] USDC out:", out);
        console2.log("  Bob wallet rBTC now:", rToken.balanceOf(bob), " USDC delta:", usdc.balanceOf(bob) - bobUsdcBefore);
        console2.log("  Bob vault debt STILL (S2):", bv.debt(), " (swap does not touch debt)");
        require(bv.debt() == 0.05e18, "swap must not change debt (S2)");

        console2.log("\n=> repay closes the loan loop; swap exits rBTC to USDC while the position stays open.");
        console2.log("========================================================");
    }

    function _deploy() internal {
        usdc = new MockUSDC();
        oracle = new MockPriceOracle(60_000e8);
        gmx = new LocalGmxMock(usdc);
        PositionVault impl = new PositionVault();
        factory = new VaultFactory(address(impl), IGmxAdapter(address(gmx)), address(usdc), address(0xADE));
        vm.prank(address(0xADE));
        rToken = RToken(factory.addMarket(BTC, IPriceOracle(address(oracle)), "RYex BTC", "rBTC", 4_500, 6_500));
        gmx.registerMarket(BTC, IPriceOracle(address(oracle)));
        pool = new MockSwapPool(IPriceOracle(address(oracle)), IERC20(address(rToken)), IERC20(address(usdc)));
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
}
