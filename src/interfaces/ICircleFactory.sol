// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title ICircleFactory
/// @notice Minimal view of the factory used by the circles, the position NFT, the reputation registry and the
///         periphery contracts to authenticate each other.
interface ICircleFactory {
    function isCircle(address circle) external view returns (bool);
    function allowedToken(address token) external view returns (bool);
    function feeRecipient() external view returns (address);
    function owner() external view returns (address);
}
