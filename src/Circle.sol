// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICircleFactory} from "./interfaces/ICircleFactory.sol";
import {ICircle} from "./interfaces/ICircle.sol";
import {PositionNFT} from "./PositionNFT.sol";
import {ReputationRegistry} from "./ReputationRegistry.sol";

/// @title Circle
/// @author Jose L Imoberdorf
/// @notice On-chain rotating savings and credit association (ROSCA: tanda, junta, pandero, chama, susu...).
///         `maxMembers` people contribute `contributionAmount` every round; each round the whole pot goes to the
///         holder of that round's PositionNFT. Members lock collateral that covers missed payments, and the
///         collateral can earn yield in an allow-listed ERC-4626 vault while the circle runs.
/// @dev Life cycle: Open (members join and pick a slot) -> Active (rounds) -> Completed, or Open -> Cancelled
///      when the circle is not filled before `joinDeadline`.
///
///      Default handling (why the circle stays solvent with `collateralBps = 10_000`):
///      - A missed payment is taken from the member's collateral so the current pot stays whole.
///      - If the collateral is exhausted, the missing part becomes the member's debt and a shortfall of that
///        round. When the member's own payout round arrives, the debt is withheld from their pot and paid to
///        the rounds that were short, and their collateral is refilled up to `requiredCollateral(slot)`.
///      - After their payout, a member still owes `maxMembers - 1 - slot` contributions, which is exactly what
///        `requiredCollateral` covers (plus one extra contribution as a buffer).
///
///      Reused and fixed from the author's previous repos:
///      - Cryptobank: per-user balance accounting and CEI withdrawals -> `collateralOf` / `withdrawCollateral`,
///        now for ERC-20 with SafeERC20 instead of native ETH.
///      - Staking-App: fixed-amount lock per user -> `requiredCollateral(slot)`; periodic rewards -> vault yield
///        shared pro-rata at settlement (no accrued yield is lost, unlike the original `claimRewards`).
///      - Presale: time windows (`startingTime`/`endingTime`, phases) -> `joinDeadline` and round deadlines; the
///        emergency withdraw -> `rescueERC20`, which can no longer touch user funds.
///      - NFTMarketplace: fee in basis points with a hard cap -> `feeBps`, collected with pull payments.
contract Circle is ICircle, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Open,
        Active,
        Completed,
        Cancelled
    }

    /// @notice Parameters chosen by the circle creator.
    /// @param token Stablecoin used for contributions and collateral (must be allow-listed in the factory).
    /// @param contributionAmount Amount each member pays per round.
    /// @param maxMembers Number of members and rounds.
    /// @param roundDuration Minimum time members have to pay each round.
    /// @param joinDeadline Timestamp after which an unfilled circle can be cancelled.
    /// @param collateralBps Share (in bps) of the post-payout exposure that must be collateralised.
    /// @param yieldVault Optional ERC-4626 vault for the collateral (address(0) = none, must be allow-listed).
    struct Config {
        IERC20 token;
        uint256 contributionAmount;
        uint32 maxMembers;
        uint64 roundDuration;
        uint64 joinDeadline;
        uint16 collateralBps;
        IERC4626 yieldVault;
    }

    uint256 public constant BPS = 10_000;
    uint32 public constant MIN_MEMBERS = 2;
    uint32 public constant MAX_MEMBERS = 50;

    ICircleFactory public immutable factory;
    PositionNFT public immutable positionNFT;
    ReputationRegistry public immutable reputation;
    IERC20 public immutable token;
    IERC4626 public immutable yieldVault;
    uint256 public immutable contributionAmount;
    uint32 public immutable maxMembers;
    uint64 public immutable roundDuration;
    uint64 public immutable joinDeadline;
    uint16 public immutable collateralBps;
    /// @notice Protocol fee on each pot, snapshotted from the factory at creation so it can never change later.
    uint16 public immutable feeBps;

    Status public status;
    uint32 public memberCount;
    uint32 public currentRound;
    uint32 public paidCount;
    uint64 public startTime;
    uint64 public currentDeadline;

    mapping(uint32 slot => address member) public slotMember;
    mapping(address member => uint32 slotPlusOne) public memberSlotPlusOne;
    mapping(uint32 slot => uint256 tokenId) public slotTokenId;
    mapping(uint32 round => mapping(address member => bool)) public hasPaid;

    /// @notice Nominal collateral of each member (the vault may hold more or less at settlement).
    mapping(address member => uint256) public collateralOf;
    uint256 public totalCollateral;
    /// @notice Missed contributions not covered by collateral.
    mapping(address member => uint256) public debtOf;
    mapping(address member => bool) public defaulted;

    mapping(uint32 round => uint256) public payoutOf;
    mapping(uint32 round => bool) public payoutClaimed;
    mapping(uint32 round => address) public payoutRecipient;
    mapping(uint32 round => uint256) public roundShortfall;
    /// @notice Late compensation owed to holders that already claimed a round that was short.
    mapping(address account => uint256) public claimable;

    uint256 public accruedFees;
    uint256 public collateralPoolAtSettlement;
    uint256 public collateralAtSettlement;

    event Joined(address indexed member, uint32 indexed slot, uint256 collateral, uint256 tokenId);
    event Started(uint64 startTime, uint64 firstDeadline);
    event Contributed(uint32 indexed round, address indexed member, address indexed payer, bool onTime);
    event MemberDefaulted(uint32 indexed round, address indexed member, uint256 slashed, uint256 uncovered);
    event DebtWithheld(uint32 indexed round, address indexed member, uint256 amount);
    event CollateralRefilled(uint32 indexed round, address indexed member, uint256 amount);
    event RoundClosed(uint32 indexed round, uint256 pot, uint256 fee, uint256 payout, uint64 nextDeadline);
    event PayoutClaimed(uint32 indexed round, address indexed to, uint256 amount);
    event CompensationCredited(uint32 indexed round, address indexed to, uint256 amount);
    event Settled(Status status, uint256 collateralPool);
    event CollateralWithdrawn(address indexed member, uint256 amount);
    event ClaimableWithdrawn(address indexed account, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error InvalidConfig();
    error NotOpen();
    error NotActive();
    error NotSettled();
    error JoinClosed();
    error JoinStillOpen();
    error InvalidSlot();
    error SlotTaken();
    error AlreadyMember();
    error NotMember();
    error AlreadyPaid();
    error RoundStillOpen();
    error RoundNotClosed();
    error AlreadyClaimed();
    error NotPositionHolder();
    error NothingToWithdraw();
    error NotFactoryOwner();
    error ProtectedToken();

    /// @dev Deployed by the CircleFactory, which becomes `factory`.
    constructor(Config memory cfg, PositionNFT positionNFT_, ReputationRegistry reputation_, uint16 feeBps_) {
        if (address(cfg.token) == address(0) || cfg.contributionAmount == 0) revert InvalidConfig();
        if (cfg.maxMembers < MIN_MEMBERS || cfg.maxMembers > MAX_MEMBERS) revert InvalidConfig();
        if (cfg.roundDuration == 0 || cfg.joinDeadline <= block.timestamp) revert InvalidConfig();
        if (cfg.collateralBps > BPS) revert InvalidConfig();
        if (address(cfg.yieldVault) != address(0) && cfg.yieldVault.asset() != address(cfg.token)) {
            revert InvalidConfig();
        }

        factory = ICircleFactory(msg.sender);
        positionNFT = positionNFT_;
        reputation = reputation_;
        token = cfg.token;
        yieldVault = cfg.yieldVault;
        contributionAmount = cfg.contributionAmount;
        maxMembers = cfg.maxMembers;
        roundDuration = cfg.roundDuration;
        joinDeadline = cfg.joinDeadline;
        collateralBps = cfg.collateralBps;
        feeBps = feeBps_;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Joining
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Collateral required for `slot`: one contribution as a buffer plus `collateralBps` of the
    ///         contributions still owed after that slot is paid out. Early slots lock more.
    function requiredCollateral(uint32 slot) public view returns (uint256) {
        if (slot >= maxMembers) revert InvalidSlot();
        uint256 exposure = contributionAmount * (maxMembers - 1 - slot);
        return contributionAmount + (exposure * collateralBps) / BPS;
    }

    /// @notice Joins the circle on a free `slot` (slot N is paid in round N), locking the required collateral.
    function join(uint32 slot) external nonReentrant {
        if (status != Status.Open) revert NotOpen();
        if (block.timestamp > joinDeadline) revert JoinClosed();
        if (slot >= maxMembers) revert InvalidSlot();
        if (slotMember[slot] != address(0)) revert SlotTaken();
        if (memberSlotPlusOne[msg.sender] != 0) revert AlreadyMember();

        uint256 amount = requiredCollateral(slot);

        // Effects
        slotMember[slot] = msg.sender;
        memberSlotPlusOne[msg.sender] = slot + 1;
        collateralOf[msg.sender] = amount;
        totalCollateral += amount;
        uint32 count = ++memberCount;
        if (count == maxMembers) {
            status = Status.Active;
            startTime = uint64(block.timestamp);
            currentDeadline = uint64(block.timestamp) + roundDuration;
            emit Started(startTime, currentDeadline);
        }

        // Interactions
        token.safeTransferFrom(msg.sender, address(this), amount);
        _depositToVault(amount);
        uint256 tokenId = positionNFT.mint(msg.sender, slot);
        slotTokenId[slot] = tokenId;

        emit Joined(msg.sender, slot, amount, tokenId);
    }

    /// @notice Cancels a circle that was not filled before `joinDeadline`. Anyone can call it.
    function cancel() external nonReentrant {
        if (status != Status.Open) revert NotOpen();
        if (block.timestamp <= joinDeadline) revert JoinStillOpen();
        _settle(Status.Cancelled);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Rounds
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Pays the caller's contribution for the current round.
    function contribute() external {
        contributeFor(msg.sender);
    }

    /// @notice Pays the current round's contribution on behalf of `member`. The payer is `msg.sender`
    ///         (used by SwapContributor, or by anyone helping a member).
    function contributeFor(address member) public nonReentrant {
        if (status != Status.Active) revert NotActive();
        if (memberSlotPlusOne[member] == 0) revert NotMember();
        uint32 round = currentRound;
        if (hasPaid[round][member]) revert AlreadyPaid();

        hasPaid[round][member] = true;
        paidCount++;
        bool onTime = block.timestamp <= currentDeadline;

        token.safeTransferFrom(msg.sender, address(this), contributionAmount);
        reputation.recordPayment(member, onTime);

        emit Contributed(round, member, msg.sender, onTime);
    }

    /// @notice Closes the current round once everybody paid or the deadline passed. Anyone can call it.
    ///         Missed payments are taken from collateral, the fee is accrued and the net pot becomes claimable
    ///         by the holder of this round's PositionNFT.
    function closeRound() external nonReentrant {
        if (status != Status.Active) revert NotActive();
        if (paidCount < maxMembers && block.timestamp <= currentDeadline) revert RoundStillOpen();

        uint32 round = currentRound;
        address recipient = slotMember[round];

        uint256 slashed = _collectDefaults(round, recipient);
        uint256 pot = uint256(paidCount) * contributionAmount + slashed;
        uint256 fee = (pot * feeBps) / BPS;
        accruedFees += fee;

        uint256 payout = _settleRecipient(round, recipient, pot - fee);
        payoutOf[round] = payout;

        // Next round: at least a full `roundDuration` from now, even if this round was closed late.
        paidCount = 0;
        currentRound = round + 1;
        uint64 previous = currentDeadline;
        uint64 base = previous > block.timestamp ? previous : uint64(block.timestamp);
        currentDeadline = base + roundDuration;

        emit RoundClosed(round, pot, fee, payout, currentDeadline);

        if (currentRound == maxMembers) _settle(Status.Completed);
    }

    /// @notice Claims the pot of a closed round. Only the current holder of that round's PositionNFT can claim;
    ///         the NFT is burned.
    function claimPayout(uint32 round) external nonReentrant {
        if (round >= currentRound) revert RoundNotClosed();
        if (payoutClaimed[round]) revert AlreadyClaimed();
        uint256 tokenId = slotTokenId[round];
        address holder = positionNFT.ownerOf(tokenId);
        if (msg.sender != holder) revert NotPositionHolder();

        uint256 amount = payoutOf[round];
        payoutClaimed[round] = true;
        payoutRecipient[round] = holder;
        payoutOf[round] = 0;

        positionNFT.burn(tokenId);
        token.safeTransfer(holder, amount);

        emit PayoutClaimed(round, holder, amount);
    }

    /// @notice Withdraws compensation credited after a round was claimed short.
    function withdrawClaimable() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        claimable[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit ClaimableWithdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Withdraws the caller's remaining collateral plus its share of the vault yield (or loss), once the
    ///         circle is completed or cancelled. On cancellation the caller's position is burned.
    function withdrawCollateral() external nonReentrant {
        if (status != Status.Completed && status != Status.Cancelled) revert NotSettled();
        uint256 nominal = collateralOf[msg.sender];
        if (nominal == 0) revert NothingToWithdraw();

        collateralOf[msg.sender] = 0;
        uint256 amount = Math.mulDiv(nominal, collateralPoolAtSettlement, collateralAtSettlement);

        if (status == Status.Cancelled) {
            positionNFT.burn(slotTokenId[memberSlotPlusOne[msg.sender] - 1]);
        }
        token.safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, amount);
    }

    /// @notice Sends the accrued protocol fees to the factory's fee recipient. Anyone can call it.
    function withdrawFees() external nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) revert NothingToWithdraw();
        accruedFees = 0;
        address to = factory.feeRecipient();
        token.safeTransfer(to, amount);
        emit FeesWithdrawn(to, amount);
    }

    /// @notice Rescues tokens sent here by mistake. Unlike Presale's `emergencyERC20Withdraw`, it can never move
    ///         the circle token or the vault shares, so the factory owner cannot touch members' funds.
    function rescueERC20(IERC20 otherToken, address to) external nonReentrant {
        if (msg.sender != factory.owner()) revert NotFactoryOwner();
        if (address(otherToken) == address(token) || address(otherToken) == address(yieldVault)) {
            revert ProtectedToken();
        }
        uint256 amount = otherToken.balanceOf(address(this));
        otherToken.safeTransfer(to, amount);
        emit Rescued(address(otherToken), to, amount);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICircle
    function isPositionLive(uint32 slot) public view returns (bool) {
        // Positions can only be traded once the circle is Active: an Open circle may still be cancelled.
        return (status == Status.Active || status == Status.Completed) && slot < maxMembers && !payoutClaimed[slot];
    }

    /// @inheritdoc ICircle
    function positionInfo(uint32 slot) external view returns (PositionInfo memory info) {
        if (slot >= maxMembers) revert InvalidSlot();
        info.token = address(token);
        info.grossPot = contributionAmount * maxMembers;
        info.live = isPositionLive(slot);
        info.closed = slot < currentRound;

        if (info.closed) {
            info.payoutAmount = payoutOf[slot];
        } else {
            address member = slotMember[slot];
            if (member != address(0)) {
                uint256 required = requiredCollateral(slot);
                uint256 current = collateralOf[member];
                info.encumbrance = debtOf[member] + (current < required ? required - current : 0);
            }
            if (startTime != 0) {
                info.estimatedPayoutTime = currentDeadline + uint256(slot - currentRound) * roundDuration;
            }
        }
    }

    function slotOf(address member) external view returns (uint32) {
        uint32 s = memberSlotPlusOne[member];
        if (s == 0) revert NotMember();
        return s - 1;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Takes each missed contribution from the member's collateral. What collateral cannot cover becomes
    ///      debt. The round recipient missing their own payment only reduces their own pot.
    function _collectDefaults(uint32 round, address recipient) private returns (uint256 slashed) {
        uint256 c = contributionAmount;
        for (uint32 i = 0; i < maxMembers; ++i) {
            address member = slotMember[i];
            if (hasPaid[round][member]) continue;

            defaulted[member] = true;
            if (member == recipient) {
                reputation.recordDefault(member, 0);
                emit MemberDefaulted(round, member, 0, 0);
                continue;
            }

            uint256 take = Math.min(c, collateralOf[member]);
            collateralOf[member] -= take;
            slashed += take;

            uint256 uncovered = c - take;
            if (uncovered > 0) {
                debtOf[member] += uncovered;
                roundShortfall[round] += uncovered;
            }
            reputation.recordDefault(member, uncovered);
            emit MemberDefaulted(round, member, take, uncovered);
        }

        if (slashed > 0) {
            totalCollateral -= slashed;
            _withdrawFromVault(slashed);
        }
    }

    /// @dev Before paying the round recipient: repay their debt to the rounds that were short, then refill their
    ///      collateral up to `requiredCollateral(slot)` so the rounds they still owe are covered.
    function _settleRecipient(uint32 round, address recipient, uint256 payout) private returns (uint256) {
        uint256 debt = debtOf[recipient];
        if (debt > 0 && payout > 0) {
            uint256 withheld = Math.min(debt, payout);
            debtOf[recipient] = debt - withheld;
            payout -= withheld;
            payout += _compensate(withheld, round);
            reputation.recordDebtRepaid(recipient, withheld);
            emit DebtWithheld(round, recipient, withheld);
        }

        uint256 target = requiredCollateral(round);
        uint256 current = collateralOf[recipient];
        if (current < target && payout > 0) {
            uint256 refill = Math.min(target - current, payout);
            collateralOf[recipient] = current + refill;
            totalCollateral += refill;
            payout -= refill;
            _depositToVault(refill);
            emit CollateralRefilled(round, recipient, refill);
        }
        return payout;
    }

    /// @dev Distributes `amount` to earlier rounds that were short, oldest first. Returns what could not be
    ///      assigned (0 in practice, kept as a safety net and returned to the caller's payout).
    function _compensate(uint256 amount, uint32 beforeRound) private returns (uint256 leftover) {
        for (uint32 r = 0; r < beforeRound && amount > 0; ++r) {
            uint256 shortfall = roundShortfall[r];
            if (shortfall == 0) continue;
            uint256 give = Math.min(shortfall, amount);
            roundShortfall[r] = shortfall - give;
            amount -= give;
            if (payoutClaimed[r]) {
                address to = payoutRecipient[r];
                claimable[to] += give;
                emit CompensationCredited(r, to, give);
            } else {
                payoutOf[r] += give;
                emit CompensationCredited(r, address(0), give);
            }
        }
        return amount;
    }

    function _settle(Status finalStatus) private {
        status = finalStatus;
        uint256 pool = totalCollateral;
        if (address(yieldVault) != address(0)) {
            uint256 shares = yieldVault.balanceOf(address(this));
            pool = shares == 0 ? 0 : yieldVault.redeem(shares, address(this), address(this));
        }
        collateralPoolAtSettlement = pool;
        collateralAtSettlement = totalCollateral;

        if (finalStatus == Status.Completed) {
            for (uint32 i = 0; i < maxMembers; ++i) {
                address member = slotMember[i];
                if (!defaulted[member]) reputation.recordCompletion(member);
            }
        }
        emit Settled(finalStatus, pool);
    }

    function _depositToVault(uint256 amount) private {
        if (address(yieldVault) == address(0) || amount == 0) return;
        token.forceApprove(address(yieldVault), amount);
        yieldVault.deposit(amount, address(this));
    }

    function _withdrawFromVault(uint256 amount) private {
        if (address(yieldVault) == address(0)) return;
        yieldVault.withdraw(amount, address(this), address(this));
    }
}
