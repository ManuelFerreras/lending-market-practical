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
}

/// @notice A feed that quotes 8 decimals, like most Chainlink USD feeds.
contract EightDecimalOracle {
    uint8 public constant decimals = 8;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2_000e8, block.timestamp, block.timestamp, 1);
    }
}
