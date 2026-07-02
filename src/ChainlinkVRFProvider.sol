// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFConsumerBaseV2Plus} from
    "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from
    "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IRandomProvider} from "./interfaces/IRandomProvider.sol";

/// @title ChainlinkVRFProvider
/// @notice Production randomness source for CharityPrizeVault. It is the real
///         Chainlink VRF v2.5 consumer (holds the subscription), and presents the
///         vault's slim `IRandomProvider` interface so the vault itself needs no
///         knowledge of Chainlink. The vault calls `requestRandomWords`; when the
///         coordinator returns verified randomness, this contract forwards it to
///         `vault.fulfillRandomWords`, satisfying the vault's
///         `msg.sender == randomProvider` check.
///
/// Verifiability: the draw's randomness is produced by Chainlink VRF, whose
/// cryptographic proof is published and validated on-chain by the coordinator
/// before this contract is ever called. Neither the operator nor this contract
/// can influence the value. The only privileged action is the one-time `setVault`
/// wiring (and gas-tuning that cannot affect the random result).
contract ChainlinkVRFProvider is VRFConsumerBaseV2Plus, IRandomProvider {
    /// @notice Gas lane key hash for the desired max gas price.
    bytes32 public immutable keyHash;
    /// @notice The VRF v2.5 subscription that funds requests (in LINK).
    uint256 public immutable subscriptionId;

    /// @notice The vault this provider serves. Set exactly once after deploy to
    ///         break the constructor circular dependency, then frozen.
    address public vault;

    /// @notice Number of block confirmations the oracle waits before responding.
    uint16 public requestConfirmations = 3;
    /// @notice Gas budget forwarded to the fulfillment callback (the vault's draw).
    uint32 public callbackGasLimit = 500_000;

    /// @notice Bounds on owner-tunable request config, so no setting can silently
    ///         brick the draw. The floor guarantees the vault's callback always has
    ///         enough gas to complete a payout; the ceiling stays within VRF limits.
    uint32 public constant MIN_CALLBACK_GAS = 200_000;
    uint32 public constant MAX_CALLBACK_GAS = 2_500_000;
    uint16 public constant MIN_CONFIRMATIONS = 3;
    uint16 public constant MAX_CONFIRMATIONS = 200;

    event VaultSet(address indexed vault);
    event RandomnessRequested(uint256 indexed requestId);
    event RandomnessFulfilled(uint256 indexed requestId);
    event RequestConfigUpdated(uint16 requestConfirmations, uint32 callbackGasLimit);

    error VaultAlreadySet();
    error VaultNotSet();
    error OnlyVault();
    error UnexpectedConsumer();
    error InvalidRequestConfig();

    /// @param _coordinator Chainlink VRF v2.5 coordinator for the target chain.
    /// @param _keyHash Gas-lane key hash.
    /// @param _subscriptionId Pre-created, LINK-funded VRF subscription id.
    constructor(address _coordinator, bytes32 _keyHash, uint256 _subscriptionId)
        VRFConsumerBaseV2Plus(_coordinator)
    {
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
    }

    /// @notice One-time wiring of the vault. Deploy order: create subscription ->
    ///         deploy this provider -> deploy vault(randomProvider = this) ->
    ///         setVault(vault) -> add this provider as a subscription consumer.
    function setVault(address _vault) external onlyOwner {
        if (vault != address(0)) revert VaultAlreadySet();
        if (_vault == address(0)) revert ZeroAddress();
        vault = _vault;
        emit VaultSet(_vault);
    }

    /// @inheritdoc IRandomProvider
    /// @dev Only the wired vault may spend the subscription's LINK. `consumer` is
    ///      the vault passing `address(this)`; we require it to match as a guard.
    function requestRandomWords(address consumer) external override returns (uint256 requestId) {
        if (vault == address(0)) revert VaultNotSet();
        if (msg.sender != vault) revert OnlyVault();
        if (consumer != vault) revert UnexpectedConsumer();

        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                // Pay request fees in LINK from the subscription (not native ETH).
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );
        emit RandomnessRequested(requestId);
    }

    /// @dev Coordinator callback (via rawFulfillRandomWords). Forwards verified
    ///      randomness to the vault, which performs the actual draw.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        IRandomConsumer(vault).fulfillRandomWords(requestId, randomWords);
        emit RandomnessFulfilled(requestId);
    }

    /// @notice Owner gas tuning. Cannot affect the random result, only delivery.
    function setRequestConfig(uint16 _requestConfirmations, uint32 _callbackGasLimit)
        external
        onlyOwner
    {
        if (
            _callbackGasLimit < MIN_CALLBACK_GAS || _callbackGasLimit > MAX_CALLBACK_GAS
                || _requestConfirmations < MIN_CONFIRMATIONS || _requestConfirmations > MAX_CONFIRMATIONS
        ) revert InvalidRequestConfig();
        requestConfirmations = _requestConfirmations;
        callbackGasLimit = _callbackGasLimit;
        emit RequestConfigUpdated(_requestConfirmations, _callbackGasLimit);
    }
}

/// @dev The vault's fulfillment entrypoint (mirrors CharityPrizeVault).
interface IRandomConsumer {
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}
