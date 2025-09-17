// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBox} from "./interfaces/IBox.sol";
import {IBoxFlashCallback} from "./interfaces/IBox.sol";
import {IFunding, IOracleCallback} from "./interfaces/IFunding.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import "./libraries/Constants.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

/**
 * @title Box
 * @notice An ERC4626 vault that holds a base asset, invest in other ERC20 tokens and can borrow/lend via funding modules.
 * @dev Features role-based access control, timelocked governance, and slippage protection
 * @dev Box is not inflation or donation resistant as deposits are strictly controlled via the isFeeder role.
 * @dev Should deposit happen in an automated way (liquidity on a Vault V2) and from multiple feeders, it should be seeded first.
 * @dev Oracles can be manipulated to give an unfair price
 * @dev It is recommanded to create resiliency by using the BoxAdapterCached
 * @dev and/or by using a Vault V2 as a parent vault, which can have a reported price a but lower the NAV price and a setMaxRate()
 * @dev During flash operations there is no totalAssets() calculation possible to avoid NAV based attacks
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

    /// @notice Duration between shutdown and wind-down phase
    uint256 public immutable shutdownWarmup;

    // ========== MUTABLE STATE ==========

    /// @notice Contract owner with administrative privileges
    address public owner;

    /// @notice Curator who add new tokens
    address public curator;

    /// @notice Guardian who can revoke sensitive actions
    address public guardian;

    /// @notice Timestamp when shutdown was triggered, no shutdown if type(uint256).max
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

    // Funding modules
    IFunding[] public fundings;
    mapping(IFunding => bool) internal fundingMap;

    // Flash loan tracking
    bool private _isInFlash;
    uint256 private _cachedNavForFlash;

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
     * @param _shutdownWarmup Duration between shutdown and wind-down phase
     */
    constructor(
        address _asset,
        address _owner,
        address _curator,
        string memory _name,
        string memory _symbol,
        uint256 _maxSlippage,
        uint256 _slippageEpochDuration,
        uint256 _shutdownSlippageDuration,
        uint256 _shutdownWarmup
    ) ERC20(_name, _symbol) {
        require(_asset != address(0), ErrorsLib.InvalidAddress());
        require(_owner != address(0), ErrorsLib.InvalidAddress());
        require(_maxSlippage <= MAX_SLIPPAGE_LIMIT, ErrorsLib.SlippageTooHigh());
        require(_slippageEpochDuration != 0, ErrorsLib.InvalidValue());
        require(_shutdownSlippageDuration != 0, ErrorsLib.InvalidValue());
        require(_shutdownWarmup <= MAX_SHUTDOWN_WARMUP, ErrorsLib.InvalidValue());

        asset = _asset;
        owner = _owner;
        curator = _curator;
        skimRecipient = address(0);
        maxSlippage = _maxSlippage;
        slippageEpochDuration = _slippageEpochDuration;
        shutdownSlippageDuration = _shutdownSlippageDuration;
        shutdownWarmup = _shutdownWarmup;
        slippageEpochStart = block.timestamp;
        shutdownTime = type(uint256).max; // No shutdown initially

        emit EventsLib.BoxCreated(
            address(this),
            asset,
            owner,
            curator,
            _name,
            _symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration
        );
        emit EventsLib.OwnershipTransferred(address(0), _owner);
        emit EventsLib.CuratorUpdated(address(0), _curator);
    }

    // ========== ERC4626 IMPLEMENTATION ==========

    /// @inheritdoc IERC4626
    /// @dev No NAV calculation during flash loans
    function totalAssets() public view returns (uint256) {
        return _nav();
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
        require(!isShutdown(), ErrorsLib.CannotDuringShutdown());
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
        require(!isShutdown(), ErrorsLib.CannotDuringShutdown());
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

    // ========== INVESTMENT MANAGEMENT ==========

    /**
     * @notice Skims non-essential tokens from the contract
     * @param token Token to skim
     * @dev Token must not be the base currency or an investment token
     */
    function skim(IERC20 token) external nonReentrant {
        require(msg.sender == skimRecipient, ErrorsLib.OnlySkimRecipient());
        require(skimRecipient != address(0), ErrorsLib.InvalidAddress());
        require(address(token) != address(asset), ErrorsLib.CannotSkimAsset());
        require(!isToken(token), ErrorsLib.CannotSkimToken());

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
     * @dev Can be called by allocators or during shutdown after warmup if there is debt for `token`
     */
    function allocate(IERC20 token, uint256 assetsAmount, ISwapper swapper, bytes calldata data) public nonReentrant {
        bool winddown = isWinddown();
        require((isAllocator[msg.sender] && !winddown) || (winddown && _debtBalance(token) > 0), ErrorsLib.OnlyAllocatorsOrWinddown());
        require(isToken(token), ErrorsLib.TokenNotWhitelisted());
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());

        IOracle oracle = oracles[token];

        uint256 slippageTolerance = maxSlippage;
        if (winddown) {
            slippageTolerance = _winddownSlippageTolerance();
        }

        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 assetsBefore = IERC20(asset).balanceOf(address(this));

        IERC20(asset).forceApprove(address(swapper), assetsAmount);
        swapper.sell(IERC20(asset), token, assetsAmount, data);

        uint256 tokensReceived = token.balanceOf(address(this)) - tokensBefore;
        uint256 assetsSpent = assetsBefore - IERC20(asset).balanceOf(address(this));

        require(assetsSpent <= assetsAmount, ErrorsLib.SwapperDidSpendTooMuch());

        // Validate slippage
        uint256 expectedTokens = assetsAmount.mulDiv(ORACLE_PRECISION, oracle.price());
        uint256 minTokens = expectedTokens.mulDiv(PRECISION - slippageTolerance, PRECISION);
        int256 slippage = int256(expectedTokens) - int256(tokensReceived);
        int256 slippagePct = expectedTokens == 0 ? int256(0) : (slippage * int256(PRECISION)) / int256(expectedTokens);

        require(tokensReceived >= minTokens, ErrorsLib.AllocationTooExpensive());

        // Revoke allowance to prevent residual approvals
        IERC20(asset).forceApprove(address(swapper), 0);

        // Track slippage, not during wind-down mode
        if (!winddown && slippage > 0) {
            uint256 slippageValue = uint256(slippage).mulDiv(oracle.price(), ORACLE_PRECISION);
            _increaseSlippage(slippageValue.mulDiv(PRECISION, _navForSlippage()));
        }

        emit EventsLib.Allocation(token, assetsSpent, tokensReceived, slippagePct, swapper, data);
    }

    /**
     * @notice Deallocates investment tokens to get assets
     * @param token Investment token to sell
     * @param tokensAmount Amount of tokens to sell
     * @param swapper Swapper contract to use
     * @param data Additional data to pass to the swapper
     * @dev Can be called by allocators or anyone during wind-down, except if there is no debt for `token`
     */
    function deallocate(IERC20 token, uint256 tokensAmount, ISwapper swapper, bytes calldata data) external nonReentrant {
        bool winddown = isWinddown();
        require((isAllocator[msg.sender] && !winddown) || (winddown && _debtBalance(token) == 0), ErrorsLib.OnlyAllocatorsOrWinddown());
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());
        require(isToken(token), ErrorsLib.TokenNotWhitelisted());

        IOracle oracle = oracles[token];

        uint256 slippageTolerance = maxSlippage;
        if (winddown) {
            slippageTolerance = _winddownSlippageTolerance();
        }

        uint256 assetsBefore = IERC20(asset).balanceOf(address(this));
        uint256 tokensBefore = token.balanceOf(address(this));

        token.forceApprove(address(swapper), tokensAmount);
        swapper.sell(token, IERC20(asset), tokensAmount, data);

        uint256 assetsReceived = IERC20(asset).balanceOf(address(this)) - assetsBefore;
        uint256 tokensSpent = tokensBefore - token.balanceOf(address(this));

        require(tokensSpent <= tokensAmount, ErrorsLib.SwapperDidSpendTooMuch());

        // Revoke allowance to prevent residual approvals
        token.forceApprove(address(swapper), 0);

        // Validate slippage
        uint256 expectedAssets = tokensAmount.mulDiv(oracle.price(), ORACLE_PRECISION);
        uint256 minAssets = expectedAssets.mulDiv(PRECISION - slippageTolerance, PRECISION);
        int256 slippage = int256(expectedAssets) - int256(assetsReceived);
        int256 slippagePct = expectedAssets == 0 ? int256(0) : (slippage * int256(PRECISION)) / int256(expectedAssets);

        require(assetsReceived >= minAssets, ErrorsLib.TokenSaleNotGeneratingEnoughAssets());

        // Track slippage (only in normal operation)
        if (!winddown && slippage > 0) {
            // slippage is already in asset units
            uint256 slippageValue = uint256(slippage);
            _increaseSlippage(slippageValue.mulDiv(PRECISION, _navForSlippage()));
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
    function reallocate(IERC20 from, IERC20 to, uint256 tokensAmount, ISwapper swapper, bytes calldata data) external nonReentrant {
        require(isAllocator[msg.sender], ErrorsLib.OnlyAllocators());
        require(!isWinddown(), ErrorsLib.CannotDuringWinddown());
        require(isToken(from) && isToken(to), ErrorsLib.TokenNotWhitelisted());
        require(address(swapper) != address(0), ErrorsLib.InvalidAddress());

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
        int256 slippagePct = expectedToTokens == 0 ? int256(0) : (slippage * int256(PRECISION)) / int256(expectedToTokens);

        require(toReceived >= minToTokens, ErrorsLib.ReallocationSlippageTooHigh());

        // Track slippage, we don't have to exclude wind-down mode as this cannot be called then
        if (slippage > 0) {
            uint256 slippageValue = uint256(slippage).mulDiv(toOracle.price(), ORACLE_PRECISION);
            _increaseSlippage(slippageValue.mulDiv(PRECISION, _navForSlippage()));
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

        address oldCurator = curator;
        curator = newCurator;

        emit EventsLib.CuratorUpdated(oldCurator, newCurator);
    }

    /**
     * @notice Updates the curator address (timelocked)
     * @param newGuardian Address of new guardian
     */
    function setGuardian(address newGuardian) external {
        require(!isWinddown(), ErrorsLib.CannotDuringWinddown());
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
        //        require(account != address(0), ErrorsLib.InvalidAddress());

        isAllocator[account] = newIsAllocator;

        emit EventsLib.AllocatorUpdated(account, newIsAllocator);
    }

    /**
     * @notice Triggers shutdown
     * @dev Only guardian and curators can trigger shutdown
     */
    function shutdown() external {
        require(msg.sender == guardian || msg.sender == curator, ErrorsLib.OnlyGuardianOrCuratorCanShutdown());
        require(!isShutdown(), ErrorsLib.AlreadyShutdown());

        shutdownTime = block.timestamp;

        emit EventsLib.Shutdown(msg.sender);
    }

    /**
     * @notice Recover from shutdown
     * @dev Only guardian can recover from shutdown, and only before wind-down period
     */
    function recover() external {
        require(msg.sender == guardian, ErrorsLib.OnlyGuardianCanRecover());
        require(isShutdown(), ErrorsLib.NotShutdown());
        require(!isWinddown(), ErrorsLib.CannotRecoverAfterWinddown());

        shutdownTime = type(uint256).max;

        emit EventsLib.Recover(msg.sender);
    }

    // ========== TIMELOCK GOVERNANCE ==========

    /**
     * @notice Submits a transaction for timelock
     * @param data Encoded function call
     * @dev If decreaseTimelock is called, the selector in the data is used to determine the timelock duration
     */
    function submit(bytes calldata data) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(executableAt[data] == 0, ErrorsLib.DataAlreadyTimelocked());
        require(data.length >= 4, ErrorsLib.InvalidAmount());

        bytes4 selector = bytes4(data);
        uint256 delay = selector == IBox.decreaseTimelock.selector ? timelock[bytes4(data[4:8])] : timelock[selector];
        executableAt[data] = block.timestamp + delay;

        emit EventsLib.TimelockSubmitted(selector, data, executableAt[data], msg.sender);
    }

    function timelocked() internal {
        require(executableAt[msg.data] > 0, ErrorsLib.DataNotTimelocked());
        require(block.timestamp >= executableAt[msg.data], ErrorsLib.TimelockNotExpired());

        executableAt[msg.data] = 0;

        emit EventsLib.TimelockExecuted(bytes4(msg.data), msg.data, msg.sender);
    }

    /**
     * @notice Revokes a timelocked transaction
     * @param data Encoded function call to revoke
     */
    function revoke(bytes calldata data) external {
        require(msg.sender == curator || msg.sender == guardian, ErrorsLib.OnlyCuratorOrGuardian());
        require(executableAt[data] > 0, ErrorsLib.DataNotTimelocked());

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

    /**
     * @notice Make a timelock selector no longer exectutable by putting it in the far future
     * @param selector Function selector
     * @dev You can't recover from this operation, be careful
     */
    function abdicateTimelock(bytes4 selector) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());

        timelock[selector] = TIMELOCK_DISABLED;

        emit EventsLib.TimelockIncreased(selector, TIMELOCK_DISABLED, msg.sender);
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
        require(isToken(token), ErrorsLib.TokenNotWhitelisted());
        require(token.balanceOf(address(this)) == 0, ErrorsLib.TokenBalanceMustBeZero());
        require(!_isTokenUsedInFunding(token), ErrorsLib.CannotRemove());

        uint256 length = tokens.length;
        for (uint256 i; i < length; ) {
            if (tokens[i] == token) {
                tokens[i] = tokens[length - 1];
                tokens.pop();
                break;
            }
            unchecked {
                ++i;
            }
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
        if (isWinddown()) {
            require(block.timestamp >= shutdownTime + shutdownWarmup + shutdownSlippageDuration, ErrorsLib.NotAllowed());
            require(msg.sender == guardian, ErrorsLib.OnlyGuardian());
        } else {
            timelocked();
        }
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
     * @notice Returns true if token is an investment token
     * @return true if it is a whitelisted investment token
     */
    function isTokenOrAsset(IERC20 token) public view returns (bool) {
        return address(token) == asset || address(oracles[token]) != address(0);
    }

    /**
     * @notice Returns number of investment tokens
     * @return count Number of investment tokens
     */
    function tokensLength() external view returns (uint256) {
        return tokens.length;
    }

    /**
     * @notice Returns true if funding module is whitelisted
     * @param fundingModule Funding module to check
     * @return true if funding module is whitelisted
     */
    function isFunding(IFunding fundingModule) public view returns (bool) {
        return fundingMap[fundingModule];
    }

    /**
     * @notice Returns number of funding modules
     * @return count Number of funding modules
     */
    function fundingsLength() external view override returns (uint256) {
        return fundings.length;
    }

    /**
     * @notice Returns true if the box is in shutdown mode (shutdownTime != type(uint256).max)
     * @return true if the box is in shutdown mode
     */
    function isShutdown() public view returns (bool) {
        return shutdownTime != type(uint256).max;
    }

    /**
     * @notice Returns true if Box is in wind-down mode (after warmup delay of shutdown)
     * @return true if the Box is in wind-down mode
     */
    function isWinddown() public view returns (bool) {
        return shutdownTime != type(uint256).max && block.timestamp >= shutdownTime + shutdownWarmup;
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @dev Returns NAV for slippage calculations - uses cached value during flash operations
     */
    function _navForSlippage() internal view returns (uint256) {
        return _isInFlash ? _cachedNavForFlash : _nav();
    }

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

        require(accumulatedSlippage < maxSlippage, ErrorsLib.TooMuchAccumulatedSlippage());

        emit EventsLib.SlippageAccumulated(slippagePct, accumulatedSlippage);
    }

    /**
     * @dev Calculates the net asset value of all tokens and assets in the vault
     * @return nav The net asset value of all assets
     * @dev The NAV for a given lending market can be negative but there is no recourse so it can be floored to 0.
     * @dev No NAV calculation during flash loans
     */
    function _nav() internal view returns (uint256 nav) {
        require(_isInFlash == false, ErrorsLib.NoNavDuringFlash());
        nav = IERC20(asset).balanceOf(address(this));

        // Add value of all tokens
        uint256 length = tokens.length;
        for (uint256 i; i < length; ) {
            IERC20 token = tokens[i];
            IOracle oracle = oracles[token];
            if (address(oracle) != address(0)) {
                uint256 tokenBalance = token.balanceOf(address(this));
                if (tokenBalance > 0) {
                    nav += tokenBalance.mulDiv(oracle.price(), ORACLE_PRECISION);
                }
            }
            unchecked {
                ++i;
            }
        }
        // Loop over funding sources
        length = fundings.length;
        for (uint256 i; i < length; ) {
            IFunding funding = fundings[i];
            nav += funding.nav(IOracleCallback(address(this)));
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Assume wind-down mode, otherwise will revert
     */
    function _winddownSlippageTolerance() internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp - shutdownWarmup - shutdownTime;
        return
            (timeElapsed < shutdownSlippageDuration)
                ? timeElapsed.mulDiv(MAX_SLIPPAGE_LIMIT, shutdownSlippageDuration)
                : MAX_SLIPPAGE_LIMIT;
    }

    function _findFundingIndex(IFunding fundingData) internal view returns (uint256) {
        for (uint256 i = 0; i < fundings.length; i++) {
            if (fundings[i] == fundingData) {
                return i;
            }
        }
        revert ErrorsLib.NotWhitelisted();
    }

    function _isTokenUsedInFunding(IERC20 token) internal view returns (bool) {
        uint256 length = fundings.length;
        for (uint256 i; i < length; i++) {
            IFunding funding = fundings[i];
            if (funding.isCollateralToken(token) || funding.isDebtToken(token)) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Returns the total debt balance across all funding modules for a given debt token
     * @param debtToken The debt token to check
     * @return totalDebt The total debt balance
     */
    function _debtBalance(IERC20 debtToken) internal view returns (uint256 totalDebt) {
        uint256 length = fundings.length;
        for (uint256 i; i < length; i++) {
            IFunding funding = fundings[i];
            totalDebt += funding.debtBalance(debtToken);
        }
    }

    // ========== FUNDING VIEW FUNCTIONS ==========

    /// @dev The fundingModule should be completely empty
    function addFunding(IFunding fundingModule) external {
        timelocked();
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(!fundingMap[fundingModule], ErrorsLib.AlreadyWhitelisted());
        require(address(fundingModule) != address(0), ErrorsLib.InvalidAddress());
        require(fundingModule.facilitiesLength() == 0, ErrorsLib.NotClean());
        require(fundingModule.collateralTokensLength() == 0, ErrorsLib.NotClean());
        require(fundingModule.debtTokensLength() == 0, ErrorsLib.NotClean());

        fundingMap[fundingModule] = true;
        fundings.push(fundingModule);

        emit EventsLib.FundingModuleAdded(fundingModule);
    }

    function addFundingFacility(IFunding fundingModule, bytes calldata facilityData) external {
        timelocked();
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        fundingModule.addFacility(facilityData);

        emit EventsLib.FundingFacilityAdded(fundingModule, facilityData);
    }

    function addFundingCollateral(IFunding fundingModule, IERC20 collateralToken) external {
        timelocked();
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());
        require(isTokenOrAsset(collateralToken), ErrorsLib.TokenNotWhitelisted());

        fundingModule.addCollateralToken(collateralToken);

        emit EventsLib.FundingCollateralAdded(fundingModule, collateralToken);
    }

    function addFundingDebt(IFunding fundingModule, IERC20 debtToken) external {
        timelocked();
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());
        require(isTokenOrAsset(debtToken), ErrorsLib.TokenNotWhitelisted());

        fundingModule.addDebtToken(debtToken);

        emit EventsLib.FundingDebtAdded(fundingModule, debtToken);
    }

    function removeFunding(IFunding fundingModule) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        require(fundingModule.facilitiesLength() == 0, ErrorsLib.CannotRemove());
        require(fundingModule.collateralTokensLength() == 0, ErrorsLib.CannotRemove());
        require(fundingModule.debtTokensLength() == 0, ErrorsLib.CannotRemove());

        fundingMap[fundingModule] = false;
        uint256 index = _findFundingIndex(fundingModule);
        fundings[index] = fundings[fundings.length - 1];
        fundings.pop();

        emit EventsLib.FundingModuleRemoved(fundingModule);
    }

    function removeFundingFacility(IFunding fundingModule, bytes calldata facilityData) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        fundingModule.removeFacility(facilityData);

        emit EventsLib.FundingFacilityRemoved(fundingModule, facilityData);
    }

    function removeFundingCollateral(IFunding fundingModule, IERC20 collateralToken) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        fundingModule.removeCollateralToken(collateralToken);

        emit EventsLib.FundingCollateralRemoved(fundingModule, collateralToken);
    }

    function removeFundingDebt(IFunding fundingModule, IERC20 debtToken) external {
        require(msg.sender == curator, ErrorsLib.OnlyCurator());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        fundingModule.removeDebtToken(debtToken);

        emit EventsLib.FundingDebtRemoved(fundingModule, debtToken);
    }

    function pledge(IFunding fundingModule, bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external {
        require(isAllocator[msg.sender] && !isWinddown(), ErrorsLib.OnlyAllocators());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        collateralToken.safeTransfer(address(fundingModule), collateralAmount);
        fundingModule.pledge(facilityData, collateralToken, collateralAmount);

        emit EventsLib.Pledge(fundingModule, facilityData, collateralToken, collateralAmount);
    }

    function depledge(IFunding fundingModule, bytes calldata facilityData, IERC20 collateralToken, uint256 collateralAmount) external {
        require(isAllocator[msg.sender] || isWinddown(), ErrorsLib.OnlyAllocatorsOrWinddown());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        uint256 pledgeAmount = fundingModule.collateralBalance(facilityData, collateralToken);

        if (collateralAmount == type(uint256).max) {
            collateralAmount = pledgeAmount;
        }

        fundingModule.depledge(facilityData, collateralToken, collateralAmount);

        emit EventsLib.Depledge(fundingModule, facilityData, collateralToken, collateralAmount);
    }

    function borrow(IFunding fundingModule, bytes calldata facilityData, IERC20 debtToken, uint256 borrowAmount) external {
        require(isAllocator[msg.sender] && !isWinddown(), ErrorsLib.OnlyAllocators());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        fundingModule.borrow(facilityData, debtToken, borrowAmount);

        emit EventsLib.Borrow(fundingModule, facilityData, debtToken, borrowAmount);
    }

    function repay(IFunding fundingModule, bytes calldata facilityData, IERC20 debtToken, uint256 repayAmount) external {
        require(isAllocator[msg.sender] || isWinddown(), ErrorsLib.OnlyAllocatorsOrWinddown());
        require(isFunding(fundingModule), ErrorsLib.NotWhitelisted());

        uint256 debtAmount = fundingModule.debtBalance(facilityData, debtToken);

        if (repayAmount == type(uint256).max) {
            repayAmount = debtAmount;
        }

        debtToken.safeTransfer(address(fundingModule), repayAmount);
        fundingModule.repay(facilityData, debtToken, repayAmount);

        emit EventsLib.Repay(fundingModule, facilityData, debtToken, repayAmount);
    }

    function flash(IERC20 flashToken, uint256 flashAmount, bytes calldata data) external {
        require(isAllocator[msg.sender] || isWinddown(), ErrorsLib.OnlyAllocators());
        require(address(flashToken) != address(0), ErrorsLib.InvalidAddress());
        require(isTokenOrAsset(flashToken), ErrorsLib.TokenNotWhitelisted());
        require(!_isInFlash, ErrorsLib.AlreadyInFlash());

        // Cache NAV before starting flash operation for slippage calculations
        _cachedNavForFlash = _nav();
        _isInFlash = true;

        // Transfer flash amount FROM caller TO this contract
        flashToken.safeTransferFrom(msg.sender, address(this), flashAmount);

        // Call the callback function on the caller
        IBoxFlashCallback(msg.sender).onBoxFlash(flashToken, flashAmount, data);

        // Repay the flash loan by transferring back TO caller
        flashToken.safeTransfer(msg.sender, flashAmount);

        _isInFlash = false;

        emit EventsLib.Flash(msg.sender, flashToken, flashAmount);
    }
}
