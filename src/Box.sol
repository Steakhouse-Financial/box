// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool success);
    function allowance(address owner, address spender) external view returns (uint256 remaining);
    function approve(address spender, uint256 amount) external returns (bool success);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool success);
}

interface IOracle {    
    /// @notice Returns the price of 1 asset of collateral token quoted in 1 asset of loan token, scaled by 1e36.
    function price() external view returns (uint256);
}

interface ISwapper {
    /// @notice Take `amountIn``input` from `msg.sender` swap to òutput`and send back to `msg.sender`
    function swap(IERC20 input, IERC20 output, uint256 amountIn) external;
}

///
contract Box /* is IERC4626 */ {
    IERC20 public immutable currency;

    address public owner;
    address public allocator;
    address public guardian;
    address public feeder;

    // ASSETS RELATED
    IERC20 public asset;
    IOracle public oracle;
    /// @dev Only used when the feeder withdraw after shutdown, this one should be immutable
    ISwapper public seller;

    // SWAPPING RELATED
    /// @notice starting date of a swapping epoch
    uint256 slippageEpochStart;
    /// @notice amount of currency alread rotated
    uint256 slippageAccum;

    /// @notice Is the Box shut down and only emergenct
    bool shutdown;
  
    /// @dev calldata => executable at
    mapping(bytes => uint256) public validAt;    
    
    // TODO: do we want different timelock or to update it?
    // TODO: we will need a longer 21 (90?) days for shutdown at least
    uint256 public timelock = 7 days;
    uint256 constant maxSlippage = 0.01 ether;

    constructor(address _owner, address _allocator, IERC20 _currency ) {
        owner = _owner;
        allocator = _allocator;
        currency = _currency;
    }


    function isFeeder(address who) public view returns (bool) {
        return who == feeder;
    }

    function isAllocator(address who) public view returns (bool) {
        return who == allocator;
    }


    /////////////////////////////
    /// Box 
    /////////////////////////////

    /// @notice Deposit currency, if not the whitelisted, there will be a fee
    function deposit(uint256 amount, address who) public {
        require(msg.sender == who, "BOX: Can't donate to third parties");
        require(isFeeder(msg.sender), "BOX: Only feeders can deposit");
        require(shutdown == false, "BOX: Can't deposit if shut down");

        currency.transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public {
        require(isFeeder(msg.sender), "BOX: Only feeders can withdraw");

        // If we are shut down, try to gather enough liqudity
        if(shutdown && currency.balanceOf(address(this)) < amount)
            _shutdownDeallocate(amount);

        // Can only transfer the USDC don't touch the assets
        currency.transfer(msg.sender, amount);
    }

    function _shutdownDeallocate(uint256 amount) internal {
        // TODO loop through the asset to deallocate until we have enough assets
        // TODO for the slippage check, we increase the allowed slipage over a year
    }

    /// @notice Return the prorata share of currency and assets against shares
    function unbox(uint256 shares) public {
        // TODO is it needed?
    }    
    
    /////////////////////////////
    /// SWAPPING
    /////////////////////////////

    /// @notice Buy asset with currency
    /// @dev we don't specify any code, just a safety threshold
    // TODO: Use the callback way
    function allocate(uint256 cash, uint256 assets) public {
        require(isAllocator(msg.sender), "BOX: Only allocator can allocate");
        require(shutdown == false, "BOX: Can't allocate if shut down");

        // TODO: safe mulDiv
        uint256 cost =  (assets * oracle.price()) / 10**36;
        uint256 maxCost = (cost * (1 ether + maxSlippage)) / 1 ether;

        require(cash < maxCost, "BOX: Allocation too expensive");

        uint256 slippage = cash - cost; // min 0
        _increaseSlippage(slippage);

        asset.transferFrom(msg.sender, address(this), assets);
        currency.transferFrom(address(this), msg.sender, cash);
    }    

    /// @notice Sell asset for currency
    // TODO: Use the callback way
    function deallocate(uint256 assets, uint256 cash) public {
        require(isAllocator(msg.sender), "BOX: Only allocator can deallocate");

        // TODO: safe mulDiv
        uint256 cost =  (assets * oracle.price()) / 10**36;
        uint256 maxCost = (cost * (1 ether + maxSlippage)) / 1 ether;

        require(cash < maxCost, "BOX: Allocation too expensive");

        currency.transferFrom(msg.sender, address(this), cash);
        asset.transferFrom(address(this), msg.sender, assets);
    }    
    
    /// @notice Sell asset for another
    // TODO: Use the callback way
    function reallocate(IERC20 from, IERC20 to, uint256 fromAmount, uint256 toAmount) public {
        require(isAllocator(msg.sender), "BOX: Only allocator can reallocate");
        require(shutdown == false, "BOX: Can't reallocate if shut down");

        // TODOs
    }    

    function _increaseSlippage(uint slippage) internal {
        uint256 sipplagePct = (slippage * 10**18)/totalAssets();

        // reset the slippage epoch if more than a week old
        if

        slippageAccum += 

        require(slippageAccum < maxSlippage, "BOX: Too much accumulated slippage");

    }
    

    /// @notice Returns total asset of the Box, cash + assets * oracle price
    function totalAssets() public view returns (uint256 assets) {
        assets = currency.balanceOf(address(this));
        // TODO: safe mulDiv as it can overflow
        assets += asset.balanceOf(address(this)) * oracle.price() / 10**36;
    }


    /* TIMELOCKS */
    function submit(bytes calldata data) external {
        require(msg.sender == owner, "BOX: Unauthorized");
        require(validAt[data] == 0, "BOX: Already Pending");

        bytes4 selector = bytes4(data);
        validAt[data] = block.timestamp + timelock[selector];
    }

    modifier timelocked() {
        require(validAt[msg.data] != 0, "BOX: No timelock set");
        require(block.timestamp >= validAt[msg.data], "BOX: Timelock not expired");
        validAt[msg.data] = 0;
        _;
    }

    function revoke(bytes calldata data) external {
        require(msg.sender == guardian, "BOX: Unauthorized, only guardian");
        require(validAt[data] != 0, "BOX: No timelock set");
        validAt[data] = 0;
    }

}
