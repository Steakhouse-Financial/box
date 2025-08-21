// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {Errors} from "./lib/Errors.sol";
import "./lib/ConstantsLib.sol";

/**
 * @title Box
 * @author Steakhouse
 * @notice An ERC4626 vault that holds a base asset and can invest in other ERC20 tokens
 * @dev Features role-based access control, timelocked governance, and slippage protection
 */
contract Box is IERC4626, ERC20, ReentrancyGuard {
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

    // ========== EVENTS ==========
    
    event BoxCreated(address indexed box, address indexed asset, address indexed owner, address curator, string name, string symbol, 
        uint256 maxSlippage, uint256 slippageEpochDuration, uint256 shutdownSlippageDuration);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event CuratorUpdated(address indexed previousCurator, address indexed newCurator);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event AllocatorUpdated(address indexed account, bool isAllocator);
    event FeederUpdated(address indexed account, bool isFeeder);
    
    event Allocation(IERC20 indexed token, uint256 assets, uint256 tokens, ISwapper indexed swapper, bytes data);
    event Deallocation(IERC20 indexed token, uint256 tokens, uint256 assets, ISwapper indexed swapper, bytes data);
    event Reallocation(IERC20 indexed fromToken, IERC20 indexed toToken, uint256 tokensFrom, uint256 tokensTo, ISwapper indexed swapper, bytes data);
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

    
    // ========== MODIFIERS ==========
        
    function timelocked() internal {
        if (executableAt[msg.data] == 0) revert Errors.DataNotTimelocked();
        if (block.timestamp < executableAt[msg.data]) revert Errors.TimelockNotExpired();
        executableAt[msg.data] = 0;
        emit TimelockExecuted(bytes4(msg.data), msg.data, msg.sender);
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
        require(_asset != address(0), Errors.InvalidAddress());
        require(_owner != address(0), Errors.InvalidAddress());
        require(_curator != address(0), Errors.InvalidAddress());
        require(_maxSlippage <= MAX_SLIPPAGE_LIMIT, Errors.SlippageTooHigh());
        require(_slippageEpochDuration != 0, Errors.InvalidAmount());
        require(_shutdownSlippageDuration != 0, Errors.InvalidAmount());

        asset = _asset;
        owner = _owner;
        curator = _curator;
        maxSlippage = _maxSlippage;
        slippageEpochDuration = _slippageEpochDuration;
        shutdownSlippageDuration = _shutdownSlippageDuration;
        slippageEpochStart = block.timestamp;

        emit BoxCreated(address(this), asset, owner, curator, _name, _symbol, maxSlippage, slippageEpochDuration, shutdownSlippageDuration);
        emit OwnershipTransferred(address(0), _owner);
        emit CuratorUpdated(address(0), _curator);
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
    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        require(isFeeder[msg.sender], Errors.OnlyFeeders());
        require(!isShutdown(), Errors.CannotDepositIfShutdown());
        require(receiver != address(0), Errors.InvalidAddress());

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
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        require(isFeeder[msg.sender], Errors.OnlyFeeders());
        require(!isShutdown(), Errors.CannotMintIfShutdown());
        require(receiver != address(0), Errors.InvalidAddress());

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
    function withdraw(uint256 assets, address receiver, address owner_) public returns (uint256 shares) {
        if (receiver == address(0)) revert Errors.InvalidAddress();
        
        shares = previewWithdraw(assets);
        
        if (msg.sender != owner_) {
            uint256 allowed = allowance(owner_, msg.sender);
            if (allowed < shares) revert Errors.InsufficientAllowance();
            if (allowed != type(uint256).max) {
                _approve(owner_, msg.sender, allowed - shares);
            }
        }
        
        if (balanceOf(owner_) < shares) revert Errors.InsufficientShares();
        if (IERC20(asset).balanceOf(address(this)) < assets) revert Errors.InsufficientLiquidity();

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
    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        if (receiver == address(0)) revert Errors.InvalidAddress();

        if (msg.sender != owner_) {
            uint256 allowed = allowance(owner_, msg.sender);
            if (allowed < shares) revert Errors.InsufficientAllowance();
            if (allowed != type(uint256).max) {
                _approve(owner_, msg.sender, allowed - shares);
            }
        }
        
        if (balanceOf(owner_) < shares) revert Errors.InsufficientShares();

        assets = previewRedeem(shares);
        if (IERC20(asset).balanceOf(address(this)) < assets) revert Errors.InsufficientLiquidity();

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
    function unbox(uint256 shares) external {
        require(shares > 0, Errors.CannotUnboxZeroShares());
        if (balanceOf(msg.sender) < shares) revert Errors.InsufficientShares();

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
        
        emit Unbox(msg.sender, shares);
    }
    
    // ========== INVESTMENT MANAGEMENT ==========

    /**
     * @notice Skims non-essential tokens from the contract
     * @param token Token to skim
     * @dev Token must not be the base currency or an investment token
     */
    function skim(IERC20 token) external {
        require(address(token) != address(asset), Errors.CannotSkimAsset());
        require(!isToken(token), Errors.CannotSkimToken());

        uint256 amount = token.balanceOf(address(this));
        require(amount > 0, Errors.CannotSkimZero());

        token.safeTransfer(skimRecipient, amount);
        emit Skim(token, skimRecipient, amount);
    }

    /**
     * @notice Allocates assets to buy tokens
     * @param token Token to buy
     * @param assets Amount of assets to spend (should be > 0)
     * @param swapper Swapper contract to use (should not be address(0))
     * @param data Additional data to pass to the swapper
     */
    function allocate(IERC20 token, uint256 assets, ISwapper swapper, bytes calldata data) external nonReentrant {
        require(isAllocator[msg.sender], Errors.OnlyAllocators());
        require(!isShutdown(), Errors.CannotAllocateIfShutdown());
        require(isToken(token), Errors.TokenNotWhitelisted());
        require(address(swapper) != address(0), Errors.InvalidAddress());
        require(assets > 0, Errors.InvalidAmount());

        IOracle oracle = oracles[token];

        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 assetsBefore = IERC20(asset).balanceOf(address(this));

        IERC20(asset).forceApprove(address(swapper), assets);
        swapper.sell(IERC20(asset), token, assets, data);
        
        uint256 tokensReceived = token.balanceOf(address(this)) - tokensBefore;
        uint256 assetsSpent = assetsBefore - IERC20(asset).balanceOf(address(this));

        require(assetsSpent <= assets, Errors.SwapperDidSpendTooMuch());

        // Validate slippage
        uint256 expectedTokens = assets.mulDiv(ORACLE_PRECISION, oracle.price());
        uint256 minTokens = expectedTokens.mulDiv(PRECISION - maxSlippage, PRECISION);

        require(tokensReceived >= minTokens, Errors.AllocationTooExpensive());

        // Track slippage
        if (expectedTokens > tokensReceived) {
            uint256 slippage = expectedTokens - tokensReceived;
            uint256 slippageValue = slippage.mulDiv(oracle.price(), ORACLE_PRECISION);
            _increaseSlippage(slippageValue.mulDiv(PRECISION, totalAssets()));
        }

        emit Allocation(token, assetsSpent, tokensReceived, swapper, data);
    }

    /**
     * @notice Deallocates investment tokens to get assets
     * @param token Investment token to sell
     * @param tokens Amount of tokens to sell
     * @param swapper Swapper contract to use
     * @param data Additional data to pass to the swapper
     */
    function deallocate(IERC20 token, uint256 tokens, ISwapper swapper, bytes calldata data) external nonReentrant {
        require(isAllocator[msg.sender] 
            || (isShutdown() && block.timestamp > shutdownTime + SHUTDOWN_WARMUP), Errors.OnlyAllocatorsOrShutdown());
        require(tokens > 0, Errors.InvalidAmount());     
        require(address(swapper) != address(0), Errors.InvalidAddress());
        
        IOracle oracle = oracles[token];
        require(address(oracle) != address(0), Errors.NoOracleForToken());

        uint256 assetsBefore = IERC20(asset).balanceOf(address(this));   
        uint256 tokensBefore = token.balanceOf(address(this));   

        token.forceApprove(address(swapper), tokens);
        swapper.sell(token, IERC20(asset), tokens, data);

        uint256 assetsReceived = IERC20(asset).balanceOf(address(this)) - assetsBefore;
        uint256 tokensSpent = tokensBefore - token.balanceOf(address(this));

        require(tokensSpent <= tokens, Errors.SwapperDidSpendTooMuch());

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
        uint256 expectedAssets = tokens.mulDiv(oracle.price(), ORACLE_PRECISION);
        uint256 minAssets = expectedAssets.mulDiv(PRECISION - slippageTolerance, PRECISION);

        require(assetsReceived >= minAssets, Errors.TokenSaleNotGeneratingEnoughAssets());

        // Track slippage (only in normal operation)
        if (isAllocator[msg.sender] && expectedAssets > assetsReceived) {
            uint256 slippage = expectedAssets - assetsReceived;
            _increaseSlippage(slippage.mulDiv(PRECISION, totalAssets()));
        }

        emit Deallocation(token, tokensSpent, assetsReceived, swapper, data);
    }

    /**
     * @notice Reallocates from one investment token to another
     * @param from Token to sell
     * @param to Token to buy
     * @param fromAmount Amount of 'from' token to sell
     * @param swapper Swapper contract to use
     * @param data Additional data to pass to the swapper
     */
    function reallocate(
        IERC20 from, 
        IERC20 to, 
        uint256 fromAmount,
        ISwapper swapper,
        bytes calldata data
    ) external nonReentrant {
        require(isAllocator[msg.sender], Errors.OnlyAllocators());
        require(!isShutdown(), Errors.CannotReallocateIfShutdown());
        require(isToken(from) && isToken(to), Errors.TokensNotWhitelisted());
        require(address(swapper) != address(0), Errors.InvalidAddress());
        require(fromAmount > 0, Errors.InvalidAmount());

        IOracle fromOracle = oracles[from];
        IOracle toOracle = oracles[to];

        uint256 toBefore = to.balanceOf(address(this));
        uint256 fromBefore = from.balanceOf(address(this));

        from.forceApprove(address(swapper), fromAmount);
        swapper.sell(from, to, fromAmount, data);

        uint256 toReceived = to.balanceOf(address(this)) - toBefore;
        uint256 fromSpent = fromBefore - from.balanceOf(address(this));

        require(fromSpent <= fromAmount, Errors.SwapperDidSpendTooMuch());

        // Calculate expected amounts
        uint256 fromValue = fromAmount.mulDiv(fromOracle.price(), ORACLE_PRECISION);
        uint256 expectedToTokens = fromValue.mulDiv(ORACLE_PRECISION, toOracle.price());
        uint256 minToTokens = expectedToTokens.mulDiv(PRECISION - maxSlippage, PRECISION);

        require(toReceived >= minToTokens, Errors.ReallocationSlippageTooHigh());

        // Track slippage
        if (expectedToTokens > toReceived) {
            uint256 slippageTokens = expectedToTokens - toReceived;
            uint256 slippageValue = slippageTokens.mulDiv(toOracle.price(), ORACLE_PRECISION);
            _increaseSlippage(slippageValue.mulDiv(PRECISION, totalAssets()));
        }

        emit Reallocation(from, to, fromSpent, toReceived, swapper, data);
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Updates the skim recipient address
     * @param newSkimRecipient Address of new skim recipient
     */
    function setSkimRecipient(address newSkimRecipient) external {
        require(msg.sender == owner, Errors.OnlyOwner());
        require(newSkimRecipient != address(0), Errors.InvalidAddress());
        require(newSkimRecipient != skimRecipient, Errors.AlreadySet());
        
        address oldRecipient = skimRecipient;
        skimRecipient = newSkimRecipient;
        
        emit SkimRecipientUpdated(oldRecipient, newSkimRecipient);
    }

    /**
     * @notice Transfers ownership to a new address
     * @param newOwner Address of new owner
     */
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, Errors.OnlyOwner());
        require(newOwner != address(0), Errors.InvalidAddress());

        address oldOwner = owner;
        owner = newOwner;
        
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /**
     * @notice Updates the curator address
     * @param newCurator Address of new curator
     */
    function setCurator(address newCurator) external {
        require(msg.sender == owner, Errors.OnlyOwner());
        require(newCurator != address(0), Errors.InvalidAddress());

        address oldCurator = curator;
        curator = newCurator;
        
        emit CuratorUpdated(oldCurator, newCurator);
    }

    /**
     * @notice Updates the curator address (timelocked)
     * @param newGuardian Address of new guardian
     */
    function setGuardian(address newGuardian) external {
        timelocked();
        require(msg.sender == curator, Errors.OnlyCurator());

        address oldGuardian = guardian;
        guardian = newGuardian;
        
        emit GuardianUpdated(oldGuardian, newGuardian);
    }

    /**
     * @notice Updates allocator status for an account
     * @param account Address to update
     * @param newIsAllocator New allocator status
     */
    function setIsAllocator(address account, bool newIsAllocator) external {
        require(msg.sender == curator, Errors.OnlyCurator());
        require(account != address(0), Errors.InvalidAddress());

        isAllocator[account] = newIsAllocator;

        emit AllocatorUpdated(account, newIsAllocator);
    }

    /**
     * @notice Triggers emergency shutdown
     * @dev Only guardian can trigger shutdown
     */
    function shutdown() external {
        require(msg.sender == guardian, Errors.OnlyGuardianCanShutdown());
        require(!isShutdown(), Errors.AlreadyShutdown());
        
        shutdownTime = block.timestamp;
        
        emit Shutdown(msg.sender);
    }

    /**
     * @notice Recover from shutdown
     * @dev Only guardian can recover from shutdown
     */
    function recover() external {
        require(msg.sender == guardian, Errors.OnlyGuardianCanRecover());
        require(isShutdown(), Errors.NotShutdown());

        shutdownTime = 0;

        emit Recover(msg.sender);
    }

    // ========== TIMELOCK GOVERNANCE ==========

    /**
     * @notice Submits a transaction for timelock
     * @param data Encoded function call
     */
    function submit(bytes calldata data) external {
        require(msg.sender == curator, Errors.OnlyCurator());
        require(executableAt[data] == 0, Errors.DataAlreadyTimelocked());
        require(data.length >= 4, Errors.InvalidAmount());
        
        bytes4 selector = bytes4(data);
        uint256 delay = timelock[selector];
        executableAt[data] = block.timestamp + delay;

        emit TimelockSubmitted(selector, data, executableAt[data], msg.sender);
    }

    /**
     * @notice Revokes a timelocked transaction
     * @param data Encoded function call to revoke
     */
    function revoke(bytes calldata data) external {
        require(msg.sender == curator || msg.sender == guardian, Errors.OnlyCuratorOrGuardian());
        
        executableAt[data] = 0;

        emit TimelockRevoked(bytes4(data), data, msg.sender);
    }

    /**
     * @notice Increases timelock duration for a function, doesn't require a timelock
     * @param selector Function selector
     * @param newDuration New timelock duration
     */
    function increaseTimelock(bytes4 selector, uint256 newDuration) external {
        require(msg.sender == curator, Errors.OnlyCurator());
        require(newDuration <= TIMELOCK_CAP, Errors.InvalidTimelock());
        require(newDuration > timelock[selector], Errors.TimelockDecrease());
        
        timelock[selector] = newDuration;

        emit TimelockIncreased(selector, newDuration, msg.sender);
    }

    /**
     * @notice Decrease timelock duration for a function requires a timelock
     * @param selector Function selector
     * @param newDuration New timelock duration
     */
    function decreaseTimelock(bytes4 selector, uint256 newDuration) external {
        timelocked();
        require(msg.sender == curator, Errors.OnlyCurator());
        require(newDuration <= TIMELOCK_CAP, Errors.InvalidTimelock());
        require(newDuration < timelock[selector], Errors.TimelockIncrease());

        timelock[selector] = newDuration;

        emit TimelockDecreased(selector, newDuration, msg.sender);
    }

    // ========== TIMELOCKED FUNCTIONS ==========

    /**
     * @notice Updates feeder status for an account
     * @param account Address to update
     * @param newIsFeeder New feeder status
     */
    function setIsFeeder(address account, bool newIsFeeder) external {
        timelocked();
        require(account != address(0), Errors.InvalidAddress());

        isFeeder[account] = newIsFeeder;

        emit FeederUpdated(account, newIsFeeder);
    }

    /**
     * @notice Updates maximum allowed slippage
     * @param newMaxSlippage New maximum slippage percentage
     */
    function setMaxSlippage(uint256 newMaxSlippage) external {
        timelocked();
        require(newMaxSlippage <= MAX_SLIPPAGE_LIMIT, Errors.SlippageTooHigh());

        uint256 oldMaxSlippage = maxSlippage;
        maxSlippage = newMaxSlippage;
        
        emit MaxSlippageUpdated(oldMaxSlippage, newMaxSlippage);
    }

    /**
     * @notice Adds a new token
     * @param token Token to add
     * @param oracle Price oracle for the token
     */
    function addToken(IERC20 token, IOracle oracle) external {
        timelocked();
        require(address(token) != address(0), Errors.InvalidAddress());
        require(address(oracle) != address(0), Errors.InvalidAddress());
        require(!isToken(token), Errors.TokenNotWhitelisted());
        
        tokens.push(token);
        oracles[token] = oracle;
        
        emit TokenAdded(token, oracle);
    }

    /**
     * @notice Removes an investment token
     * @param token Token to remove
     */
    function removeToken(IERC20 token) external {
        timelocked();
        require(isToken(token), Errors.TokenNotWhitelisted());
        require(token.balanceOf(address(this)) == 0, Errors.TokenBalanceMustBeZero());

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
        
        emit TokenRemoved(token);
    }

        /**
     * @notice Change the oracle of a token
     * @param token Token that is already allowed
     * @param oracle New oracle
     */
    function changeTokenOracle(IERC20 token, IOracle oracle) external {
        timelocked();
        require(address(oracle) != address(0), Errors.InvalidAddress());
        require(isToken(token), Errors.TokenNotWhitelisted());
        
        oracles[token] = oracle;
        
        emit TokenOracleChanged(token, oracle);
    }


    // ========== VIEW FUNCTIONS ==========
    /**
     * @notice Returns true if token is an investment token
     * @return true if it is a whitelisted investment token
     */
    function isToken(IERC20 token) public view returns (bool) {
        return address(this.oracles(token)) != address(0);
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
            emit SlippageEpochReset(block.timestamp);
        } else {
            accumulatedSlippage += slippagePct;
        }
        
        if (accumulatedSlippage >= maxSlippage) revert Errors.TooMuchAccumulatedSlippage();
        
        emit SlippageAccumulated(slippagePct, accumulatedSlippage);
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