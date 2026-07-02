// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {IRandomProvider} from "./interfaces/IRandomProvider.sol";
import {IEndaomentOrgFundFactory, IEndaomentEntity} from "./interfaces/IEndaomentOrgFundFactory.sol";
import {EasternTime} from "./EasternTime.sol";

/// @title CharityPrizeVault
/// @notice A no-lose, prize-linked charity vault. Depositors' principal is always
///         theirs and withdrawable at any time. Pooled deposits earn yield in Aave;
///         each draw, that yield is split 90% to one randomly selected depositor,
///         5% to a rotating charity, 5% to the company treasury.
///
/// Legal-by-design (the reason this is not a lottery and not money transmission):
///   - DEPOSITS ARE REFUNDABLE AT ANY TIME (`withdraw`), so no "consideration" is
///     paid -> not a lottery. Only forgone *yield* funds the prize, never principal.
///   - The contract is NON-CUSTODIAL: there is NO function by which the owner can
///     move user principal. Yield is the only thing ever distributed, and only the
///     excess of aToken balance over tracked principal is ever touchable. This keeps
///     the operator outside FinCEN money-transmitter custody.
///   - Odds are EQUAL PER $1: tickets track dollars, not wallets, so splitting a
///     deposit across many wallets confers no advantage (Sybil-proof).
contract CharityPrizeVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Immutable wiring ---
    IERC20 public immutable asset; // e.g. USDC
    IAavePool public immutable aavePool; // Aave v3 Pool
    IERC20 public immutable aToken; // e.g. aUSDC (rebasing receipt)
    IRandomProvider public immutable randomProvider; // Chainlink VRF coordinator

    // --- Prize split (basis points, must sum to 10_000) ---
    uint16 public constant WINNER_BPS = 9000;
    uint16 public constant CHARITY_BPS = 500;
    uint16 public constant COMPANY_BPS = 500;

    // --- Draw cadence: every Thursday 21:00 America/New_York (EDT/EST, DST-aware) ---
    uint256 public nextDrawTime; // UTC instant of the upcoming scheduled draw
    uint256 public lastDrawTime; // UTC instant the most recent draw actually executed
    bool public drawPending; // true between requestDraw() and fulfillRandomWords()
    uint256 public pendingRequestId;
    uint256 public pendingSince; // when the open randomness request was made

    /// @notice How long a randomness request may sit unfulfilled before anyone can
    ///         cancel it and re-request. VRF normally fulfills within minutes; a request
    ///         this old is dead (e.g. the callback ran out of gas, which VRF never
    ///         retries) and would otherwise block every future draw.
    uint256 public constant STALE_DRAW_TIMEOUT = 1 days;

    // --- Self-healing keeper bounty ---
    /// @notice The primary trigger is a free off-chain heartbeat (a public scheduled job)
    ///         that fires the draw at the scheduled time. If it MISSES — i.e. the draw is
    ///         fired more than DRAW_BOUNTY_GRACE after it became due — whoever steps in to
    ///         fire it earns `drawBounty`, paid ONLY from the company slice and only on a
    ///         late draw. On-time draws pay no bounty, so normal operation is free. This
    ///         makes the schedule self-healing without trusting any single keeper.
    uint256 public constant DRAW_BOUNTY_GRACE = 5 minutes;
    uint256 public constant MAX_DRAW_BOUNTY = 10e6; // hard cap = $10 (USDC, 6 decimals)
    uint256 public drawBounty; // owner-set bounty (asset units), 0..MAX_DRAW_BOUNTY
    address public drawStarter; // who fired the current/last draw (paid the bounty if late)
    bool public drawStartedLate; // whether that draw was fired past the grace window

    // --- Payout recipients ---
    address public companyTreasury;
    address public charity; // fallback direct-address charity, must be on the allowlist
    mapping(address => bool) public allowedCharity;

    // --- Charity routing via Endaoment (on-chain 501(c)(3) community foundation) ---
    /// @notice When `useEndaoment` is true, the charity 5% is donated on-chain to an
    ///         Endaoment Org (the nonprofit's IRS EIN encoded to bytes32), instead of being
    ///         sent to the `charity` address above. Endaoment then grants the funds to the
    ///         nonprofit in USD/USDC, so the charity needs no crypto wallet. The whole
    ///         donation is wrapped in try/catch in the draw, so a failed external call can
    ///         never brick the weekly draw or trap the yield.
    ///
    ///         Endaoment charges a protocol fee (~1.5%) out of the donated amount; that fee
    ///         is taken from the charity 5% slice (i.e. the charity nets 5% less the fee) —
    ///         the winner's 90% and the company's 5% are unaffected.
    IEndaomentOrgFundFactory public endaomentFactory;
    bool public useEndaoment;
    /// @notice Ordered list of vetted Endaoment Org ids (each = a nonprofit's IRS EIN
    ///         encoded to bytes32). The charity 5% rotates through this list ONE STEP PER
    ///         DRAW — deterministic and predictable so participants can see this week's and
    ///         next week's beneficiary in advance. Only the WINNER is chosen by VRF; the
    ///         charity is never random. `charityIndex` points at the entry that receives
    ///         THIS week's slice; it advances by one after each completed draw. Curation of
    ///         the list (which charities, in what order) is an owner action, done off-chain.
    bytes32[] public charityRotation;
    uint256 public charityIndex;

    /// @notice The operator's deposit earns yield for the pool but is NOT eligible to
    ///         win, avoiding "founder wins his own charity draw" optics. It is a SINGLE
    ///         address and is IMMUTABLE: set once at deploy and never changeable. This
    ///         is deliberate — because it is one fixed slot, not a growable blocklist,
    ///         no one can ever exclude depositors to narrow the field toward a chosen
    ///         winner, and the owner has zero influence over who is eligible. Set it to
    ///         the company's own wallet (or address(0) for no exclusion) at construction.
    address public immutable operator;

    // --- Ledger (principal only; yield is never credited to individuals) ---
    mapping(address => uint256) public balanceOf; // principal per depositor
    uint256 public totalDeposited; // sum of all principal

    /// @notice Distinct depositor index, 1-based (0 = never deposited). Once assigned
    ///         it is permanent, even after a full withdrawal, so the Fenwick tree below
    ///         keeps a stable slot for each address.
    mapping(address => uint256) public indexOf;
    mapping(uint256 => address) public depositorAt;
    uint256 public numDepositors;

    /// @dev Fenwick tree (Binary Indexed Tree) over per-depositor balances, keyed by
    ///      `indexOf`. Gives O(log n) prefix sums and O(log n) "find the depositor whose
    ///      cumulative dollar range contains target", so the draw's winner selection
    ///      costs the same whether there are 10 entries or 10 million — it never runs
    ///      out of gas. A zero-balance (fully withdrawn) slot occupies no range and so
    ///      can never be selected, exactly like the old skip-on-zero walk.
    mapping(uint256 => uint256) private _tree;

    // --- Events ---
    event Deposited(address indexed user, uint256 amount, uint256 newBalance);
    event Withdrawn(address indexed user, uint256 amount, uint256 newBalance);
    event DrawRequested(uint256 indexed requestId, uint256 timestamp);
    event StaleDrawCancelled(uint256 indexed requestId);
    /// @notice A late draw paid a self-healing keeper bounty (from the company slice).
    event DrawBountyPaid(address indexed keeper, uint256 amount);
    event DrawBountySet(uint256 amount);
    event PrizeAwarded(
        address indexed winner, uint256 winnerAmount, address indexed charity, uint256 charityAmount, uint256 companyAmount
    );
    event DrawSkipped(string reason);
    event CharitySet(address indexed charity);
    event CharityAllowed(address indexed charity, bool allowed);
    event CompanyTreasurySet(address indexed treasury);
    event EndaomentFactorySet(address indexed factory);
    event UseEndaomentSet(bool enabled);
    /// @notice The whole weekly charity rotation was replaced (pointer reset to 0).
    event CharityRotationSet(uint256 count);
    event CharityOrgIdAdded(bytes32 indexed orgId, uint256 index);
    event CharityOrgIdRemoved(bytes32 indexed orgId, uint256 index);
    event CharityIndexSet(uint256 index);
    /// @notice The weekly charity rotation advanced one step after a completed draw.
    event CharityRotationAdvanced(uint256 newIndex, bytes32 newCurrentOrgId);
    /// @notice Charity 5% was donated on-chain to an Endaoment Org. `net` is what was sent
    ///         to Endaoment (Endaoment then skims its protocol fee from this before granting).
    event CharityDonatedToEndaoment(bytes32 indexed orgId, address indexed org, uint256 net);
    /// @notice Endaoment routing was attempted but reverted; the draw fell back (to the
    ///         direct charity address if set, otherwise the slice folded into the company).
    event CharityRouteFailed(bytes32 indexed orgId);

    error NotRandomProvider();
    error DrawNotDue();
    error DrawAlreadyPending();
    error DrawNotStale();
    error BountyTooHigh();
    error CharityNotAllowed();
    error IndexOutOfRange();
    error OnlySelf();
    error ZeroAmount();
    error InsufficientBalance();
    error ProtectedToken();

    constructor(
        IERC20 _asset,
        IAavePool _aavePool,
        IERC20 _aToken,
        IRandomProvider _randomProvider,
        address _companyTreasury,
        address _operator,
        address _owner
    ) Ownable(_owner) {
        asset = _asset;
        aavePool = _aavePool;
        aToken = _aToken;
        randomProvider = _randomProvider;
        companyTreasury = _companyTreasury;
        operator = _operator;
        nextDrawTime = EasternTime.nextThursday2100ET(block.timestamp);
        asset.forceApprove(address(_aavePool), type(uint256).max);
    }

    // --- Depositor actions (permissionless) ---

    /// @notice Deposit `amount` of asset. Mints an equal claim on your principal,
    ///         which you may withdraw at any time. Every $1 deposited is one equal
    ///         ticket in each draw while it remains deposited.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 idx = indexOf[msg.sender];
        balanceOf[msg.sender] += amount;
        totalDeposited += amount;
        if (idx == 0) {
            // First-ever deposit from this address: assign a permanent slot and
            // initialize its Fenwick node from already-built children.
            idx = ++numDepositors;
            indexOf[msg.sender] = idx;
            depositorAt[idx] = msg.sender;
            _treeAppend(idx, amount);
        } else {
            _treeUpdate(idx, amount, true);
        }
        aavePool.supply(address(asset), amount, address(this), 0);
        emit Deposited(msg.sender, amount, balanceOf[msg.sender]);
    }

    /// @notice Withdraw your principal at any time. This is what makes the deposit
    ///         legally "your money under your control" — no lock-ups, no permission.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        totalDeposited -= amount;
        _treeUpdate(indexOf[msg.sender], amount, false);
        aavePool.withdraw(address(asset), amount, msg.sender);
        emit Withdrawn(msg.sender, amount, balanceOf[msg.sender]);
    }

    // --- Yield views ---

    /// @notice Yield accrued and currently available to award (aToken balance above
    ///         tracked principal). Principal is never included, so it cannot be paid out.
    function accruedYield() public view returns (uint256) {
        uint256 bal = aToken.balanceOf(address(this));
        return bal > totalDeposited ? bal - totalDeposited : 0;
    }

    /// @notice Total principal eligible to win (everything except the operator's).
    function eligibleTotal() public view returns (uint256) {
        return totalDeposited - balanceOf[operator];
    }

    /// @notice The winner's share of the current accrued yield, for live UI display.
    function projectedPrize() external view returns (uint256) {
        return (accruedYield() * WINNER_BPS) / 10_000;
    }

    function depositorCount() external view returns (uint256) {
        return numDepositors;
    }

    // --- Draw lifecycle ---

    /// @notice Step 1: request randomness once the scheduled Thursday draw time has
    ///         arrived. Callable by anyone (and by Chainlink Automation on a schedule).
    function requestDraw() external returns (uint256 requestId) {
        if (block.timestamp < nextDrawTime) revert DrawNotDue();
        if (drawPending) revert DrawAlreadyPending();
        drawPending = true;
        pendingSince = block.timestamp;
        // Record who fired this draw and whether it was late, so the payout can reward a
        // backstop keeper that covered for a missed primary trigger. "Late" = fired more
        // than DRAW_BOUNTY_GRACE after it became due. Permissionless, so anyone may step in.
        drawStarter = msg.sender;
        drawStartedLate = block.timestamp >= nextDrawTime + DRAW_BOUNTY_GRACE;
        requestId = randomProvider.requestRandomWords(address(this));
        pendingRequestId = requestId;
        emit DrawRequested(requestId, block.timestamp);
    }

    /// @notice Recovery: clear a randomness request that has sat unfulfilled past
    ///         STALE_DRAW_TIMEOUT, so the draw can be re-requested. Callable by anyone
    ///         and gated only by the fixed timeout — like the schedule itself, no human
    ///         gets discretion over draw timing. A late callback for the cancelled
    ///         request is ignored by the requestId check in fulfillRandomWords.
    function cancelStaleDraw() external {
        if (!drawPending || block.timestamp < pendingSince + STALE_DRAW_TIMEOUT) revert DrawNotStale();
        uint256 staleId = pendingRequestId;
        drawPending = false;
        pendingRequestId = 0;
        pendingSince = 0; // hygiene: never leave a stale anchor for a future pending state
        emit StaleDrawCancelled(staleId);
    }

    /// @notice Step 2: randomness callback. Selects an equal-per-$1 weighted winner,
    ///         harvests yield, and splits it 90/5/5. Only the random provider may call.
    /// @dev In production this maps to Chainlink VRF's fulfillRandomWords.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external nonReentrant {
        if (msg.sender != address(randomProvider)) revert NotRandomProvider();
        // Stale/duplicate callbacks are ignored.
        if (!drawPending || requestId != pendingRequestId) return;
        // Defensive: a well-behaved provider always returns numWords=1, but never
        // index into an empty array. Treat a malformed callback as a no-op skip.
        if (randomWords.length == 0) {
            emit DrawSkipped("no randomness");
            return;
        }

        drawPending = false;
        lastDrawTime = block.timestamp;
        // Re-anchor to the next Thursday 21:00 ET. Computing from `now` (not by adding
        // a fixed 7 days) keeps the schedule calendar-locked and DST-correct even if
        // Automation fires the draw a little late.
        nextDrawTime = EasternTime.nextThursday2100ET(block.timestamp);

        // Harvest + payout is isolated behind a self-call + try/catch. A transient
        // external failure (e.g. Aave withdrawals paused or the reserve frozen) then
        // skips THIS week's distribution cleanly — the yield simply stays in Aave and
        // is awarded at the next draw — instead of reverting the VRF callback and
        // leaving the request stranded until the stale-timeout. The schedule above is
        // already advanced, so a skipped week never double-fires or sticks.
        try this.executeDraw(randomWords[0]) {}
        catch {
            emit DrawSkipped("draw failed");
        }
    }

    /// @notice The harvest + winner selection + 90/5/5 payout. Self-call only: invoked
    ///         exclusively by `fulfillRandomWords` via `this.` so its external
    ///         interactions sit behind a try/catch and can never brick the callback.
    function executeDraw(uint256 randomWord) external {
        if (msg.sender != address(this)) revert OnlySelf();

        uint256 yield_ = accruedYield();
        uint256 pool = eligibleTotal();
        if (yield_ == 0 || pool == 0) {
            emit DrawSkipped(yield_ == 0 ? "no yield" : "no eligible depositors");
            return;
        }

        address winner = _selectWinner(randomWord % pool);
        if (winner == address(0)) {
            emit DrawSkipped("no winner");
            return;
        }

        // Pull only the accrued yield out of Aave; principal stays supplied.
        aavePool.withdraw(address(asset), yield_, address(this));

        uint256 winnerAmount = (yield_ * WINNER_BPS) / 10_000;
        uint256 charityAmount = (yield_ * CHARITY_BPS) / 10_000;
        uint256 companyAmount = yield_ - winnerAmount - charityAmount; // remainder absorbs dust

        asset.safeTransfer(winner, winnerAmount);

        // Route the charity slice. Primary path is Endaoment (an on-chain 501(c)(3) DAF);
        // the whole external interaction is isolated behind a self-call + try/catch so a
        // failed donation can never revert this VRF callback or trap the yield. On failure
        // we fall back to the direct charity address; if neither is available the slice
        // folds into the company so the draw still completes.
        address charityRecipient = address(0);
        bool routed = false;
        // THIS week's charity = the current entry in the deterministic weekly rotation.
        bytes32 weekOrg = currentCharityOrgId();
        if (
            charityAmount > 0 && useEndaoment && address(endaomentFactory) != address(0)
                && weekOrg != bytes32(0)
        ) {
            try this.routeCharityToEndaoment(weekOrg, charityAmount) returns (address org) {
                charityRecipient = org;
                routed = true;
                emit CharityDonatedToEndaoment(weekOrg, org, charityAmount);
            } catch {
                emit CharityRouteFailed(weekOrg);
            }
        }
        if (!routed && charityAmount > 0) {
            if (charity != address(0)) {
                asset.safeTransfer(charity, charityAmount);
                charityRecipient = charity;
            } else {
                companyAmount += charityAmount; // no route available -> hold with company
            }
        }

        // Self-healing keeper bounty: if this draw was fired late (the free primary trigger
        // missed its slot), pay a small bounty to whoever stepped in. Taken ONLY from the
        // company slice (the party whose keeper failed bears it), capped at companyAmount so
        // it can never underflow, and only when late — on-time draws pay nothing.
        if (drawStartedLate && drawBounty > 0 && drawStarter != address(0)) {
            uint256 bounty = drawBounty > companyAmount ? companyAmount : drawBounty;
            if (bounty > 0) {
                companyAmount -= bounty;
                asset.safeTransfer(drawStarter, bounty);
                emit DrawBountyPaid(drawStarter, bounty);
            }
        }
        // Consume the late flag so a stale value can never pay a second bounty even if a
        // future refactor decoupled requestDraw/executeDraw (defense-in-depth; today the
        // flag is already freshly set by every requestDraw). drawStarter is kept readable
        // on-chain as "who fired the last draw" for transparency.
        drawStartedLate = false;

        asset.safeTransfer(companyTreasury, companyAmount);

        emit PrizeAwarded(winner, winnerAmount, charityRecipient, charityAmount, companyAmount);

        // Advance the weekly charity rotation one step (deterministic — only the winner is
        // random). Done regardless of route success so the published schedule stays on
        // cadence. Bounded modulo keeps `charityIndex` in range; cheap (one SLOAD + SSTORE).
        uint256 rotLen = charityRotation.length;
        if (rotLen > 0) {
            charityIndex = (charityIndex + 1) % rotLen;
            emit CharityRotationAdvanced(charityIndex, charityRotation[charityIndex]);
        }
    }

    /// @notice Donate `amount` of asset to the Endaoment Org for `orgId`. Restricted to
    ///         a self-call: `fulfillRandomWords` invokes it via `this.` so the entire
    ///         external interaction sits behind a try/catch and cannot brick the draw.
    /// @dev First tries `deployOrgAndDonate` (deploys the Org clone if it does not yet
    ///      exist, then donates). That reverts if the Org already exists, so on failure we
    ///      donate directly to the deterministic Org address. Approvals are scoped to the
    ///      exact puller and reset to 0 afterward. Endaoment skims its fee from `amount`.
    function routeCharityToEndaoment(bytes32 orgId, uint256 amount) external returns (address org) {
        if (msg.sender != address(this)) revert OnlySelf();
        IEndaomentOrgFundFactory factory = endaomentFactory;
        asset.forceApprove(address(factory), amount);
        try factory.deployOrgAndDonate(orgId, amount) returns (address deployed) {
            asset.forceApprove(address(factory), 0);
            return deployed;
        } catch {
            // Org already deployed: the Org entity pulls the asset, so move the approval.
            asset.forceApprove(address(factory), 0);
            org = factory.computeOrgAddress(orgId);
            asset.forceApprove(org, amount);
            IEndaomentEntity(org).donate(amount);
            asset.forceApprove(org, 0);
            return org;
        }
    }

    /// @dev Equal-per-$1 winner selection in O(log n). `targetEligible` is a random
    ///      value in [0, eligibleTotal()). The operator is kept in the Fenwick tree
    ///      (so its balance still earns yield) but excluded here: we map the eligible-
    ///      space target into full-tree space by stepping over the operator's dollar
    ///      range, then ask the tree which depositor owns that dollar. A depositor with
    ///      balance B owns exactly B of the range, so each $1 has identical odds.
    function _selectWinner(uint256 targetEligible) internal view returns (address) {
        uint256 fullTarget = targetEligible;
        uint256 opBal = balanceOf[operator];
        if (opBal > 0) {
            // Dollars before the operator's slot in tree order.
            uint256 opStart = _treePrefix(indexOf[operator] - 1);
            // If the target is at or past where the operator's block sits in eligible
            // space, shift it past that block so the operator is never selected.
            if (targetEligible >= opStart) fullTarget = targetEligible + opBal;
        }
        return depositorAt[_treeFind(fullTarget)];
    }

    // --- Fenwick tree (Binary Indexed Tree) helpers, all O(log n) ---

    /// @dev Lowest set bit of `i` (i & -i), the span a Fenwick node covers.
    function _lowbit(uint256 i) private pure returns (uint256) {
        return i & (~i + 1);
    }

    /// @dev Initialize a freshly appended node `k` by folding in its child nodes,
    ///      which are already correct. Used only on a depositor's first deposit.
    function _treeAppend(uint256 k, uint256 value) private {
        uint256 sum = value;
        uint256 stop = k - _lowbit(k);
        uint256 j = k - 1;
        while (j > stop) {
            sum += _tree[j];
            j -= _lowbit(j);
        }
        _tree[k] = sum;
    }

    /// @dev Point update: add or subtract `delta` at index `i`, propagating upward.
    function _treeUpdate(uint256 i, uint256 delta, bool add) private {
        for (; i <= numDepositors; i += _lowbit(i)) {
            if (add) _tree[i] += delta;
            else _tree[i] -= delta;
        }
    }

    /// @dev Prefix sum of balances over indices [1, i].
    function _treePrefix(uint256 i) private view returns (uint256 sum) {
        for (; i > 0; i -= _lowbit(i)) {
            sum += _tree[i];
        }
    }

    /// @dev Largest power of two <= numDepositors (0 if there are none).
    function _highBit() private view returns (uint256) {
        uint256 n = numDepositors;
        if (n == 0) return 0;
        uint256 h = 1;
        while (h << 1 <= n) h <<= 1;
        return h;
    }

    /// @dev Smallest index whose prefix sum strictly exceeds `target`, via binary
    ///      lifting. Matches the old walk's "first cumulative > target" semantics, so
    ///      zero-balance slots (which add nothing to any prefix) are skipped naturally.
    function _treeFind(uint256 target) private view returns (uint256) {
        uint256 pos = 0;
        for (uint256 mask = _highBit(); mask > 0; mask >>= 1) {
            uint256 next = pos + mask;
            if (next <= numDepositors && _tree[next] <= target) {
                pos = next;
                target -= _tree[next];
            }
        }
        return pos + 1;
    }

    // --- Owner: charity rotation & config (NEVER touches principal) ---

    function allowCharity(address _charity, bool allowed) external onlyOwner {
        allowedCharity[_charity] = allowed;
        emit CharityAllowed(_charity, allowed);
    }

    /// @notice Rotate the active charity. Must be on the vetted allowlist
    ///         (curated to high-efficiency, ≥~90% program-expense charities off-chain).
    function setCharity(address _charity) external onlyOwner {
        if (!allowedCharity[_charity]) revert CharityNotAllowed();
        charity = _charity;
        emit CharitySet(_charity);
    }

    /// @notice Set the Endaoment OrgFundFactory used to route charity donations on-chain.
    ///         Must be the verified Endaoment factory for the deployed network.
    function setEndaomentFactory(address _factory) external onlyOwner {
        endaomentFactory = IEndaomentOrgFundFactory(_factory);
        emit EndaomentFactorySet(_factory);
    }

    /// @notice Replace the entire weekly charity rotation with a new ordered list and reset
    ///         the pointer to the first entry. Each id is a vetted Endaoment Org id (the
    ///         nonprofit's IRS EIN encoded to bytes32). Vetting/curation is done off-chain.
    function setCharityRotation(bytes32[] calldata orgIds) external onlyOwner {
        charityRotation = orgIds;
        charityIndex = 0;
        emit CharityRotationSet(orgIds.length);
    }

    /// @notice Append one Endaoment Org id to the end of the rotation.
    function addCharityOrgId(bytes32 orgId) external onlyOwner {
        charityRotation.push(orgId);
        emit CharityOrgIdAdded(orgId, charityRotation.length - 1);
    }

    /// @notice Remove the Org id at `index`, preserving the order of the remaining entries.
    /// @dev Keeps the pointer aimed at the SAME beneficiary wherever possible, so removing an
    ///      UNRELATED entry never silently changes the charity the frontend already published
    ///      as "this week's". Cases: removing an entry before the pointer shifts the pointer
    ///      down with it; removing the currently-active entry advances to whatever fills the
    ///      slot (or wraps to 0 if it was last); removing after the pointer leaves it put. The
    ///      resulting pointer is always echoed via CharityIndexSet so off-chain indexers can
    ///      track the live beneficiary through a removal.
    function removeCharityOrgId(uint256 index) external onlyOwner {
        uint256 len = charityRotation.length;
        if (index >= len) revert IndexOutOfRange();
        bytes32 removed = charityRotation[index];
        for (uint256 i = index; i + 1 < len; i++) {
            charityRotation[i] = charityRotation[i + 1];
        }
        charityRotation.pop();

        uint256 newLen = charityRotation.length;
        if (newLen == 0) {
            charityIndex = 0;
        } else if (index < charityIndex) {
            // Entries at/after `index` shifted down one slot, so the pointed-at org moved
            // to charityIndex-1 — follow it to keep "this week's" charity unchanged.
            charityIndex -= 1;
        } else if (charityIndex >= newLen) {
            // Removed the last entry while the pointer sat on it — wrap to the start.
            charityIndex = 0;
        }
        // (index == charityIndex && charityIndex < newLen: the active charity itself was
        //  removed; the slot now holds the next org, which becomes this week's — intended.)

        emit CharityOrgIdRemoved(removed, index);
        emit CharityIndexSet(charityIndex); // echo the resulting live pointer
    }

    /// @notice Owner override of which entry is THIS week's charity.
    function setCharityIndex(uint256 index) external onlyOwner {
        if (index >= charityRotation.length) revert IndexOutOfRange();
        charityIndex = index;
        emit CharityIndexSet(index);
    }

    // --- Charity rotation views (the frontend reads these to show this week + next week) ---

    /// @notice Number of charities in the weekly rotation.
    function charityRotationLength() external view returns (uint256) {
        return charityRotation.length;
    }

    /// @notice The full ordered rotation, so the site can display the upcoming schedule.
    function charityRotationAll() external view returns (bytes32[] memory) {
        return charityRotation;
    }

    /// @notice THIS week's charity Org id (the one the next draw donates to). Zero if the
    ///         rotation is empty.
    function currentCharityOrgId() public view returns (bytes32) {
        uint256 len = charityRotation.length;
        if (len == 0) return bytes32(0);
        return charityRotation[charityIndex % len];
    }

    /// @notice NEXT week's charity Org id (what the rotation lands on after this draw).
    function nextCharityOrgId() external view returns (bytes32) {
        uint256 len = charityRotation.length;
        if (len == 0) return bytes32(0);
        return charityRotation[(charityIndex + 1) % len];
    }

    /// @notice Toggle Endaoment routing for the charity slice. When off, the draw uses the
    ///         direct `charity` address path instead.
    function setUseEndaoment(bool enabled) external onlyOwner {
        useEndaoment = enabled;
        emit UseEndaomentSet(enabled);
    }

    function setCompanyTreasury(address _treasury) external onlyOwner {
        companyTreasury = _treasury;
        emit CompanyTreasurySet(_treasury);
    }

    /// @notice Set the self-healing keeper bounty (in asset units, e.g. USDC; $1 = 1e6).
    ///         Paid from the company slice ONLY when a draw is fired late (primary trigger
    ///         missed). Capped at MAX_DRAW_BOUNTY. Set to 0 to disable the bounty.
    function setDrawBounty(uint256 amount) external onlyOwner {
        if (amount > MAX_DRAW_BOUNTY) revert BountyTooHigh();
        drawBounty = amount;
        emit DrawBountySet(amount);
    }

    /// @notice Recover tokens accidentally sent here. CANNOT touch the asset or the
    ///         aToken — that is the on-chain guarantee that no admin path reaches
    ///         depositor principal.
    function rescueToken(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (address(token) == address(asset) || address(token) == address(aToken)) revert ProtectedToken();
        token.safeTransfer(to, amount);
    }
}
