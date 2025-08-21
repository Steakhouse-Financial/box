// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association, Steakhouse Financial
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import {IERC4626} from "../lib/vault-v2/src/interfaces/IERC4626.sol";
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";
import {ERC4626Mock} from "../lib/vault-v2/test//mocks/ERC4626Mock.sol";
import {VaultV2Mock} from "../lib/vault-v2/test//mocks/VaultV2Mock.sol";
import {WAD} from "../lib/vault-v2/src/VaultV2.sol";
import {IERC20} from "../lib/vault-v2/src/interfaces/IERC20.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {MathLib} from "../lib/vault-v2/src/libraries/MathLib.sol";

import {Box} from "../src/Box.sol";
import {IBoxAdapter} from "../src/interfaces/IBoxAdapter.sol";
import {BoxAdapter} from "../src/BoxAdapter.sol";
import {IBoxAdapterFactory} from "../src/interfaces/IBoxAdapterFactory.sol";
import {BoxAdapterFactory} from "../src/BoxAdapterFactory.sol";
import {BoxLib} from "../src/lib/BoxLib.sol";

contract BoxAdapterTest is Test {
    using MathLib for uint256;
    using BoxLib for Box;

    IERC20 internal asset;
    IERC20 internal rewardToken;
    VaultV2Mock internal parentVault;
    Box internal box;
    IBoxAdapterFactory internal factory;
    IBoxAdapter internal adapter;
    address internal owner;
    address internal recipient;
    bytes32[] internal expectedIds;

    uint256 internal constant MAX_TEST_ASSETS = 1e36;
    uint256 internal constant EXCHANGE_RATE = 42;

    function setUp() public {
        owner = makeAddr("owner");
        recipient = makeAddr("recipient");

        asset = IERC20(address(new ERC20Mock(18)));
        rewardToken = IERC20(address(new ERC20Mock(18)));
        box = new Box(address(asset), owner, owner, "Box", "BOX", 0, 1, 1);

        parentVault = new VaultV2Mock(address(asset), owner, address(0), address(0), address(0));

        factory = new BoxAdapterFactory();
        adapter = IBoxAdapter(factory.createBoxAdapter(address(parentVault), box));

        vm.prank(owner);
        box.addFeeder(address(adapter));

        deal(address(asset), address(this), type(uint256).max);
        asset.approve(address(box), type(uint256).max);

        deal(address(asset), address(box), 1);

        // Increase the exchange rate to make so 1 asset is worth EXCHANGE_RATE shares.
        deal(address(box), address(0), EXCHANGE_RATE, true);
        assertEq(box.convertToShares(1), EXCHANGE_RATE, "exchange rate not set correctly");

        expectedIds = new bytes32[](1);
        expectedIds[0] = keccak256(abi.encode("this", address(adapter)));
    }

    function testFactoryAndParentVaultAndAssetSet() public view {
        assertEq(adapter.factory(), address(factory), "Incorrect factory set");
        assertEq(adapter.parentVault(), address(parentVault), "Incorrect parent vault set");
        assertEq(address(adapter.box()), address(box), "Incorrect box vault set");
    }

    function testAllocateNotAuthorizedReverts(uint256 assets) public {
        assets = bound(assets, 0, MAX_TEST_ASSETS);
        vm.expectRevert(IBoxAdapter.NotAuthorized.selector);
        adapter.allocate(hex"", assets, bytes4(0), address(0));
    }

    function testDeallocateNotAuthorizedReverts(uint256 assets) public {
        assets = bound(assets, 0, MAX_TEST_ASSETS);
        vm.expectRevert(IBoxAdapter.NotAuthorized.selector);
        adapter.deallocate(hex"", assets, bytes4(0), address(0));
    }

    function testAllocate(uint256 assets) public {
        assets = bound(assets, 0, MAX_TEST_ASSETS);
        deal(address(asset), address(adapter), assets);

        (bytes32[] memory ids, int256 change) = parentVault.allocateMocked(address(adapter), hex"", assets);

        uint256 adapterShares = box.balanceOf(address(adapter));
        assertEq(adapterShares, assets * EXCHANGE_RATE, "Incorrect share balance after deposit");
        assertEq(asset.balanceOf(address(adapter)), 0, "Underlying tokens not transferred to vault");
        assertEq(ids, expectedIds, "Incorrect ids returned");
        assertEq(change, int256(assets), "Incorrect change returned");
    }

    function testDeallocate(uint256 initialAssets, uint256 withdrawAssets) public {
        initialAssets = bound(initialAssets, 0, MAX_TEST_ASSETS);
        withdrawAssets = bound(withdrawAssets, 0, initialAssets);

        deal(address(asset), address(adapter), initialAssets);
        parentVault.allocateMocked(address(adapter), hex"", initialAssets);

        uint256 beforeShares = box.balanceOf(address(adapter));
        assertEq(beforeShares, initialAssets * EXCHANGE_RATE, "Precondition failed: shares not set");

        (bytes32[] memory ids, int256 change) = parentVault.deallocateMocked(address(adapter), hex"", withdrawAssets);

        assertEq(adapter.allocation(), initialAssets - withdrawAssets, "incorrect allocation");
        uint256 afterShares = box.balanceOf(address(adapter));
        assertEq(afterShares, (initialAssets - withdrawAssets) * EXCHANGE_RATE, "Share balance not decreased correctly");

        uint256 adapterBalance = asset.balanceOf(address(adapter));
        assertEq(adapterBalance, withdrawAssets, "Adapter did not receive withdrawn tokens");
        assertEq(ids, expectedIds, "Incorrect ids returned");
        assertEq(change, -int256(withdrawAssets), "Incorrect change returned");
    }

    function testFactoryCreateAdapter() public {
        VaultV2Mock newParentVault = new VaultV2Mock(address(asset), owner, address(0), address(0), address(0));
        Box newBox = new Box(address(asset), owner, owner, "Box2", "BOX2", 0, 1, 1);

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(BoxAdapter).creationCode, abi.encode(address(newParentVault), address(newBox))
            )
        );
        address expectedNewAdapter =
            address(uint160(uint256(keccak256(abi.encodePacked(uint8(0xff), factory, bytes32(0), initCodeHash)))));
        vm.expectEmit();
        emit IBoxAdapterFactory.CreateBoxAdapter(
            address(newParentVault), address(newBox), IBoxAdapter(expectedNewAdapter)
        );

        address newAdapter = address(factory.createBoxAdapter(address(newParentVault), newBox));

        expectedIds[0] = keccak256(abi.encode("this", address(newAdapter)));

        assertTrue(newAdapter != address(0), "Adapter not created");
        assertEq(IBoxAdapter(newAdapter).factory(), address(factory), "Incorrect factory");
        assertEq(IBoxAdapter(newAdapter).parentVault(), address(newParentVault), "Incorrect parent vault");
        assertEq(address(IBoxAdapter(newAdapter).box()), address(newBox), "Incorrect Box");
        assertEq(IBoxAdapter(newAdapter).adapterId(), expectedIds[0], "Incorrect adapterId");
        assertEq(
            address(factory.boxAdapter(address(newParentVault), newBox)),
            newAdapter,
            "Adapter not tracked correctly"
        );
        assertTrue(factory.isBoxAdapter(address(newAdapter)), "Adapter not tracked correctly");
    }

    function testSetSkimRecipient(address newRecipient, address caller) public {
        vm.assume(newRecipient != address(0));
        vm.assume(caller != address(0));
        vm.assume(caller != owner);

        // Access control
        vm.prank(caller);
        vm.expectRevert(IBoxAdapter.NotAuthorized.selector);
        adapter.setSkimRecipient(newRecipient);

        // Normal path
        vm.prank(owner);
        vm.expectEmit();
        emit IBoxAdapter.SetSkimRecipient(newRecipient);
        adapter.setSkimRecipient(newRecipient);
        assertEq(adapter.skimRecipient(), newRecipient, "Skim recipient not set correctly");
    }

    function testSkim(uint256 assets) public {
        assets = bound(assets, 0, MAX_TEST_ASSETS);

        ERC20Mock token = new ERC20Mock(18);

        // Setup
        vm.prank(owner);
        adapter.setSkimRecipient(recipient);
        deal(address(token), address(adapter), assets);
        assertEq(token.balanceOf(address(adapter)), assets, "Adapter did not receive tokens");

        // Normal path
        vm.expectEmit();
        emit IBoxAdapter.Skim(address(token), assets);
        vm.prank(recipient);
        adapter.skim(address(token));
        assertEq(token.balanceOf(address(adapter)), 0, "Tokens not skimmed from adapter");
        assertEq(token.balanceOf(recipient), assets, "Recipient did not receive tokens");

        // Access control
        vm.expectRevert(IBoxAdapter.NotAuthorized.selector);
        adapter.skim(address(token));

        // Can't skim morphoVaultV1
        vm.prank(recipient);
        vm.expectRevert(IBoxAdapter.CannotSkimBoxShares.selector);
        adapter.skim(address(box));
    }

    function testIds() public view {
        assertEq(adapter.ids(), expectedIds);
    }

    function testInvalidData(bytes memory data) public {
        vm.assume(data.length > 0);

        vm.expectRevert(IBoxAdapter.InvalidData.selector);
        adapter.allocate(data, 0, bytes4(0), address(0));

        vm.expectRevert(IBoxAdapter.InvalidData.selector);
        adapter.deallocate(data, 0, bytes4(0), address(0));
    }

    function testDifferentAssetReverts(address randomAsset) public {
        vm.assume(randomAsset != parentVault.asset());
        vm.assume(randomAsset != address(0));

        Box newBox = new Box(randomAsset, owner, owner, "Box2", "BOX2", 0, 1, 1);
        vm.expectRevert(IBoxAdapter.AssetMismatch.selector);
        new BoxAdapter(address(parentVault), newBox);
    }

    function testDonationResistance(uint256 deposit, uint256 donation) public {
        deposit = bound(deposit, 0, MAX_TEST_ASSETS);
        donation = bound(donation, 1, MAX_TEST_ASSETS);

        Box otherBox = new Box(address(asset), owner, owner, "Box Mock Extended", "BOX_MOCK_EXTENDED", 0, 1, 1);

        // Deposit some assets
        deal(address(asset), address(adapter), deposit * 2);
        parentVault.allocateMocked(address(adapter), hex"", deposit);

        uint256 realAssetsBefore = adapter.realAssets();

        // Donate to adapter
        address donor = makeAddr("donor");

        vm.startPrank(owner);
        otherBox.addFeeder(donor);
        otherBox.addFeeder(address(adapter));
        vm.stopPrank();

        assertTrue(otherBox.isFeeder(donor), "Donor is not a feeder");

        deal(address(asset), donor, donation);
        vm.startPrank(donor);
        asset.approve(address(otherBox), type(uint256).max);
        otherBox.deposit(donation, address(adapter));
        vm.stopPrank();

        uint256 realAssetsAfter = adapter.realAssets();

        assertEq(realAssetsAfter, realAssetsBefore, "realAssets should not change");
    }

    function testLoss(uint256 deposit, uint256 loss) public {
        deposit = bound(deposit, 1, MAX_TEST_ASSETS);
        loss = bound(loss, 1, deposit);

        deal(address(asset), address(adapter), deposit);
        parentVault.allocateMocked(address(adapter), hex"", deposit);
        
        vm.startPrank(address(box));
        asset.transfer(address(0xdead), loss);
        vm.stopPrank();

        assertEq(adapter.realAssets(), deposit - loss, "realAssets");
    }

    function testInterest(uint256 deposit, uint256 interest) public {
        deposit = bound(deposit, 1, MAX_TEST_ASSETS);
        interest = bound(interest, 1, deposit);

        deal(address(asset), address(adapter), deposit);
        parentVault.allocateMocked(address(adapter), hex"", deposit);
        asset.transfer(address(box), interest);

        // approx because of the virtual shares.
        assertApproxEqAbs(adapter.realAssets() - deposit, interest, interest.mulDivUp(1, deposit + 1), "realAssets");
    }
}


function zeroFloorSub(uint256 a, uint256 b) pure returns (uint256) {
    if (a < b) return 0;
    return a - b;
}
