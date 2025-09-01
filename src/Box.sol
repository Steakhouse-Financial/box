// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBox} from "./interfaces/IBox.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import "./lib/Constants.sol";
import {ErrorsLib} from "./lib/ErrorsLib.sol";
import {EventsLib} from "./lib/EventsLib.sol";

/**
 * @title Box
 * @author Steakhouse
 * @notice An ERC4626 vault that holds a base asset and can invest in other ERC20 tokens
 * @dev Features role-based access control, timelocked governance, and slippage protection
 */
contract Box is IBox, ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ========== IMMUTABLE STATE ==========
    
    /// @notice Base currency token (e.g., USDC)
    address public immutable asset;
        
    /// @notice Duration of slippage tracking epochs
    uint256 public immutable slippageEpochDuration;
    
    /// @notice Duration over which shutdown slippage tolerance increases
    uint256 public immutable shutdownSlippageDuration;
    
    // ========== MUTABLE STATE ==========
    
    /// @notice Contract owner with administrative privileges
    address public owner;
    
    /// @notice Curator who add new tokens
    address public curator;

    /// @notice Guardian who can revoke sensitive actions
    address public guardian;

    /// @notice Timestamp when shutdown was triggered, no shutdown if 0
    uint256 public shutdownTime;

    /// @notice Recipient of skimmed tokens
    address public skimRecipient;

    // Role mappings
    mapping(address => bool) public isAllocator;
    mapping(address => bool) public isFeeder;

    // Tokens management
    IERC20[] public tokens;
    mapping(IERC20 => IOracle) public oracles;

    // Slippage tracking
    uint256 public maxSlippage;
    uint256 public accumulatedSlippage;
    uint256 public slippageEpochStart;

    // Timelock governance
    mapping(bytes4 => uint256) public timelock;
    mapping(bytes => uint256) public executableAt;
    
    // ========== MODIFIERS ==========
        
    function timelocked() internal {
        if (executableAt[msg.data] == 0) revert ErrorsLib.DataNotTimelocked();
        if (block.timestamp < executableAt[msg.data]) revert ErrorsLib.TimelockNotExpired();
        executableAt[msg.data] = 0;
        emit EventsLib.TimelockExecuted(bytes4(msg.data), msg.data, msg.sender);
    }

    // ========== CONSTRUCTOR ==========
    
    /**
     * @notice Initializes the Box vault
     * @param _asset Base currency token (e.g., USDC)
     * @param _owner Initial owner address
     * @param _curator Initial curator address  
     * @param _name ERC20 token name
     * @param _symbol ERC20 token symbol
     * @param _maxSlippage Max allowed slippage for a swap or aggregated over `_slippageEpochDuration`
     * @param _slippageEpochDuration Duration for which slippage is measured
     * @param _shutdownSlippageDuration When shutdown duration for slippage allowance to widen
     */
    constructor(
        address _asset,
        address _owner,
        address _curator,
        string memory _name,
        string memory _symbol,
        uint256 _maxSlippage,
        uint256 _slippageEpochDuration,
        uint256 _shutdownSlippageDuration
    ) ERC20(_name, _symbol) {
        require(_asset != address(0), ErrorsLib.InvalidAddress());
        require(_owner != address(0), ErrorsLib.InvalidAddress());
        require(_curator != address(0), ErrorsLib.InvalidAddress());
        require(_maxSlippage <= MAX_SLIPPAGE_LIMIT, ErrorsLib.SlippageTooHigh());
        require(_slippageEpochDuration != 0, ErrorsLib.InvalidAmount());
        require(_shutdownSlippageDuration != 0, ErrorsLib.InvalidAmount());

        asset = _asset;
        owner = _owner;
        curator = _curator;
        skimRecipient = _owner;
        maxSlippage = _maxSlippage;
        slippageEpochDuration = _slippageEpochDuration;
        shutdownSlippageDuration = _shutdownSlippageDuration;
        slippageEpochStart = block.timestamp;

        emit EventsLib.BoxCreated(address(this), asset, owner, curator, _name, _symbol, maxSlippage, slippageEpochDuration, shutdownSlippageDuration);
        emit EventsLib.OwnershipTransferred(address(0), _owner);
        emit EventsLib.CuratorUpdated(address(0), _curator);
    }

    // ========== ERC4626 IMPLEMENTATION ==========

    /// @inheritdoc IERC4626
    function totalAssets() public view returns (uint256 assets_) {
        return _calculateTotalAssets();
    }

    /// @inheritdoc IERC4626
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets.mulDiv(supply, totalAssets());
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : shares.mulDiv(totalAssets(), supply);
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address) external view returns (uint256) {
        return (isShutdown()) ? 0 : type(uint256).max;
    }

    /// @inheritdoc IERC4626
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
        require(isFeeder[msg.sender], ErrorsLib.OnlyFeeders());
        require(!isShutdown(), ErrorsLib.CannotDepositIfShutdown());
        require(receiver != address(0), ErrorsLib.InvalidAddress());

        shares = previewDeposit(assets);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IERC4626
    function maxMint(address) external view returns (uint256) {
        return (isShutdown()) ? 0 : type(uint256).max;
    }

    /// @inheritdoc IERC4626
    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : shares.mulDiv(totalAssets(), supply, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        require(isFeeder[msg.sender], ErrorsLib.OnlyFeeders());
        require(!isShutdown(), ErrorsLib.CannotMintIfShutdown());
        require(receiver != address(0), ErrorsLib.InvalidAddress());

        assets = previewMint(shares);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address owner_) external view returns (uint256) {
        return convertToAssets(balanceOf(owner_));
    }

    /// @inheritdoc IERC4626
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets.mulDiv(supply, totalAssets(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner_) public nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) revert ErrorsLib.InvalidAddress();
        
        shares = previewWithdraw(assets);
        
        if (msg.sender != owner_) {
            uint256 allowed = allowance(owner_, msg.sender);
            if (allowed < shares) revert ErrorsLib.InsufficientAllowance();
            if (allowed != type(uint256).max) {
                _approve(owner_, msg.sender, allowed - shares);
            }
        }

        if (balanceOf(owner_) < shares) revert ErrorsLib.InsufficientShares();
        if (IERC20(asset).balanceOf(address(this)) < assets) revert ErrorsLib.InsufficientLiquidity();

        _burn(owner_, shares);
        IERC20(asset).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address owner_) external view returns (uint256) {
        return balanceOf(owner_);
    }

    /// @inheritdoc IERC4626
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner_) external nonReentrant returns (uint256 assets) {
        if (receiver == address(0)) revert ErrorsLib.InvalidAddress();

        if (msg.sender != owner_) {
            uint256 allowed = allowance(owner_, msg.sender);
            if (allowed < shares) revert ErrorsLib.InsufficientAllowance();
            if (allowed != type(uint256).max) {
                _approve(owner_, msg.sender, allowed - shares);
            }
        }

        if (balanceOf(owner_) < shares) revert ErrorsLib.InsufficientShares();

        assets = previewRedeem(shares);
        if (IERC20(asset).balanceOf(address(this)) < assets) revert ErrorsLib.InsufficientLiquidity();

        _burn(owner_, shares);
        IERC20(asset).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    // ========== EMERGENCY EXIT ==========

    /**
     * @notice Emergency exit that returns pro-rata share of all assets
     * @param shares Amount of shares to burn
     * @dev Can be called by anyone holding shares
     */
    function unbox(uint256 shares) external nonReentrant {
        require(shares > 0, ErrorsLib.CannotUnboxZeroShares());
        if (balanceOf(msg.sender) < shares) revert ErrorsLib.InsufficientShares();

        uint256 supply = totalSupply();
        uint256 assetsAmount = IERC20(asset).balanceOf(address(this)).mulDiv(shares, supply);

        _burn(msg.sender, shares);

        if (assetsAmount > 0) {
            IERC20(asset).safeTransfer(msg.sender, assetsAmount);
        }

        // Transfer pro-rata share of each token
        uint256 length = tokens.length;
        for (uint256 i; i < length;) {
            IERC20 token = tokens[i];
            uint256 tokenAmount = token.balanceOf(address(this)).mulDiv(shares, supply);
            if (tokenAmount > 0) {
                token.safeTransfer(msg.sender, tokenAmount);
            }
            unchecked { ++i; }
        }
        
        emit EventsLib.Unbox(msg.sender, shares);
    }
    
    // ========== INVESTMENT MANAGEMENT ==========

    /**
     * @notice Skims non-essential tokens from the contract
     * @param token Token to skim
     * @dev Token must not be the base currency or an investment token
     */
    function skim(IERC20 token) external nonReentrant {
        require(msg.sender == skimRecipient, ErrorsLib.OnlySkimRecipient());
        require(address(token) != address(asset), ErrorsLib.CannotSkimAsset());
        require(!isToken(token), ErrorsLib.CannotSkimToken());
        require(skimRecipient != address(0), ErrorsLib.InvalidAddress());

        uint256 amount = token.balanceOf(address(this));
        require(amount > 0, ErrorsLib.CannotSkimZero());

        token.safeTransfer(skimRecipient, amount);
        emit EventsLib.Skim(token, skimRecipient, amount);
    }

    /**
     * @notice Allocates assets to buy tokens
     * @param token Token to buy
     * @param assetsAmount Amount of assets to spend (should be > 0)
     * @param swapper Swapper contract to use (should not be address(0))
     * @param data Additional data to pass to the swapper
     */
    function allocate(IERC20 token, uint256 assetsAmount, ISwapper swapper, bytes calldata data) external nonReentrant {
        require(isAllocator[msg.sender], ErrorsLib.OnlyAllocators());
        require(!isShutdown(), ErrorsLib.CannotAllocateIfShutdown());
        require(isToken(token), ErrorsLib.TokenNotWhitelisted());
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());
        require(assetsAmount > 0, ErrorsLib.InvalidAmount());

        IOracle oracle = oracles[token];

        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 assetsBefore = IERC20(asset).balanceOf(address(this));

        IERC20(asset).forceApprove(address(swapper), assetsAmount);
        swapper.sell(IERC20(asset), token, assetsAmount, data);
        
        uint256 tokensReceived = token.balanceOf(address(this)) - tokensBefore;
        uint256 assetsSpent = assetsBefore - IERC20(asset).balanceOf(address(this));

        require(assetsSpent <= assetsAmount, ErrorsLib.SwapperDidSpendTooMuch());

        // Validate slippage
        uint256 expectedTokens = assetsAmount.mulDiv(ORACLE_PRECISION, oracle.price());
        uint256 minTokens = expectedTokens.mulDiv(PRECISION - maxSlippage, PRECISION);
        int256 slippage = int256(expectedTokens) - int256(tokensReceived);
        int256 slippagePct = expectedTokens == 0 ? int256(0) : slippage * int256(PRECISION) / int256(expectedTokens);

        require(tokensReceived >= minTokens, ErrorsLib.AllocationTooExpensive());

        // Revoke allowance to prevent residual approvals
        IERC20(asset).forceApprove(address(swapper), 0);

        // Track slippage
        if (slippage > 0) {
            uint256 slippageValue = uint256(slippage).mulDiv(oracle.price(), ORACLE_PRECISION);
            _increaseSlippage(slippageValue.mulDiv(PRECISION, totalAssets()));
        }

        emit EventsLib.Allocation(token, assetsSpent, tokensReceived, slippagePct, swapper, data);
    }

    /**
     * @notice Deallocates investment tokens to get assets
     * @param token Investment token to sell
     * @param tokensAmount Amount of tokens to sell
     * @param swapper Swapper contract to use
     * @param data Additional data to pass to the swapper
     */
    function deallocate(IERC20 token, uint256 tokensAmount, ISwapper swapper, bytes calldata data) external nonReentrant {
        require(isAllocator[msg.sender] 
            || (isShutdown() && block.timestamp > shutdownTime + SHUTDOWN_WARMUP), ErrorsLib.OnlyAllocatorsOrShutdown());
        require(tokensAmount > 0, ErrorsLib.InvalidAmount());
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());

        IOracle oracle = oracles[token];
        require(address(oracle) != address(0), ErrorsLib.NoOracleForToken());

        uint256 assetsBefore = IERC20(asset).balanceOf(address(this));   
        uint256 tokensBefore = token.balanceOf(address(this));   

        token.forceApprove(address(swapper), tokensAmount);
        swapper.sell(token, IERC20(asset), tokensAmount, data);

        uint256 assetsReceived = IERC20(asset).balanceOf(address(this)) - assetsBefore;
        uint256 tokensSpent = tokensBefore - token.balanceOf(address(this));

        require(tokensSpent <= tokensAmount, ErrorsLib.SwapperDidSpendTooMuch());

        // Revoke allowance to prevent residual approvals
        token.forceApprove(address(swapper), 0);

        // Calculate slippage tolerance, default to allocator slippage
        uint256 slippageTolerance = maxSlippage;
        // For non-allocators during shutdown, calculate slippage based on elapsed time
        if (!isAllocator[msg.sender]) {
            uint256 timeElapsed = block.timestamp - SHUTDOWN_WARMUP - shutdownTime;
            if (timeElapsed < shutdownSlippageDuration) {
                slippageTolerance = timeElapsed.mulDiv(MAX_SLIPPAGE_LIMIT, shutdownSlippageDuration);
            } else {
                slippageTolerance = MAX_SLIPPAGE_LIMIT;
            }
        }

        // Validate slippage
        uint256 expectedAssets = tokensAmount.mulDiv(oracle.price(), ORACLE_PRECISION);
        uint256 minAssets = expectedAssets.mulDiv(PRECISION - slippageTolerance, PRECISION);
        int256 slippage = int256(expectedAssets) - int256(assetsReceived);
        int256 slippagePct = expectedAssets == 0 ? int256(0) : slippage * int256(PRECISION) / int256(expectedAssets);

        require(assetsReceived >= minAssets, ErrorsLib.TokenSaleNotGeneratingEnoughAssets());

        // Track slippage (only in normal operation)
        if (isAllocator[msg.sender] && slippage > 0) {
            // slippage is already in asset units
            uint256 slippageValue = uint256(slippage);
            _increaseSlippage(slippageValue.mulDiv(PRECISION, totalAssets()));
        }

        emit EventsLib.Deallocation(token, tokensSpent, assetsReceived, slippagePct, swapper, data);
    }

    /**
     * @notice Reallocates from one investment token to another
     * @param from Token to sell
     * @param to Token to buy
     * @param tokensAmount Amount of 'from' token to sell
     * @param swapper Swapper contract to use
     * @param data Additional data to pass to the swapper
     */
    function reallocate(
        IERC20 from, 
        IERC20 to, 
        uint256 tokensAmount,
        ISwapper swapper,
        bytes calldata data
    ) external nonReentrant {
        require(isAllocator[msg.sender], ErrorsLib.OnlyAllocators());
        require(!isShutdown(), ErrorsLib.CannotReallocateIfShutdown());
        require(isToken(from) && isToken(to), ErrorsLib.TokenNotWhitelisted());
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());
        require(tokensAmount > 0, ErrorsLib.InvalidAmount());

        IOracle fromOracle = oracles[from];
        IOracle toOracle = oracles[to];

        uint256 toBefore = to.balanceOf(address(this));
        uint256 fromBefore = from.balanceOf(address(this));

        from.forceApprove(address(swapper), tokensAmount);
        swapper.sell(from, to, tokensAmount, data);

        uint256 toReceived = to.balanceOf(address(this)) - toBefore;
        uint256 fromSpent = fromBefore - from.balanceOf(address(this));

        require(fromSpent <= tokensAmount, ErrorsLib.SwapperDidSpendTooMuch());

        // Revoke allowance to prevent residual approvals
        from.forceApprove(address(swapper), 0);

        // Calculate expected amounts
        uint256 fromValue = tokensAmount.mulDiv(fromOracle.price(), ORACLE_PRECISION);
        uint256 expectedToTokens = fromValue.mulDiv(ORACLE_PRECISION, toOracle.price());
        uint256 minToTokens = expectedToTokens.mulDiv(PRECISION - maxSlippage, PRECISION);
        int256 slippage = int256(expectedToTokens) - int256(toReceived);
        int256 slippagePct = expectedToTokens == 0 ? int256(0) : slippage * int256(PRECISION) / int256(expectedToTokens);

        require(toReceived >= minToTokens, ErrorsLib.ReallocationSlippageTooHigh());

        // Track slippage
        if (slippage > 0) {
            uint256 slippageValue = uint256(slippage).mulDiv(toOracle.price(), ORACLE_PRECISION);
            _increaseSlippage(slippageValue.mulDiv(PRECISION, totalAssets()));
        }

        emit EventsLib.Reallocation(from, to, fromSpent, toReceived, slippagePct, swapper, data);
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Updates the skim recipient address
     * @param newSkimRecipient Address of new skim recipient
     */
    function setSkimRecipient(address newSkimRecipient) external {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(newSkimRecipient != address(0), ErrorsLib.InvalidAddress());
        require(newSkimRecipient != skimRecipient, ErrorsLib.AlreadySet());

        address oldRecipient = skimRecipient;
        skimRecipient = newSkimRecipient;
        
        emit EventsLib.SkimRecipientUpdated(oldRecipient, newSkimRecipient);
    }

    /**
     * @notice Transfers ownership to a new address
     * @param newOwner Address of new owner
     */
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(newOwner != address(0), ErrorsLib.InvalidAddress());

        address oldOwner = owner;
        owner = newOwner;
        
        emit EventsLib.OwnershipTransferred(oldOwner, newOwner);
    }

    /**
     * @notice Updates the curator address
     * @param newCurator Address of new curator
     */
    function setCurator(address newCurator) external {
        require(msg.sender == owner, ErrorsLib.OnlyOwner());
        require(newCurator != address(0), ErrorsLib.InvalidAddress());

        address oldCurator = curator;
        curator = newCurator;
        
        emit EventsLib.CuratorUpdated(oldCurator, newCurator);
    }

    /**
     * @notice Updates the curator address (timelocked)
     * @param newGuardian Address of new guardian
     */
    function setGuardian(address newGuardian) external {
        timelocked();
        require(msg.sender == curator, ErrorsLib.OnlyCurator());

        address oldGuardian = guardian;
        guardian = newGuardian;
        
        emit EventsLib.GuardianUpdated(oldGuardian, newGuardian);
    }

    /**
     * @notice Updates allocator status for an account
     * @param account Address to update
     * @param newIsAllocator New allocator status
     */
    function setIsAllocator(address account, bool newIsAllocator) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(account != address(0), ErrorsLib.InvalidAddress());

        isAllocator[account] = newIsAllocator;

        emit EventsLib.AllocatorUpdated(account, newIsAllocator);
    }

    /**
     * @notice Triggers emergency shutdown
     * @dev Only guardian can trigger shutdown
     */
    function shutdown() external {
        require(msg.sender == guardian, ErrorsLib.OnlyGuardianCanShutdown());
        require(!isShutdown(), ErrorsLib.AlreadyShutdown());

        shutdownTime = block.timestamp;
        
        emit EventsLib.Shutdown(msg.sender);
    }

    /**
     * @notice Recover from shutdown
     * @dev Only guardian can recover from shutdown
     */
    function recover() external {
        require(msg.sender == guardian, ErrorsLib.OnlyGuardianCanRecover());
        require(isShutdown(), ErrorsLib.NotShutdown());

        shutdownTime = 0;

        emit EventsLib.Recover(msg.sender);
    }

    // ========== TIMELOCK GOVERNANCE ==========

    /**
     * @notice Submits a transaction for timelock
     * @param data Encoded function call
     */
    function submit(bytes calldata data) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(executableAt[data] == 0, ErrorsLib.DataAlreadyTimelocked());
        require(data.length >= 4, ErrorsLib.InvalidAmount());

        bytes4 selector = bytes4(data);
        uint256 delay = timelock[selector];
        executableAt[data] = block.timestamp + delay;

        emit EventsLib.TimelockSubmitted(selector, data, executableAt[data], msg.sender);
    }

    /**
     * @notice Revokes a timelocked transaction
     * @param data Encoded function call to revoke
     */
    function revoke(bytes calldata data) external {
        require(msg.sender == curator || msg.sender == guardian, ErrorsLib.OnlyCuratorOrGuardian());

        executableAt[data] = 0;

        emit EventsLib.TimelockRevoked(bytes4(data), data, msg.sender);
    }

    /**
     * @notice Increases timelock duration for a function, doesn't require a timelock
     * @param selector Function selector
     * @param newDuration New timelock duration
     */
    function increaseTimelock(bytes4 selector, uint256 newDuration) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(newDuration <= TIMELOCK_CAP, ErrorsLib.InvalidTimelock());
        require(newDuration > timelock[selector], ErrorsLib.TimelockDecrease());

        timelock[selector] = newDuration;

        emit EventsLib.TimelockIncreased(selector, newDuration, msg.sender);
    }

    /**
     * @notice Decrease timelock duration for a function requires a timelock
     * @param selector Function selector
     * @param newDuration New timelock duration
     */
    function decreaseTimelock(bytes4 selector, uint256 newDuration) external {
        timelocked();
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(newDuration <= TIMELOCK_CAP, ErrorsLib.InvalidTimelock());
        require(newDuration < timelock[selector], ErrorsLib.TimelockIncrease());

        timelock[selector] = newDuration;

        emit EventsLib.TimelockDecreased(selector, newDuration, msg.sender);
    }

    // ========== TIMELOCKED FUNCTIONS ==========

    /**
     * @notice Updates feeder status for an account
     * @param account Address to update
     * @param newIsFeeder New feeder status
     */
    function setIsFeeder(address account, bool newIsFeeder) external {
        timelocked();
        require(account != address(0), ErrorsLib.InvalidAddress());

        isFeeder[account] = newIsFeeder;

        emit EventsLib.FeederUpdated(account, newIsFeeder);
    }

    /**
     * @notice Updates maximum allowed slippage
     * @param newMaxSlippage New maximum slippage percentage
     */
    function setMaxSlippage(uint256 newMaxSlippage) external {
        timelocked();
        require(newMaxSlippage <= MAX_SLIPPAGE_LIMIT, ErrorsLib.SlippageTooHigh());

        uint256 oldMaxSlippage = maxSlippage;
        maxSlippage = newMaxSlippage;
        
        emit EventsLib.MaxSlippageUpdated(oldMaxSlippage, newMaxSlippage);
    }

    /**
     * @notice Adds a new token
     * @param token Token to add
     * @param oracle Price oracle for the token
     */
    function addToken(IERC20 token, IOracle oracle) external {
        timelocked();
        require(address(token) != address(0), ErrorsLib.InvalidAddress());
        require(address(oracle) != address(0), ErrorsLib.OracleRequired());
        require(!isToken(token), ErrorsLib.TokenAlreadyWhitelisted());
        require(tokens.length < MAX_TOKENS, ErrorsLib.TooManyTokens());

        tokens.push(token);
        oracles[token] = oracle;
        
        emit EventsLib.TokenAdded(token, oracle);
    }

    /**
     * @notice Removes an investment token
     * @param token Token to remove
     */
    function removeToken(IERC20 token) external {
        timelocked();
        require(isToken(token), ErrorsLib.TokenNotWhitelisted());
        require(token.balanceOf(address(this)) == 0, ErrorsLib.TokenBalanceMustBeZero());

        uint256 length = tokens.length;
        for (uint256 i; i < length;) {
            if (tokens[i] == token) {
                tokens[i] = tokens[length - 1];
                tokens.pop();
                break;
            }
            unchecked { ++i; }
        }

        delete oracles[token];
        
        emit EventsLib.TokenRemoved(token);
    }

        /**
     * @notice Change the oracle of a token
     * @param token Token that is already allowed
     * @param oracle New oracle
     */
    function changeTokenOracle(IERC20 token, IOracle oracle) external {
        timelocked();
        require(address(oracle) != address(0), ErrorsLib.InvalidAddress());
        require(isToken(token), ErrorsLib.TokenNotWhitelisted());

        oracles[token] = oracle;
        
        emit EventsLib.TokenOracleChanged(token, oracle);
    }


    // ========== VIEW FUNCTIONS ==========
    /**
     * @notice Returns true if token is an investment token
     * @return true if it is a whitelisted investment token
     */
    function isToken(IERC20 token) public view returns (bool) {
        return address(oracles[token]) != address(0);
    }
    

    /**
     * @notice Returns number of investment tokens
     * @return count Number of investment tokens
     */
    function tokensLength() external view returns (uint256) {
        return tokens.length;
    }

    /**
     * @notice Returns true if the box is in shutdown mode (shutdownTime != 0)
     * @return true if the box is in shutdown mode
     */
    function isShutdown() public view returns (bool) {
        return shutdownTime != 0;
    }
    


    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @dev Increases accumulated slippage and checks against maximum
     */
    function _increaseSlippage(uint256 slippagePct) internal {
        // Reset epoch if expired
        if (block.timestamp >= slippageEpochStart + slippageEpochDuration) {
            slippageEpochStart = block.timestamp;
            accumulatedSlippage = slippagePct;
            emit EventsLib.SlippageEpochReset(block.timestamp);
        } else {
            accumulatedSlippage += slippagePct;
        }

        if (accumulatedSlippage >= maxSlippage) revert ErrorsLib.TooMuchAccumulatedSlippage();

        emit EventsLib.SlippageAccumulated(slippagePct, accumulatedSlippage);
    }

    /**
     * @dev Calculates the total value of all tokens and assets in the vault
     * @return assets_ The total value of all assets
     */
    function _calculateTotalAssets() internal view returns (uint256 assets_) {
        assets_ = IERC20(asset).balanceOf(address(this));

        // Add value of all tokens
        uint256 length = tokens.length;
        for (uint256 i; i < length;) {
            IERC20 token = tokens[i];
            IOracle oracle = oracles[token];
            if (address(oracle) != address(0)) {
                uint256 tokenBalance = token.balanceOf(address(this));
                if (tokenBalance > 0) {
                    assets_ += tokenBalance.mulDiv(oracle.price(), ORACLE_PRECISION);
                }
            }
            unchecked { ++i; }
        }
    }
}