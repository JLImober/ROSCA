// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BaseTest} from "./BaseTest.sol";
import {Circle} from "../src/Circle.sol";
import {CircleFactory} from "../src/CircleFactory.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {MockERC20} from "./mocks/Mocks.sol";

contract CircleTest is BaseTest {
    IERC4626 internal constant NO_VAULT = IERC4626(address(0));

    // ------------------------------------------------------------------ creation & joining

    function test_RevertWhen_TokenNotAllowed() public {
        Circle.Config memory cfg = _config(NO_VAULT, 10_000);
        cfg.token = IERC20(address(new MockERC20("X", "X", 18)));
        vm.expectRevert(CircleFactory.TokenNotAllowed.selector);
        factory.createCircle(cfg);
    }

    function test_RevertWhen_InvalidConfig() public {
        Circle.Config memory cfg = _config(NO_VAULT, 10_001);
        vm.expectRevert(Circle.InvalidConfig.selector);
        factory.createCircle(cfg);
    }

    function test_RequiredCollateral_DecreasesBySlot() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        assertEq(circle.requiredCollateral(0), 4 * C); // buffer + 3 contributions still owed after payout
        assertEq(circle.requiredCollateral(1), 3 * C);
        assertEq(circle.requiredCollateral(2), 2 * C);
        assertEq(circle.requiredCollateral(3), 1 * C);

        Circle half = _createCircle(NO_VAULT, 5_000);
        assertEq(half.requiredCollateral(0), C + (3 * C) / 2);
    }

    function test_Join_MintsPositionsAndStarts() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);

        assertEq(uint8(circle.status()), uint8(Circle.Status.Active));
        assertEq(circle.totalCollateral(), 10 * C);
        for (uint32 i = 0; i < N; ++i) {
            assertEq(nft.ownerOf(circle.slotTokenId(i)), members[i]);
        }
        assertEq(circle.currentDeadline(), block.timestamp + ROUND);
    }

    function test_RevertWhen_SlotTaken() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        vm.prank(members[0]);
        circle.join(2);
        vm.prank(members[1]);
        vm.expectRevert(Circle.SlotTaken.selector);
        circle.join(2);
    }

    function test_RevertWhen_AlreadyMember() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        vm.startPrank(members[0]);
        circle.join(0);
        vm.expectRevert(Circle.AlreadyMember.selector);
        circle.join(1);
        vm.stopPrank();
    }

    function test_RevertWhen_JoinAfterDeadline() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(members[0]);
        vm.expectRevert(Circle.JoinClosed.selector);
        circle.join(0);
    }

    // ------------------------------------------------------------------ happy path

    function test_FullCycle_AllPay() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);

        for (uint32 r = 0; r < N; ++r) {
            _payAll(circle);
            circle.closeRound(); // everybody paid: no need to wait for the deadline
            _assertSolvent(circle);

            uint256 before = usdc.balanceOf(members[r]);
            vm.prank(members[r]);
            circle.claimPayout(r);
            assertEq(usdc.balanceOf(members[r]) - before, _net(N * C));
        }

        assertEq(uint8(circle.status()), uint8(Circle.Status.Completed));
        for (uint32 i = 0; i < N; ++i) {
            vm.prank(members[i]);
            circle.withdrawCollateral();
        }
        circle.withdrawFees();

        assertEq(usdc.balanceOf(address(circle)), 0);
        assertEq(usdc.balanceOf(treasury), N * ((N * C * FEE_BPS) / 10_000));
        for (uint256 i = 0; i < N; ++i) {
            // Each member paid N contributions and received one pot minus the fee.
            assertEq(usdc.balanceOf(members[i]), INITIAL_BALANCE - (N * C * FEE_BPS) / 10_000);
            ReputationRegistry.Record memory rec = reputation.recordOf(members[i]);
            assertEq(rec.onTimePayments, N);
            assertEq(rec.circlesCompleted, 1);
            assertEq(rec.defaults, 0);
        }
    }

    function test_RevertWhen_CloseBeforeDeadline() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);
        vm.prank(members[0]);
        circle.contribute();

        vm.expectRevert(Circle.RoundStillOpen.selector);
        circle.closeRound();

        vm.warp(circle.currentDeadline() + 1);
        circle.closeRound();
    }

    function test_RevertWhen_ContributeTwice() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);
        vm.startPrank(members[0]);
        circle.contribute();
        vm.expectRevert(Circle.AlreadyPaid.selector);
        circle.contribute();
        vm.stopPrank();
    }

    function test_RevertWhen_ClaimTwiceOrOpenRound() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);

        vm.prank(members[0]);
        vm.expectRevert(Circle.RoundNotClosed.selector);
        circle.claimPayout(0);

        _payAll(circle);
        circle.closeRound();
        vm.startPrank(members[0]);
        circle.claimPayout(0);
        vm.expectRevert(Circle.AlreadyClaimed.selector);
        circle.claimPayout(0);
        vm.stopPrank();
    }

    function test_LateClose_GivesFullWindowToNextRound() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);

        vm.warp(block.timestamp + 100 days); // nobody closes round 0 for a long time
        circle.closeRound();

        // A griefer cannot close round 1 immediately: members get a full round to pay.
        assertEq(circle.currentDeadline(), block.timestamp + ROUND);
        vm.expectRevert(Circle.RoundStillOpen.selector);
        circle.closeRound();
    }

    // ------------------------------------------------------------------ defaults

    function test_Default_CollateralKeepsPotWhole() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);

        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(members[i]);
            circle.contribute();
        }
        vm.warp(circle.currentDeadline() + 1);
        circle.closeRound();

        assertEq(circle.payoutOf(0), _net(N * C), "pot must stay whole");
        assertEq(circle.collateralOf(members[3]), 0);
        assertTrue(circle.defaulted(members[3]));
        assertEq(reputation.recordOf(members[3]).defaults, 1);
        _assertSolvent(circle);
    }

    /// @dev members[3] (last slot, smallest collateral) skips rounds 0 and 1. Round 0 is covered by collateral,
    ///      round 1 is short. In round 3 their debt is withheld from their own pot, round 1's holder is
    ///      compensated and members[3]'s collateral is refilled.
    function test_Default_DebtWithheldFromOwnPayoutAndCompensated() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);

        for (uint32 r = 0; r < 2; ++r) {
            for (uint256 i = 0; i < 3; ++i) {
                vm.prank(members[i]);
                circle.contribute();
            }
            vm.warp(circle.currentDeadline() + 1);
            circle.closeRound();
            vm.prank(members[r]);
            circle.claimPayout(r);
        }
        assertEq(circle.debtOf(members[3]), C);
        assertEq(circle.roundShortfall(1), C);
        assertEq(reputation.recordOf(members[3]).outstandingDebt, C);

        for (uint32 r = 2; r < N; ++r) {
            _payAll(circle);
            circle.closeRound();
            _assertSolvent(circle);
        }

        // Pot 400 - fee 4 - debt 100 - collateral refill 100 = 196
        assertEq(circle.payoutOf(3), _net(N * C) - 2 * C);
        assertEq(circle.debtOf(members[3]), 0);
        assertEq(circle.roundShortfall(1), 0);
        assertEq(circle.claimable(members[1]), C);
        assertEq(circle.collateralOf(members[3]), C);
        assertEq(reputation.recordOf(members[3]).outstandingDebt, 0);
        assertEq(reputation.recordOf(members[3]).circlesCompleted, 0);

        vm.prank(members[1]);
        circle.withdrawClaimable();
        vm.prank(members[2]);
        circle.claimPayout(2);
        vm.prank(members[3]);
        circle.claimPayout(3);
        for (uint256 i = 0; i < N; ++i) {
            vm.prank(members[i]);
            circle.withdrawCollateral();
        }
        circle.withdrawFees();
        assertEq(usdc.balanceOf(address(circle)), 0);
    }

    /// @dev Random payments and collateral levels: the circle is solvent after every round, and at the end every
    ///      token that came in went out (nothing stuck, nothing created).
    function testFuzz_Conservation(uint256 seed, uint16 collateralBps) public {
        collateralBps = uint16(bound(collateralBps, 0, 10_000));
        Circle circle = _createCircle(NO_VAULT, collateralBps);
        _joinAll(circle);

        for (uint32 r = 0; r < N; ++r) {
            for (uint256 i = 0; i < N; ++i) {
                if (uint256(keccak256(abi.encode(seed, r, i))) % 4 != 0) {
                    vm.prank(members[i]);
                    circle.contribute();
                }
            }
            vm.warp(circle.currentDeadline() + 1);
            circle.closeRound();
            _assertSolvent(circle);
            vm.prank(members[r]);
            circle.claimPayout(r);
        }

        for (uint256 i = 0; i < N; ++i) {
            vm.startPrank(members[i]);
            if (circle.collateralOf(members[i]) > 0) circle.withdrawCollateral();
            if (circle.claimable(members[i]) > 0) circle.withdrawClaimable();
            vm.stopPrank();
        }
        if (circle.accruedFees() > 0) circle.withdrawFees();

        assertEq(usdc.balanceOf(address(circle)), 0, "tokens stuck");
        uint256 total = usdc.balanceOf(treasury);
        for (uint256 i = 0; i < N; ++i) {
            total += usdc.balanceOf(members[i]);
        }
        assertEq(total, N * INITIAL_BALANCE, "tokens created or lost");
    }

    // ------------------------------------------------------------------ positions

    function test_TransferredPosition_MovesPayoutRight() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);
        address buyer = makeAddr("buyer");
        uint256 tokenId = circle.slotTokenId(0);

        vm.prank(members[0]);
        nft.transferFrom(members[0], buyer, tokenId);

        _payAll(circle); // members[0] still owes the contributions
        circle.closeRound();

        vm.prank(members[0]);
        vm.expectRevert(Circle.NotPositionHolder.selector);
        circle.claimPayout(0);

        vm.prank(buyer);
        circle.claimPayout(0);
        assertEq(usdc.balanceOf(buyer), _net(N * C));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        nft.ownerOf(tokenId);
    }

    function test_TokenURI_IsOnChainJson() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);
        string memory uri = nft.tokenURI(circle.slotTokenId(1));
        assertEq(bytes(uri).length > 29, true);
        assertEq(_prefix(uri, 29), "data:application/json;base64,");
    }

    function test_RevertWhen_NonCircleMints() public {
        vm.expectRevert();
        nft.mint(address(this), 0);
    }

    // ------------------------------------------------------------------ cancel

    function test_Cancel_ReturnsCollateralAndBurnsPositions() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        vm.prank(members[0]);
        circle.join(0);
        vm.prank(members[1]);
        circle.join(1);
        uint256 tokenId = circle.slotTokenId(0);

        vm.expectRevert(Circle.JoinStillOpen.selector);
        circle.cancel();

        vm.warp(block.timestamp + 7 days + 1);
        circle.cancel();
        assertFalse(circle.isPositionLive(0));

        vm.prank(members[0]);
        circle.withdrawCollateral();
        vm.prank(members[1]);
        circle.withdrawCollateral();

        assertEq(usdc.balanceOf(members[0]), INITIAL_BALANCE);
        assertEq(usdc.balanceOf(members[1]), INITIAL_BALANCE);
        assertEq(usdc.balanceOf(address(circle)), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        nft.ownerOf(tokenId);
    }

    function test_RevertWhen_CancelActiveCircle() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(Circle.NotOpen.selector);
        circle.cancel();
    }

    // ------------------------------------------------------------------ yield

    function test_YieldVault_SharesYieldProRata() public {
        Circle circle = _createCircle(IERC4626(address(vault)), 10_000);
        _joinAll(circle);
        assertEq(usdc.balanceOf(address(circle)), 0, "collateral should sit in the vault");

        usdc.mint(address(vault), 100e6); // 10 % yield on 1000 USDC of collateral

        for (uint32 r = 0; r < N; ++r) {
            _payAll(circle);
            circle.closeRound();
            vm.prank(members[r]);
            circle.claimPayout(r);
        }

        for (uint32 i = 0; i < N; ++i) {
            uint256 before = usdc.balanceOf(members[i]);
            vm.prank(members[i]);
            circle.withdrawCollateral();
            uint256 expected = (circle.requiredCollateral(i) * 11) / 10;
            assertApproxEqAbs(usdc.balanceOf(members[i]) - before, expected, 10);
        }
    }

    // ------------------------------------------------------------------ admin

    function test_RescueERC20_CannotTouchMembersFunds() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        _joinAll(circle);
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(circle), 1e18);

        vm.expectRevert(Circle.NotFactoryOwner.selector);
        circle.rescueERC20(other, address(this));

        vm.startPrank(owner);
        vm.expectRevert(Circle.ProtectedToken.selector);
        circle.rescueERC20(IERC20(address(usdc)), owner);

        circle.rescueERC20(other, owner);
        vm.stopPrank();
        assertEq(other.balanceOf(owner), 1e18);
    }

    function test_FeeIsSnapshottedAtCreation() public {
        Circle circle = _createCircle(NO_VAULT, 10_000);
        vm.prank(owner);
        factory.setFeeBps(200);
        assertEq(circle.feeBps(), FEE_BPS);

        vm.prank(owner);
        vm.expectRevert(CircleFactory.FeeTooHigh.selector);
        factory.setFeeBps(201);
    }

    function _prefix(string memory s, uint256 len) private pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = b[i];
        }
        return string(out);
    }
}
