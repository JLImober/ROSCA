// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Circle} from "../src/Circle.sol";
import {CircleFactory} from "../src/CircleFactory.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {MockERC20, MockVault} from "./mocks/Mocks.sol";

abstract contract BaseTest is Test {
    uint256 internal constant C = 100e6; // 100 USDC per round
    uint32 internal constant N = 4;
    uint64 internal constant ROUND = 30 days;
    uint16 internal constant FEE_BPS = 100; // 1 %
    uint256 internal constant INITIAL_BALANCE = 10_000e6;

    MockERC20 internal usdc;
    MockVault internal vault;
    PositionNFT internal nft;
    ReputationRegistry internal reputation;
    CircleFactory internal factory;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address[] internal members;

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockVault(IERC20(address(usdc)));

        // PositionNFT and ReputationRegistry need the factory address, and the factory checks both: pre-compute it.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        nft = new PositionNFT(predicted);
        reputation = new ReputationRegistry(predicted);
        factory = new CircleFactory(owner, treasury, FEE_BPS, nft, reputation);
        assertEq(address(factory), predicted);

        vm.startPrank(owner);
        factory.setTokenAllowed(address(usdc), true);
        factory.setVaultAllowed(address(vault), true);
        vm.stopPrank();

        for (uint256 i = 0; i < N; ++i) {
            address m = makeAddr(string.concat("member", vm.toString(i)));
            members.push(m);
            usdc.mint(m, INITIAL_BALANCE);
        }
    }

    function _config(IERC4626 yieldVault, uint16 collateralBps) internal view returns (Circle.Config memory) {
        return Circle.Config({
            token: IERC20(address(usdc)),
            contributionAmount: C,
            maxMembers: N,
            roundDuration: ROUND,
            joinDeadline: uint64(block.timestamp + 7 days),
            collateralBps: collateralBps,
            yieldVault: yieldVault
        });
    }

    function _createCircle(IERC4626 yieldVault, uint16 collateralBps) internal returns (Circle circle) {
        circle = Circle(factory.createCircle(_config(yieldVault, collateralBps)));
        for (uint256 i = 0; i < N; ++i) {
            vm.prank(members[i]);
            usdc.approve(address(circle), type(uint256).max);
        }
    }

    function _joinAll(Circle circle) internal {
        for (uint32 i = 0; i < N; ++i) {
            vm.prank(members[i]);
            circle.join(i);
        }
    }

    function _payAll(Circle circle) internal {
        for (uint256 i = 0; i < N; ++i) {
            vm.prank(members[i]);
            circle.contribute();
        }
    }

    function _net(uint256 pot) internal pure returns (uint256) {
        return pot - (pot * FEE_BPS) / 10_000;
    }

    /// @dev The circle must always hold at least what it owes.
    function _assertSolvent(Circle circle) internal view {
        uint256 liabilities = circle.accruedFees();
        for (uint32 r = 0; r < circle.currentRound(); ++r) {
            liabilities += circle.payoutOf(r);
        }
        for (uint256 i = 0; i < N; ++i) {
            liabilities += circle.claimable(members[i]);
        }
        liabilities += uint256(circle.paidCount()) * C;
        if (address(circle.yieldVault()) == address(0)) liabilities += circle.totalCollateral();
        assertGe(usdc.balanceOf(address(circle)), liabilities, "circle insolvent");
    }
}
