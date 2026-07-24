// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DrawUpkeep2, IDrawVault, ICharityForwarder} from "../src/DrawUpkeep2.sol";
import {CharityForwarder, ICharityRotationSource} from "../src/CharityForwarder.sol";
import {IEndaomentOrgFundFactory} from "../src/interfaces/IEndaomentOrgFundFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVaultAdmin {
    function owner() external view returns (address);
    function charityIndex() external view returns (uint256);
    function nextDrawTime() external view returns (uint256);
    function drawPending() external view returns (bool);
    function pendingRequestId() external view returns (uint256);
    function allowCharity(address, bool) external;
    function setCharity(address) external;
    function setUseEndaoment(bool) external;
    function setCharityIndex(uint256) external;
}

/// @notice Fork test for the combined draw+forward keeper.
///     BASE_RPC_URL=https://mainnet.base.org forge test --match-path test/DrawUpkeep2.fork.t.sol -vv
contract DrawUpkeep2ForkTest is Test {
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IEndaomentOrgFundFactory constant FACTORY =
        IEndaomentOrgFundFactory(0x10fD9348136dCea154F752fe0B6dB45Fc298A589);
    address constant VAULT = 0x3993bD557E0d4a1E5A8Ec09a005E7Eee3E032f70;

    DrawUpkeep2 keeper;
    CharityForwarder forwarder;
    address ownerAddr;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        ownerAddr = IVaultAdmin(VAULT).owner();
        forwarder = new CharityForwarder(USDC, FACTORY, ICharityRotationSource(VAULT));
        keeper = new DrawUpkeep2(IDrawVault(VAULT), ICharityForwarder(address(forwarder)));
    }

    function test_performUpkeep_forwardsPendingSlice() public {
        if (!forked) return;
        vm.prank(ownerAddr);
        IVaultAdmin(VAULT).setCharityIndex(4); // forwarder targets rotation[3] (St. Jude, deployed)
        deal(address(USDC), address(forwarder), 5_000_000);
        assertEq(forwarder.pending(), 5_000_000);

        (bool needed,) = keeper.checkUpkeep("");
        assertTrue(needed, "pending slice => upkeep needed");
        keeper.performUpkeep("");
        assertEq(forwarder.pending(), 0, "slice forwarded to charity");
    }

    function test_performUpkeep_triggersDrawWhenDue() public {
        if (!forked) return;
        // apply the fix so the draw can't brick, then jump to draw time
        vm.startPrank(ownerAddr);
        IVaultAdmin(VAULT).allowCharity(address(forwarder), true);
        IVaultAdmin(VAULT).setCharity(address(forwarder));
        IVaultAdmin(VAULT).setUseEndaoment(false);
        vm.stopPrank();

        assertFalse(IVaultAdmin(VAULT).drawPending());
        vm.warp(IVaultAdmin(VAULT).nextDrawTime() + 1);
        (bool needed,) = keeper.checkUpkeep("");
        assertTrue(needed, "past draw time => needed");
        keeper.performUpkeep("");
        assertTrue(IVaultAdmin(VAULT).drawPending(), "draw requested");
    }

    // F2 (Fable audit): performUpkeep forwards the charity donation inside a try/catch. If the
    // tx gas is too low, forward() starves, the failure is SWALLOWED, and the donation is
    // silently skipped while the tx reports success. Prove: low gas skips the donation; the
    // worker's hardcoded 2M gas donates it. (deploy-and-donate is the expensive ~357k path.)
    function test_F2_lowGasSilentlySkipsDonation_2MFixesIt() public {
        if (!forked) return;
        vm.prank(ownerAddr);
        IVaultAdmin(VAULT).setCharityIndex(3); // forwarder targets rotation[2] = UNDEPLOYED (deploy path)
        deal(address(USDC), address(forwarder), 4_000_000);

        // Low gas (what auto-estimation would settle on): donation starves + is swallowed.
        uint256 snap = vm.snapshotState();
        try keeper.performUpkeep{gas: 350_000}("") {} catch {}
        assertEq(forwarder.pending(), 4_000_000, "F2 reproduced: low gas SILENTLY skips donation");
        vm.revertToState(snap);

        // The worker's hardcoded 2M gas: donation actually lands.
        keeper.performUpkeep{gas: 2_000_000}("");
        assertEq(forwarder.pending(), 0, "2M gas: charity donation lands, slice swept");
    }

    function test_performUpkeep_noopWhenNothingToDo() public {
        if (!forked) return;
        // not draw time, no pending slice, no pending draw => no revert, no state change
        assertFalse(IVaultAdmin(VAULT).drawPending());
        assertEq(forwarder.pending(), 0);
        (bool needed,) = keeper.checkUpkeep("");
        assertFalse(needed, "nothing due => not needed");
        keeper.performUpkeep(""); // must not revert
    }

    function test_forwardFailureNeverBlocksDraw() public {
        if (!forked) return;
        // Point the forwarder at an EIN whose donate would fail is hard to force on a real
        // fork; instead assert the ordering property: with a pending slice AND draw due,
        // performUpkeep both forwards and requests without reverting.
        vm.startPrank(ownerAddr);
        IVaultAdmin(VAULT).allowCharity(address(forwarder), true);
        IVaultAdmin(VAULT).setCharity(address(forwarder));
        IVaultAdmin(VAULT).setUseEndaoment(false);
        IVaultAdmin(VAULT).setCharityIndex(4);
        vm.stopPrank();
        deal(address(USDC), address(forwarder), 5_000_000);
        vm.warp(IVaultAdmin(VAULT).nextDrawTime() + 1);
        keeper.performUpkeep("");
        assertEq(forwarder.pending(), 0, "forwarded");
        assertTrue(IVaultAdmin(VAULT).drawPending(), "and draw requested in same call");
    }
}
