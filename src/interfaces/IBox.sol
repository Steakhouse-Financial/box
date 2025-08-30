// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Steakhouse
pragma solidity >= 0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ISwapper} from "./ISwapper.sol";
import {IOracle} from "./IOracle.sol";

interface IBox is IERC4626 {
    /* EVENTS */
    event BoxCreated(address indexed box, address indexed asset, address indexed owner, address curator, string name, string symbol, 
        uint256 maxSlippage, uint256 slippageEpochDuration, uint256 shutdownSlippageDuration);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event CuratorUpdated(address indexed previousCurator, address indexed newCurator);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event AllocatorUpdated(address indexed account, bool isAllocator);
    event FeederUpdated(address indexed account, bool isFeeder);
    
    event Allocation(IERC20 indexed token, uint256 assets, uint256 tokens, int256 slippagePct, ISwapper indexed swapper, bytes data);
    event Deallocation(IERC20 indexed token, uint256 tokens, uint256 assets, int256 slippagePct, ISwapper indexed swapper, bytes data);
    event Reallocation(IERC20 indexed fromToken, IERC20 indexed toToken, uint256 tokensFrom, uint256 tokensTo, int256 slippagePct, ISwapper indexed swapper, bytes data);
    event Shutdown(address indexed guardian);
    event Recover(address indexed guardian);
    event Unbox(address indexed user, uint256 shares);
    event Skim(IERC20 indexed token, address indexed recipient, uint256 amount);
    event SkimRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    
    event SlippageAccumulated(uint256 amount, uint256 total);
    event SlippageEpochReset(uint256 newEpochStart);
    event MaxSlippageUpdated(uint256 previousMaxSlippage, uint256 newMaxSlippage);
    
    event TokenAdded(IERC20 indexed token, IOracle indexed oracle);
    event TokenRemoved(IERC20 indexed token);
    event TokenOracleChanged(IERC20 indexed token, IOracle indexed oracle);
    
    event TimelockSubmitted(bytes4 indexed selector, bytes data, uint256 executableAt, address who);
    event TimelockRevoked(bytes4 indexed selector, bytes data, address who);
    event TimelockIncreased(bytes4 indexed selector, uint256 newDuration, address who);
    event TimelockDecreased(bytes4 indexed selector, uint256 newDuration, address who);
    event TimelockExecuted(bytes4 indexed selector, bytes data, address who);

    /* ERRORS */

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

    /* FUNCTIONS */

    // ========== STATE FUNCTIONS ==========
    function asset() external view returns (address);
    function slippageEpochDuration() external view returns (uint256);
    function shutdownSlippageDuration() external view returns (uint256);
    function owner() external view returns (address);
    function curator() external view returns (address);
    function guardian() external view returns (address);
    function shutdownTime() external view returns (uint256);
    function skimRecipient() external view returns (address);
    function isAllocator(address account) external view returns (bool);
    function isFeeder(address account) external view returns (bool);
    function tokens(uint256 index) external view returns (IERC20);
    function oracles(IERC20 token) external view returns (IOracle);
    function maxSlippage() external view returns (uint256);
    function accumulatedSlippage() external view returns (uint256);
    function slippageEpochStart() external view returns (uint256);
    function timelock(bytes4 selector) external view returns (uint256);
    function executableAt(bytes calldata data) external view returns (uint256);

    // ========== INVESTMENT MANAGEMENT ==========
    function skim(IERC20 token) external;
    function allocate(IERC20 token, uint256 assetsAmount, ISwapper swapper, bytes calldata data) external;
    function deallocate(IERC20 token, uint256 tokensAmount, ISwapper swapper, bytes calldata data) external;
    function reallocate(IERC20 from, IERC20 to, uint256 tokensAmount, ISwapper swapper, bytes calldata data) external;

    // ========== EMERGENCY ==========
    function shutdown() external;
    function recover() external;
    function unbox(uint256 shares) external;

    // ========== ADMIN FUNCTIONS ==========
    function setSkimRecipient(address newSkimRecipient) external;
    function transferOwnership(address newOwner) external;
    function setCurator(address newCurator) external;
    function setGuardian(address newGuardian) external;
    function setIsAllocator(address account, bool newIsAllocator) external;

    // ========== TIMELOCK GOVERNANCE ==========
    function submit(bytes calldata data) external;
    function revoke(bytes calldata data) external;
    function increaseTimelock(bytes4 selector, uint256 newDuration) external;
    function decreaseTimelock(bytes4 selector, uint256 newDuration) external;

    // ========== TIMELOCKED FUNCTIONS ==========
    function setIsFeeder(address account, bool newIsFeeder) external;
    function setMaxSlippage(uint256 newMaxSlippage) external;
    function addToken(IERC20 token, IOracle oracle) external;
    function removeToken(IERC20 token) external;
    function changeTokenOracle(IERC20 token, IOracle oracle) external;


    // ========== VIEW FUNCTIONS ==========
    function isToken(IERC20 token) external view returns (bool);
    function tokensLength() external view returns (uint256);
    function isShutdown() external view returns (bool);
}