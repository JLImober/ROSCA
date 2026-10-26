// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BaseTest} from "./BaseTest.sol";
import {Circle} from "../src/Circle.sol";
import {SwapContributor} from "../src/SwapContributor.sol";
import {ICircleFactory} from "../src/interfaces/ICircleFactory.sol";
import {IV2Router02} from "../src/interfaces/IV2Router02.sol";
import {MockERC20, MockV2Router} from "./mocks/Mocks.sol";

contract SwapContributorTest is BaseTest {
    MockERC20 internal dai;
    MockV2Router internal router;
    SwapContributor internal contributor;
    Circle internal circle;
    address internal member;

    function setUp() public override {
        super.setUp();
        dai = new MockERC20("Dai", "DAI", 18);
        // 1 USDC (6 dec) costs 1.01 DAI (18 dec)
        router = new MockV2Router(1e12 * 101, 100);
        contributor = new SwapContributor(IV2Router02(address(router)), ICircleFactory(address(factory)));
        circle = _createCircle(IERC4626(address(0)), 10_000);
        _joinAll(circle);

        member = members[0];
        dai.mint(member, 1_000e18);
        vm.prank(member);
        dai.approve(address(contributor), type(uint256).max);
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function test_ContributeWithSwap_RefundsLeftover() public {
        vm.prank(member);
        uint256 spent = contributor.contributeWithSwap(
            circle, member, 200e18, _path(address(dai), address(usdc)), block.timestamp
        );

        assertEq(spent, 101e18);
        assertTrue(circle.hasPaid(0, member));
        assertEq(dai.balanceOf(member), 1_000e18 - 101e18, "leftover must be refunded");
        assertEq(dai.balanceOf(address(contributor)), 0);
        assertEq(usdc.balanceOf(address(contributor)), 0);
        assertEq(dai.allowance(address(contributor), address(router)), 0, "router allowance must be reset");
    }

    function test_RevertWhen_PathDoesNotEndInCircleToken() public {
        vm.prank(member);
        vm.expectRevert(SwapContributor.InvalidPath.selector);
        contributor.contributeWithSwap(circle, member, 200e18, _path(address(usdc), address(dai)), block.timestamp);
    }

    function test_RevertWhen_UnknownCircle() public {
        vm.prank(member);
        vm.expectRevert(SwapContributor.UnknownCircle.selector);
        contributor.contributeWithSwap(
            Circle(address(0xBEEF)), member, 200e18, _path(address(dai), address(usdc)), block.timestamp
        );
    }

    function test_RevertWhen_SlippageTooHigh() public {
        vm.prank(member);
        vm.expectRevert("EXCESSIVE_INPUT_AMOUNT");
        contributor.contributeWithSwap(circle, member, 100e18, _path(address(dai), address(usdc)), block.timestamp);
    }
}
