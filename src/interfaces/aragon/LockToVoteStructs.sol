// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

// Local definitions matching LockToVote plugin structs
struct VotingSettings {
    uint8 votingMode;
    uint32 supportThreshold;
    uint32 minParticipation;
    uint32 minApprovalRatio;
    uint64 proposalDuration;
    uint256 minProposerVotingPower;
}

struct TargetConfig {
    address target;
    uint8 operation;
}

struct InstallationParameters {
    address token;
    VotingSettings votingSettings;
    bytes pluginMetadata;
    address createProposalCaller;
    address executeCaller;
    TargetConfig targetConfig;
}
