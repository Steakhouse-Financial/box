// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association, Steakhouse Financial
pragma solidity 0.8.28;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "./interfaces/IBoxAdapter.sol";
import {Box} from "./Box.sol";
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {SafeERC20Lib} from "../lib/vault-v2/src/libraries/SafeERC20Lib.sol";
import {MathLib} from "../lib/vault-v2/src/libraries/MathLib.sol";

contract BoxAdapter is IBoxAdapter {
    using MathLib for uint256;

    /* IMMUTABLES */

    address public immutable factory;
    address public immutable parentVault;
    Box public immutable box;
    bytes32 public immutable adapterId;

    /* STORAGE */

    address public skimRecipient;
    /// @dev `shares` are the recorded shares created by allocate and burned by deallocate.
    uint256 public shares;

    uint256 public loss;

    /* FUNCTIONS */

    constructor(address _parentVault, Box _box) {
        factory = msg.sender;
        parentVault = _parentVault;
        box = _box;
        adapterId = keccak256(abi.encode("this", address(this)));
        address asset = IVaultV2(_parentVault).asset();
        require(asset == _box.asset(), AssetMismatch());
        SafeERC20Lib.safeApprove(asset, _parentVault, type(uint256).max);
        SafeERC20Lib.safeApprove(asset, address(_box), type(uint256).max);
    }

    function setSkimRecipient(address newSkimRecipient) external {
        require(msg.sender == IVaultV2(parentVault).owner(), NotAuthorized());
        skimRecipient = newSkimRecipient;
        emit SetSkimRecipient(newSkimRecipient);
    }

    /// @dev Skims the adapter's balance of `token` and sends it to `skimRecipient`.
    /// @dev This is useful to handle rewards that the adapter has earned.
    function skim(address token) external {
        require(msg.sender == skimRecipient, NotAuthorized());
        require(token != address(box), CannotSkimBoxShares());
        uint256 balance = IERC20(token).balanceOf(address(this));
        SafeERC20Lib.safeTransfer(token, skimRecipient, balance);
        emit Skim(token, balance);
    }

    /// @dev Does not log anything because the ids (logged in the parent vault) are enough.
    /// @dev Returns the ids of the allocation and the interest accrued.
    function allocate(bytes memory data, uint256 assets, bytes4, address)
        external
        returns (bytes32[] memory, uint256)
    {
        require(data.length == 0, InvalidData());
        require(msg.sender == parentVault, NotAuthorized());

        // To accrue interest only one time.
        IERC4626(box).deposit(0, address(this));
        uint256 interest = IERC4626(box).previewRedeem(shares).zeroFloorSub(allocation());

        if (assets > 0) shares += IERC4626(box).deposit(assets, address(this));

        return (ids(), interest);
    }

    /// @dev Does not log anything because the ids (logged in the parent vault) are enough.
    /// @dev Returns the ids of the deallocation and the interest accrued.
    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        returns (bytes32[] memory, uint256)
    {
        require(data.length == 0, InvalidData());
        require(msg.sender == parentVault, NotAuthorized());

        // To accrue interest only one time.
        IERC4626(box).deposit(0, address(this));
        uint256 interest = IERC4626(box).previewRedeem(shares).zeroFloorSub(allocation());

        if (assets > 0) shares -= IERC4626(box).withdraw(assets, address(this), address(this));

        return (ids(), interest);
    }

    function realizeLoss(bytes memory data, bytes4, address) external returns (bytes32[] memory, uint256) {
        require(data.length == 0, InvalidData());
        require(msg.sender == parentVault, NotAuthorized());

        uint256 recognizedLoss = loss;

        loss = 0;

        return (ids(), recognizedLoss);
    }

    function recognizeLoss() external {
        // Only guardian or curator can recognize loss.
        require(msg.sender == box.guardian() || msg.sender == box.curator(), NotAuthorized());

        loss = allocation() - IERC4626(box).previewRedeem(shares);

        emit RecognizeLoss(loss, msg.sender);
    }



    /// @dev Returns adapter's ids.
    function ids() public view returns (bytes32[] memory) {
        bytes32[] memory ids_ = new bytes32[](1);
        ids_[0] = adapterId;
        return ids_;
    }

    function allocation() public view returns (uint256) {
        return IVaultV2(parentVault).allocation(adapterId);
    }

    function data() external view returns (bytes memory) {
        return abi.encode("this", address(this));
    }

}
