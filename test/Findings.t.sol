// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/**
 * @notice One test per finding. Each asserts the correct behaviour, so it fails against the
 *         baseline contract and passes against the fix. The setup mirrors script/Deploy.s.sol:
 *         the implementation behind the proxy, one key as proxy admin and market admin, and a
 *         separate pause guardian.
 */
contract FindingsTest is Test {
    uint256 internal constant FACTOR = 1e18;
    uint256 internal constant RATE_PER_SECOND = uint256(0.05e18) / 365 days;
    uint256 internal constant WETH_PRICE = 2_000e18;
    uint256 internal constant INCENTIVE = 1.1e18;
    uint256 internal constant LIQUIDITY = 100_000e18;

    address internal admin = address(0xA11CE);
    address internal guardian = address(0x6DA12D);
    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    MockERC20 internal base;
    MockERC20 internal weth;
    MockOracle internal wethOracle;

    LendingMarket internal market;

    function setUp() public {
        base = new MockERC20("Base USD", "bUSD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wethOracle = new MockOracle(int256(WETH_PRICE));

        LendingMarket impl = new LendingMarket();
        bytes memory initData = abi.encodeCall(
            LendingMarket.initialize,
            (
                admin,
                guardian,
                address(wethOracle),
                address(base),
                address(weth),
                0.8e18,
                INCENTIVE,
                RATE_PER_SECOND
            )
        );
        market = LendingMarket(address(new TransparentUpgradeableProxy(address(impl), admin, initData)));

        base.mint(supplier, LIQUIDITY);
        vm.startPrank(supplier);
        base.approve(address(market), type(uint256).max);
        market.supply(LIQUIDITY);
        vm.stopPrank();
    }

    function _postCollateral(address who, uint256 amount) internal {
        weth.mint(who, amount);
        vm.startPrank(who);
        weth.approve(address(market), type(uint256).max);
        market.supplyCollateral(amount);
        vm.stopPrank();
    }

    function _fundLiquidator(uint256 amount) internal {
        base.mint(liquidator, amount);
        vm.prank(liquidator);
        base.approve(address(market), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------

    // Bob posts 10 WETH and borrows 15,000. WETH drops to 1,800, so he is liquidatable. A
    // liquidator repaying 1,000 should get 1,000 * 1.10 / 1,800 = 0.611 WETH, not all 10.
    function test_F1_liquidation_seizes_collateral_worth_repay_plus_incentive() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        wethOracle.setPrice(1_800e18);
        _fundLiquidator(1_000e18);

        vm.prank(liquidator);
        market.liquidate(borrower, 1_000e18);

        uint256 expectedSeize = (1_000e18 * INCENTIVE) / 1_800e18;
        assertEq(weth.balanceOf(liquidator), expectedSeize, "liquidator seized the wrong amount");
        assertEq(market.collateralBalance(borrower), 10e18 - expectedSeize, "borrower lost too much");
        assertApproxEqAbs(market.borrowBalanceOf(borrower), 14_000e18, 1);
    }

    // Same position, but WETH falls to 1,000, so 10 WETH (10,000) no longer covers 15,000 of debt
    // plus the incentive. The liquidator offers 15,000. They should get all 10 WETH and pay only the
    // 9,090.9 it is worth at a 10% discount, leaving the rest as debt on the borrower.
    function test_F1_capped_seize_charges_only_the_repay_it_covers() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        wethOracle.setPrice(1_000e18);
        _fundLiquidator(15_000e18);

        vm.prank(liquidator);
        market.liquidate(borrower, 15_000e18);

        uint256 charged = (10e18 * 1_000e18 + INCENTIVE - 1) / INCENTIVE;
        assertEq(weth.balanceOf(liquidator), 10e18);
        assertEq(base.balanceOf(liquidator), 15_000e18 - charged, "liquidator overpaid");
        assertApproxEqAbs(market.borrowBalanceOf(borrower), 15_000e18 - charged, 1);
    }

    // For any price that makes the 10 WETH / 15,000 position liquidatable and any repay, the
    // liquidator never receives more collateral value than they paid times the incentive, and the
    // borrower's debt falls by exactly what the liquidator paid.
    function testFuzz_liquidation_never_pays_more_than_the_incentive(uint256 price, uint256 repay) public {
        price = bound(price, 100e18, 1_870e18);
        repay = bound(repay, 1e18, 20_000e18);

        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        wethOracle.setPrice(int256(price));
        _fundLiquidator(repay);

        vm.prank(liquidator);
        market.liquidate(borrower, repay);

        uint256 paid = repay - base.balanceOf(liquidator);
        uint256 seized = weth.balanceOf(liquidator);

        assertLe(seized * price, paid * INCENTIVE, "seized more than repay plus incentive");
        assertLe(seized, 10e18);
        assertApproxEqAbs(market.borrowBalanceOf(borrower), 15_000e18 - paid, 1);
        assertEq(market.collateralBalance(borrower), 10e18 - seized);
    }

    // The pause guardian is only meant to stop the market. With setOracle it can point pricing
    // at a feed that says 1 WETH = 1,000,000 base, post 1 WETH and borrow the whole pool.
    function test_F2_guardian_cannot_replace_the_oracle() public {
        MockOracle rigged = new MockOracle(1_000_000e18);

        vm.prank(guardian);
        vm.expectRevert("not admin");
        market.setOracle(address(rigged));

        assertEq(address(market.oracle()), address(wethOracle), "guardian changed pricing");

        vm.prank(admin);
        market.setOracle(address(rigged));
        assertEq(address(market.oracle()), address(rigged), "admin must still be able to rewire");
    }

    // The feed reports -1. getPrice() casts it to 2^256 - 1, so 1 wei of WETH looks like enough
    // collateral to borrow all 100,000 of base liquidity.
    function test_F3_negative_price_cannot_be_borrowed_against() public {
        _postCollateral(borrower, 1);
        wethOracle.setPrice(-1);

        vm.prank(borrower);
        vm.expectRevert("bad price");
        market.borrow(LIQUIDITY);

        assertEq(base.balanceOf(address(market)), LIQUIDITY, "pool was drained");
    }

    // The feed stops updating at 2,000 while WETH trades lower. A day later Bob can still borrow
    // 16,000 against 10 WETH at the frozen price.
    function test_F3_stale_price_cannot_be_borrowed_against() public {
        _postCollateral(borrower, 10e18);
        vm.warp(block.timestamp + 1 days);

        vm.prank(borrower);
        vm.expectRevert("stale price");
        market.borrow(16_000e18);

        assertEq(base.balanceOf(borrower), 0, "borrowed against a stale price");
    }

    // The admin rewires to a Chainlink-style feed quoting 8 decimals. Every price would read
    // 1e10 times too low and every borrower would become liquidatable at once.
    function test_F3_oracle_with_wrong_decimals_is_rejected() public {
        EightDecimalOracle feed = new EightDecimalOracle();

        vm.prank(admin);
        vm.expectRevert("oracle decimals");
        market.setOracle(address(feed));

        assertEq(address(market.oracle()), address(wethOracle));
    }

    // Bob posts 10 WETH and borrows 15,000 (limit 16,000). Nobody touches the market for a year,
    // so he really owes about 15,750. He then withdraws 0.6 WETH, which leaves 15,040 of borrowing
    // power. That only passes if the health check reads the stale 15,000.
    function test_F4_withdraw_collateral_checks_health_on_accrued_debt() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        vm.warp(block.timestamp + 365 days);
        wethOracle.setPrice(int256(WETH_PRICE));

        vm.prank(borrower);
        vm.expectRevert("would be undercollateralized");
        market.withdrawCollateral(0.6e18);

        assertEq(market.collateralBalance(borrower), 10e18);
    }

    // Governance means 5% a year but passes 0.05e18 as the per second rate. Each accrual now
    // grows the borrow index by 60%. I measured an overflow after about 100 accruals, 20 minutes
    // at one per block. From then on accrueInterest() reverts, and so does setParameters(), which
    // accrues first, so the admin cannot lower the rate back without an upgrade.
    function test_F5_borrow_rate_above_the_cap_is_rejected() public {
        vm.prank(admin);
        vm.expectRevert("rate too high");
        market.setParameters(0.8e18, INCENTIVE, 0.05e18);

        assertEq(market.borrowRatePerSecond(), RATE_PER_SECOND);
    }

    // With a 95% collateral factor and a 10% incentive, repaying 1.00 seizes 1.10 of collateral,
    // which cuts borrowing power by 0.95 * 1.10 = 1.045. Debt falls slower than borrowing power,
    // so each liquidation leaves the position less healthy and it ends as bad debt.
    function test_F5_collateral_factor_times_incentive_must_stay_below_one() public {
        vm.prank(admin);
        vm.expectRevert("cf * incentive too high");
        market.setParameters(0.95e18, INCENTIVE, RATE_PER_SECOND);

        assertEq(market.collateralFactor(), 0.8e18);
    }

    // A collateral factor of 0 (a market being wound down) passes the cf * incentive bound with any
    // incentive. At 50x, a 400 repay at 2,000 would seize all 10 WETH.
    function test_F5_incentive_above_the_cap_is_rejected() public {
        vm.prank(admin);
        vm.expectRevert("incentive too high");
        market.setParameters(0, 50e18, RATE_PER_SECOND);

        assertEq(market.liquidationIncentive(), INCENTIVE);
    }

    // A new market deployed through Deploy.s.sol goes through initialize(), not setParameters(),
    // so the same unit slip in the rate must be caught there too.
    function test_F5_initialize_applies_the_same_bounds() public {
        LendingMarket impl = new LendingMarket();
        bytes memory initData = abi.encodeCall(
            LendingMarket.initialize,
            (admin, guardian, address(wethOracle), address(base), address(weth), 0.8e18, INCENTIVE, 0.05e18)
        );

        vm.expectRevert("rate too high");
        new TransparentUpgradeableProxy(address(impl), admin, initData);
    }

    // Anyone can call initialize() on the bare implementation and make themselves its admin.
    // There is no delegatecall or selfdestruct today, so no impact, but a future version could add one.
    function test_F6_implementation_cannot_be_initialized() public {
        LendingMarket impl = new LendingMarket();

        vm.expectRevert("already initialized");
        impl.initialize(
            address(this),
            address(this),
            address(wethOracle),
            address(base),
            address(weth),
            0.8e18,
            INCENTIVE,
            0
        );

        assertEq(impl.admin(), address(0));
    }
}

/// @notice A feed that quotes 8 decimals, like most Chainlink USD feeds.
contract EightDecimalOracle {
    uint8 public constant decimals = 8;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2_000e8, block.timestamp, block.timestamp, 1);
    }
}
