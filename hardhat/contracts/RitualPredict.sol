// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RitualChain, IScheduler, IRitualWallet, ITEEServiceRegistry} from "./ritual/RitualChain.sol";

/**
 * RitualPredict — a self-resolving binary prediction market.
 *
 * Users stake native RITUAL on YES or NO. When the betting window closes, nobody
 * clicks "resolve" and no backend cron runs: the Ritual Scheduler wakes the contract
 * at a block chosen at market-creation time. The contract then calls the HTTP
 * precompile (0x0801) to read the configured oracle URL, extracts one number with the
 * jq precompile (0x0803), compares it to the target, and settles the market.
 *
 * Payouts are pari-mutuel and pull-based: each winner claims
 * `stake * totalPool / winningPool`. Nothing loops over participants.
 *
 * Every deadline is a BLOCK NUMBER, so "betting is closed" and "the Scheduler woke us"
 * can never disagree. Human durations are converted at `blockTimeMs`, measured from the
 * live chain at deploy time (`scripts/block-time.ts`).
 */
contract RitualPredict {
    // ─────────────────────────────── Types ───────────────────────────────

    enum MarketState {
        Open, // accepting bets
        Closed, // betting window over, waiting for the scheduled wake-up
        Resolving, // a resolution attempt has run and failed; retries pending
        Resolved, // outcome final, winners can claim
        Invalid // could not be resolved (or nobody won); everyone refunds
    }

    enum Comparator {
        GT, // observed >  target
        GTE, // observed >= target
        LT, // observed <  target
        LTE // observed <= target
    }

    enum Outcome {
        Unresolved,
        Yes,
        No
    }

    /// Storage layout *and* the shape returned by `getMarket` / `getMarkets`.
    struct Market {
        uint256 id;
        address creator;
        string question;
        // ── resolution rule: fixed at creation, no setter exists ──
        string oracleUrl;
        string jsonPath;
        uint256 target;
        Comparator comparator;
        uint64 closeBlock;
        uint64 resolveBlock;
        uint256 scheduleId;
        // ── mutable state ──
        uint256 totalYes;
        uint256 totalNo;
        MarketState state;
        Outcome outcome;
        uint8 attempts;
        uint256 observedValue;
        string invalidReason;
    }

    /// Arguments to `createMarket`, grouped so the whole rule reads as one unit at the
    /// call site (and to keep the stack shallow).
    struct NewMarket {
        string question;
        string oracleUrl;
        string jsonPath;
        uint256 target;
        Comparator comparator;
        uint256 bettingSeconds;
        uint256 resolveDelaySeconds;
    }

    // ────────────────────────────── Constants ────────────────────────────

    /// Resolution attempts per market, booked up front as the Scheduler's `numCalls`,
    /// `RETRY_INTERVAL_BLOCKS` apart. `frequency * numCalls` must stay under the
    /// Scheduler's MAX_LIFESPAN of 10,000.
    uint32 public constant MAX_ATTEMPTS = 3;
    uint32 public constant RETRY_INTERVAL_BLOCKS = 200;

    /// Gas per scheduled execution — one HTTP call, one jq call, a few storage writes.
    uint32 public constant RESOLVE_GAS_LIMIT = 2_000_000;

    /// Scheduler TTL. Must cover trigger drift *and* async HTTP settlement, because the
    /// settlement replay re-runs Scheduler.execute() and re-checks the TTL.
    uint32 public constant SCHEDULER_TTL_BLOCKS = 150;

    /// Blocks the TEE executor has to fulfil the HTTP request.
    uint256 public constant HTTP_TTL_BLOCKS = 100;

    /// Registry slots to probe when picking a TEE executor.
    uint256 public constant EXECUTOR_PROBES = 8;

    /// Floor for the fee authorised per scheduled execution.
    uint256 public constant MIN_MAX_FEE_PER_GAS = 1 gwei;

    uint256 public constant MIN_BETTING_SECONDS = 30;
    uint256 public constant MIN_RESOLVE_DELAY_SECONDS = 15;
    uint256 public constant MAX_MARKET_SECONDS = 1 days;

    // ────────────────────────────── Storage ──────────────────────────────

    /// Assumed block time, used only to turn human durations into block counts.
    /// Ritual Chain ran ~195ms when this was written.
    uint256 public immutable blockTimeMs;

    uint256 public marketCount;
    mapping(uint256 => Market) private _markets;

    mapping(uint256 => mapping(address => uint256)) public yesStake;
    mapping(uint256 => mapping(address => uint256)) public noStake;
    mapping(uint256 => mapping(address => bool)) public settled;

    // ────────────────────────────── Events ───────────────────────────────

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        uint64 closeBlock,
        uint64 resolveBlock,
        uint256 scheduleId
    );
    /// The resolution rule, emitted separately from MarketCreated. None of these values
    /// can change afterwards — there is no setter.
    event ResolutionRuleSet(
        uint256 indexed marketId,
        string oracleUrl,
        string jsonPath,
        uint256 target,
        Comparator comparator
    );
    event BetPlaced(
        uint256 indexed marketId,
        address indexed bettor,
        bool isYes,
        uint256 amount
    );
    event ResolutionAttempted(
        uint256 indexed marketId,
        uint8 attempt,
        address executor
    );
    event ResolutionFailed(
        uint256 indexed marketId,
        uint8 attempt,
        string reason
    );
    event MarketResolved(
        uint256 indexed marketId,
        Outcome outcome,
        uint256 observedValue
    );
    event MarketInvalidated(uint256 indexed marketId, string reason);
    event WinningsClaimed(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );
    event StakeRefunded(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );

    // ────────────────────────────── Errors ───────────────────────────────

    error UnknownMarket();
    error OnlyScheduler();
    error BettingClosed();
    error ZeroStake();
    error NotResolved();
    error NotInvalid();
    error NothingToClaim();
    error AlreadySettled();
    error BadDuration();
    error EmptyString();
    error TransferFailed();

    constructor(uint256 blockTimeMs_) {
        if (blockTimeMs_ == 0) revert BadDuration();
        blockTimeMs = blockTimeMs_;

        // Let the Scheduler call back into this contract and draw execution fees from
        // this contract's RitualWallet balance.
        IScheduler(RitualChain.SCHEDULER).approveScheduler(
            RitualChain.SCHEDULER
        );
    }

    // ───────────────────────── Market lifecycle ──────────────────────────

    /**
     * Create a market and, in the same transaction, book its own resolution with the
     * Scheduler: `MAX_ATTEMPTS` executions starting at `resolveBlock`.
     */
    function createMarket(
        NewMarket calldata p
    ) external returns (uint256 marketId) {
        if (
            bytes(p.question).length == 0 ||
            bytes(p.oracleUrl).length == 0 ||
            bytes(p.jsonPath).length == 0
        ) revert EmptyString();
        if (
            p.bettingSeconds < MIN_BETTING_SECONDS ||
            p.resolveDelaySeconds < MIN_RESOLVE_DELAY_SECONDS ||
            p.bettingSeconds > MAX_MARKET_SECONDS ||
            p.resolveDelaySeconds > MAX_MARKET_SECONDS ||
            p.bettingSeconds > MAX_MARKET_SECONDS - p.resolveDelaySeconds
        ) revert BadDuration();

        uint256 closeBlock = block.number + _secondsToBlocks(p.bettingSeconds);
        uint256 resolveBlock = closeBlock +
            _secondsToBlocks(p.resolveDelaySeconds);
        if (
            closeBlock > type(uint64).max ||
            resolveBlock > type(uint32).max
        ) revert BadDuration();

        marketId = ++marketCount;
        Market storage m = _markets[marketId];
        m.id = marketId;
        m.creator = msg.sender;
        m.question = p.question;
        m.oracleUrl = p.oracleUrl;
        m.jsonPath = p.jsonPath;
        m.target = p.target;
        m.comparator = p.comparator;
        m.closeBlock = uint64(closeBlock);
        m.resolveBlock = uint64(resolveBlock);
        m.scheduleId = _scheduleResolution(marketId, uint64(resolveBlock));

        emit MarketCreated(
            marketId,
            msg.sender,
            p.question,
            m.closeBlock,
            m.resolveBlock,
            m.scheduleId
        );
        emit ResolutionRuleSet(
            marketId,
            p.oracleUrl,
            p.jsonPath,
            p.target,
            p.comparator
        );
    }

    function bet(uint256 marketId, bool isYes) external payable {
        Market storage m = _market(marketId);
        if (msg.value == 0) revert ZeroStake();
        if (m.state != MarketState.Open || block.number >= m.closeBlock)
            revert BettingClosed();

        if (isYes) {
            yesStake[marketId][msg.sender] += msg.value;
            m.totalYes += msg.value;
        } else {
            noStake[marketId][msg.sender] += msg.value;
            m.totalNo += msg.value;
        }

        emit BetPlaced(marketId, msg.sender, isYes, msg.value);
    }

    /**
     * Scheduler callback. `executionIndex` is written into calldata bytes 4-35 by the
     * Scheduler, so it must be the first parameter.
     *
     * Deliberately revert-free for anything that is not an authorisation failure: a
     * reverted execution would roll back the attempt counter, and the market could then
     * never reach `Invalid`.
     */
    function onScheduledResolve(
        uint256 executionIndex,
        uint256 marketId
    ) external {
        if (msg.sender != RitualChain.SCHEDULER) revert OnlyScheduler();

        Market storage m = _markets[marketId];
        if (m.closeBlock == 0 || executionIndex >= MAX_ATTEMPTS) return;
        if (
            m.state == MarketState.Resolved ||
            m.state == MarketState.Invalid ||
            block.number < m.resolveBlock
        ) return;

        uint8 attempt = uint8(executionIndex + 1);
        if (attempt <= m.attempts) return;

        m.attempts = attempt;
        m.state = MarketState.Resolving;

        address executor = _pickExecutor(marketId, executionIndex);
        if (executor == address(0)) {
            _fail(m, marketId, attempt, "no HTTP executor available");
            return;
        }

        emit ResolutionAttempted(marketId, attempt, executor);
        (bool ok, uint256 observedValue, string memory reason) = _readOracle(
            m,
            executor
        );
        if (!ok) {
            _fail(m, marketId, attempt, reason);
            return;
        }

        bool yesWon = _compare(observedValue, m.target, m.comparator);
        uint256 winningPool = yesWon ? m.totalYes : m.totalNo;
        if (winningPool == 0) {
            m.observedValue = observedValue;
            _invalidate(m, marketId, "empty winning pool");
            _cancelRemaining(m.scheduleId);
            return;
        }

        m.observedValue = observedValue;
        m.outcome = yesWon ? Outcome.Yes : Outcome.No;
        m.state = MarketState.Resolved;
        emit MarketResolved(marketId, m.outcome, observedValue);
        _cancelRemaining(m.scheduleId);
    }

    /// A failed oracle read is never interpreted as NO. Once the booked attempts are
    /// exhausted the market becomes refundable instead.
    function _fail(
        Market storage m,
        uint256 marketId,
        uint8 attempt,
        string memory reason
    ) private {
        emit ResolutionFailed(marketId, attempt, reason);
        if (attempt >= MAX_ATTEMPTS) _invalidate(m, marketId, reason);
    }

    function _invalidate(
        Market storage m,
        uint256 marketId,
        string memory reason
    ) private {
        m.state = MarketState.Invalid;
        m.invalidReason = reason;
        emit MarketInvalidated(marketId, reason);
    }

    // ────────────────────────────── Payouts ──────────────────────────────

    /// Pull-based, proportional share of the whole pool. No loops over participants.
    function claimWinnings(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Resolved) revert NotResolved();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 payout = _payout(m, marketId, msg.sender);
        if (payout == 0) revert NothingToClaim();

        settled[marketId][msg.sender] = true;
        emit WinningsClaimed(marketId, msg.sender, payout);
        _pay(msg.sender, payout);
    }

    /// Reclaim the original stake from an invalid market.
    function claimRefund(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Invalid) revert NotInvalid();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 amount = yesStake[marketId][msg.sender] +
            noStake[marketId][msg.sender];
        if (amount == 0) revert NothingToClaim();

        settled[marketId][msg.sender] = true;
        emit StakeRefunded(marketId, msg.sender, amount);
        _pay(msg.sender, amount);
    }

    /// `stake * totalPool / winningPool`, or 0 if this account backed the losing side.
    function _payout(
        Market storage m,
        uint256 marketId,
        address account
    ) private view returns (uint256) {
        bool yesWon = m.outcome == Outcome.Yes;
        uint256 stake = yesWon
            ? yesStake[marketId][account]
            : noStake[marketId][account];
        uint256 winningPool = yesWon ? m.totalYes : m.totalNo;
        if (stake == 0 || winningPool == 0) return 0;
        return (stake * (m.totalYes + m.totalNo)) / winningPool;
    }

    // ─────────────────────────────── Views ───────────────────────────────

    function getMarket(uint256 marketId) public view returns (Market memory m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
        // No transaction exists to flip Open → Closed, so the view does it.
        if (m.state == MarketState.Open && block.number >= m.closeBlock)
            m.state = MarketState.Closed;
    }

    /// Every market, newest first. A workshop has a handful; there is no pagination.
    function getMarkets() external view returns (Market[] memory all) {
        uint256 total = marketCount;
        all = new Market[](total);
        for (uint256 i = 0; i < total; i++) {
            all[i] = getMarket(total - i);
        }
    }

    function stakesOf(
        uint256 marketId,
        address account
    )
        external
        view
        returns (
            uint256 yes,
            uint256 no,
            bool alreadySettled,
            uint256 claimable
        )
    {
        Market storage m = _market(marketId);
        (yes, no, alreadySettled) = (
            yesStake[marketId][account],
            noStake[marketId][account],
            settled[marketId][account]
        );
        if (alreadySettled) return (yes, no, true, 0);

        if (m.state == MarketState.Resolved)
            claimable = _payout(m, marketId, account);
        else if (m.state == MarketState.Invalid) claimable = yes + no;
    }

    // ───────────────────────── Execution funding ─────────────────────────

    /// Prepay Scheduler + HTTP precompile fees. Anyone may top the contract up; the
    /// balance lives in RitualWallet under this contract's address, which is the
    /// `payer` of every scheduled execution.
    function fundExecution(uint256 lockDurationBlocks) external payable {
        if (msg.value == 0) revert ZeroStake();
        IRitualWallet(RitualChain.RITUAL_WALLET).deposit{value: msg.value}(
            lockDurationBlocks
        );
    }

    function executionBalance() external view returns (uint256) {
        return
            IRitualWallet(RitualChain.RITUAL_WALLET).balanceOf(address(this));
    }

    // ───────────────────── Ritual: oracle read path ──────────────────────

    /// HTTP (0x0801) → jq (0x0803), both inside this one scheduled transaction.
    function _readOracle(
        Market storage m,
        address executor
    ) private returns (bool ok, uint256 value, string memory reason) {
        bytes[] memory noSecrets = new bytes[](0);
        string[] memory noHeaders = new string[](0);
        bytes memory input = abi.encode(
            executor,
            noSecrets,
            HTTP_TTL_BLOCKS,
            noSecrets,
            bytes(""),
            m.oracleUrl,
            RitualChain.HTTP_GET,
            noHeaders,
            noHeaders,
            bytes(""),
            uint256(0),
            uint8(0),
            false
        );

        (bool called, bytes memory raw) = RitualChain.HTTP_PRECOMPILE.call(
            input
        );
        if (!called) return (false, 0, "HTTP precompile call failed");

        try this.decodeHttpResponse(raw) returns (
            uint16 status,
            bytes memory body,
            string memory errorMessage
        ) {
            if (bytes(errorMessage).length != 0)
                return (false, 0, errorMessage);
            if (status != 200) return (false, 0, "HTTP response was not 200");

            (bool jqOk, uint256 extracted) = _jqUint(
                m.jsonPath,
                string(body)
            );
            if (!jqOk) return (false, 0, "jq could not extract uint256");
            return (true, extracted, "");
        } catch Error(string memory decodeReason) {
            return (false, 0, decodeReason);
        } catch {
            return (false, 0, "malformed HTTP response");
        }
    }

    /**
     * Unwraps the short-running async envelope `(bytes simmedInput, bytes actualOutput)`
     * and the 5-field HTTP response inside it.
     *
     * External so `_readOracle` can call it through `try`. Reverting on malformed input
     * is exactly the signal the caller wants.
     */
    function decodeHttpResponse(
        bytes calldata raw
    )
        external
        pure
        returns (uint16 status, bytes memory body, string memory errorMessage)
    {
        (, bytes memory actualOutput) = abi.decode(raw, (bytes, bytes));
        // Empty during simulation, before the executor has run.
        require(actualOutput.length > 0, "async output not settled");
        (status, , , body, errorMessage) = abi.decode(
            actualOutput,
            (uint16, string[], string[], bytes, string)
        );
    }

    /// jq is synchronous. A wrong outputType returns ok=true with zero-length output,
    /// so the length check is load-bearing.
    function _jqUint(
        string memory query,
        string memory json
    ) private view returns (bool, uint256) {
        (bool ok, bytes memory result) = RitualChain.JQ_PRECOMPILE.staticcall(
            abi.encode(query, json, RitualChain.JQ_OUT_UINT256)
        );
        if (!ok || result.length < 32) return (false, 0);
        return (true, abi.decode(result, (uint256)));
    }

    function _pickExecutor(
        uint256 marketId,
        uint256 executionIndex
    ) private view returns (address) {
        uint256 seed = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    address(this),
                    marketId,
                    executionIndex
                )
            )
        );
        try
            ITEEServiceRegistry(RitualChain.TEE_SERVICE_REGISTRY)
                .pickServiceByCapability(
                    RitualChain.CAPABILITY_HTTP_CALL,
                    true,
                    seed,
                    EXECUTOR_PROBES
                )
        returns (address executor, bool found) {
            return found ? executor : address(0);
        } catch {
            return address(0);
        }
    }

    // ────────────────────── Ritual: scheduling ───────────────────────────

    function _scheduleResolution(
        uint256 marketId,
        uint64 resolveBlock
    ) private returns (uint256 callId) {
        uint256 maxFeePerGas = block.basefee;
        if (maxFeePerGas < MIN_MAX_FEE_PER_GAS)
            maxFeePerGas = MIN_MAX_FEE_PER_GAS;

        callId = IScheduler(RitualChain.SCHEDULER).schedule(
            abi.encodeWithSelector(
                this.onScheduledResolve.selector,
                uint256(0),
                marketId
            ),
            RESOLVE_GAS_LIMIT,
            uint32(resolveBlock),
            MAX_ATTEMPTS,
            RETRY_INTERVAL_BLOCKS,
            SCHEDULER_TTL_BLOCKS,
            maxFeePerGas,
            0,
            0,
            address(this)
        );
    }

    /// Scheduler cancellation must never turn a completed resolution into a retry.
    function _cancelRemaining(uint256 scheduleId) private {
        if (scheduleId == 0) return;
        RitualChain.SCHEDULER.call(
            abi.encodeCall(IScheduler.cancel, (scheduleId))
        );
    }

    // ────────────────────────────── Helpers ──────────────────────────────

    function _market(uint256 marketId) private view returns (Market storage m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
    }

    function _compare(
        uint256 observed,
        uint256 target,
        Comparator comparator
    ) private pure returns (bool) {
        if (comparator == Comparator.GT) return observed > target;
        if (comparator == Comparator.GTE) return observed >= target;
        if (comparator == Comparator.LT) return observed < target;
        return observed <= target;
    }

    function _secondsToBlocks(
        uint256 seconds_
    ) private view returns (uint256 blocks) {
        blocks = (seconds_ * 1000) / blockTimeMs;
        if (blocks == 0) blocks = 1;
    }

    function _pay(address to, uint256 amount) private {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// Scheduler gas refunds land in RitualWallet, but accept plain transfers anyway.
    receive() external payable {}
}
