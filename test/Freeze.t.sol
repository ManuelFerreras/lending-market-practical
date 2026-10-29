// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {LendingMarketV1} from "./legacy/LendingMarketV1.sol";

/**
 * @notice Reproduces the F-5 freeze on the live version (test/legacy/LendingMarketV1.sol). It passes
 *         because the bug is real. The fixed contract rejects the rate, see test_F5_* in Findings.t.sol.
 */
contract FreezeTest is Test {
    address internal admin = address(0xA11CE);
    address internal borrower = makeAddr("borrower");

    // Governance passes 0.05e18 per second meaning 5% a year. With one accrual per 12 second block
    // the borrow index overflows in about 100 blocks, and after that the admin cannot lower the rate.
    function test_F5_mistyped_rate_freezes_the_live_version() public {
        MockERC20 base = new MockERC20("Base USD", "bUSD", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockOracle oracle = new MockOracle(2_000e18);
        LendingMarketV1 v1 = new LendingMarketV1();
        bytes memory initData = abi.encodeCall(
            LendingMarketV1.initialize,
            (admin, address(0x6DA12D), address(oracle), address(base), address(weth), 0.8e18, 1.1e18, 1e9)
        );
        LendingMarketV1 market =
            LendingMarketV1(address(new TransparentUpgradeableProxy(address(v1), admin, initData)));

        base.mint(address(this), 100_000e18);
        base.approve(address(market), type(uint256).max);
        market.supply(100_000e18);
        weth.mint(borrower, 10e18);
        vm.startPrank(borrower);
        weth.approve(address(market), type(uint256).max);
        market.supplyCollateral(10e18);
        market.borrow(15_000e18);
        vm.stopPrank();

        vm.prank(admin);
        market.setParameters(0.8e18, 1.1e18, 0.05e18);

        uint256 blocks;
        while (blocks < 200) {
            vm.warp(block.timestamp + 12);
            try market.accrueInterest() {
                blocks++;
            } catch {
                break;
            }
        }
        assertLt(blocks, 200, "index never overflowed");
        assertGt(blocks, 80);

        // Frozen: the admin cannot set a sane rate, and the borrower cannot even repay.
        vm.prank(admin);
        vm.expectRevert();
        market.setParameters(0.8e18, 1.1e18, 1e9);

        vm.prank(borrower);
        vm.expectRevert();
        market.repay(1e18);
    }
}
