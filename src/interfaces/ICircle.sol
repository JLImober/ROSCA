// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title ICircle
/// @notice Read-only view of a circle used by the position NFT metadata and by the position market.
interface ICircle {
    /// @notice Snapshot of one payout position (one slot = one round's pot).
    /// @param token Token in which the pot is paid.
    /// @param grossPot Pot size if every member pays (contribution * members), before fees.
    /// @param payoutAmount Net amount claimable once the round is closed (0 while open).
    /// @param encumbrance Amount that will be withheld from this slot's pot to repay the slot member's debt and
    ///        refill their collateral. Buyers of a position must price this in.
    /// @param estimatedPayoutTime Deadline of the round that pays this slot (0 before the circle starts).
    /// @param closed True once the round has been closed and the payout is claimable.
    /// @param live False once the payout was claimed or the circle was cancelled.
    struct PositionInfo {
        address token;
        uint256 grossPot;
        uint256 payoutAmount;
        uint256 encumbrance;
        uint256 estimatedPayoutTime;
        bool closed;
        bool live;
    }

    function positionInfo(uint32 slot) external view returns (PositionInfo memory);
    function isPositionLive(uint32 slot) external view returns (bool);
}
