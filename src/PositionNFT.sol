// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ICircleFactory} from "./interfaces/ICircleFactory.sol";
import {ICircle} from "./interfaces/ICircle.sol";

/// @title PositionNFT
/// @author Jose L Imoberdorf
/// @notice One ERC-721 token per circle slot. Holding the token is the right to claim that slot's pot, so turns
///         can be transferred or sold on the PositionMarket while the payment obligation stays with the member.
/// @dev Based on CarsNFTCollection (NFT-Collection repo):
///      - Kept: ERC721 inheritance, `Strings` usage and the `_requireOwned` check in `tokenURI`.
///      - Fixed: public, unlimited `mint()` is now restricted to circles registered in the factory.
///      - Changed: `_safeMint` -> `_mint`, so a joining contract cannot re-enter `Circle.join` through
///        `onERC721Received`; metadata is built fully on-chain from the circle state instead of a base URI.
contract PositionNFT is ERC721 {
    using Strings for uint256;

    struct Position {
        address circle;
        uint32 slot;
    }

    /// @notice Factory that registers the circles allowed to mint and burn.
    ICircleFactory public immutable factory;
    /// @notice Last token id minted. Ids start at 1 so that 0 means "no position".
    uint256 public lastTokenId;
    /// @notice Circle and slot backing each token id. Kept after burn for history.
    mapping(uint256 => Position) public positions;

    event PositionMinted(address indexed circle, uint32 indexed slot, uint256 indexed tokenId, address to);
    event PositionBurned(address indexed circle, uint32 indexed slot, uint256 indexed tokenId);

    error ZeroAddress();
    error NotCircle();
    error NotPositionCircle();

    modifier onlyCircle() {
        if (!factory.isCircle(msg.sender)) revert NotCircle();
        _;
    }

    /// @param factory_ Address of the CircleFactory (it can be pre-computed before the factory is deployed).
    constructor(address factory_) ERC721("ROSCA Position", "ROSCA-POS") {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = ICircleFactory(factory_);
    }

    /// @notice Mints the position for `slot` of the calling circle.
    function mint(address to, uint32 slot) external onlyCircle returns (uint256 tokenId) {
        tokenId = ++lastTokenId;
        positions[tokenId] = Position({circle: msg.sender, slot: slot});
        _mint(to, tokenId);
        emit PositionMinted(msg.sender, slot, tokenId, to);
    }

    /// @notice Burns a position. Only the circle that minted it can burn it (on payout claim or cancellation).
    function burn(uint256 tokenId) external {
        Position memory p = positions[tokenId];
        if (p.circle != msg.sender) revert NotPositionCircle();
        _burn(tokenId);
        emit PositionBurned(p.circle, p.slot, tokenId);
    }

    /// @notice Fully on-chain JSON metadata describing the position.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Position memory p = positions[tokenId];
        ICircle.PositionInfo memory info = ICircle(p.circle).positionInfo(p.slot);

        string memory json = string.concat(
            '{"name":"ROSCA Position #',
            tokenId.toString(),
            '","description":"Right to claim one round of an on-chain rotating savings circle.","attributes":[',
            '{"trait_type":"circle","value":"',
            Strings.toHexString(p.circle),
            '"},{"trait_type":"slot","value":',
            uint256(p.slot).toString(),
            '},{"trait_type":"gross_pot","value":',
            info.grossPot.toString(),
            '},{"trait_type":"encumbrance","value":',
            info.encumbrance.toString(),
            '},{"trait_type":"payout_time","value":',
            info.estimatedPayoutTime.toString(),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
