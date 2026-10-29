// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {LendingMarketV1} from "./legacy/LendingMarketV1.sol";

/**
 * @notice Deploys the contract as it is live today (test/legacy/LendingMarketV1.sol, the baseline
 *         with only the contract name and the two import paths changed), builds up balances and
 *         interest, then upgrades the proxy to the fixed implementation the way the proxy admin would.
 */
contract UpgradeTest is Test {
    uint256 internal constant RATE_PER_SECOND = uint256(0.05e18) / 365 days;

    address internal admin = address(0xA11CE);
    address internal guardian = address(0x6DA12D);
    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    MockERC20 internal base;
    MockERC20 internal weth;
    MockOracle internal wethOracle;

    TransparentUpgradeableProxy internal proxy;

    function setUp() public {
        base = new MockERC20("Base USD", "bUSD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wethOracle = new MockOracle(2_000e18);

        LendingMarketV1 v1 = new LendingMarketV1();
        bytes memory initData = abi.encodeCall(
            LendingMarketV1.initialize,
            (
                admin,
                guardian,
                address(wethOracle),
                address(base),
                address(weth),
                0.8e18,
                1.1e18,
                RATE_PER_SECOND
            )
        );
        proxy = new TransparentUpgradeableProxy(address(v1), admin, initData);
        LendingMarketV1 live = LendingMarketV1(address(proxy));

        base.mint(supplier, 100_000e18);
        vm.startPrank(supplier);
        base.approve(address(proxy), type(uint256).max);
        live.supply(100_000e18);
        vm.stopPrank();

        weth.mint(borrower, 10e18);
        vm.startPrank(borrower);
        weth.approve(address(proxy), type(uint256).max);
        live.supplyCollateral(10e18);
        live.borrow(15_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        live.accrueInterest();
    }

    function test_upgrade_keeps_every_balance_and_fixes_liquidation() public {
        LendingMarketV1 live = LendingMarketV1(address(proxy));

        uint256 borrowIndex = live.baseBorrowIndex();
        uint256 supplyIndex = live.baseSupplyIndex();
        uint256 lastAccrual = live.lastAccrualTime();
        uint256 supplyBalance = live.supplyBalanceOf(supplier);
        uint256 borrowBalance = live.borrowBalanceOf(borrower);
        uint256 totalSupplyPrincipal = live.totalSupplyPrincipal();
        uint256 totalBorrowPrincipal = live.totalBorrowPrincipal();
        assertGt(borrowIndex, 1e18, "no interest accrued before the upgrade");

        LendingMarket fixedImpl = new LendingMarket();
        vm.prank(admin);
        proxy.upgradeTo(address(fixedImpl));
        assertEq(proxy.implementation(), address(fixedImpl));

        LendingMarket market = LendingMarket(address(proxy));

        // Roles, wiring and parameters.
        assertEq(market.admin(), admin);
        assertEq(market.pauseGuardian(), guardian);
        assertEq(address(market.oracle()), address(wethOracle));
        assertEq(address(market.baseToken()), address(base));
        assertEq(address(market.collateralToken()), address(weth));
        assertEq(market.collateralFactor(), 0.8e18);
        assertEq(market.liquidationIncentive(), 1.1e18);
        assertEq(market.borrowRatePerSecond(), RATE_PER_SECOND);
        assertFalse(market.paused());

        // Accrual state, totals and per-account balances.
        assertEq(market.baseBorrowIndex(), borrowIndex);
        assertEq(market.baseSupplyIndex(), supplyIndex);
        assertEq(market.lastAccrualTime(), lastAccrual);
        assertEq(market.totalSupplyPrincipal(), totalSupplyPrincipal);
        assertEq(market.totalBorrowPrincipal(), totalBorrowPrincipal);
        assertEq(market.totalCollateral(), 10e18);
        assertEq(market.supplyBalanceOf(supplier), supplyBalance);
        assertEq(market.borrowBalanceOf(borrower), borrowBalance);
        assertEq(market.collateralBalance(borrower), 10e18);

        // The proxy stays initialized, so nobody can re-run initialize() after the upgrade.
        vm.expectRevert("already initialized");
        market.initialize(
            address(this), address(this), address(wethOracle), address(base), address(weth), 0, 1e18, 0
        );

        // F-1 no longer reproduces on the upgraded proxy: repaying 1,000 at 1,800 seizes 0.611 WETH.
        wethOracle.setPrice(1_800e18);
        base.mint(liquidator, 1_000e18);
        vm.startPrank(liquidator);
        base.approve(address(proxy), type(uint256).max);
        market.liquidate(borrower, 1_000e18);
        vm.stopPrank();
        assertEq(weth.balanceOf(liquidator), (uint256(1_000e18) * 1.1e18) / 1_800e18);

        // Suppliers keep the balance they had before the upgrade and can still withdraw against it.
        vm.prank(supplier);
        market.withdraw(50_000e18);
        assertEq(base.balanceOf(supplier), 50_000e18);
        assertApproxEqAbs(market.supplyBalanceOf(supplier), supplyBalance - 50_000e18, 1);
    }
}
