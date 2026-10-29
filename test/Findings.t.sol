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
}
