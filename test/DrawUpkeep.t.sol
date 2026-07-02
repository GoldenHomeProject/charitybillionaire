// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CharityPrizeVault} from "../src/CharityPrizeVault.sol";
import {DrawUpkeep, IDrawVault} from "../src/DrawUpkeep.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20, MockAavePool, MockRandomProvider} from "./mocks/Mocks.sol";

contract DrawUpkeepTest is Test {
    MockERC20 usdc;
    MockERC20 aUsdc;
    MockAavePool pool;
    MockRandomProvider vrf;
    CharityPrizeVault vault;
    DrawUpkeep upkeep;

    address owner = makeAddr("owner");
    address company = makeAddr("company");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");

    uint256 constant ONE = 1e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        pool = new MockAavePool(usdc, aUsdc);
        vrf = new MockRandomProvider();
        vault = new CharityPrizeVault(
            IERC20(address(usdc)), pool, IERC20(address(aUsdc)), vrf, company, operator, owner
        );
        upkeep = new DrawUpkeep(IDrawVault(address(vault)));

        usdc.mint(alice, 1_000 * ONE);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(100 * ONE);
        pool.accrueYield(address(vault), 10 * ONE);
    }

    function _check() internal view returns (bool needed) {
        (needed,) = upkeep.checkUpkeep("");
    }

    function test_NotNeededBeforeDrawTime() public view {
        assertFalse(_check());
    }

    function test_NeededAtDrawTime_PerformRequests() public {
        vm.warp(vault.nextDrawTime());
        assertTrue(_check());
        upkeep.performUpkeep("");
        assertTrue(vault.drawPending());
        // While pending and fresh, no further upkeep is needed.
        assertFalse(_check());
    }

    function test_FulfilledDraw_NotNeededUntilNextWeek() public {
        vm.warp(vault.nextDrawTime());
        upkeep.performUpkeep("");
        vrf.fulfill(vrf.lastRequestId(), 0);
        assertFalse(vault.drawPending());
        assertFalse(_check()); // re-anchored to next Thursday
        vm.warp(vault.nextDrawTime());
        assertTrue(_check());
    }

    function test_StalePending_PerformCancelsAndRerequests() public {
        vm.warp(vault.nextDrawTime());
        upkeep.performUpkeep("");
        uint256 deadId = vrf.lastRequestId();

        // Unfulfilled but not yet stale: nothing to do.
        vm.warp(block.timestamp + vault.STALE_DRAW_TIMEOUT() - 1);
        assertFalse(_check());

        // Past the timeout the upkeep self-heals in one perform.
        vm.warp(block.timestamp + 1);
        assertTrue(_check());
        upkeep.performUpkeep("");
        assertTrue(vault.drawPending());
        assertTrue(vrf.lastRequestId() != deadId);

        // The retry fulfills and pays out.
        vrf.fulfill(vrf.lastRequestId(), 0);
        assertFalse(vault.drawPending());
        assertGt(usdc.balanceOf(alice), 900 * ONE); // prize landed
    }
}
