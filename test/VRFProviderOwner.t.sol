// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkVRFProvider} from "../src/ChainlinkVRFProvider.sol";
import {VRFProviderOwner} from "../src/VRFProviderOwner.sol";
import {MockCoordinator} from "./ChainlinkVRFProvider.t.sol";

/// @notice Proves the C-1 fix: transferring the provider's ownership to the immutable
///         lock removes the owner's ability to repoint the VRF coordinator (the
///         winner-rigging vector) while keeping bounded gas tuning available.
contract VRFProviderOwnerTest is Test {
    MockCoordinator coordinator;
    ChainlinkVRFProvider provider;
    VRFProviderOwner lock;

    address constant ADMIN = address(0xA11CE);
    address constant ATTACKER = address(0xBAD);

    bytes32 constant KEY_HASH = bytes32(uint256(0xABCD));
    uint256 constant SUB_ID = 7;

    function setUp() public {
        coordinator = new MockCoordinator();
        // This test contract deploys the provider, so it is the initial owner.
        provider = new ChainlinkVRFProvider(address(coordinator), KEY_HASH, SUB_ID);
        lock = new VRFProviderOwner(address(provider), ADMIN);
    }

    /// @notice BEFORE the fix: the provider owner can repoint the coordinator, which is
    ///         exactly the rig vector. This documents the vulnerability the lock closes.
    function test_OwnerCanRepointCoordinator_BeforeLock() public {
        provider.setCoordinator(ATTACKER);
        assertEq(address(provider.s_vrfCoordinator()), ATTACKER);
    }

    function test_TransferOwnershipToLock_MakesLockOwner() public {
        provider.transferOwnership(address(lock));
        lock.acceptProviderOwnership();
        assertEq(provider.owner(), address(lock));
    }

    /// @notice AFTER the fix: the previous owner can no longer repoint the coordinator,
    ///         and the lock has no function that can — so no human can rig the draw.
    function test_AfterLock_NoHumanCanRepointCoordinator() public {
        provider.transferOwnership(address(lock));
        lock.acceptProviderOwnership();

        // The ex-owner (this contract) is no longer owner.
        vm.expectRevert();
        provider.setCoordinator(ATTACKER);

        // The attacker certainly cannot.
        vm.prank(ATTACKER);
        vm.expectRevert();
        provider.setCoordinator(ATTACKER);

        // And the lock itself exposes no setCoordinator path (compile-time guarantee):
        // its only privileged call is bounded request-config tuning.
        assertEq(address(provider.s_vrfCoordinator()), address(coordinator));
    }

    function test_AfterLock_AdminCanTuneGasWithinBounds() public {
        provider.transferOwnership(address(lock));
        lock.acceptProviderOwnership();

        vm.prank(ADMIN);
        lock.setProviderRequestConfig(5, 800_000);
        assertEq(provider.callbackGasLimit(), 800_000);
        assertEq(provider.requestConfirmations(), 5);
    }

    function test_AfterLock_NonAdminCannotTune() public {
        provider.transferOwnership(address(lock));
        lock.acceptProviderOwnership();

        vm.prank(ATTACKER);
        vm.expectRevert(VRFProviderOwner.OnlyAdmin.selector);
        lock.setProviderRequestConfig(5, 800_000);
    }

    /// @notice Even the admin cannot brick the draw: the provider re-clamps the bounds,
    ///         so a too-low gas limit is rejected through the lock too.
    function test_AfterLock_AdminCannotBrickViaLowGas() public {
        provider.transferOwnership(address(lock));
        lock.acceptProviderOwnership();

        vm.prank(ADMIN);
        vm.expectRevert(ChainlinkVRFProvider.InvalidRequestConfig.selector);
        lock.setProviderRequestConfig(3, 1);
    }
}
