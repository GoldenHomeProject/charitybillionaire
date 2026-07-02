// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkVRFProvider} from "../src/ChainlinkVRFProvider.sol";
import {VRFConsumerBaseV2Plus} from
    "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from
    "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @notice Minimal stand-in for the VRF v2.5 coordinator. Records the last request
///         and, on `fulfill`, calls back the consumer's `rawFulfillRandomWords`
///         FROM this address so the consumer's coordinator check passes.
contract MockCoordinator {
    uint256 public nextId = 1;
    uint256 public lastSubId;
    bytes32 public lastKeyHash;
    uint32 public lastCallbackGasLimit;
    uint16 public lastConfirmations;
    bool public lastNativePayment;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req)
        external
        returns (uint256 requestId)
    {
        requestId = nextId++;
        lastSubId = req.subId;
        lastKeyHash = req.keyHash;
        lastCallbackGasLimit = req.callbackGasLimit;
        lastConfirmations = req.requestConfirmations;
        // Decode extraArgs (skip the 4-byte tag) to confirm LINK payment.
        bytes calldata args = req.extraArgs;
        VRFV2PlusClient.ExtraArgsV1 memory decoded =
            abi.decode(args[4:], (VRFV2PlusClient.ExtraArgsV1));
        lastNativePayment = decoded.nativePayment;
    }

    function fulfill(address consumer, uint256 requestId, uint256 randomWord) external {
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        ChainlinkVRFProvider(consumer).rawFulfillRandomWords(requestId, words);
    }
}

/// @notice Stand-in vault: records the randomness it receives from the provider.
contract MockVault {
    uint256 public lastRequestId;
    uint256 public lastRandomWord;
    uint256 public callCount;

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        lastRequestId = requestId;
        lastRandomWord = randomWords[0];
        callCount++;
    }
}

contract ChainlinkVRFProviderTest is Test {
    MockCoordinator coordinator;
    ChainlinkVRFProvider provider;
    MockVault vault;

    bytes32 constant KEY_HASH = bytes32(uint256(0xABCD));
    uint256 constant SUB_ID = 42;
    address constant STRANGER = address(0xBEEF);

    function setUp() public {
        coordinator = new MockCoordinator();
        provider = new ChainlinkVRFProvider(address(coordinator), KEY_HASH, SUB_ID);
        vault = new MockVault();
    }

    function test_constructor_setsImmutables() public view {
        assertEq(provider.keyHash(), KEY_HASH);
        assertEq(provider.subscriptionId(), SUB_ID);
        assertEq(address(provider.s_vrfCoordinator()), address(coordinator));
        assertEq(provider.vault(), address(0));
    }

    function test_setVault_onlyOnce() public {
        provider.setVault(address(vault));
        assertEq(provider.vault(), address(vault));
        vm.expectRevert(ChainlinkVRFProvider.VaultAlreadySet.selector);
        provider.setVault(address(0x1234));
    }

    function test_setVault_rejectsZero() public {
        vm.expectRevert(VRFConsumerBaseV2Plus.ZeroAddress.selector);
        provider.setVault(address(0));
    }

    function test_setVault_onlyOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        provider.setVault(address(vault));
    }

    function test_requestRandomWords_revertsBeforeVaultSet() public {
        vm.expectRevert(ChainlinkVRFProvider.VaultNotSet.selector);
        provider.requestRandomWords(address(vault));
    }

    function test_requestRandomWords_onlyVaultMayCall() public {
        provider.setVault(address(vault));
        vm.prank(STRANGER);
        vm.expectRevert(ChainlinkVRFProvider.OnlyVault.selector);
        provider.requestRandomWords(address(vault));
    }

    function test_requestRandomWords_rejectsUnexpectedConsumer() public {
        provider.setVault(address(vault));
        vm.prank(address(vault));
        vm.expectRevert(ChainlinkVRFProvider.UnexpectedConsumer.selector);
        provider.requestRandomWords(STRANGER);
    }

    function test_requestRandomWords_forwardsCorrectParams() public {
        provider.setVault(address(vault));
        vm.prank(address(vault));
        uint256 requestId = provider.requestRandomWords(address(vault));

        assertEq(requestId, 1);
        assertEq(coordinator.lastSubId(), SUB_ID);
        assertEq(coordinator.lastKeyHash(), KEY_HASH);
        assertEq(coordinator.lastCallbackGasLimit(), 500_000);
        assertEq(coordinator.lastConfirmations(), 3);
        assertEq(coordinator.lastNativePayment(), false); // pays in LINK
    }

    function test_fullFlow_forwardsRandomnessToVault() public {
        provider.setVault(address(vault));
        vm.prank(address(vault));
        uint256 requestId = provider.requestRandomWords(address(vault));

        coordinator.fulfill(address(provider), requestId, 777);

        assertEq(vault.callCount(), 1);
        assertEq(vault.lastRequestId(), requestId);
        assertEq(vault.lastRandomWord(), 777);
    }

    function test_rawFulfill_onlyCoordinator() public {
        provider.setVault(address(vault));
        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        vm.prank(STRANGER);
        vm.expectRevert();
        provider.rawFulfillRandomWords(1, words);
    }

    function test_setRequestConfig_ownerOnly_andApplies() public {
        provider.setRequestConfig(5, 800_000);
        assertEq(provider.requestConfirmations(), 5);
        assertEq(provider.callbackGasLimit(), 800_000);

        vm.prank(STRANGER);
        vm.expectRevert();
        provider.setRequestConfig(1, 1);
    }

    /// @notice Security (H-1): config bounds prevent bricking the draw with a gas limit
    ///         too low to complete a payout (or an out-of-range confirmation count).
    function test_setRequestConfig_rejectsOutOfBounds() public {
        // Cache constants first: reading them after vm.expectRevert would consume the arm.
        uint32 minGas = provider.MIN_CALLBACK_GAS();
        uint32 maxGas = provider.MAX_CALLBACK_GAS();
        uint16 minConf = provider.MIN_CONFIRMATIONS();

        vm.expectRevert(ChainlinkVRFProvider.InvalidRequestConfig.selector);
        provider.setRequestConfig(3, 1); // gas below floor — the brick vector

        vm.expectRevert(ChainlinkVRFProvider.InvalidRequestConfig.selector);
        provider.setRequestConfig(3, maxGas + 1);

        vm.expectRevert(ChainlinkVRFProvider.InvalidRequestConfig.selector);
        provider.setRequestConfig(2, 500_000); // confirmations below floor

        vm.expectRevert(ChainlinkVRFProvider.InvalidRequestConfig.selector);
        provider.setRequestConfig(201, 500_000); // confirmations above ceiling

        // Boundaries are accepted.
        provider.setRequestConfig(minConf, minGas);
        assertEq(provider.callbackGasLimit(), minGas);
    }
}
