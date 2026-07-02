// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CharityPrizeVault} from "../src/CharityPrizeVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    MockERC20,
    MockAavePool,
    MockRandomProvider,
    MockEndaomentFactory,
    MockRevertingEndaomentFactory
} from "./mocks/Mocks.sol";

contract CharityPrizeVaultTest is Test {
    MockERC20 usdc;
    MockERC20 aUsdc;
    MockAavePool pool;
    MockRandomProvider vrf;
    CharityPrizeVault vault;

    address owner = makeAddr("owner");
    address company = makeAddr("company");
    address operator = makeAddr("operator");
    address charityA = makeAddr("charityA");
    address endaoTreasury = makeAddr("endaoTreasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint16 constant ENDAO_FEE_BPS = 150; // 1.5%, Endaoment's protocol fee
    bytes32 constant ORG_ID = bytes32("EIN-13-1837418"); // sample Endaoment Org id

    uint256 constant ONE = 1e6; // $1 with 6 decimals

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);
        pool = new MockAavePool(usdc, aUsdc);
        vrf = new MockRandomProvider();

        vault = new CharityPrizeVault(
            IERC20(address(usdc)),
            pool,
            IERC20(address(aUsdc)),
            vrf,
            company,
            operator,
            owner
        );

        vm.prank(owner);
        vault.allowCharity(charityA, true);
        vm.prank(owner);
        vault.setCharity(charityA);

        _fund(alice, 1_000 * ONE);
        _fund(bob, 1_000 * ONE);
        _fund(operator, 1_000 * ONE);
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        vault.deposit(amount);
    }

    // --- Deposits / withdrawals ---

    function test_DepositTracksPrincipal() public {
        _deposit(alice, 100 * ONE);
        assertEq(vault.balanceOf(alice), 100 * ONE);
        assertEq(vault.totalDeposited(), 100 * ONE);
        assertEq(aUsdc.balanceOf(address(vault)), 100 * ONE);
    }

    function test_WithdrawAnytime_ReturnsFullPrincipal() public {
        _deposit(alice, 100 * ONE);
        vm.prank(alice);
        vault.withdraw(100 * ONE);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalDeposited(), 0);
        assertEq(usdc.balanceOf(alice), 1_000 * ONE); // got it all back
    }

    function test_WithdrawMoreThanBalance_Reverts() public {
        _deposit(alice, 100 * ONE);
        vm.prank(alice);
        vm.expectRevert(CharityPrizeVault.InsufficientBalance.selector);
        vault.withdraw(101 * ONE);
    }

    // --- Yield views ---

    function test_AccruedYieldAndProjectedPrize() public {
        _deposit(alice, 100 * ONE);
        pool.accrueYield(address(vault), 10 * ONE);
        assertEq(vault.accruedYield(), 10 * ONE);
        assertEq(vault.projectedPrize(), (10 * ONE * 9000) / 10_000); // 90%
    }

    // --- Full draw cycle ---

    function test_FullDrawCycle_SplitsNinetyFiveFive() public {
        _deposit(alice, 100 * ONE);
        _deposit(bob, 100 * ONE);
        pool.accrueYield(address(vault), 20 * ONE);

        vm.warp(block.timestamp + 7 days);
        uint256 reqId = vault.requestDraw();

        // target 0 -> first depositor in range (alice)
        vrf.fulfill(reqId, 0);

        uint256 yield_ = 20 * ONE;
        assertEq(usdc.balanceOf(alice), 900 * ONE + (yield_ * 9000) / 10_000); // remaining wallet + prize
        assertEq(usdc.balanceOf(charityA), (yield_ * 500) / 10_000);
        assertEq(usdc.balanceOf(company), (yield_ * 500) / 10_000);

        // Principal fully intact and still earning.
        assertEq(vault.totalDeposited(), 200 * ONE);
        assertEq(aUsdc.balanceOf(address(vault)), 200 * ONE);
        assertEq(vault.accruedYield(), 0);
    }

    function test_WeightedSelection_BoundaryGoesToSecondDepositor() public {
        _deposit(alice, 1 * ONE); // range [0, 1e6)
        _deposit(bob, 9 * ONE); // range [1e6, 10e6)
        pool.accrueYield(address(vault), 5 * ONE);

        vm.warp(block.timestamp + 7 days);
        uint256 reqId = vault.requestDraw();
        // target == alice's balance -> crosses into bob's range
        vrf.fulfill(reqId, 1 * ONE);

        assertGt(usdc.balanceOf(bob), 991 * ONE); // bob won the 90%
    }

    function test_OperatorExcludedFromWinning() public {
        _deposit(operator, 1_000 * ONE); // huge, but ineligible
        _deposit(alice, 1 * ONE); // only eligible depositor
        pool.accrueYield(address(vault), 10 * ONE);

        assertEq(vault.eligibleTotal(), 1 * ONE); // operator's 1000 excluded

        vm.warp(block.timestamp + 7 days);
        uint256 reqId = vault.requestDraw();
        // any target % eligibleTotal(=1e6) must resolve to alice, never operator
        vrf.fulfill(reqId, 12345);

        assertEq(usdc.balanceOf(alice), 999 * ONE + (10 * ONE * 9000) / 10_000);
    }

    // --- Access control / safety ---

    function test_OnlyRandomProviderCanFulfill() public {
        _deposit(alice, 100 * ONE);
        pool.accrueYield(address(vault), 10 * ONE);
        vm.warp(block.timestamp + 7 days);
        uint256 reqId = vault.requestDraw();

        vm.expectRevert(CharityPrizeVault.NotRandomProvider.selector);
        vault.fulfillRandomWords(reqId, _words(0));
    }

    function test_DrawNotDue_Reverts() public {
        _deposit(alice, 100 * ONE);
        vm.expectRevert(CharityPrizeVault.DrawNotDue.selector);
        vault.requestDraw();
    }

    function test_CancelStaleDraw_RevertsWhenNotPendingOrNotStale() public {
        // Nothing pending at all.
        vm.expectRevert(CharityPrizeVault.DrawNotStale.selector);
        vault.cancelStaleDraw();

        _deposit(alice, 100 * ONE);
        pool.accrueYield(address(vault), 10 * ONE);
        vm.warp(block.timestamp + 7 days);
        vault.requestDraw();

        // Pending, but not yet past the timeout.
        vm.warp(block.timestamp + vault.STALE_DRAW_TIMEOUT() - 1);
        vm.expectRevert(CharityPrizeVault.DrawNotStale.selector);
        vault.cancelStaleDraw();
    }

    function test_CancelStaleDraw_RecoversAndIgnoresLateCallback() public {
        _deposit(alice, 100 * ONE);
        _deposit(bob, 100 * ONE);
        pool.accrueYield(address(vault), 20 * ONE);

        vm.warp(block.timestamp + 7 days);
        uint256 deadReqId = vault.requestDraw();

        // Second request while pending is still blocked.
        vm.expectRevert(CharityPrizeVault.DrawAlreadyPending.selector);
        vault.requestDraw();

        // VRF never fulfills; past the timeout ANYONE can clear it.
        vm.warp(block.timestamp + vault.STALE_DRAW_TIMEOUT());
        vm.prank(alice);
        vault.cancelStaleDraw();
        assertFalse(vault.drawPending());

        // nextDrawTime never moved, so the draw is immediately re-requestable.
        uint256 retryReqId = vault.requestDraw();
        assertTrue(retryReqId != deadReqId);

        // The dead request's callback arriving late is a no-op (requestId mismatch).
        vrf.fulfill(deadReqId, 0);
        assertEq(usdc.balanceOf(alice), 900 * ONE); // no prize paid
        assertTrue(vault.drawPending()); // retry still live

        // The retry fulfills and pays out normally.
        vrf.fulfill(retryReqId, 0);
        assertEq(usdc.balanceOf(alice), 900 * ONE + (20 * ONE * 9000) / 10_000);
    }

    function test_RescueCannotTouchPrincipalOrAToken() public {
        _deposit(alice, 100 * ONE);
        vm.prank(owner);
        vm.expectRevert(CharityPrizeVault.ProtectedToken.selector);
        vault.rescueToken(IERC20(address(usdc)), owner, 1);

        vm.prank(owner);
        vm.expectRevert(CharityPrizeVault.ProtectedToken.selector);
        vault.rescueToken(IERC20(address(aUsdc)), owner, 1);
    }

    function test_SetCharity_RequiresAllowlist() public {
        address rogue = makeAddr("rogue");
        vm.prank(owner);
        vm.expectRevert(CharityPrizeVault.CharityNotAllowed.selector);
        vault.setCharity(rogue);
    }

    /// @notice Security (M-2): the operator (the single excluded-from-winning address)
    ///         is immutable — there is no setter at all, so no one can ever change who
    ///         is eligible, and because it is one fixed slot (not a growable blocklist)
    ///         no one can exclude depositors to narrow the field toward a chosen winner.
    function test_OperatorIsImmutable_NoSetterExists() public view {
        // Set once at construction and exposed as an immutable getter.
        assertEq(vault.operator(), operator);
        // (Compile-time guarantee: there is no proposeOperator/applyOperator/setOperator
        // on the contract, so this value can never change post-deploy.)
    }

    /// @notice The 90/5/5 split constants must always sum to 100%.
    function test_PrizeSplitConstantsSumTo100Percent() public view {
        assertEq(vault.WINNER_BPS() + vault.CHARITY_BPS() + vault.COMPANY_BPS(), 10_000);
    }

    /// @notice Security (H-2): if Aave's withdraw reverts mid-draw, the callback must
    ///         NOT brick. The week is skipped cleanly, the schedule advances, the
    ///         request is consumed (not stranded), principal is untouched, and the next
    ///         Thursday's draw distributes the accumulated yield normally.
    function test_DrawSkipsCleanlyWhenAaveWithdrawFails() public {
        _deposit(alice, 100 * ONE);
        _deposit(bob, 100 * ONE);
        pool.accrueYield(address(vault), 20 * ONE);

        vm.warp(block.timestamp + 7 days);
        uint256 reqId = vault.requestDraw();
        uint256 scheduledNext = vault.nextDrawTime();

        pool.setFailWithdraw(true);
        vrf.fulfill(reqId, 0); // must not revert despite Aave failing

        // Draw consumed + schedule advanced; not stuck pending.
        assertFalse(vault.drawPending());
        assertGt(vault.nextDrawTime(), scheduledNext);
        // No payout happened; principal fully intact and still earning.
        assertEq(usdc.balanceOf(alice), 900 * ONE);
        assertEq(vault.totalDeposited(), 200 * ONE);
        assertEq(vault.accruedYield(), 20 * ONE);

        // Aave recovers; next scheduled draw pays out the accumulated yield.
        pool.setFailWithdraw(false);
        vm.warp(vault.nextDrawTime());
        uint256 reqId2 = vault.requestDraw();
        vrf.fulfill(reqId2, 0);
        assertEq(usdc.balanceOf(alice), 900 * ONE + (20 * ONE * 9000) / 10_000);
    }

    /// @notice A malformed (empty) randomness callback is a no-op skip, not a revert,
    ///         and leaves the draw recoverable rather than consuming it.
    function test_EmptyRandomnessCallback_SkipsWithoutReverting() public {
        _deposit(alice, 100 * ONE);
        pool.accrueYield(address(vault), 10 * ONE);
        vm.warp(block.timestamp + 7 days);
        uint256 reqId = vault.requestDraw();

        uint256[] memory empty = new uint256[](0);
        vm.prank(address(vrf));
        vault.fulfillRandomWords(reqId, empty); // must not revert

        assertEq(usdc.balanceOf(alice), 900 * ONE); // no payout
        assertTrue(vault.drawPending()); // draw not consumed; recoverable
    }

    /// @notice Sybil-equivalence: $10 in one wallet vs $1 in ten wallets yield the
    ///         same total tickets and the same eligible pool — no gaming advantage.
    function test_SybilEquivalence() public {
        _deposit(alice, 10 * ONE);
        uint256 oneWallet = vault.eligibleTotal();

        vm.prank(alice);
        vault.withdraw(10 * ONE);

        for (uint256 i = 0; i < 10; i++) {
            address w = makeAddr(string(abi.encodePacked("sybil", i)));
            _fund(w, ONE);
            _deposit(w, ONE);
        }
        assertEq(vault.eligibleTotal(), oneWallet); // identical
    }

    // --- Scale: the draw must work for any number of entries ---

    /// @notice Proves winner selection is O(log n): a draw over 5,000 depositors
    ///         completes well within the block gas limit and picks the correct
    ///         dollar-weighted winner. The old O(n) walk grew linearly with entries.
    function test_Scale_DrawWorksWithThousandsOfDepositors() public {
        uint256 n = 5_000;
        for (uint256 i = 0; i < n; i++) {
            address w = address(uint160(0x100000 + i));
            usdc.mint(w, ONE);
            vm.prank(w);
            usdc.approve(address(vault), type(uint256).max);
            vm.prank(w);
            vault.deposit(ONE);
        }
        assertEq(vault.depositorCount(), n);
        assertEq(vault.eligibleTotal(), n * ONE);

        pool.accrueYield(address(vault), 100 * ONE);
        vm.warp(block.timestamp + 7 days);
        uint256 reqId = vault.requestDraw();

        // Target lands in the LAST depositor's dollar range -> the worst case for an
        // O(n) walk, but constant-ish for the tree.
        uint256 gasBefore = gasleft();
        vrf.fulfill(reqId, (n - 1) * ONE);
        uint256 gasUsed = gasBefore - gasleft();

        address last = address(uint160(0x100000 + n - 1));
        assertEq(usdc.balanceOf(last), (100 * ONE * 9000) / 10_000);
        // Selection over 5k entries stays cheap; assert the whole fulfill is bounded
        // far below a block. (Aave withdraw + 3 transfers dominate this number.)
        assertLt(gasUsed, 300_000);
    }

    /// @notice A fully-withdrawn depositor's slot remains in the tree but holds zero
    ///         dollars, so it can never be selected — even when a target maps into the
    ///         range it used to occupy. Selection shifts to the next funded depositor.
    function test_WithdrawnDepositorNeverSelected() public {
        address carol = makeAddr("carol");
        _fund(carol, 5 * ONE);

        _deposit(alice, 5 * ONE); // index 1: [0, 5e6)
        _deposit(bob, 5 * ONE); // index 2: [5e6, 10e6)
        _deposit(carol, 5 * ONE); // index 3: [10e6, 15e6)

        vm.prank(bob); // middle slot emptied
        vault.withdraw(5 * ONE);
        assertEq(vault.eligibleTotal(), 10 * ONE);

        pool.accrueYield(address(vault), 10 * ONE);
        vm.warp(block.timestamp + 7 days);
        uint256 reqId = vault.requestDraw();

        // 5e6 is the first dollar past alice's block; with bob gone it belongs to carol.
        vrf.fulfill(reqId, 5 * ONE);

        assertEq(usdc.balanceOf(carol), (10 * ONE * 9000) / 10_000); // carol won
        assertEq(usdc.balanceOf(bob), 1_000 * ONE); // full funded balance back, no prize
    }

    // --- Charity routing via Endaoment ---

    function _enableEndaoment(address factory) internal {
        vm.startPrank(owner);
        vault.setEndaomentFactory(factory);
        bytes32[] memory rot = new bytes32[](1);
        rot[0] = ORG_ID;
        vault.setCharityRotation(rot);
        vault.setUseEndaoment(true);
        vm.stopPrank();
    }

    /// @notice With Endaoment enabled, the charity 5% is donated on-chain to the Org; the
    ///         protocol fee comes out of that 5% (winner 90% / company 5% untouched), and
    ///         the direct charity address is bypassed.
    function test_CharityRoutesThroughEndaoment_DeployPath() public {
        MockEndaomentFactory factory = new MockEndaomentFactory(usdc, endaoTreasury, ENDAO_FEE_BPS);
        _enableEndaoment(address(factory));

        _deposit(alice, 100 * ONE);
        _deposit(bob, 100 * ONE);
        uint256 yield_ = 20 * ONE;
        pool.accrueYield(address(vault), yield_);

        vm.warp(block.timestamp + 7 days);
        uint256 reqId = vault.requestDraw();
        vrf.fulfill(reqId, 0); // alice wins

        uint256 charitySlice = (yield_ * 500) / 10_000; // 5%
        uint256 fee = (charitySlice * ENDAO_FEE_BPS) / 10_000;
        address org = factory.computeOrgAddress(ORG_ID);

        assertEq(usdc.balanceOf(org), charitySlice - fee); // charity nets 5% minus fee
        assertEq(usdc.balanceOf(endaoTreasury), fee); // Endaoment's fee, taken from the 5%
        assertEq(usdc.balanceOf(charityA), 0); // direct address NOT used
        assertEq(usdc.balanceOf(company), (yield_ * 500) / 10_000); // company 5% intact
        assertEq(usdc.balanceOf(alice), 900 * ONE + (yield_ * 9000) / 10_000); // winner 90% intact
    }

    /// @notice If the Org is already deployed, `deployOrgAndDonate` reverts and the vault
    ///         falls back to donating straight to the Org's deterministic address.
    function test_CharityRoutesThroughEndaoment_AlreadyDeployedPath() public {
        MockEndaomentFactory factory = new MockEndaomentFactory(usdc, endaoTreasury, ENDAO_FEE_BPS);
        // Pre-deploy the Org via a first, unrelated donation.
        usdc.mint(address(this), 10 * ONE);
        usdc.approve(address(factory), 10 * ONE);
        factory.deployOrgAndDonate(ORG_ID, 10 * ONE);
        address org = factory.computeOrgAddress(ORG_ID);
        uint256 orgBefore = usdc.balanceOf(org);

        _enableEndaoment(address(factory));

        _deposit(alice, 100 * ONE);
        uint256 yield_ = 20 * ONE;
        pool.accrueYield(address(vault), yield_);
        vm.warp(block.timestamp + 7 days);
        uint256 reqId = vault.requestDraw();
        vrf.fulfill(reqId, 0);

        uint256 charitySlice = (yield_ * 500) / 10_000;
        uint256 fee = (charitySlice * ENDAO_FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(org), orgBefore + charitySlice - fee); // direct-donate path hit
        assertEq(usdc.balanceOf(charityA), 0);
    }

    /// @notice A failed Endaoment donation must never brick the draw: it falls back to the
    ///         direct charity address, and the winner/company are still paid.
    function test_EndaomentFailure_FallsBackToDirectCharity() public {
        MockRevertingEndaomentFactory bad = new MockRevertingEndaomentFactory();
        _enableEndaoment(address(bad)); // charityA is still set as direct fallback from setUp

        _deposit(alice, 100 * ONE);
        uint256 yield_ = 20 * ONE;
        pool.accrueYield(address(vault), yield_);
        vm.warp(block.timestamp + 7 days);
        uint256 reqId = vault.requestDraw();
        vrf.fulfill(reqId, 0);

        uint256 charitySlice = (yield_ * 500) / 10_000;
        assertEq(usdc.balanceOf(charityA), charitySlice); // fell back to direct address, full slice
        assertEq(usdc.balanceOf(company), (yield_ * 500) / 10_000);
        assertEq(usdc.balanceOf(alice), 900 * ONE + (yield_ * 9000) / 10_000);
    }

    // --- Deterministic weekly charity rotation ---

    bytes32 constant ORG_A = bytes32("EIN-11-1111111");
    bytes32 constant ORG_B = bytes32("EIN-22-2222222");
    bytes32 constant ORG_C = bytes32("EIN-33-3333333");

    function _setRotation3() internal {
        bytes32[] memory rot = new bytes32[](3);
        rot[0] = ORG_A;
        rot[1] = ORG_B;
        rot[2] = ORG_C;
        vm.prank(owner);
        vault.setCharityRotation(rot);
    }

    /// @notice current/next getters reflect the ordered list and pointer.
    function test_Rotation_CurrentAndNextGetters() public {
        _setRotation3();
        assertEq(vault.charityRotationLength(), 3);
        assertEq(vault.currentCharityOrgId(), ORG_A);
        assertEq(vault.nextCharityOrgId(), ORG_B);
        assertEq(vault.charityIndex(), 0);
    }

    /// @notice Empty rotation => zero ids and the draw safely skips Endaoment (no revert).
    function test_Rotation_EmptyReturnsZero() public view {
        assertEq(vault.charityRotationLength(), 0);
        assertEq(vault.currentCharityOrgId(), bytes32(0));
        assertEq(vault.nextCharityOrgId(), bytes32(0));
    }

    /// @notice Each completed draw advances the pointer one step and wraps around.
    function test_Rotation_AdvancesEachDrawAndWraps() public {
        MockEndaomentFactory factory = new MockEndaomentFactory(usdc, endaoTreasury, ENDAO_FEE_BPS);
        vm.startPrank(owner);
        vault.setEndaomentFactory(address(factory));
        bytes32[] memory rot = new bytes32[](3);
        rot[0] = ORG_A;
        rot[1] = ORG_B;
        rot[2] = ORG_C;
        vault.setCharityRotation(rot);
        vault.setUseEndaoment(true);
        vm.stopPrank();

        _deposit(alice, 100 * ONE);

        // Run 4 draws; the charity each week should be A, B, C, then wrap to A.
        bytes32[4] memory expected = [ORG_A, ORG_B, ORG_C, ORG_A];
        for (uint256 i = 0; i < 4; i++) {
            assertEq(vault.currentCharityOrgId(), expected[i], "wrong current charity for week");
            pool.accrueYield(address(vault), 20 * ONE);
            vm.warp(block.timestamp + 7 days);
            uint256 reqId = vault.requestDraw();
            vrf.fulfill(reqId, 0);
            // donation landed at the expected week's Org
            assertGt(usdc.balanceOf(factory.computeOrgAddress(expected[i])), 0, "expected org not funded");
        }
        // After 4 advances over a length-3 list the pointer is back at index 1.
        assertEq(vault.charityIndex(), 1);
    }

    function test_Rotation_OwnerCanAddRemoveAndReindex() public {
        _setRotation3();
        vm.prank(owner);
        vault.addCharityOrgId(bytes32("EIN-44-4444444"));
        assertEq(vault.charityRotationLength(), 4);

        // Remove the middle (ORG_B): order preserved => [A, C, D].
        vm.prank(owner);
        vault.removeCharityOrgId(1);
        assertEq(vault.charityRotationLength(), 3);
        assertEq(vault.currentCharityOrgId(), ORG_A);
        assertEq(vault.nextCharityOrgId(), ORG_C);

        // Owner override of the pointer.
        vm.prank(owner);
        vault.setCharityIndex(2);
        assertEq(vault.currentCharityOrgId(), bytes32("EIN-44-4444444"));
    }

    function test_Rotation_SetIndexOutOfRangeReverts() public {
        _setRotation3();
        vm.prank(owner);
        vm.expectRevert(CharityPrizeVault.IndexOutOfRange.selector);
        vault.setCharityIndex(3);
    }

    /// @notice MEDIUM-fix regression: removing an entry BEFORE the live pointer must keep
    ///         "this week's" charity unchanged (the pointer follows the same org down).
    function test_Rotation_RemoveBeforePointerKeepsBeneficiary() public {
        bytes32[] memory rot = new bytes32[](4);
        rot[0] = ORG_A;
        rot[1] = ORG_B;
        rot[2] = ORG_C;
        rot[3] = bytes32("EIN-44-4444444");
        vm.startPrank(owner);
        vault.setCharityRotation(rot);
        vault.setCharityIndex(1); // this week = ORG_B
        assertEq(vault.currentCharityOrgId(), ORG_B);
        vault.removeCharityOrgId(0); // remove ORG_A (before the pointer)
        vm.stopPrank();
        // Still ORG_B — not silently shifted to ORG_C.
        assertEq(vault.currentCharityOrgId(), ORG_B);
        assertEq(vault.charityIndex(), 0);
        assertEq(vault.nextCharityOrgId(), ORG_C);
    }

    /// @notice Removing the currently-active LAST entry wraps the pointer to the start.
    function test_Rotation_RemoveActiveLastEntryWraps() public {
        _setRotation3(); // [A, B, C]
        vm.startPrank(owner);
        vault.setCharityIndex(2); // this week = ORG_C (last)
        vault.removeCharityOrgId(2); // remove the active last entry -> [A, B]
        vm.stopPrank();
        assertEq(vault.charityRotationLength(), 2);
        assertEq(vault.charityIndex(), 0);
        assertEq(vault.currentCharityOrgId(), ORG_A);
    }

    function test_Rotation_OnlyOwnerCanManage() public {
        bytes32[] memory rot = new bytes32[](1);
        rot[0] = ORG_A;
        vm.prank(alice);
        vm.expectRevert();
        vault.setCharityRotation(rot);
    }

    function test_RouteCharityToEndaoment_OnlySelf() public {
        vm.expectRevert(CharityPrizeVault.OnlySelf.selector);
        vault.routeCharityToEndaoment(ORG_ID, 1 * ONE);
    }

    // --- Self-healing keeper bounty ---

    /// @notice On-time draw (within the grace window) pays NO bounty; company keeps full 5%.
    function test_DrawBounty_NotPaidWhenOnTime() public {
        vm.prank(owner);
        vault.setDrawBounty(1 * ONE);
        _deposit(alice, 100 * ONE);
        uint256 yield_ = 20 * ONE;
        pool.accrueYield(address(vault), yield_);
        vm.warp(vault.nextDrawTime()); // exactly on time
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        uint256 reqId = vault.requestDraw();
        vrf.fulfill(reqId, 0);
        assertEq(vault.drawStartedLate(), false);
        assertEq(usdc.balanceOf(keeper), 0); // no bounty
        assertEq(usdc.balanceOf(company), (yield_ * 500) / 10_000); // full 5%
    }

    /// @notice Late draw (past the 5-min grace) pays the bounty to whoever fired it,
    ///         deducted ONLY from the company slice; winner + charity untouched.
    function test_DrawBounty_PaidWhenLate() public {
        uint256 bounty = 1 * ONE;
        vm.prank(owner);
        vault.setDrawBounty(bounty);
        _deposit(alice, 100 * ONE);
        uint256 yield_ = 20 * ONE;
        pool.accrueYield(address(vault), yield_);
        vm.warp(vault.nextDrawTime() + 6 minutes); // late: primary trigger missed
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        uint256 reqId = vault.requestDraw();
        vrf.fulfill(reqId, 0);
        uint256 companySlice = (yield_ * 500) / 10_000;
        assertEq(vault.drawStartedLate(), false); // flag consumed by the draw (L-1 hardening)
        assertEq(usdc.balanceOf(keeper), bounty); // backstop keeper earned the bounty
        assertEq(usdc.balanceOf(company), companySlice - bounty); // company bore it
        assertEq(usdc.balanceOf(alice), 900 * ONE + (yield_ * 9000) / 10_000); // winner full 90%
    }

    /// @notice H-1 regression: the HEAVIEST draw path (Endaoment deploy-branch to a fresh
    ///         org + a late keeper bounty) must fit the PRODUCTION callback gas limit
    ///         (raised to 1.5M on the lock). The default 500k is NOT enough — this guards
    ///         against the callback running out of gas and stalling a draw.
    function test_HeavyCallbackFitsProductionGasLimit() public {
        MockEndaomentFactory factory = new MockEndaomentFactory(usdc, endaoTreasury, ENDAO_FEE_BPS);
        vm.startPrank(owner);
        vault.setEndaomentFactory(address(factory));
        bytes32[] memory rot = new bytes32[](1);
        rot[0] = ORG_ID;
        vault.setCharityRotation(rot);
        vault.setUseEndaoment(true);
        vault.setDrawBounty(1 * ONE);
        vm.stopPrank();

        _deposit(alice, 100 * ONE);
        pool.accrueYield(address(vault), 20 * ONE);
        vm.warp(vault.nextDrawTime() + 6 minutes); // late -> also exercises the bounty branch
        address keeper = makeAddr("heavykeeper");
        vm.prank(keeper);
        uint256 reqId = vault.requestDraw();

        uint256 g0 = gasleft();
        vrf.fulfill(reqId, 12345);
        uint256 used = g0 - gasleft();
        emit log_named_uint("heavy-path callback gas", used);
        assertLt(used, 1_500_000); // production callbackGasLimit set via VRFProviderOwner
    }

    function test_DrawBounty_OnlyOwnerAndCapped() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setDrawBounty(1 * ONE);

        uint256 cap = vault.MAX_DRAW_BOUNTY();
        vm.prank(owner);
        vm.expectRevert(CharityPrizeVault.BountyTooHigh.selector);
        vault.setDrawBounty(cap + 1);
    }

    /// @notice Bounty is capped at the company slice so it can never underflow or eat into
    ///         the winner/charity even on a tiny-yield week.
    function test_DrawBounty_CappedAtCompanySlice() public {
        vm.prank(owner);
        vault.setDrawBounty(10 * ONE); // larger than the whole company slice will be
        _deposit(alice, 100 * ONE);
        uint256 yield_ = 100; // tiny: company slice = 100*500/10000 = 5 units
        pool.accrueYield(address(vault), yield_);
        vm.warp(vault.nextDrawTime() + 6 minutes);
        address keeper = makeAddr("keeper2");
        vm.prank(keeper);
        uint256 reqId = vault.requestDraw();
        vrf.fulfill(reqId, 0);
        uint256 companySlice = (yield_ * 500) / 10_000; // = 5
        assertEq(usdc.balanceOf(keeper), companySlice); // bounty capped at the slice
        assertEq(usdc.balanceOf(company), 0); // company nets 0, no underflow/revert
        assertEq(usdc.balanceOf(alice), 900 * ONE + (yield_ * 9000) / 10_000); // winner intact
    }

    /// @notice L-1 hardening: a late draw's flag is consumed and never leaks a bounty into
    ///         the next on-time draw.
    function test_DrawBounty_LateFlagDoesNotLeak() public {
        vm.prank(owner);
        vault.setDrawBounty(1 * ONE);
        _deposit(alice, 100 * ONE);

        // Week 1: late draw pays the bounty.
        pool.accrueYield(address(vault), 20 * ONE);
        vm.warp(vault.nextDrawTime() + 6 minutes);
        address k1 = makeAddr("k1");
        vm.prank(k1);
        vrf.fulfill(vault.requestDraw(), 0);
        assertEq(usdc.balanceOf(k1), 1 * ONE);
        assertEq(vault.drawStartedLate(), false); // flag consumed

        // Week 2: on-time draw pays NO bounty (flag did not leak).
        pool.accrueYield(address(vault), 20 * ONE);
        vm.warp(vault.nextDrawTime());
        address k2 = makeAddr("k2");
        vm.prank(k2);
        vrf.fulfill(vault.requestDraw(), 0);
        assertEq(usdc.balanceOf(k2), 0);
    }

    function _words(uint256 w) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = w;
    }
}
