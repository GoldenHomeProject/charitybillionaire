// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Slim randomness interface, modeled on Chainlink VRF v2.5.
/// In production this is the VRFCoordinatorV2Plus; the vault is the consumer.
/// The provider calls back `CharityPrizeVault.fulfillRandomWords(requestId, randomWords)`.
interface IRandomProvider {
    function requestRandomWords(address consumer) external returns (uint256 requestId);
}
