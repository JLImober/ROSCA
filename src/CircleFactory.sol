// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Circle} from "./Circle.sol";
import {PositionNFT} from "./PositionNFT.sol";
import {ReputationRegistry} from "./ReputationRegistry.sol";

/// @title CircleFactory
/// @author Jose L Imoberdorf
/// @notice Deploys circles and keeps the registry that PositionNFT and ReputationRegistry use to authenticate
///         them. The owner curates which stablecoins and ERC-4626 vaults can be used and sets the fee for
///         future circles (existing circles keep the fee they were created with).
/// @dev Reused from the author's repos:
///      - Presale: allow-list of accepted payment tokens (USDT/USDC) -> `allowedToken`, now configurable.
///      - NFTMarketplace: `feeBps` + `MAX_FEE_BPS` cap + `FeeUpdated` event.
///      - Fixed: `Ownable2Step` instead of a fixed admin (Cryptobank) or plain `Ownable`, so ownership cannot be
///        lost to a mistyped address; zero-address checks on every setter.
contract CircleFactory is Ownable2Step {
    uint16 public constant MAX_FEE_BPS = 200; // 2 %

    PositionNFT public immutable positionNFT;
    ReputationRegistry public immutable reputation;

    address public feeRecipient;
    uint16 public feeBps;

    mapping(address => bool) public isCircle;
    mapping(address => bool) public allowedToken;
    mapping(address => bool) public allowedVault;
    address[] public circles;

    event CircleCreated(address indexed circle, address indexed creator, address indexed token);
    event TokenAllowed(address indexed token, bool allowed);
    event VaultAllowed(address indexed vault, bool allowed);
    event FeeUpdated(uint16 previousFeeBps, uint16 newFeeBps);
    event FeeRecipientUpdated(address previousRecipient, address newRecipient);

    error ZeroAddress();
    error FeeTooHigh();
    error WrongFactory();
    error TokenNotAllowed();
    error VaultNotAllowed();

    /// @param positionNFT_ PositionNFT deployed with this factory's (pre-computed) address.
    /// @param reputation_ ReputationRegistry deployed with this factory's (pre-computed) address.
    constructor(
        address owner_,
        address feeRecipient_,
        uint16 feeBps_,
        PositionNFT positionNFT_,
        ReputationRegistry reputation_
    ) Ownable(owner_) {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (address(positionNFT_.factory()) != address(this)) revert WrongFactory();
        if (address(reputation_.factory()) != address(this)) revert WrongFactory();

        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        positionNFT = positionNFT_;
        reputation = reputation_;
    }

    /// @notice Creates a new circle. Anyone can create one with an allow-listed token (and vault, if any).
    function createCircle(Circle.Config calldata cfg) external returns (address circle) {
        if (!allowedToken[address(cfg.token)]) revert TokenNotAllowed();
        if (address(cfg.yieldVault) != address(0) && !allowedVault[address(cfg.yieldVault)]) {
            revert VaultNotAllowed();
        }

        circle = address(new Circle(cfg, positionNFT, reputation, feeBps));
        isCircle[circle] = true;
        circles.push(circle);

        emit CircleCreated(circle, msg.sender, address(cfg.token));
    }

    function circlesCount() external view returns (uint256) {
        return circles.length;
    }

    // ------------------------------------------------------------------ admin

    /// @notice Only plain stablecoins should be allowed: fee-on-transfer and rebasing tokens are not supported.
    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedToken[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    /// @notice Only audited ERC-4626 vaults with instant liquidity should be allowed.
    function setVaultAllowed(address vault, bool allowed) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        allowedVault[vault] = allowed;
        emit VaultAllowed(vault, allowed);
    }

    /// @notice Fee for circles created from now on. Examples: 50 = 0.5 %, 100 = 1 %, 200 = 2 % (max).
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
}
