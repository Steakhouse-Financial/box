// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/ISwapper.sol";
import "./lib/Errors.sol";

/// @title Box: A contract that can hold a currency and some assets and swap them
contract Box is IERC4626 {
    using SafeERC20 for IERC20;
    
    uint256 constant TIMELOCK_CAP = 2 weeks;
    uint256 constant MAX_SLIPPAGE = 0.1 ether; // 10%

    IERC20 public immutable currency;
    ISwapper public immutable backupSwapper;

    address public owner;
    address public curator;

    // Role-based access control
    mapping(address => bool) public isAllocator;
    mapping(address => bool) public isFeeder;

    // ERC20 state
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Investment tokens and oracles
    IERC20[] public investmentTokens;
    mapping(IERC20 => IOracle) public oracles;
    mapping(IERC20 => bool) public isInvestmentToken;

    // Slippage tracking
    uint256 public maxSlippage = 0.01 ether; // 1%
    uint256 public accumulatedSlippage;
    uint256 public slippageEpochStart;

    // Shutdown mechanism
    bool public shutdown;
    uint256 public shutdownTime;

    // Timelock governance (VaultV2 pattern)
    mapping(bytes4 => uint256) public timelock;
    mapping(bytes => uint256) public executableAt;

    // Events
    event Allocation(IERC20 indexed token, uint256 amount, ISwapper indexed swapper);
    event Deallocation(IERC20 indexed token, uint256 amount, ISwapper indexed swapper);
    event Reallocation(IERC20 indexed fromToken, IERC20 indexed toToken, uint256 amount, ISwapper indexed swapper);
    event Shutdown(address indexed guardian);
    event Unbox(address indexed user, uint256 shares);
    event SlippageAccumulated(uint256 amount, uint256 total);
    event SlippageEpochReset(uint256 newEpochStart);
    event TimelockSubmitted(bytes4 indexed selector, bytes data, uint256 executableAt);
    event TimelockRevoked(bytes4 indexed selector, bytes data);
    event TimelockIncreased(bytes4 indexed selector, uint256 newDuration);
    
    constructor(
        IERC20 _currency,
        ISwapper _backupSwapper,
        address _owner,
        address _curator
    ) {
        currency = _currency;
        backupSwapper = _backupSwapper;
        owner = _owner;
        curator = _curator;
        slippageEpochStart = block.timestamp;
        
        name = "Box Shares";
        symbol = "BOX";

        isAllocator[owner] = true;
        isFeeder[owner] = true;

        // Initialize timelock durations
        timelock[this.setMaxSlippage.selector] = 1 days;
        timelock[this.addInvestmentToken.selector] = 1 days;
        timelock[this.removeInvestmentToken.selector] = 1 days;
        timelock[this.setIsAllocator.selector] = 1 days;
        timelock[this.setIsFeeder.selector] = 1 days;
    }

    /////////////////////////////
    /// ERC4626 Implementation
    /////////////////////////////

    /// @notice Returns the address of the underlying token used for the Vault for accounting, depositing, and withdrawing.
    function asset() external view returns (address) {
        return address(currency);
    }

    /// @notice Returns the total amount of the underlying asset that is "managed" by Vault.
    function totalAssets() public view returns (uint256 assets_) {
        assets_ = currency.balanceOf(address(this));
        
        // Add value of all investment tokens
        for (uint256 i = 0; i < investmentTokens.length; i++) {
            IERC20 token = investmentTokens[i];
            IOracle oracle = oracles[token];
            if (address(oracle) != address(0)) {
                uint256 tokenBalance = token.balanceOf(address(this));
                assets_ += (tokenBalance * oracle.price()) / 1e36;
            }
        }
    }

    /// @notice Returns the amount of shares that the Vault would exchange for the amount of assets provided
    function convertToShares(uint256 assets) public view returns (uint256) {
        return totalSupply == 0 ? assets : (assets * totalSupply) / totalAssets();
    }

    /// @notice Returns the amount of assets that the Vault would exchange for the amount of shares provided
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return totalSupply == 0 ? shares : (shares * totalAssets()) / totalSupply;
    }

    /// @notice Returns the maximum amount of the underlying asset that can be deposited
    function maxDeposit(address) external view returns (uint256) {
        return shutdown ? 0 : type(uint256).max;
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their deposit
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Mints shares Vault shares to receiver by depositing exactly amount of underlying tokens.
    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        if (!isFeeder[msg.sender]) revert Errors.OnlyFeeders();
        if (shutdown) revert Errors.CannotDepositIfShutdown();
        if (assets == 0) revert Errors.CannotDepositZero();

        shares = previewDeposit(assets);
        if (shares == 0) revert Errors.CannotDepositZero();

        currency.safeTransferFrom(msg.sender, address(this), assets);
        
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Returns the maximum amount of the Vault shares that can be minted
    function maxMint(address) external view returns (uint256) {
        return shutdown ? 0 : type(uint256).max;
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their mint
    function previewMint(uint256 shares) public view returns (uint256) {
        return totalSupply == 0 ? shares : (shares * totalAssets() + totalSupply - 1) / totalSupply;
    }

    /// @notice Mints exactly shares Vault shares to receiver
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        if (!isFeeder[msg.sender]) revert Errors.OnlyFeeders();
        if (shutdown) revert Errors.CannotMintIfShutdown();
        if (shares == 0) revert Errors.CannotMintZero();

        assets = previewMint(shares);
        
        currency.safeTransferFrom(msg.sender, address(this), assets);
        
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Returns the maximum amount of the underlying asset that can be withdrawn
    function maxWithdraw(address owner_) external view returns (uint256) {
        uint256 shares = balanceOf[owner_];
        return convertToAssets(shares);
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their withdrawal
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return totalSupply == 0 ? assets : (assets * totalSupply + totalAssets() - 1) / totalAssets();
    }

    /// @notice Burns shares from owner and sends exactly assets of underlying tokens to receiver
    function withdraw(uint256 assets, address receiver, address owner_) public returns (uint256 shares) {
        if (!isFeeder[msg.sender]) revert Errors.OnlyFeeders();
        
        shares = previewWithdraw(assets);
        if (msg.sender != owner_ && allowance[owner_][msg.sender] < shares) revert Errors.InsufficientAllowance();
        if (balanceOf[owner_] < shares) revert Errors.InsufficientShares();
        if (currency.balanceOf(address(this)) < assets) revert Errors.InsufficientLiquidity();

        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[owner_][msg.sender] = allowed - shares;
            }
        }

        _burn(owner_, shares);
        currency.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @notice Returns the maximum amount of Vault shares that can be redeemed
    function maxRedeem(address owner_) external view returns (uint256) {
        return balanceOf[owner_];
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their redemption
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @notice Burns exactly shares from owner and sends assets of underlying tokens to receiver
    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        if (!isFeeder[msg.sender]) revert Errors.OnlyFeeders();
        if (msg.sender != owner_ && allowance[owner_][msg.sender] < shares) revert Errors.InsufficientAllowance();
        if (balanceOf[owner_] < shares) revert Errors.InsufficientShares();

        assets = previewRedeem(shares);

        if (currency.balanceOf(address(this)) < assets) revert Errors.InsufficientLiquidity();

        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[owner_][msg.sender] = allowed - shares;
            }
        }

        _burn(owner_, shares);
        currency.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /////////////////////////////
    /// ERC20 Functions for Shares
    /////////////////////////////

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    /////////////////////////////
    /// Emergency Exit (Unbox)
    /////////////////////////////

    /// @notice Return the prorata share of currency and assets against shares (emergency exit)
    function unbox(uint256 shares) public {
        if (balanceOf[msg.sender] < shares) revert Errors.InsufficientShares();
        if (shares == 0) revert Errors.CannotUnboxZeroShares();

        uint256 currencyAmount = (currency.balanceOf(address(this)) * shares) / totalSupply;
        
        _burn(msg.sender, shares);

        if (currencyAmount > 0) {
            currency.safeTransfer(msg.sender, currencyAmount);
        }

        // Transfer pro-rata share of each investment token
        for (uint256 i = 0; i < investmentTokens.length; i++) {
            IERC20 token = investmentTokens[i];
            // needs `+ shares` because _burn reduced totalSupply
            uint256 tokenAmount = (token.balanceOf(address(this)) * shares) / (totalSupply + shares);
            if (tokenAmount > 0) {
                token.safeTransfer(msg.sender, tokenAmount);
            }
        }
    }
    
    /////////////////////////////
    /// SWAPPING
    /////////////////////////////

    /// @notice Buy investment token with currency
    function allocate(IERC20 token, uint256 currencyAmount, ISwapper swapper) public {
        if (!isAllocator[msg.sender]) revert Errors.OnlyAllocators();
        if (shutdown) revert Errors.CannotAllocateIfShutdown();
        if (!isInvestmentToken[token]) revert Errors.TokenNotWhitelisted();
        if (address(oracles[token]) == address(0)) revert Errors.NoOracleForToken();

        uint256 tokensBefore = token.balanceOf(address(this));

        currency.approve(address(swapper), currencyAmount);
        swapper.sell(currency, token, currencyAmount);
        
        uint256 tokensReceived = token.balanceOf(address(this)) - tokensBefore;

        // Calculate expected tokens and minimum acceptable
        uint256 expectedTokens = (currencyAmount * 1e36) / oracles[token].price();
        uint256 minTokens = (expectedTokens * (1 ether - maxSlippage)) / 1 ether;

        if (tokensReceived < minTokens) revert Errors.AllocationTooExpensive();

        // Calculate slippage as difference between expected and actual
        uint256 slippage = expectedTokens > tokensReceived ? 
            expectedTokens - tokensReceived : 0;
        _increaseSlippage((slippage * oracles[token].price() / 1e36 * 1e18) / totalAssets());

        emit Allocation(token, currencyAmount, swapper);
    }

    /// @notice Sell investment token for currency
    function deallocate(IERC20 token, uint256 tokensAmount, ISwapper swapper) public {
        if (!isAllocator[msg.sender] && !shutdown) revert Errors.OnlyAllocatorsOrShutdown();
        if (address(oracles[token]) == address(0)) revert Errors.NoOracleForToken();

        if (shutdown) {
            _deallocateShutdown(token, tokensAmount);
        } else {
            _deallocateNormal(token, tokensAmount, swapper);
        }
    }

    function _deallocateNormal(IERC20 token, uint256 tokensAmount, ISwapper swapper) internal {
        uint256 currencyBefore = currency.balanceOf(address(this));

        token.approve(address(swapper), tokensAmount);
        swapper.sell(token, currency, tokensAmount);

        uint256 currencyReceived = currency.balanceOf(address(this)) - currencyBefore;

        // Calculate expected currency and minimum acceptable
        uint256 expectedCurrency = (tokensAmount * oracles[token].price()) / 1e36;
        uint256 minCurrency = (expectedCurrency * (1 ether - maxSlippage)) / 1 ether;

        if (currencyReceived < minCurrency) revert Errors.TokenSaleNotGeneratingEnoughCurrency();

        // Calculate slippage
        uint256 slippage = expectedCurrency > currencyReceived ? 
            expectedCurrency - currencyReceived : 0;
        _increaseSlippage((slippage * 1e18) / totalAssets());

        emit Deallocation(token, tokensAmount, swapper);
    }

    function _deallocateShutdown(IERC20 token, uint256 tokensAmount) internal {
        uint256 currencyBefore = currency.balanceOf(address(this));

        // Use backup swapper during shutdown
        token.approve(address(backupSwapper), tokensAmount);
        backupSwapper.sell(token, currency, tokensAmount);

        uint256 currencyReceived = currency.balanceOf(address(this)) - currencyBefore;

        // During shutdown, slippage tolerance increases over time (0% to 10% over 10 days)
        uint256 timeElapsed = block.timestamp - shutdownTime;
        uint256 shutdownSlippage = timeElapsed > 10 days ? 0.1 ether : (timeElapsed * 0.1 ether) / 10 days;
        
        uint256 expectedCurrency = (tokensAmount * oracles[token].price()) / 1e36;
        uint256 minCurrency = (expectedCurrency * (1 ether - shutdownSlippage)) / 1 ether;

        if (currencyReceived < minCurrency) revert Errors.TokenSaleNotGeneratingEnoughCurrency();

        emit Deallocation(token, tokensAmount, backupSwapper);
    }

    function _deallocateForLiquidity(uint256 currencyNeeded) internal {
        // Try to deallocate from investment tokens to get needed liquidity
        for (uint256 i = 0; i < investmentTokens.length && currency.balanceOf(address(this)) < currencyNeeded; i++) {
            IERC20 token = investmentTokens[i];
            uint256 tokenBalance = token.balanceOf(address(this));
            if (tokenBalance > 0) {
                uint256 tokensToSell = ((currencyNeeded - currency.balanceOf(address(this))) * 1e36) / oracles[token].price();
                if (tokensToSell > tokenBalance) {
                    tokensToSell = tokenBalance;
                }
                _deallocateShutdown(token, tokensToSell);
            }
        }
    }

    /// @notice Reallocate from one investment token to another
    function reallocate(IERC20 from, IERC20 to, uint256 fromAmount, ISwapper swapper) public {
        if (!isAllocator[msg.sender]) revert Errors.OnlyAllocators();
        if (shutdown) revert Errors.CannotReallocateIfShutdown();
        if (!isInvestmentToken[from] || !isInvestmentToken[to]) revert Errors.TokensNotWhitelisted();
        if (address(oracles[from]) == address(0) || address(oracles[to]) == address(0)) revert Errors.OracleRequired();

        uint256 toBefore = to.balanceOf(address(this));

        from.approve(address(swapper), fromAmount);
        swapper.sell(from, to, fromAmount);

        uint256 toReceived = to.balanceOf(address(this)) - toBefore;

        // Calculate expected amounts based on both oracles
        // fromAmount * fromPrice / toPrice = expected toTokens
        uint256 fromValue = (fromAmount * oracles[from].price()) / 1e36; // Value in currency terms
        uint256 expectedToTokens = (fromValue * 1e36) / oracles[to].price(); // Expected tokens based on oracle prices
        uint256 minToTokens = (expectedToTokens * (1 ether - maxSlippage)) / 1 ether;

        if (toReceived < minToTokens) revert Errors.ReallocationSlippageTooHigh();

        // Calculate slippage as difference between expected and actual, in currency terms
        uint256 expectedValue = (expectedToTokens * oracles[to].price()) / 1e36;
        uint256 actualValue = (toReceived * oracles[to].price()) / 1e36;
        uint256 slippage = expectedValue > actualValue ? expectedValue - actualValue : 0;
        
        // Track slippage as percentage of total assets
        _increaseSlippage((slippage * 1e18) / totalAssets());

        emit Reallocation(from, to, fromAmount, swapper);
    }

    function _increaseSlippage(uint256 slippagePct) internal {
        // Reset the slippage epoch if more than a week old
        if (slippageEpochStart + 7 days < block.timestamp) {
            slippageEpochStart = block.timestamp;
            accumulatedSlippage = 0;
        }

        accumulatedSlippage += slippagePct;
        if (accumulatedSlippage >= maxSlippage) revert Errors.TooMuchAccumulatedSlippage();
    }

    /////////////////////////////
    /// OWNER FUNCTIONS
    /////////////////////////////

    function setOwner(address newOwner) external {
        if (msg.sender != owner) revert Errors.OnlyOwner();
        if (newOwner == address(0)) revert Errors.InvalidOwner();
        address oldOwner = owner;
        owner = newOwner;
    }

    function setCurator(address newCurator) external {
        if (msg.sender != owner) revert Errors.OnlyOwner();
        curator = newCurator;
    }

    function triggerShutdown() external {
        if (msg.sender != curator) revert Errors.OnlyCuratorCanShutdown();
        if (shutdown) revert Errors.AlreadyShutdown();
        shutdown = true;
        shutdownTime = block.timestamp;
        emit Shutdown(curator);
    }

    /////////////////////////////
    /// TIMELOCK FUNCTIONS (VaultV2 pattern)
    /////////////////////////////

    function submit(bytes calldata data) external {
        if (msg.sender != curator) revert Errors.OnlyCurator();
        if (executableAt[data] != 0) revert Errors.DataNotTimelocked();

        bytes4 selector = bytes4(data);
        executableAt[data] = block.timestamp + timelock[selector];
        emit TimelockSubmitted(selector, data, executableAt[data]);
    }

    modifier timelocked() {
        if (executableAt[msg.data] == 0) revert Errors.DataNotTimelocked();
        if (block.timestamp < executableAt[msg.data]) revert Errors.TimelockNotExpired();
        executableAt[msg.data] = 0;
        _;
    }

    function revoke(bytes calldata data) external {
        if (msg.sender != curator) revert Errors.OnlyCurator();
        if (executableAt[data] == 0) revert Errors.DataNotTimelocked();
        executableAt[data] = 0;
        emit TimelockRevoked(bytes4(data), data);
    }

    function increaseTimelock(bytes4 selector, uint256 newDuration) external {
        if (msg.sender != curator) revert Errors.OnlyCurator();
        if (newDuration > TIMELOCK_CAP) revert Errors.SlippageTooHigh(); // Reusing error for timelock cap
        if (newDuration < timelock[selector]) revert Errors.SlippageTooHigh(); // Reusing error for timelock decrease
        timelock[selector] = newDuration;
        emit TimelockIncreased(selector, newDuration);
    }

    /////////////////////////////
    /// TIMELOCKED FUNCTIONS
    /////////////////////////////

    function setIsAllocator(address account, bool newIsAllocator) external timelocked {
        isAllocator[account] = newIsAllocator;
    }

    function setIsFeeder(address account, bool newIsFeeder) external timelocked {
        isFeeder[account] = newIsFeeder;
    }

    function setMaxSlippage(uint256 newMaxSlippage) external timelocked {
        if (newMaxSlippage > MAX_SLIPPAGE) revert Errors.SlippageTooHigh();
        maxSlippage = newMaxSlippage;
    }

    function addInvestmentToken(IERC20 token, IOracle oracle) external timelocked {
        if (address(token) == address(0)) revert Errors.TokenNotWhitelisted();
        if (address(oracle) == address(0)) revert Errors.OracleRequired();
        if (isInvestmentToken[token]) revert Errors.TokenNotWhitelisted();
        
        investmentTokens.push(token);
        oracles[token] = oracle;
        isInvestmentToken[token] = true;
    }

    function removeInvestmentToken(IERC20 token) external timelocked {
        if (!isInvestmentToken[token]) revert Errors.TokenNotWhitelisted();
        if (token.balanceOf(address(this)) != 0) revert Errors.TokenBalanceMustBeZero();
        
        for (uint256 i = 0; i < investmentTokens.length; i++) {
            if (investmentTokens[i] == token) {
                investmentTokens[i] = investmentTokens[investmentTokens.length - 1];
                investmentTokens.pop();
                break;
            }
        }

        delete oracles[token];
        isInvestmentToken[token] = false;
    }

    /////////////////////////////
    /// VIEW FUNCTIONS
    /////////////////////////////

    function getInvestmentTokensLength() external view returns (uint256) {
        return investmentTokens.length;
    }

    function getInvestmentToken(uint256 index) external view returns (IERC20) {
        return investmentTokens[index];
    }
}
