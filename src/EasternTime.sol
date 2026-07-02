// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title EasternTime
/// @notice Pure, dependency-free date math to schedule a recurring draw at
///         21:00 America/New_York — 9:00 PM Eastern, which is EDT (UTC-4) during
///         US daylight saving and EST (UTC-5) otherwise. DST switches on the
///         2nd Sunday of March (02:00 local) and the 1st Sunday of November
///         (02:00 local). Thursdays are never near those Sunday transitions, so
///         the offset for any given draw is unambiguous.
/// @dev Civil <-> day-index conversions use Howard Hinnant's algorithms.
library EasternTime {
    error ScheduleError();

    uint256 internal constant SECONDS_PER_DAY = 86400;

    /// @dev Days since 1970-01-01 for a civil (year, month, day). Valid for y >= 1970.
    function daysFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        int256 yy = int256(y);
        if (m <= 2) yy -= 1;
        int256 era = (yy >= 0 ? yy : yy - 399) / 400;
        uint256 yoe = uint256(yy - era * 400); // [0, 399]
        uint256 mp = m > 2 ? m - 3 : m + 9; // March = 0
        uint256 doy = (153 * mp + 2) / 5 + d - 1; // [0, 365]
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
        return uint256(era * 146097 + int256(doe) - 719468);
    }

    /// @dev Calendar year containing the UTC instant `ts`.
    function yearOf(uint256 ts) internal pure returns (uint256 y) {
        int256 z = int256(ts / SECONDS_PER_DAY) + 719468;
        int256 era = (z >= 0 ? z : z - 146096) / 146097;
        uint256 doe = uint256(z - era * 146097); // [0, 146096]
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
        uint256 mp = (5 * doy + 2) / 153; // [0, 11]
        uint256 m = mp < 10 ? mp + 3 : mp - 9; // [1, 12]
        y = uint256(int256(yoe) + era * 400 + (m <= 2 ? int256(1) : int256(0)));
    }

    /// @dev Day of week for a day-index. 0 = Sunday .. 6 = Saturday.
    function weekday(uint256 dayIndex) internal pure returns (uint256) {
        return (dayIndex + 4) % 7; // 1970-01-01 (index 0) was a Thursday -> 4
    }

    /// @dev Day-index of the nth Sunday of (year, month). n is 1-based.
    function nthSundayDay(uint256 y, uint256 m, uint256 n) internal pure returns (uint256) {
        uint256 first = daysFromCivil(y, m, 1);
        uint256 firstSunday = first + ((7 - weekday(first)) % 7);
        return firstSunday + (n - 1) * 7;
    }

    /// @dev Is US Eastern observing daylight saving (EDT) at UTC instant `ts`?
    function isEDT(uint256 ts) internal pure returns (bool) {
        uint256 y = yearOf(ts);
        uint256 dstStart = nthSundayDay(y, 3, 2) * SECONDS_PER_DAY + 7 hours; // 2nd Sun Mar, 02:00 EST = 07:00 UTC
        uint256 dstEnd = nthSundayDay(y, 11, 1) * SECONDS_PER_DAY + 6 hours; // 1st Sun Nov, 02:00 EDT = 06:00 UTC
        return ts >= dstStart && ts < dstEnd;
    }

    /// @notice The smallest UTC instant strictly greater than `from` that equals
    ///         Thursday 21:00 America/New_York. In UTC this lands in the early hours
    ///         of Friday: 01:00 (during EDT) or 02:00 (during EST).
    function nextThursday2100ET(uint256 from) internal pure returns (uint256) {
        uint256 startDay = from / SECONDS_PER_DAY;
        for (uint256 i = 0; i < 9; i++) {
            uint256 d = startDay + i;
            if (weekday(d) == 5) {
                // UTC Friday carries the Thursday-21:00-ET instant
                uint256 ts = d * SECONDS_PER_DAY + (isEDT(d * SECONDS_PER_DAY) ? 1 hours : 2 hours);
                if (ts > from) return ts;
            }
        }
        revert ScheduleError(); // unreachable: a Friday occurs within any 7-day span
    }
}
