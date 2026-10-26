// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ICircleFactory} from "./interfaces/ICircleFactory.sol";

/// @title ReputationRegistry
/// @author Jose L Imoberdorf
/// @notice Non-transferable payment history of every member across all circles. Only circles registered in the
///         factory can write, so the history cannot be faked or sold. Other circles (or other protocols) can read
///         it to lower collateral requirements for reliable members in future versions.
contract ReputationRegistry {
    struct Record {
        uint32 onTimePayments;
        uint32 latePayments;
        uint32 defaults;
        uint32 circlesCompleted;
        uint256 outstandingDebt;
    }

    ICircleFactory public immutable factory;
    mapping(address => Record) private _records;

    event PaymentRecorded(address indexed member, address indexed circle, bool onTime);
    event DefaultRecorded(address indexed member, address indexed circle, uint256 uncovered);
    event DebtRepaid(address indexed member, address indexed circle, uint256 amount);
    event CompletionRecorded(address indexed member, address indexed circle);

    error ZeroAddress();
    error NotCircle();

    modifier onlyCircle() {
        if (!factory.isCircle(msg.sender)) revert NotCircle();
        _;
    }

    /// @param factory_ Address of the CircleFactory (it can be pre-computed before the factory is deployed).
    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = ICircleFactory(factory_);
    }

    function recordPayment(address member, bool onTime) external onlyCircle {
        if (onTime) _records[member].onTimePayments++;
        else _records[member].latePayments++;
        emit PaymentRecorded(member, msg.sender, onTime);
    }

    function recordDefault(address member, uint256 uncovered) external onlyCircle {
        Record storage r = _records[member];
        r.defaults++;
        r.outstandingDebt += uncovered;
        emit DefaultRecorded(member, msg.sender, uncovered);
    }

    function recordDebtRepaid(address member, uint256 amount) external onlyCircle {
        Record storage r = _records[member];
        r.outstandingDebt = amount >= r.outstandingDebt ? 0 : r.outstandingDebt - amount;
        emit DebtRepaid(member, msg.sender, amount);
    }

    function recordCompletion(address member) external onlyCircle {
        _records[member].circlesCompleted++;
        emit CompletionRecorded(member, msg.sender);
    }

    function recordOf(address member) external view returns (Record memory) {
        return _records[member];
    }
}
