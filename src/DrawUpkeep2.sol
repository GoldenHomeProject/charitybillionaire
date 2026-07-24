// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IDrawVault {
    function nextDrawTime() external view returns (uint256);
    function drawPending() external view returns (bool);
    function pendingSince() external view returns (uint256);
    function STALE_DRAW_TIMEOUT() external view returns (uint256);
    function requestDraw() external returns (uint256);
    function cancelStaleDraw() external;
}

interface ICharityForwarder {
    function pending() external view returns (uint256);
    function forward() external returns (address, uint256);
}

/// @title DrawUpkeep2
/// @notice Permissionless keeper for the weekly draw that ALSO sweeps the charity slice
///         through the CharityForwarder. Supersedes DrawUpkeep: same self-healing draw
///         trigger (fires at the vault's own `nextDrawTime` so it tracks the EDT/EST
///         switch, and re-requests a stalled VRF request past the stale timeout), plus it
///         calls `forwarder.forward()` shortly after each draw so the week's donation lands
///         within minutes and the forwarder never accumulates more than one slice.
/// @dev Both duties are INDEPENDENT: the forward is wrapped in try/catch so an Endaoment
///      outage can never block the draw trigger, and every branch is guarded so a call at
///      the "wrong" time is a no-op rather than a revert (safe for a fixed cron/Automation).
///      Stateless and permissionless — every vault/forwarder function it calls is itself
///      permissionless and gated on-chain, so this contract adds no authority.
contract DrawUpkeep2 {
    IDrawVault public immutable vault;
    ICharityForwarder public immutable forwarder;

    constructor(IDrawVault _vault, ICharityForwarder _forwarder) {
        vault = _vault;
        forwarder = _forwarder;
    }

    /// @notice Chainlink Automation view: work is needed if a draw is due, a VRF request is
    ///         stale, or there is a charity slice waiting to be forwarded.
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory) {
        bool drawWork;
        if (vault.drawPending()) {
            drawWork = block.timestamp >= vault.pendingSince() + vault.STALE_DRAW_TIMEOUT();
        } else {
            drawWork = block.timestamp >= vault.nextDrawTime();
        }
        upkeepNeeded = drawWork || forwarder.pending() > 0;
        return (upkeepNeeded, "");
    }

    /// @notice Sweep any pending charity slice, then trigger/heal the draw. Safe to call at
    ///         any time: each step is guarded, so an untimely call is a no-op, and the
    ///         forward can never revert the draw logic.
    function performUpkeep(bytes calldata) external {
        // 1. Forward the charity slice if one is waiting — isolated so a failure here
        //    (e.g. a transient Endaoment issue) never blocks the draw trigger below.
        if (forwarder.pending() > 0) {
            try forwarder.forward() {} catch {}
        }

        // 2. Draw trigger / stale-heal — guarded so it only acts when actually due.
        if (vault.drawPending()) {
            if (block.timestamp >= vault.pendingSince() + vault.STALE_DRAW_TIMEOUT()) {
                vault.cancelStaleDraw();
                vault.requestDraw();
            }
        } else if (block.timestamp >= vault.nextDrawTime()) {
            vault.requestDraw();
        }
    }
}
