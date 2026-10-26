// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICircleFactory} from "./interfaces/ICircleFactory.sol";
import {ICircle} from "./interfaces/ICircle.sol";
import {PositionNFT} from "./PositionNFT.sol";

/// @title PositionMarket
/// @author Jose L Imoberdorf
/// @notice Secondary market for circle positions: someone who needs the money earlier buys an early turn from
///         someone who can wait, paying a premium in stablecoins.
/// @dev Based on NFTMarketplace (NFTMarketPlace repo). Kept: list / buy / cancel flow, `nonReentrant`, fee in bps
///      with `MAX_FEE_BPS`, `FeeUpdated` event, custom errors, delete-before-transfer. Fixed:
///      - Payments in allow-listed ERC-20 (SafeERC20) instead of native ETH pushed with `call`.
///      - Fees are accrued and pulled by the recipient, so a reverting fee receiver cannot block every sale.
///      - Stale listings: `buy` checks the seller still owns the token (the original only reverted indirectly).
///      - Front-running: the buyer passes `maxPrice` and `paymentToken`, so a seller cannot raise the price or
///        change the token while the buy transaction is pending.
///      - Listing requires the market to be approved, and only positions of Active/Completed circles that were
///        not claimed yet can be traded.
///      - `Ownable2Step` for the admin instead of an immutable deployer.
contract PositionMarket is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 500; // 5 %

    ICircleFactory public immutable factory;
    PositionNFT public immutable positionNFT;

    address public feeRecipient;
    uint16 public feeBps;

    struct Listing {
        address seller;
        IERC20 paymentToken;
        uint256 price;
    }

    mapping(uint256 tokenId => Listing) public listings;
    mapping(address token => uint256) public accruedFees;

    event PositionListed(uint256 indexed tokenId, address indexed seller, address paymentToken, uint256 price);
    event ListingCancelled(uint256 indexed tokenId, address indexed seller);
    event PositionSold(
        uint256 indexed tokenId, address indexed seller, address indexed buyer, address paymentToken, uint256 price
    );
    event FeeUpdated(uint16 previousFeeBps, uint16 newFeeBps);
    event FeeRecipientUpdated(address previousRecipient, address newRecipient);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error FeeTooHigh();
    error ZeroPrice();
    error NotTokenOwner();
    error MarketNotApproved();
    error TokenNotAllowed();
    error PositionNotLive();
    error ListingNotFound();
    error NotListingOwner();
    error StaleListing();
    error PriceAboveMax();
    error PaymentTokenMismatch();
    error NothingToWithdraw();

    constructor(address owner_, address feeRecipient_, uint16 feeBps_, ICircleFactory factory_, PositionNFT nft_)
        Ownable(owner_)
    {
        if (feeRecipient_ == address(0) || address(factory_) == address(0) || address(nft_) == address(0)) {
            revert ZeroAddress();
        }
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        factory = factory_;
        positionNFT = nft_;
    }

    /// @notice Lists a position. The market must be approved for the token (approve or setApprovalForAll).
    function list(uint256 tokenId, IERC20 paymentToken, uint256 price) external {
        if (price == 0) revert ZeroPrice();
        if (positionNFT.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (
            positionNFT.getApproved(tokenId) != address(this)
                && !positionNFT.isApprovedForAll(msg.sender, address(this))
        ) revert MarketNotApproved();
        if (!factory.allowedToken(address(paymentToken))) revert TokenNotAllowed();
        if (!_isLive(tokenId)) revert PositionNotLive();

        listings[tokenId] = Listing({seller: msg.sender, paymentToken: paymentToken, price: price});
        emit PositionListed(tokenId, msg.sender, address(paymentToken), price);
    }

    /// @notice Cancels a listing. The seller can always cancel; anyone can clear a listing whose seller no
    ///         longer owns the token.
    function cancel(uint256 tokenId) external {
        Listing memory l = listings[tokenId];
        if (l.seller == address(0)) revert ListingNotFound();
        if (msg.sender != l.seller && _ownerOrZero(tokenId) == l.seller) revert NotListingOwner();
        delete listings[tokenId];
        emit ListingCancelled(tokenId, l.seller);
    }

    /// @notice Buys a listed position.
    /// @param paymentToken Token the buyer expects to pay with (protects against listing changes).
    /// @param maxPrice Highest price the buyer accepts (protects against the seller front-running a price raise).
    function buy(uint256 tokenId, IERC20 paymentToken, uint256 maxPrice) external nonReentrant {
        Listing memory l = listings[tokenId];
        if (l.seller == address(0)) revert ListingNotFound();
        if (address(l.paymentToken) != address(paymentToken)) revert PaymentTokenMismatch();
        if (l.price > maxPrice) revert PriceAboveMax();
        if (!_isLive(tokenId)) revert PositionNotLive();
        if (positionNFT.ownerOf(tokenId) != l.seller) revert StaleListing();

        uint256 fee = (l.price * feeBps) / BPS;

        // Effects
        delete listings[tokenId];
        accruedFees[address(paymentToken)] += fee;

        // Interactions
        paymentToken.safeTransferFrom(msg.sender, l.seller, l.price - fee);
        if (fee > 0) paymentToken.safeTransferFrom(msg.sender, address(this), fee);
        positionNFT.safeTransferFrom(l.seller, msg.sender, tokenId);

        emit PositionSold(tokenId, l.seller, msg.sender, address(paymentToken), l.price);
    }

    /// @notice Sends accrued fees in `token` to the fee recipient. Anyone can call it.
    function withdrawFees(address token) external nonReentrant {
        uint256 amount = accruedFees[token];
        if (amount == 0) revert NothingToWithdraw();
        accruedFees[token] = 0;
        IERC20(token).safeTransfer(feeRecipient, amount);
        emit FeesWithdrawn(token, feeRecipient, amount);
    }

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function calculateFee(uint256 amount) external view returns (uint256) {
        return (amount * feeBps) / BPS;
    }

    function _isLive(uint256 tokenId) private view returns (bool) {
        (address circle, uint32 slot) = positionNFT.positions(tokenId);
        return circle != address(0) && ICircle(circle).isPositionLive(slot);
    }

    function _ownerOrZero(uint256 tokenId) private view returns (address) {
        try positionNFT.ownerOf(tokenId) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }
}
