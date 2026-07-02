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

/// @title DrawUpkeep
/// @notice Chainlink Automation custom-logic upkeep for the weekly draw. Unlike a
///         fixed-UTC cron (which cannot follow the EDT/EST switch), this watches the
///         vault's own `nextDrawTime`, so the draw fires at exactly Thursday 21:00
///         Eastern year-round. It also self-heals: if a randomness request sits
///         unfulfilled past the vault's stale timeout, the next perform cancels it
///         and immediately re-requests instead of waiting for a human.
/// @dev Stateless and permissionless — both vault functions it calls are themselves
///      permissionless and gated on-chain, so this contract adds no authority.
contract DrawUpkeep {
    IDrawVault public immutable vault;

    constructor(IDrawVault _vault) {
        vault = _vault;
    }

    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory) {
        if (vault.drawPending()) {
            upkeepNeeded = block.timestamp >= vault.pendingSince() + vault.STALE_DRAW_TIMEOUT();
        } else {
            upkeepNeeded = block.timestamp >= vault.nextDrawTime();
        }
        return (upkeepNeeded, "");
    }

    function performUpkeep(bytes calldata) external {
        if (vault.drawPending()) vault.cancelStaleDraw();
        vault.requestDraw();
    }
}
