// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IV2Router02} from "./interfaces/IV2Router02.sol";
import {ICircleFactory} from "./interfaces/ICircleFactory.sol";
import {Circle} from "./Circle.sol";

/// @title SwapContributor
/// @author Jose L Imoberdorf
/// @notice Lets a member pay a round with any token that has a Uniswap V2 route to the circle's stablecoin.
/// @dev Based on SwapApp (Swapping-App / SwapLiquiPools). Kept: SafeERC20 pull, router call, event. Fixed:
///      - `swapTokensForExactTokens` gets exactly the contribution, and the unused input is refunded (the
///        original left leftovers stuck in the contract).
///      - `forceApprove` instead of `approve` (works with USDT) and the router allowance is reset to 0.
///      - The path is validated (must end in the circle token) and only factory circles are accepted.
///      - The contract never holds user funds between transactions; `removeLiquidity`, which let anyone steal LP
///        tokens sent to the contract, was not carried over.
contract SwapContributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IV2Router02 public immutable router;
    ICircleFactory public immutable factory;

    event ContributedWithSwap(
        address indexed circle, address indexed member, address indexed payer, address tokenIn, uint256 amountIn
    );

    error ZeroAddress();
    error UnknownCircle();
    error InvalidPath();

    constructor(IV2Router02 router_, ICircleFactory factory_) {
        if (address(router_) == address(0) || address(factory_) == address(0)) revert ZeroAddress();
        router = router_;
        factory = factory_;
    }

    /// @notice Swaps at most `amountInMax` of `path[0]` into the exact contribution and pays it for `member`.
    /// @return amountIn Amount of `path[0]` actually spent; the rest is refunded to the caller.
    function contributeWithSwap(
        Circle circle,
        address member,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountIn) {
        if (!factory.isCircle(address(circle))) revert UnknownCircle();
        IERC20 tokenOut = circle.token();
        if (path.length < 2 || path[path.length - 1] != address(tokenOut) || path[0] == address(tokenOut)) {
            revert InvalidPath();
        }

        IERC20 tokenIn = IERC20(path[0]);
        uint256 needed = circle.contributionAmount();

        tokenIn.safeTransferFrom(msg.sender, address(this), amountInMax);
        tokenIn.forceApprove(address(router), amountInMax);
        uint256[] memory amounts = router.swapTokensForExactTokens(needed, amountInMax, path, address(this), deadline);
        tokenIn.forceApprove(address(router), 0);
        amountIn = amounts[0];

        tokenOut.forceApprove(address(circle), needed);
        circle.contributeFor(member);

        if (amountInMax > amountIn) tokenIn.safeTransfer(msg.sender, amountInMax - amountIn);

        emit ContributedWithSwap(address(circle), member, msg.sender, address(tokenIn), amountIn);
    }
}
