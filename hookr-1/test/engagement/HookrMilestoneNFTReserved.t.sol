// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {HookrMilestoneNFT} from "../../src/engagement/HookrMilestoneNFT.sol";
import {HookrMilestoneNFTFactory} from "../../src/engagement/HookrMilestoneNFTFactory.sol";
import {IHookrMilestoneNFTFactory} from "../../src/interfaces/IHookrMilestoneNFTFactory.sol";
import {IHookrMilestoneNFT} from "../../src/interfaces/IHookrMilestoneNFT.sol";

/// @dev A contract receiver that answers `answer`, or reverts with `reason` when it is set, and records the operator.
contract MilestoneReceiver is IERC721Receiver {
    bytes4 public answer = IERC721Receiver.onERC721Received.selector;
    bytes public reason;
    address public operator;
    address public from;

    function set(bytes4 answer_, bytes calldata reason_) external {
        answer = answer_;
        reason = reason_;
    }

    function onERC721Received(address operator_, address from_, uint256, bytes calldata) external returns (bytes4) {
        bytes memory r = reason;
        if (r.length != 0) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
        operator = operator_;
        from = from_;
        return answer;
    }
}

/// @dev A contract with no ERC-721 receiver.
contract MilestoneNoReceiver {}

/// @notice HookrMilestoneNFT.mintReserved: only the collection's immutable controller (the HookrPrograms that created
///         it through its own factory) mints, only IDs from 1 to maxSupply, each once, by safe mint (a contract
///         recipient must accept it); and a non-transferable collection's tokens never move after the mint.
contract HookrMilestoneNFTReservedTest is Test {
    uint256 internal constant MAX = 3;
    address internal holder = makeAddr("holder");
    HookrMilestoneNFTFactory internal factory;
    IHookrMilestoneNFT internal nft;

    function setUp() public {
        // This test stands in for HookrPrograms: it deploys the factory, so it is the factory's deployer and every
        // collection's controller.
        factory = new HookrMilestoneNFTFactory();
        nft = factory.create(MAX, "Milestones", "MS", "ipfs://base/", false);
    }

    function test_theFactoryDeployerIsTheController() public {
        assertEq(factory.deployer(), address(this));
        assertEq(nft.controller(), address(this));
        assertEq(nft.maxSupply(), MAX);
        assertFalse(nft.transferable());
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IHookrMilestoneNFTFactory.OnlyDeployer.selector);
        factory.create(MAX, "Other", "OT", "", true);
    }

    function test_mintReserved_mintsEveryIdFromOneToMaxSupply() public {
        for (uint256 id = 1; id <= MAX; ++id) {
            vm.expectEmit(address(nft));
            emit IERC721.Transfer(address(0), holder, id);
            nft.mintReserved(holder, id);
            assertEq(nft.ownerOf(id), holder);
        }
        assertEq(nft.balanceOf(holder), MAX);
        assertEq(nft.tokenURI(MAX), "ipfs://base/3");
    }

    function test_mintReserved_refusesIdZeroAndIdsAboveMaxSupply() public {
        uint256[3] memory bad = [uint256(0), MAX + 1, type(uint256).max];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IHookrMilestoneNFT.InvalidTokenId.selector);
            nft.mintReserved(holder, bad[i]);
        }
        assertEq(nft.balanceOf(holder), 0);
    }

    /// Only the controller: strangers, the recipient, the factory and the collection itself are refused.
    function test_mintReserved_isTheControllersAlone() public {
        address[4] memory callers = [makeAddr("stranger"), holder, address(factory), address(nft)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IHookrMilestoneNFT.OnlyController.selector);
            nft.mintReserved(holder, 1);
        }
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        nft.ownerOf(1);
    }

    /// A minted ID never mints again. In a non-transferable collection the mint's own move is refused first
    /// (TransfersDisabled, from the collection's transfer check); in a transferable one the ERC-721 mint refuses it.
    function test_mintReserved_eachIdMintsOnce() public {
        address other = makeAddr("other");
        nft.mintReserved(holder, 2);
        vm.expectRevert(IHookrMilestoneNFT.TransfersDisabled.selector);
        nft.mintReserved(other, 2);
        vm.expectRevert(IHookrMilestoneNFT.TransfersDisabled.selector);
        nft.mintReserved(holder, 2);
        assertEq(nft.ownerOf(2), holder);
        assertEq(nft.balanceOf(holder), 1);

        IHookrMilestoneNFT open = factory.create(MAX, "Open", "OP", "", true);
        open.mintReserved(holder, 2);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        open.mintReserved(other, 2);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        open.mintReserved(holder, 2);
        assertEq(open.ownerOf(2), holder);
        assertEq(open.balanceOf(holder), 1);
        assertEq(open.balanceOf(other), 0);
    }

    /// A safe mint: the zero address and a contract that does not accept are refused; a receiver's own revert reason
    /// comes back unchanged; an accepting receiver gets the token with the controller as operator.
    function test_mintReserved_checksTheRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        nft.mintReserved(address(0), 1);
        MilestoneNoReceiver none = new MilestoneNoReceiver();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(none)));
        nft.mintReserved(address(none), 1);
        MilestoneReceiver receiver = new MilestoneReceiver();
        receiver.set(0xdeadbeef, "");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        nft.mintReserved(address(receiver), 1);
        receiver.set(IERC721Receiver.onERC721Received.selector, abi.encodeWithSignature("Error(string)", "full"));
        vm.expectRevert(bytes("full"));
        nft.mintReserved(address(receiver), 1);
        receiver.set(IERC721Receiver.onERC721Received.selector, "");
        nft.mintReserved(address(receiver), 1);
        assertEq(nft.ownerOf(1), address(receiver));
        assertEq(receiver.operator(), address(this), "the controller mints");
        assertEq(receiver.from(), address(0));
    }

    /// A non-transferable collection's tokens never move once minted; a transferable one's move as any ERC-721.
    function test_mintedTokensMoveOnlyInATransferableCollection() public {
        nft.mintReserved(holder, 1);
        address to = makeAddr("to");
        vm.startPrank(holder);
        vm.expectRevert(IHookrMilestoneNFT.TransfersDisabled.selector);
        nft.transferFrom(holder, to, 1);
        vm.expectRevert(IHookrMilestoneNFT.TransfersDisabled.selector);
        nft.safeTransferFrom(holder, to, 1);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), holder);

        IHookrMilestoneNFT open = factory.create(MAX, "Open", "OP", "", true);
        open.mintReserved(holder, 1);
        vm.prank(holder);
        open.transferFrom(holder, to, 1);
        assertEq(open.ownerOf(1), to);
        assertEq(open.tokenURI(1), "", "no base, no URI");
    }

    /// The constructor's bounds: a controller, a supply, a name of 1 to 100 bytes, a symbol of 1 to 16 and a base of
    /// at most 512.
    function test_collectionBounds() public {
        string memory name101 = string(new bytes(101));
        string memory symbol17 = string(new bytes(17));
        string memory base513 = string(new bytes(513));
        vm.expectRevert(IHookrMilestoneNFT.InvalidCollection.selector);
        new HookrMilestoneNFT(address(0), MAX, "N", "S", "", false);
        vm.expectRevert(IHookrMilestoneNFT.InvalidCollection.selector);
        new HookrMilestoneNFT(address(this), 0, "N", "S", "", false);
        vm.expectRevert(IHookrMilestoneNFT.InvalidCollection.selector);
        new HookrMilestoneNFT(address(this), MAX, "", "S", "", false);
        vm.expectRevert(IHookrMilestoneNFT.InvalidCollection.selector);
        new HookrMilestoneNFT(address(this), MAX, name101, "S", "", false);
        vm.expectRevert(IHookrMilestoneNFT.InvalidCollection.selector);
        new HookrMilestoneNFT(address(this), MAX, "N", "", "", false);
        vm.expectRevert(IHookrMilestoneNFT.InvalidCollection.selector);
        new HookrMilestoneNFT(address(this), MAX, "N", symbol17, "", false);
        vm.expectRevert(IHookrMilestoneNFT.InvalidCollection.selector);
        new HookrMilestoneNFT(address(this), MAX, "N", "S", base513, false);
        HookrMilestoneNFT edge = new HookrMilestoneNFT(
            address(this), 1, string(new bytes(100)), string(new bytes(16)), string(new bytes(512)), false
        );
        edge.mintReserved(holder, 1);
        vm.expectRevert(IHookrMilestoneNFT.InvalidTokenId.selector);
        edge.mintReserved(holder, 2);
    }
}
