// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

library ErrorsLib {

    // General errors
    error InvalidAddress();
    error InvalidAmount();

    // Access control errors
    error OnlyOwner();
    error OnlyCurator();
    error OnlyGuardian();
    error OnlyCuratorOrGuardian();
    error OnlyAllocators();
    error OnlyFeeders();
    error OnlySkimRecipient();
    error OnlyAllocatorsOrShutdown();
    error OnlyMorpho();
    error InvalidOwner();
    
    // Deposit/Mint errors
    error CannotDepositZero();
    error CannotMintZero();
    error CannotDepositIfShutdown();
    error CannotMintIfShutdown();
    
    // Withdraw/Redeem errors
    error InsufficientShares();
    error InsufficientAllowance();
    error InsufficientLiquidity();
    error CannotUnboxZeroShares();
    error DataAlreadyTimelocked();
    
    // Token errors
    error TokenNotWhitelisted();
    error TokenAlreadyWhitelisted();
    error OracleRequired();
    error NoOracleForToken();
    error TokenBalanceMustBeZero();
    error TooManyTokens();

    // Slippage errors
    error SwapperDidSpendTooMuch();
    error AllocationTooExpensive();
    error TokenSaleNotGeneratingEnoughAssets();
    error ReallocationSlippageTooHigh();
    error TooMuchAccumulatedSlippage();
    error SlippageTooHigh();
    
    // Shutdown/Recover errors
    error OnlyGuardianCanShutdown();
    error OnlyGuardianCanRecover();
    error AlreadyShutdown();
    error NotShutdown();
    error CannotAllocateIfShutdown();
    error CannotReallocateIfShutdown();

    // Timelock errors
    error TimelockNotExpired();
    error DataNotTimelocked();
    error InvalidTimelock();
    error TimelockDecrease();
    error TimelockIncrease();

    // Skim errors
    error CannotSkimAsset();
    error CannotSkimToken();
    error AlreadySet();
    error CannotSkimZero();
}