// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RitualPredict} from "./RitualPredict.sol";
import {RitualChain} from "./ritual/RitualChain.sol";
import {
    MockScheduler,
    MockRitualWallet,
    MockTEEServiceRegistry,
    MockHttpPrecompile,
    MockJqPrecompile
} from "./mocks/RitualMocks.sol";

contract RitualPredictTest is Test {
    uint256 private constant BLOCK_TIME_MS = 1_000;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA701);
    address private constant EXECUTOR_ONE = address(0xE1);
    address private constant EXECUTOR_TWO = address(0xE2);

    RitualPredict private predict;
    MockScheduler private scheduler;
    MockRitualWallet private wallet;
    MockTEEServiceRegistry private registry;
    MockHttpPrecompile private http;
    MockJqPrecompile private jq;

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        uint64 closeBlock,
        uint64 resolveBlock,
        uint256 scheduleId
    );
    event ResolutionRuleSet(
        uint256 indexed marketId,
        string oracleUrl,
        string jsonPath,
        uint256 target,
        RitualPredict.Comparator comparator
    );
    event ResolutionAttempted(
        uint256 indexed marketId,
        uint8 attempt,
        address executor
    );

    function setUp() public {
        _installMocks();
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(CAROL, 100 ether);
        predict = new RitualPredict(BLOCK_TIME_MS);
        registry.setExecutor(EXECUTOR_ONE, true);
        http.setResponse(200, '{"price":5000}', "");
        jq.setValue(5_000);
    }

    function testCreateMarketStoresRuleEmitsEventsAndSchedules() public {
        uint64 closeBlock = uint64(block.number + 30);
        uint64 resolveBlock = uint64(uint256(closeBlock) + 15);
        vm.expectEmit(true, true, false, true, address(predict));
        emit MarketCreated(
            1,
            address(this),
            "ETH over 4000?",
            closeBlock,
            resolveBlock,
            1
        );
        vm.expectEmit(true, false, false, true, address(predict));
        emit ResolutionRuleSet(
            1,
            "https://oracle.example/eth",
            ".price",
            4_000,
            RitualPredict.Comparator.GTE
        );

        uint256 marketId = _create(RitualPredict.Comparator.GTE, 4_000);
        RitualPredict.Market memory m = predict.getMarket(marketId);
        assertEq(m.id, 1);
        assertEq(m.creator, address(this));
        assertEq(m.question, "ETH over 4000?");
        assertEq(m.oracleUrl, "https://oracle.example/eth");
        assertEq(m.jsonPath, ".price");
        assertEq(m.target, 4_000);
        assertEq(uint256(m.comparator), uint256(RitualPredict.Comparator.GTE));
        assertEq(m.closeBlock, closeBlock);
        assertEq(m.resolveBlock, resolveBlock);
        assertEq(m.scheduleId, 1);

        assertEq(scheduler.callTarget(1), address(predict));
        assertEq(
            scheduler.callData(1),
            abi.encodeWithSelector(
                predict.onScheduledResolve.selector,
                uint256(0),
                marketId
            )
        );
        assertEq(scheduler.callGasLimit(1), predict.RESOLVE_GAS_LIMIT());
        assertEq(scheduler.callStartBlock(1), resolveBlock);
        assertEq(scheduler.callNumCalls(1), predict.MAX_ATTEMPTS());
        assertEq(scheduler.callFrequency(1), predict.RETRY_INTERVAL_BLOCKS());
        assertEq(scheduler.callTtl(1), predict.SCHEDULER_TTL_BLOCKS());
        assertGe(
            scheduler.callMaxFeePerGas(1),
            predict.MIN_MAX_FEE_PER_GAS()
        );
        assertEq(scheduler.callMaxPriorityFeePerGas(1), 0);
        assertEq(scheduler.callValue(1), 0);
        assertEq(scheduler.callPayer(1), address(predict));
        assertEq(scheduler.getCallState(1), 0);
    }

    function testCreateMarketRejectsEmptyQuestion() public {
        RitualPredict.NewMarket memory p = _params();
        p.question = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);
    }

    function testCreateMarketRejectsEmptyOracleUrl() public {
        RitualPredict.NewMarket memory p = _params();
        p.oracleUrl = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);
    }

    function testCreateMarketRejectsEmptyJqPath() public {
        RitualPredict.NewMarket memory p = _params();
        p.jsonPath = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);
    }

    function testCreateMarketRejectsInvalidDuration() public {
        RitualPredict.NewMarket memory p = _params();
        p.bettingSeconds = 29;
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);
    }

    function testBetsTrackBothSidesAndPools() public {
        uint256 marketId = _create(RitualPredict.Comparator.GTE, 4_000);
        vm.prank(ALICE);
        predict.bet{value: 2 ether}(marketId, true);
        vm.prank(BOB);
        predict.bet{value: 3 ether}(marketId, false);

        RitualPredict.Market memory m = predict.getMarket(marketId);
        assertEq(predict.yesStake(marketId, ALICE), 2 ether);
        assertEq(predict.noStake(marketId, BOB), 3 ether);
        assertEq(m.totalYes, 2 ether);
        assertEq(m.totalNo, 3 ether);
    }

    function testFundExecutionUsesRitualWalletMock() public {
        predict.fundExecution{value: 1 ether}(1_000);
        assertEq(predict.executionBalance(), 1 ether);
        assertGt(wallet.lockUntil(address(predict)), block.number);
    }

    function testBetRejectsZeroValueAndClosedMarket() public {
        uint256 marketId = _create(RitualPredict.Comparator.GTE, 4_000);
        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        predict.bet(marketId, true);

        RitualPredict.Market memory m = predict.getMarket(marketId);
        vm.roll(m.closeBlock);
        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.BettingClosed.selector);
        predict.bet{value: 1 ether}(marketId, true);
    }

    function testScheduledResolutionProducesYesAndCancelsRemainder() public {
        uint256 marketId = _create(RitualPredict.Comparator.GTE, 4_000);
        vm.prank(ALICE);
        predict.bet{value: 1 ether}(marketId, true);

        vm.expectEmit(true, false, false, true, address(predict));
        emit ResolutionAttempted(marketId, 1, EXECUTOR_ONE);
        _invokeAtResolve(marketId, 0);

        RitualPredict.Market memory m = predict.getMarket(marketId);
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Resolved));
        assertEq(uint256(m.outcome), uint256(RitualPredict.Outcome.Yes));
        assertEq(m.observedValue, 5_000);
        assertGt(http.lastInput().length, 0);
        assertEq(scheduler.getCallState(m.scheduleId), 3);
    }

    function testScheduledResolutionProducesNo() public {
        uint256 marketId = _create(RitualPredict.Comparator.GT, 6_000);
        vm.prank(BOB);
        predict.bet{value: 1 ether}(marketId, false);
        _invokeAtResolve(marketId, 0);

        RitualPredict.Market memory m = predict.getMarket(marketId);
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Resolved));
        assertEq(uint256(m.outcome), uint256(RitualPredict.Outcome.No));
    }

    function testRetryAfterFirstOracleFailureUsesFreshExecutor() public {
        uint256 marketId = _create(RitualPredict.Comparator.GTE, 4_000);
        vm.prank(ALICE);
        predict.bet{value: 1 ether}(marketId, true);
        http.setShouldRevert(true);
        _invokeAtResolve(marketId, 0);

        RitualPredict.Market memory failed = predict.getMarket(marketId);
        assertEq(failed.attempts, 1);
        assertEq(uint256(failed.state), uint256(RitualPredict.MarketState.Resolving));

        http.setShouldRevert(false);
        registry.setExecutor(EXECUTOR_TWO, true);
        vm.expectEmit(true, false, false, true, address(predict));
        emit ResolutionAttempted(marketId, 2, EXECUTOR_TWO);
        _invokeAtResolve(marketId, 1);

        RitualPredict.Market memory resolved = predict.getMarket(marketId);
        assertEq(resolved.attempts, 2);
        assertEq(uint256(resolved.state), uint256(RitualPredict.MarketState.Resolved));
        assertGt(http.lastInput().length, 0);
    }

    function testThreeFailuresInvalidateAndAllowRefunds() public {
        uint256 marketId = _create(RitualPredict.Comparator.GTE, 4_000);
        vm.prank(ALICE);
        predict.bet{value: 2 ether}(marketId, true);
        vm.prank(BOB);
        predict.bet{value: 3 ether}(marketId, false);
        http.setShouldRevert(true);

        _invokeAtResolve(marketId, 0);
        _invokeAtResolve(marketId, 1);
        _invokeAtResolve(marketId, 2);

        RitualPredict.Market memory m = predict.getMarket(marketId);
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Invalid));
        assertEq(m.attempts, 3);
        uint256 aliceBefore = ALICE.balance;
        vm.prank(ALICE);
        predict.claimRefund(marketId);
        assertEq(ALICE.balance, aliceBefore + 2 ether);
        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        predict.claimRefund(marketId);
        assertEq(BOB.balance, bobBefore + 3 ether);
    }

    function testEmptyWinningSideInvalidatesAndRefunds() public {
        uint256 marketId = _create(RitualPredict.Comparator.GTE, 4_000);
        vm.prank(BOB);
        predict.bet{value: 3 ether}(marketId, false);
        _invokeAtResolve(marketId, 0);

        RitualPredict.Market memory m = predict.getMarket(marketId);
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Invalid));
        assertEq(m.observedValue, 5_000);
        vm.prank(BOB);
        predict.claimRefund(marketId);
        assertTrue(predict.settled(marketId, BOB));
    }

    function testWinningPayoutsAreProportionalAndClaimsAreOneTime() public {
        uint256 marketId = _create(RitualPredict.Comparator.GTE, 4_000);
        vm.prank(ALICE);
        predict.bet{value: 2 ether}(marketId, true);
        vm.prank(BOB);
        predict.bet{value: 1 ether}(marketId, true);
        vm.prank(CAROL);
        predict.bet{value: 3 ether}(marketId, false);
        _invokeAtResolve(marketId, 0);

        uint256 aliceBefore = ALICE.balance;
        vm.prank(ALICE);
        predict.claimWinnings(marketId);
        assertEq(ALICE.balance, aliceBefore + 4 ether);
        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        predict.claimWinnings(marketId);
        assertEq(BOB.balance, bobBefore + 2 ether);
        vm.prank(CAROL);
        vm.expectRevert(RitualPredict.NothingToClaim.selector);
        predict.claimWinnings(marketId);
        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        predict.claimWinnings(marketId);
    }

    function testOnlySchedulerCanResolveAndCallbackIsIdempotent() public {
        uint256 marketId = _create(RitualPredict.Comparator.GTE, 4_000);
        vm.expectRevert(RitualPredict.OnlyScheduler.selector);
        predict.onScheduledResolve(0, marketId);

        vm.prank(ALICE);
        predict.bet{value: 1 ether}(marketId, true);
        _invokeAtResolve(marketId, 0);
        RitualPredict.Market memory first = predict.getMarket(marketId);
        (bool ok, ) = scheduler.invoke(first.scheduleId, 1);
        assertTrue(ok);
        RitualPredict.Market memory second = predict.getMarket(marketId);
        assertEq(second.attempts, first.attempts);
        assertEq(uint256(second.state), uint256(RitualPredict.MarketState.Resolved));
    }

    function testMalformedHttpAndJqFailuresAreRetryable() public {
        uint256 malformedMarket = _create(RitualPredict.Comparator.GTE, 4_000);
        http.setMalformed(true);
        _invokeAtResolve(malformedMarket, 0);
        assertEq(
            uint256(predict.getMarket(malformedMarket).state),
            uint256(RitualPredict.MarketState.Resolving)
        );

        http.setMalformed(false);
        jq.setEmptyResult(true);
        uint256 jqMarket = _create(RitualPredict.Comparator.GTE, 4_000);
        _invokeAtResolve(jqMarket, 0);
        assertEq(
            uint256(predict.getMarket(jqMarket).state),
            uint256(RitualPredict.MarketState.Resolving)
        );
    }

    function testUnavailableExecutorIsRetryable() public {
        uint256 marketId = _create(RitualPredict.Comparator.GTE, 4_000);
        registry.setExecutor(address(0), false);
        _invokeAtResolve(marketId, 0);
        RitualPredict.Market memory m = predict.getMarket(marketId);
        assertEq(m.attempts, 1);
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Resolving));
    }

    function testCancellationFailureDoesNotBreakResolution() public {
        uint256 marketId = _create(RitualPredict.Comparator.GTE, 4_000);
        vm.prank(ALICE);
        predict.bet{value: 1 ether}(marketId, true);
        scheduler.setRevertOnCancel(true);
        _invokeAtResolve(marketId, 0);
        assertEq(
            uint256(predict.getMarket(marketId).state),
            uint256(RitualPredict.MarketState.Resolved)
        );
    }

    function _installMocks() private {
        MockScheduler schedulerImplementation = new MockScheduler();
        MockRitualWallet walletImplementation = new MockRitualWallet();
        MockTEEServiceRegistry registryImplementation = new MockTEEServiceRegistry();
        MockHttpPrecompile httpImplementation = new MockHttpPrecompile();
        MockJqPrecompile jqImplementation = new MockJqPrecompile();
        vm.etch(RitualChain.SCHEDULER, address(schedulerImplementation).code);
        vm.etch(RitualChain.RITUAL_WALLET, address(walletImplementation).code);
        vm.etch(
            RitualChain.TEE_SERVICE_REGISTRY,
            address(registryImplementation).code
        );
        vm.etch(RitualChain.HTTP_PRECOMPILE, address(httpImplementation).code);
        vm.etch(RitualChain.JQ_PRECOMPILE, address(jqImplementation).code);
        scheduler = MockScheduler(RitualChain.SCHEDULER);
        wallet = MockRitualWallet(RitualChain.RITUAL_WALLET);
        registry = MockTEEServiceRegistry(RitualChain.TEE_SERVICE_REGISTRY);
        http = MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE);
        jq = MockJqPrecompile(RitualChain.JQ_PRECOMPILE);
    }

    function _params() private pure returns (RitualPredict.NewMarket memory p) {
        p = RitualPredict.NewMarket({
            question: "ETH over 4000?",
            oracleUrl: "https://oracle.example/eth",
            jsonPath: ".price",
            target: 4_000,
            comparator: RitualPredict.Comparator.GTE,
            bettingSeconds: 30,
            resolveDelaySeconds: 15
        });
    }

    function _create(
        RitualPredict.Comparator comparator,
        uint256 target
    ) private returns (uint256 marketId) {
        RitualPredict.NewMarket memory p = _params();
        p.comparator = comparator;
        p.target = target;
        marketId = predict.createMarket(p);
    }

    function _invokeAtResolve(uint256 marketId, uint256 executionIndex) private {
        RitualPredict.Market memory m = predict.getMarket(marketId);
        if (block.number < m.resolveBlock) vm.roll(m.resolveBlock);
        (bool ok, bytes memory result) = scheduler.invoke(
            m.scheduleId,
            executionIndex
        );
        assertTrue(ok, string(result));
    }
}
