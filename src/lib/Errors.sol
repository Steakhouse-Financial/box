// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

library Errors {
    // Access control errors
    error OnlyOwner();
    error OnlyCurator();
    error OnlyGuardian();
    error OnlyCuratorOrGuardian();
    error OnlyAllocators();
    error OnlyFeeders();
    error OnlyAllocatorsOrShutdown();
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
    
    // Investment token errors
    error TokenNotWhitelisted();
    error TokensNotWhitelisted();
    error OracleRequired();
    error NoOracleForToken();
    error TokenBalanceMustBeZero();
    
    // Slippage errors
    error SwapperDidSpendTooMuch();
    error AllocationTooExpensive();
    error TokenSaleNotGeneratingEnoughCurrency();
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

    // Skim errors
    error CannotSkimCurrency();
    error CannotSkimInvestmentToken();
    error AlreadySet();
    error CannotSkimZero();
} 