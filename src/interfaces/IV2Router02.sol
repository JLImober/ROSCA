// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IV2Router02
/// @notice Subset of the Uniswap V2 router. Taken from Swapping-App / SwapLiquiPools and extended with
///         `swapTokensForExactTokens` and `getAmountsIn`, which let the caller receive an exact contribution.
interface IV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
}
