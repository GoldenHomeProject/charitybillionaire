// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EasternTime} from "../src/EasternTime.sol";

contract EasternTimeTest is Test {
    // Helper: build a UTC unix timestamp from a civil date/time.
    function _utc(uint256 y, uint256 m, uint256 d, uint256 hh, uint256 mm) internal pure returns (uint256) {
        return EasternTime.daysFromCivil(y, m, d) * 1 days + hh * 1 hours + mm * 1 minutes;
    }

    function test_NextDraw_SummerIsEDT_0100UTC() public pure {
        // From Wed Jun 10 2026 -> Thu Jun 11 2026 21:00 EDT == Fri Jun 12 01:00 UTC.
        uint256 got = EasternTime.nextThursday2100ET(_utc(2026, 6, 11, 2, 12));
        assertEq(got, _utc(2026, 6, 12, 1, 0));
    }

    function test_NextDraw_WinterIsEST_0200UTC() public pure {
        // Thu Jan 1 2026 21:00 EST == Fri Jan 2 02:00 UTC.
        uint256 got = EasternTime.nextThursday2100ET(_utc(2026, 1, 1, 0, 0));
        assertEq(got, _utc(2026, 1, 2, 2, 0));
    }

    function test_NextDraw_JustAfterDraw_AdvancesAFullWeek() public pure {
        // 30 min after the Jun 11 draw -> next is Jun 18, not a same-week double-fire.
        uint256 got = EasternTime.nextThursday2100ET(_utc(2026, 6, 12, 1, 30));
        assertEq(got, _utc(2026, 6, 19, 1, 0));
    }

    function test_NextDraw_AcrossSpringForward() public pure {
        // DST starts 2nd Sun Mar 8 2026. Thu Mar 5 is still EST (02:00 UTC),
        // the following Thu Mar 12 is EDT (01:00 UTC).
        assertEq(EasternTime.nextThursday2100ET(_utc(2026, 3, 5, 0, 0)), _utc(2026, 3, 6, 2, 0));
        assertEq(EasternTime.nextThursday2100ET(_utc(2026, 3, 9, 0, 0)), _utc(2026, 3, 13, 1, 0));
    }

    function test_NextDraw_AcrossFallBack() public pure {
        // DST ends 1st Sun Nov 1 2026. Thu Oct 29 is EDT (01:00 UTC),
        // the following Thu Nov 5 is EST (02:00 UTC).
        assertEq(EasternTime.nextThursday2100ET(_utc(2026, 10, 30, 0, 0)), _utc(2026, 10, 30, 1, 0));
        assertEq(EasternTime.nextThursday2100ET(_utc(2026, 11, 2, 0, 0)), _utc(2026, 11, 6, 2, 0));
    }

    function test_DstBoundaries_2026() public pure {
        assertEq(EasternTime.nthSundayDay(2026, 3, 2), EasternTime.daysFromCivil(2026, 3, 8));
        assertEq(EasternTime.nthSundayDay(2026, 11, 1), EasternTime.daysFromCivil(2026, 11, 1));
    }

    function test_Result_AlwaysThursday2100ET_Fuzz(uint256 from) public pure {
        from = bound(from, _utc(2024, 1, 1, 0, 0), _utc(2035, 12, 31, 0, 0));
        uint256 draw = EasternTime.nextThursday2100ET(from);
        assertGt(draw, from);
        // The instant must be EDT->01:00 or EST->02:00 UTC, landing on a UTC Friday.
        uint256 day = draw / 1 days;
        assertEq(EasternTime.weekday(day), 5); // Friday in UTC
        uint256 secondsIntoDay = draw - day * 1 days;
        assertEq(secondsIntoDay, EasternTime.isEDT(draw) ? 1 hours : 2 hours);
        // And it must be the *first* such slot: no Thursday draw strictly between from
        // and draw. The max gap is 7 days + 1 hour, not 7 days: starting just after the
        // last EDT draw of the year (Fri 01:00 UTC), the next draw is EST (Fri 02:00 UTC).
        assertLe(draw - from, 7 days + 1 hours);
    }

    function test_NextDraw_FallBackWeekGapIs7DaysPlus1Hour() public pure {
        // One second after the last EDT draw (Thu Oct 29 2026 21:00 EDT = Fri Oct 30
        // 01:00 UTC) the next draw is Thu Nov 5 21:00 EST = Fri Nov 6 02:00 UTC.
        uint256 from = _utc(2026, 10, 30, 1, 0) + 1;
        uint256 draw = EasternTime.nextThursday2100ET(from);
        assertEq(draw, _utc(2026, 11, 6, 2, 0));
        assertEq(draw - from, 7 days + 1 hours - 1);
    }

    function test_NextDraw_ExactDrawInstant_AdvancesFullWeek() public pure {
        // `from` exactly equal to a draw instant must yield the NEXT week's draw
        // (strictly-greater), so a fulfill in the same second can't double-fire.
        assertEq(EasternTime.nextThursday2100ET(_utc(2026, 6, 12, 1, 0)), _utc(2026, 6, 19, 1, 0));
    }

    function test_IsEDT_ExactTransitionInstants_2026() public pure {
        // Spring forward: 2nd Sun Mar 8 2026, 02:00 EST = 07:00 UTC.
        assertFalse(EasternTime.isEDT(_utc(2026, 3, 8, 6, 59) + 59));
        assertTrue(EasternTime.isEDT(_utc(2026, 3, 8, 7, 0)));
        // Fall back: 1st Sun Nov 1 2026, 02:00 EDT = 06:00 UTC.
        assertTrue(EasternTime.isEDT(_utc(2026, 11, 1, 5, 59) + 59));
        assertFalse(EasternTime.isEDT(_utc(2026, 11, 1, 6, 0)));
    }

    function test_NextDraw_LeapDayThursday2024() public pure {
        // Feb 29 2024 was a Thursday (EST; DST 2024 starts Mar 10).
        assertEq(EasternTime.nextThursday2100ET(_utc(2024, 2, 29, 0, 0)), _utc(2024, 3, 1, 2, 0));
    }

    function test_NextDraw_YearBoundaryThursday() public pure {
        // Dec 31 2026 is a Thursday; its 21:00 EST draw lands on Jan 1 2027 02:00 UTC.
        assertEq(EasternTime.nextThursday2100ET(_utc(2026, 12, 31, 0, 0)), _utc(2027, 1, 1, 2, 0));
    }
}
