// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BaseTest} from "./BaseTest.sol";
import {Circle} from "../src/Circle.sol";
import {PositionMarket} from "../src/PositionMarket.sol";
import {ICircleFactory} from "../src/interfaces/ICircleFactory.sol";

contract PositionMarketTest is BaseTest {
    uint16 internal constant MARKET_FEE = 250; // 2.5 %
    uint256 internal constant PRICE = 350e6;

    PositionMarket internal market;
    Circle internal circle;
    address internal seller;
    address internal buyer = makeAddr("buyer");
    uint256 internal tokenId;
    IERC20 internal pay;

    function setUp() public override {
        super.setUp();
        market = new PositionMarket(owner, treasury, MARKET_FEE, ICircleFactory(address(factory)), nft);
        circle = _createCircle(IERC4626(address(0)), 10_000);
        _joinAll(circle);

        seller = members[3]; // sells the last turn
        tokenId = circle.slotTokenId(3);
        pay = IERC20(address(usdc));

        usdc.mint(buyer, 1_000e6);
        vm.prank(buyer);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);
    }

    function test_ListAndBuy() public {
        vm.prank(seller);
        market.list(tokenId, pay, PRICE);

        uint256 sellerBefore = usdc.balanceOf(seller);
        vm.prank(buyer);
        market.buy(tokenId, pay, PRICE);

        uint256 fee = (PRICE * MARKET_FEE) / 10_000;
        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE - fee);
        assertEq(market.accruedFees(address(usdc)), fee);

        market.withdrawFees(address(usdc));
        assertEq(usdc.balanceOf(treasury), fee);
    }

    function test_RevertWhen_ListingIsStale() public {
        vm.startPrank(seller);
        market.list(tokenId, pay, PRICE);
        nft.transferFrom(seller, makeAddr("someoneElse"), tokenId);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(PositionMarket.StaleListing.selector);
        market.buy(tokenId, pay, PRICE);

        // Anyone can clean a stale listing.
        market.cancel(tokenId);
        (address listedSeller,,) = market.listings(tokenId);
        assertEq(listedSeller, address(0));
    }

    function test_RevertWhen_SellerRaisesPriceBeforeBuy() public {
        vm.prank(seller);
        market.list(tokenId, pay, PRICE);
        vm.prank(seller);
        market.list(tokenId, pay, PRICE * 2); // front-run

        vm.prank(buyer);
        vm.expectRevert(PositionMarket.PriceAboveMax.selector);
        market.buy(tokenId, pay, PRICE);
    }

    function test_RevertWhen_ListWithoutApproval() public {
        vm.prank(seller);
        nft.setApprovalForAll(address(market), false);
        vm.prank(seller);
        vm.expectRevert(PositionMarket.MarketNotApproved.selector);
        market.list(tokenId, pay, PRICE);
    }

    function test_RevertWhen_NotOwnerLists() public {
        vm.prank(buyer);
        vm.expectRevert(PositionMarket.NotTokenOwner.selector);
        market.list(tokenId, pay, PRICE);
    }

    function test_RevertWhen_PositionAlreadyClaimed() public {
        uint256 firstToken = circle.slotTokenId(0);
        vm.prank(members[0]);
        nft.setApprovalForAll(address(market), true);
        vm.prank(members[0]);
        market.list(firstToken, pay, PRICE);

        _payAll(circle);
        circle.closeRound();
        vm.prank(members[0]);
        circle.claimPayout(0); // seller cashes out before the buy lands

        vm.prank(buyer);
        vm.expectRevert(PositionMarket.PositionNotLive.selector);
        market.buy(firstToken, pay, PRICE);
    }

    function test_RevertWhen_PositionOfOpenCircle() public {
        Circle open = _createCircle(IERC4626(address(0)), 10_000);
        vm.prank(members[0]);
        open.join(0);
        uint256 id = open.slotTokenId(0);
        vm.startPrank(members[0]);
        nft.approve(address(market), id);
        vm.expectRevert(PositionMarket.PositionNotLive.selector);
        market.list(id, pay, PRICE);
        vm.stopPrank();
    }

    function test_RevertWhen_FeeAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(PositionMarket.FeeTooHigh.selector);
        market.setFeeBps(501);
    }
}
