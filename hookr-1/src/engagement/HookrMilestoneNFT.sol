// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrMilestoneNFT} from "../interfaces/IHookrMilestoneNFT.sol";

/// @title HookrMilestoneNFT
/// @notice Campaign-owned, capped milestone collection. No creator mint or metadata mutation.
/// @dev The engagement sidecar reserves IDs before delivery; a rejecting receiver cannot erase that reservation.
contract HookrMilestoneNFT is HookrReleased, ERC721, IHookrMilestoneNFT {
    /// @inheritdoc IHookrMilestoneNFT
    address public immutable controller;
    /// @inheritdoc IHookrMilestoneNFT
    uint256 public immutable maxSupply;
    /// @inheritdoc IHookrMilestoneNFT
    bool public immutable transferable;
    string private _metadataBase;

    constructor(
        address _controller,
        uint256 _maxSupply,
        string memory _name,
        string memory _symbol,
        string memory _metadataBaseURI,
        bool _transferable
    ) ERC721(_name, _symbol) {
        if (
            _controller == address(0) || _maxSupply == 0 || bytes(_name).length == 0 || bytes(_name).length > 100
                || bytes(_symbol).length == 0 || bytes(_symbol).length > 16 || bytes(_metadataBaseURI).length > 512
        ) revert InvalidCollection();
        controller = _controller;
        maxSupply = _maxSupply;
        transferable = _transferable;
        _metadataBase = _metadataBaseURI;
    }

    /// @inheritdoc IHookrMilestoneNFT
    function mintReserved(address to, uint256 tokenId) external {
        if (msg.sender != controller) revert OnlyController();
        if (tokenId == 0 || tokenId > maxSupply) revert InvalidTokenId();
        _safeMint(to, tokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return _metadataBase;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (!transferable && from != address(0) && to != address(0)) revert TransfersDisabled();
    }
}
