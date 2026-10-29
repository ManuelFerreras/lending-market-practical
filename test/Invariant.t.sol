// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/// @notice Drives the market with random supply, borrow, repay, collateral moves, liquidations,
///         price moves and time, from three accounts. Calls that the market rejects are skipped.
///         Borrows go close to the limit and runs are 200 calls deep, so price drops lead to real
///         liquidations (checked by counting them while writing this).
contract MarketHandler is Test {
    LendingMarket internal market;
    MockERC20 internal base;
    MockERC20 internal weth;
    MockOracle internal oracle;

    address[3] internal actors = [address(0xA1), address(0xB2), address(0xC3)];
    int256 internal lastPrice = 2_000e18;

    /// @dev Set if any liquidation paid out more collateral value than repay times the incentive.
    bool public overSeized;

    constructor(LendingMarket market_, MockERC20 base_, MockERC20 weth_, MockOracle oracle_) {
        market = market_;
        base = base_;
        weth = weth_;
        oracle = oracle_;
        for (uint256 i; i < actors.length; i++) {
            vm.startPrank(actors[i]);
            base.approve(address(market), type(uint256).max);
            weth.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function supply(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 100_000e18);
        base.mint(who, amount);
        vm.prank(who);
        market.supply(amount);
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 100_000e18);
        vm.prank(who);
        try market.withdraw(amount) {} catch {}
    }

    function supplyCollateral(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 100e18);
        weth.mint(who, amount);
        vm.prank(who);
        market.supplyCollateral(amount);
    }

    function withdrawCollateral(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 100e18);
        vm.prank(who);
        try market.withdrawCollateral(amount) {} catch {}
    }

    function borrow(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 power = (market.collateralBalance(who) * uint256(lastPrice) / 1e18) * 0.8e18 / 1e18;
        uint256 debt = market.borrowBalanceOf(who);
        uint256 cash = base.balanceOf(address(market));
        if (power <= debt + 1 || cash < 2) return;
        uint256 room = power - debt;
        uint256 cap = room < cash ? room : cash;
        // Borrow close to the limit so later price moves make positions liquidatable.
        amount = bound(amount, cap / 2 + 1, cap);
        vm.prank(who);
        try market.borrow(amount) {} catch {}
    }

    function repay(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 100_000e18);
        base.mint(who, amount);
        vm.prank(who);
        try market.repay(amount) {} catch {}
    }

    function liquidate(uint256 seed, uint256 target, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 100_000e18);
        base.mint(who, amount);
        address victim = _actor(target);
        for (uint256 i; i < actors.length; i++) {
            if (market.borrowBalanceOf(actors[i]) > 0 && !market.isHealthy(actors[i])) victim = actors[i];
        }
        uint256 baseBefore = base.balanceOf(who);
        uint256 wethBefore = weth.balanceOf(who);
        vm.prank(who);
        try market.liquidate(victim, amount) {
            uint256 paid = baseBefore - base.balanceOf(who);
            uint256 seized = weth.balanceOf(who) - wethBefore;
            if (seized * uint256(lastPrice) > paid * market.liquidationIncentive()) overSeized = true;
        } catch {}
    }

    function movePrice(uint256 price) external {
        lastPrice = int256(bound(price, 100e18, 4_000e18));
        oracle.setPrice(lastPrice);
    }

    function passTime(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
        // Keep the feed fresh so time passing does not just turn every call into a stale revert.
        oracle.setPrice(lastPrice);
    }
}

/**
 * @notice Accounting invariants. The bookkeeping ones held on the baseline too and pin that the fixes
 *         kept principals, totals and balances in step. invariant_liquidation_never_overpays fails on
 *         the baseline (F-1).
 */
contract InvariantTest is Test {
    LendingMarket internal market;
    MockERC20 internal base;
    MockERC20 internal weth;
    MarketHandler internal handler;

    function setUp() public {
        base = new MockERC20("Base USD", "bUSD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockOracle oracle = new MockOracle(2_000e18);

        LendingMarket impl = new LendingMarket();
        bytes memory initData = abi.encodeCall(
            LendingMarket.initialize,
            (
                address(0xA11CE),
                address(0x6DA12D),
                address(oracle),
                address(base),
                address(weth),
                0.8e18,
                1.1e18,
                uint256(0.05e18) / 365 days
            )
        );
        market = LendingMarket(
            address(new TransparentUpgradeableProxy(address(impl), address(0xA11CE), initData))
        );

        handler = new MarketHandler(market, base, weth, oracle);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.depth = 200
    function invariant_principal_totals_match_accounts() public view {
        uint256 supplySum;
        uint256 borrowSum;
        uint256 collateralSum;
        for (uint256 i; i < handler.actorCount(); i++) {
            address who = handler.actorAt(i);
            supplySum += market.supplyPrincipal(who);
            borrowSum += market.borrowPrincipal(who);
            collateralSum += market.collateralBalance(who);
        }
        assertEq(market.totalSupplyPrincipal(), supplySum);
        assertEq(market.totalBorrowPrincipal(), borrowSum);
        assertEq(market.totalCollateral(), collateralSum);
    }

    /// forge-config: default.invariant.depth = 200
    function invariant_liquidation_never_overpays() public view {
        assertFalse(handler.overSeized(), "a liquidation seized more than repay times incentive");
    }

    /// forge-config: default.invariant.depth = 200
    function invariant_base_covers_supplier_claims() public view {
        // Unpaid debt stays in the totals, so cash plus debt covers what suppliers are owed, up to
        // rounding drift. accrueInterest() rounds the borrow index down but credits suppliers the
        // unrounded interest, so suppliers can be owed a few thousand wei more (see README, Low).
        uint256 assets =
            base.balanceOf(address(market)) + market.presentValueBorrow(market.totalBorrowPrincipal());
        uint256 owed = market.presentValueSupply(market.totalSupplyPrincipal());
        assertGe(assets + owed / 1e15 + 10, owed, "suppliers are owed more than the market holds");
    }

    /// forge-config: default.invariant.depth = 200
    function invariant_market_can_always_accrue() public {
        // The handler swallows reverts, so check here that the market never reaches a frozen state.
        market.accrueInterest();
    }

    /// forge-config: default.invariant.depth = 200
    function invariant_collateral_is_held_by_the_market() public view {
        assertEq(weth.balanceOf(address(market)), market.totalCollateral());
    }
}
