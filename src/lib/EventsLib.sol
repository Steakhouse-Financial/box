// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";
import {IOracle} from "../interfaces/IOracle.sol";

library EventsLib {

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
}