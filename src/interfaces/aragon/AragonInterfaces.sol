// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.0;

/**
 * @title Aragon Interfaces
 * @notice Minimal interfaces for interacting with Aragon DAOs
 * @dev Used by deployment scripts to interact with deployed DAOs
 */

/**
 * @notice Interface for Aragon LockManager (helper contract from LockToVote plugin)
 */
interface ILockManager {
    function lock(uint256 _amount) external;
    function unlock(uint256 _amount) external;
    function vote(uint256 _proposalId, uint8 _voteOption) external;
    function getVotingPower(address _account) external view returns (uint256);
}

/**
 * @notice Interface for Aragon LockToVote plugin
 */
interface ILockToVotePlugin {
    struct Action {
        address to;
        uint256 value;
        bytes data;
    }

    function createProposal(
        bytes calldata _metadata,
        Action[] memory _actions,
        uint64 _startDate,
        uint64 _endDate,
        bytes memory _data
    ) external returns (uint256 proposalId);

    function execute(uint256 _proposalId) external;

    function canExecute(uint256 _proposalId) external view returns (bool);
}

/**
 * @notice Interface for Aragon Multisig plugin
 */
interface IMultisig {
    struct Action {
        address to;
        uint256 value;
        bytes data;
    }

    function createProposal(
        bytes calldata _metadata,
        Action[] memory _actions,
        uint256 _allowFailureMap
    ) external returns (uint256 proposalId);

    function approve(uint256 _proposalId) external;

    function execute(uint256 _proposalId) external;

    function canApprove(uint256 _proposalId, address _account) external view returns (bool);

    function canExecute(uint256 _proposalId) external view returns (bool);
}

/**
 * @notice Interface for Aragon DAO
 */
interface IDAO {
    function hasPermission(address _where, address _who, bytes32 _permissionId, bytes memory _data) external view returns (bool);

    function grant(address _where, address _who, bytes32 _permissionId) external;

    function revoke(address _where, address _who, bytes32 _permissionId) external;

    function execute(bytes32 _callId, Action[] memory _actions, uint256 _allowFailureMap) external returns (bytes[] memory, uint256);

    struct Action {
        address to;
        uint256 value;
        bytes data;
    }
}
