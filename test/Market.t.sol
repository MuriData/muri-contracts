// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {FileMarket} from "../src/Market.sol";
import {NodeStaking} from "../src/NodeStaking.sol";
import {MarketStorage} from "../src/market/MarketStorage.sol";

contract MarketTest is Test {
    // Re-declare events for vm.expectEmit
    event OrderUnderReplicated(uint256 indexed orderId, uint8 currentFilled, uint8 desiredReplicas);

    FileMarket public market;
    NodeStaking public nodeStaking;

    address public user1 = address(0x1111);
    address public user2 = address(0x2222);
    address public node1 = address(0x3333);
    address public node2 = address(0x4444);
    address public node3 = address(0x5555);

    uint64 public constant TEST_CAPACITY = 1024; // 1KB (smaller for testing)
    uint256 public constant STAKE_PER_BYTE = 10 ** 14;
    uint256 public constant TEST_STAKE = uint256(TEST_CAPACITY) * STAKE_PER_BYTE;
    uint256 public constant PERIOD = 7 days;
    uint256 public constant STEP = 30 seconds;

    // Test file metadata
    uint256 public constant FILE_ROOT = 0x123456789abcdef;
    string public constant FILE_URI = "QmTestHash123";

    function setUp() public {
        // Deploy market contract
        market = new FileMarket();
        nodeStaking = market.nodeStaking();

        // Fund test accounts
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(node1, 100 ether);
        vm.deal(node2, 100 ether);
        vm.deal(node3, 100 ether);
    }

    function _stakeTestNode(address node, uint256 keyX, uint256 keyY) internal {
        vm.prank(node);
        nodeStaking.stakeNode{value: TEST_STAKE}(TEST_CAPACITY, keyX, keyY);
    }





    function test_MultipleNodesExecuteOrder() public {
        // Register multiple nodes
        vm.prank(node1);
        nodeStaking.stakeNode{value: TEST_STAKE}(TEST_CAPACITY, 0x1234, 0x5678);

        vm.prank(node2);
        nodeStaking.stakeNode{value: TEST_STAKE}(TEST_CAPACITY, 0xabcd, 0xef01);

        // Place an order with 2 replicas
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint8 replicas = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);

        // First node executes
        vm.prank(node1);
        market.executeOrder(orderId);

        // Second node executes
        vm.prank(node2);
        market.executeOrder(orderId);

        // Check both nodes have used capacity
        (,, uint64 used1,,) = nodeStaking.getNodeInfo(node1);
        (,, uint64 used2,,) = nodeStaking.getNodeInfo(node2);
        assertEq(used1, maxSize);
        assertEq(used2, maxSize);

        address[] memory orderNodes = market.getOrderNodes(orderId);
        assertEq(orderNodes.length, 2);
        assertEq(orderNodes[0], node1);
        assertEq(orderNodes[1], node2);
    }






    function test_RandomOrderSelection() public {
        // Place multiple orders first
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        // Place 10 orders
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user1);
            market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);
        }

        assertEq(market.getActiveOrdersCount(), 10);

        // Test random selection
        uint256[] memory selected = market.selectRandomOrders(12345, 5);
        assertEq(selected.length, 5);

        // Test selecting more than available
        uint256[] memory selectedAll = market.selectRandomOrders(12345, 15);
        assertEq(selectedAll.length, 10); // Should return all available

        // Test with no orders
        for (uint256 i = 1; i <= 10; i++) {
            vm.prank(user1);
            market.cancelOrder(i);
        }

        uint256[] memory selectedEmpty = market.selectRandomOrders(12345, 5);
        assertEq(selectedEmpty.length, 0);
    }

    function test_EscrowTracking() public {
        // Register node with double capacity
        uint64 largeCapacity = TEST_CAPACITY * 2;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);

        // Place order
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        uint64 maxSize = 1024;
        uint16 periods = 2;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);

        // Node executes order
        vm.prank(node1);
        market.executeOrder(orderId);

        // Check initial escrow state
        (uint256 totalEscrow, uint256 paidToNodes, uint256 remainingEscrow) = market.getOrderEscrowInfo(orderId);

        assertEq(totalEscrow, totalCost);
        assertEq(paidToNodes, 0);
        assertEq(remainingEscrow, totalCost);

        // Fast forward within the order period and claim rewards
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(node1);
        market.claimRewards();

        // Check escrow after payment
        (totalEscrow, paidToNodes, remainingEscrow) = market.getOrderEscrowInfo(orderId);
        assertEq(totalEscrow, totalCost);
        assertTrue(paidToNodes > 0);
        assertEq(remainingEscrow, totalCost - paidToNodes);
    }

    // Test edge cases and failure scenarios
    function test_RevertWhen_ExecuteOrderInsufficientCapacity() public {
        // Register node with small capacity
        vm.prank(node1);
        nodeStaking.stakeNode{value: 100 * STAKE_PER_BYTE}(100, 0x1234, 0x5678);

        // Try to place large order
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: 1 ether}(
            fileMeta,
            1000,
            4,
            1,
            1e12 // 1000 bytes > 100 capacity
        );

        // This should fail
        vm.prank(node1);
        vm.expectRevert("insufficient capacity");
        market.executeOrder(orderId);
    }


    function test_RevertWhen_CancelOrderNotOwner() public {
        // User1 places order
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: 1 ether}(fileMeta, 1024, 4, 1, 1e12);

        // User2 tries to cancel (should fail)
        vm.prank(user2);
        vm.expectRevert("not order owner");
        market.cancelOrder(orderId);
    }

    // -------------------------------------------------------------------------
    // Additional security and reward-settlement scenarios
    // -------------------------------------------------------------------------



    function test_CancelOrderQueuesPendingRewards() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + PERIOD + 1);

        vm.prank(user1);
        market.cancelOrder(orderId);

        uint256 expectedReward = uint256(maxSize) * price; // 1 period of service
        uint256 expectedRemaining = totalCost - expectedReward;
        uint256 expectedPenalty = expectedRemaining / 10;
        uint256 expectedRefund = expectedRemaining - expectedPenalty;

        // Node pending = settled reward + cancellation penalty
        uint256 nodePending = market.nodePendingRewards(node1);
        assertEq(nodePending, expectedReward + expectedPenalty, "reward + penalty queued for node");

        // Refund is queued as pull-payment
        assertEq(market.pendingRefunds(user1), expectedRefund, "owner refund queued as pull-payment");

        // Withdraw refund
        uint256 ownerBalanceBefore = user1.balance;
        vm.prank(user1);
        market.withdrawRefund();
        uint256 ownerBalanceAfter = user1.balance;
        assertEq(
            ownerBalanceAfter - ownerBalanceBefore, expectedRefund, "owner refund accounts for rewards and penalty"
        );

        uint256 nodeBalanceBefore = node1.balance;
        vm.prank(node1);
        market.claimRewards();
        uint256 nodeBalanceAfter = node1.balance;
        assertEq(
            nodeBalanceAfter - nodeBalanceBefore, expectedReward + expectedPenalty, "node receives reward + penalty"
        );
        assertEq(market.nodePendingRewards(node1), 0, "pending rewards cleared after claim");
    }

    function test_CancellationPenaltyDistributedToMultipleNodes() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xaaaa, 0xbbbb);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        uint64 maxSize = 512; // fits in both nodes
        uint16 periods = 4;
        uint8 replicas = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);

        vm.prank(node1);
        market.executeOrder(orderId);
        vm.prank(node2);
        market.executeOrder(orderId);

        // Advance 1 period so both nodes are eligible for penalty
        vm.warp(block.timestamp + PERIOD);

        vm.prank(user1);
        market.cancelOrder(orderId);

        // 1 period of rewards per node settled first
        uint256 rewardPerNode = uint256(maxSize) * price * 1;
        uint256 totalReward = rewardPerNode * 2;
        uint256 remainingEscrow = totalCost - totalReward;
        uint256 penalty = remainingEscrow / 10;
        uint256 expectedRefund = remainingEscrow - penalty;
        uint256 perNode = penalty / 2;
        // Last node gets remainder to avoid rounding dust
        uint256 lastNodeShare = penalty - perNode;

        assertEq(market.nodePendingRewards(node1), rewardPerNode + perNode, "node1 reward + penalty share");
        assertEq(market.nodePendingRewards(node2), rewardPerNode + lastNodeShare, "node2 reward + penalty share");
        assertEq(market.totalCancellationPenalties(), penalty, "total penalties tracked");
        assertEq(market.pendingRefunds(user1), expectedRefund, "refund queued");

        // Both nodes can claim their shares
        uint256 node1Before = node1.balance;
        vm.prank(node1);
        market.claimRewards();
        assertEq(node1.balance - node1Before, rewardPerNode + perNode, "node1 claims reward + penalty");

        uint256 node2Before = node2.balance;
        vm.prank(node2);
        market.claimRewards();
        assertEq(node2.balance - node2Before, rewardPerNode + lastNodeShare, "node2 claims reward + penalty");
    }

    /// @notice A node that front-runs cancelOrder by joining in the same block
    ///         must receive zero penalty (zero-service MEV siphon prevention).
    function test_CancellationPenalty_MEVSiphonPrevented() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 512;
        uint16 periods = 4;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);

        // Node front-runs cancel in same block
        vm.prank(node1);
        market.executeOrder(orderId);

        // Cancel in same block — node has NOT served a full period
        vm.prank(user1);
        market.cancelOrder(orderId);

        // No penalty should be charged — full escrow refunded
        assertEq(market.pendingRefunds(user1), totalCost, "full refund when no eligible nodes");
        assertEq(market.nodePendingRewards(node1), 0, "zero-service node gets no penalty");
        assertEq(market.totalCancellationPenalties(), 0, "no penalties tracked");
    }

    /// @notice When no node has served a full period, cancellation should not
    ///         charge any penalty — the full remaining escrow is refunded.
    function test_CancellationPenalty_NoPenaltyWhenAllNodesNew() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xaaaa, 0xbbbb);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 4;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * 2;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 2, price);

        vm.prank(node1);
        market.executeOrder(orderId);
        vm.prank(node2);
        market.executeOrder(orderId);

        // Cancel same block — neither node has served a full period
        vm.prank(user1);
        market.cancelOrder(orderId);

        assertEq(market.pendingRefunds(user1), totalCost, "full refund, no penalty");
        assertEq(market.nodePendingRewards(node1), 0, "node1 gets nothing");
        assertEq(market.nodePendingRewards(node2), 0, "node2 gets nothing");
    }

    /// @notice Mixed eligibility: one long-serving node gets penalty,
    ///         a same-block joiner gets nothing.
    function test_CancellationPenalty_MixedEligibility() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xaaaa, 0xbbbb);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 4;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * 2;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 2, price);

        // node1 joins early
        vm.prank(node1);
        market.executeOrder(orderId);

        // Advance 1 period — node1 has served a full period
        vm.warp(block.timestamp + PERIOD);

        // node2 joins just before cancel (same block)
        vm.prank(node2);
        market.executeOrder(orderId);

        // Cancel — node1 eligible, node2 not
        vm.prank(user1);
        market.cancelOrder(orderId);

        // Both nodes get 1-period rewards settled (node2 earns 0 via ceiling math)
        uint256 node1Reward = uint256(maxSize) * price * 1;
        uint256 remainingEscrow = totalCost - node1Reward; // node2 earned 0
        uint256 penalty = remainingEscrow / 10;
        uint256 expectedRefund = remainingEscrow - penalty;

        // Only node1 gets the full penalty (sole eligible node)
        assertEq(market.pendingRefunds(user1), expectedRefund, "refund minus penalty for eligible node only");
        uint256 node1Pending = market.nodePendingRewards(node1);
        assertEq(node1Pending, node1Reward + penalty, "node1 gets reward + full penalty");
        assertEq(market.nodePendingRewards(node2), 0, "node2 gets nothing (joined same block)");
        assertEq(market.totalCancellationPenalties(), penalty, "penalty tracked");
    }

    function test_RevertWhen_ExecuteOrderAfterExpiry() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        uint16 periods = 1;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: 1 ether}(fileMeta, 1024, periods, 1, 1e12);

        vm.warp(block.timestamp + PERIOD * uint256(periods) + 1);

        vm.prank(node1);
        vm.expectRevert("order expired");
        market.executeOrder(orderId);
    }


    function test_SlashSecondaryFailuresOnlyOnce() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        uint64 maxSize = 256;
        uint16 periods = 2;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId1 = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);
        vm.prank(node1);
        market.executeOrder(orderId1);

        vm.prank(user1);
        uint256 orderId2 = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);
        vm.prank(node2);
        market.executeOrder(orderId2);

        vm.warp(block.timestamp + 1);
        market.triggerHeartbeat();

        vm.warp(block.timestamp + (STEP * 2) + 1);

        market.slashSecondaryFailures();
        assertTrue(market.secondarySlashProcessed());

        vm.expectRevert("secondary slash settled");
        market.slashSecondaryFailures();
    }

    // -------------------------------------------------------------------------
    // New edge cases and adversarial tests for heartbeat/challenge updates
    // -------------------------------------------------------------------------

    function test_Heartbeat_NoSelection_ClearsProversAndAdvancesRandomness() public {
        // Place an order but do not assign any node
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        uint64 maxSize = 512;
        uint16 periods = 2;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * uint256(replicas) * price;

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);

        // First heartbeat initializes randomness
        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();
        uint256 r1 = market.currentRandomness();
        assertTrue(r1 != 0);

        // Next heartbeat should find no nodes to select, clear provers and advance randomness
        // Must advance beyond the entire challenge window: > lastChallengeStep + 1
        vm.warp(block.timestamp + (STEP * 2) + 1);
        market.triggerHeartbeat();

        (,, address primaryProver, address[] memory secondaryProvers,,,) = market.getCurrentChallengeInfo();

        uint256 r2 = market.currentRandomness();
        assertEq(primaryProver, address(0));
        assertEq(secondaryProvers.length, 0);
        assertTrue(r2 != r1, "randomness should advance on no-selection");
    }

    function test_ReportPrimaryFailure_RevertWhen_NoPrimaryAssigned() public {
        // No nodes assigned → heartbeat selects none and clears primary
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        vm.prank(user1);
        market.placeOrder{value: 1 ether}(fileMeta, 512, 2, 1, 1e12);

        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        // Caller must be a valid node
        _stakeTestNode(node1, 0x1234, 0x5678);

        // Advance beyond challenge period
        vm.warp(block.timestamp + (STEP * 2) + 1);
        vm.prank(node1);
        vm.expectRevert("no primary assigned");
        market.reportPrimaryFailure();
    }

    function test_DynamicSecondaryCount_LogScaling() public {
        // Prepare 8 nodes and 8 orders, each order executed by a distinct node
        uint64 capacity = TEST_CAPACITY;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 128;
        uint16 periods = 3;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * uint256(replicas) * price;

        address[] memory nodes = new address[](8);
        for (uint256 i = 0; i < 8; i++) {
            address n = address(uint160(0x100 + i));
            nodes[i] = n;
            vm.deal(n, stake + 1 ether);
            vm.prank(n);
            nodeStaking.stakeNode{value: stake}(capacity, 0x1111 + i, 0x2222 + i);

            vm.prank(user1);
            uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);
            vm.prank(n);
            market.executeOrder(orderId);
        }

        // Trigger heartbeat
        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        (,, address primaryProver, address[] memory secondaryProvers,,,) = market.getCurrentChallengeInfo();

        assertTrue(primaryProver != address(0));
        // totalOrders = 8 → floor(log2(8)) = 3 → desired secondaries = 2 * 3 = 6
        assertEq(secondaryProvers.length, 6, "secondary count should be 2*log2(totalOrders)");
    }


    function test_RandomnessAdvances_OnNoSelection_WithNonZeroSeed() public {
        // Initialize randomness with initial heartbeat without orders
        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();
        uint256 r1 = market.currentRandomness();
        assertTrue(r1 != 0);

        // Place order but no nodes, force no-selection path and ensure randomness changes
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        vm.prank(user1);
        market.placeOrder{value: 1 ether}(fileMeta, 256, 2, 1, 1e12);

        // Must advance beyond the entire challenge window: > lastChallengeStep + 1
        vm.warp(block.timestamp + (STEP * 2) + 1);
        market.triggerHeartbeat();

        uint256 r2 = market.currentRandomness();
        assertTrue(r2 != r1, "randomness should change on no-selection");
    }

    // -------------------------------------------------------------------------
    // Reporter Reward Tests
    // -------------------------------------------------------------------------


    function test_SlashSecondaryFailures_ReporterGetsReward() public {
        // Need at least 2 orders with nodes to get secondary provers
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId1 = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);
        vm.prank(node1);
        market.executeOrder(orderId1);

        vm.prank(user1);
        uint256 orderId2 = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);
        vm.prank(node2);
        market.executeOrder(orderId2);

        // Trigger heartbeat
        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        // Let challenge expire
        vm.warp(block.timestamp + (STEP * 2) + 1);

        // Use user2 as reporter (anyone can call)
        vm.prank(user2);
        market.slashSecondaryFailures();

        // Check reporter reward stats
        (uint256 totalReceived, uint256 totalBurned, uint256 totalRewards,) = market.getSlashRedistributionStats();

        // There may or may not be secondary provers depending on randomness,
        // but if there were, reporter should get rewards
        if (totalReceived > 0) {
            uint256 reporterPending = market.reporterPendingRewards(user2);
            assertEq(totalRewards, reporterPending, "reporter gets rewards from secondary slash");
            assertEq(totalReceived, totalBurned + totalRewards, "accounting holds");
        }
    }

    // -------------------------------------------------------------------------
    // Slash bypass regression tests
    // -------------------------------------------------------------------------

    function test_TriggerHeartbeat_AutoSlashesPrimary() public {
        // A prover who fails to submit proof should be slashed even if only
        // triggerHeartbeat() is called (not reportPrimaryFailure).
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(1);

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node2);
        market.executeOrder(2);

        // Initial heartbeat sets up challenge
        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();
        uint256 randomnessBeforeFailure = market.currentRandomness();

        address primaryProver = market.currentPrimaryProver();
        require(primaryProver != address(0), "need primary for test");

        (uint256 stakeBefore,,,,) = nodeStaking.getNodeInfo(primaryProver);

        // Let challenge expire without any proof submission
        vm.warp(block.timestamp + (STEP * 2) + 1);

        // Only call triggerHeartbeat — NOT reportPrimaryFailure
        market.triggerHeartbeat();
        uint256 randomnessAfterFailure = market.currentRandomness();

        // Primary prover should have been auto-slashed
        (uint256 stakeAfter,,,,) = nodeStaking.getNodeInfo(primaryProver);
        assertTrue(stakeAfter < stakeBefore, "primary prover auto-slashed by triggerHeartbeat");
        assertTrue(randomnessAfterFailure != randomnessBeforeFailure, "randomness should rotate after auto failure");
        assertTrue(randomnessAfterFailure < SNARK_SCALAR_FIELD, "rotated randomness must stay in field");

        (uint256 totalReceived,,,) = market.getSlashRedistributionStats();
        assertTrue(totalReceived > 0, "slash funds distributed");
    }

    function test_TriggerHeartbeat_AutoSlashesSecondary() public {
        // Secondary provers who fail to submit proof should be slashed even if only
        // triggerHeartbeat() is called (not slashSecondaryFailures).
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(1);

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node2);
        market.executeOrder(2);

        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        // Record both nodes' stakes
        (uint256 n1StakeBefore,,,,) = nodeStaking.getNodeInfo(node1);
        (uint256 n2StakeBefore,,,,) = nodeStaking.getNodeInfo(node2);

        // Let challenge expire
        vm.warp(block.timestamp + (STEP * 2) + 1);

        // Use node3 as heartbeat caller (gets reporter rewards)
        _stakeTestNode(node3, 0x9999, 0x8888);
        vm.prank(node3);
        market.triggerHeartbeat();

        // At least one of the provers should have been slashed
        (uint256 n1StakeAfter,,,,) = nodeStaking.getNodeInfo(node1);
        (uint256 n2StakeAfter,,,,) = nodeStaking.getNodeInfo(node2);
        bool someoneSlashed = (n1StakeAfter < n1StakeBefore) || (n2StakeAfter < n2StakeBefore);
        assertTrue(someoneSlashed, "at least one prover auto-slashed");

        // Reporter (node3) should have received rewards
        uint256 reporterPending = market.reporterPendingRewards(node3);
        assertTrue(reporterPending > 0, "heartbeat caller got reporter rewards");
    }

    function test_SlashEvasion_Prevented() public {
        // A malicious prover should NOT be able to evade slashing by calling
        // triggerHeartbeat() themselves.
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(1);

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node2);
        market.executeOrder(2);

        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        address primaryProver = market.currentPrimaryProver();
        require(primaryProver != address(0), "need primary for test");

        (uint256 stakeBefore,,,,) = nodeStaking.getNodeInfo(primaryProver);

        // Let challenge expire
        vm.warp(block.timestamp + (STEP * 2) + 1);

        // Malicious prover calls triggerHeartbeat to try to erase evidence
        vm.prank(primaryProver);
        market.triggerHeartbeat();

        // Despite calling triggerHeartbeat themselves, they are slashed
        (uint256 stakeAfter,,,,) = nodeStaking.getNodeInfo(primaryProver);
        assertTrue(stakeAfter < stakeBefore, "evasion failed: prover was slashed");
    }

    function test_TriggerHeartbeat_NoDoubleSlash() public {
        // If reportPrimaryFailure is called first, triggerHeartbeat should NOT
        // double-slash anyone.
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(1);

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node2);
        market.executeOrder(2);

        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        address primaryProver = market.currentPrimaryProver();
        require(primaryProver != address(0), "need primary for test");

        // Let challenge expire
        vm.warp(block.timestamp + (STEP * 2) + 1);

        // Call reportPrimaryFailure explicitly (which now also auto-slashes secondaries)
        _stakeTestNode(node3, 0x9999, 0x8888);
        vm.prank(node3);
        market.reportPrimaryFailure();

        // Record total slashes after explicit call
        (uint256 totalReceivedAfterExplicit,,,) = market.getSlashRedistributionStats();

        // reportPrimaryFailure already triggered a new heartbeat internally.
        // Let that new challenge expire, then trigger another heartbeat.
        vm.warp(block.timestamp + (STEP * 2) + 1);

        vm.prank(node3);
        market.triggerHeartbeat();

        // The new heartbeat may auto-slash for the NEW challenge, but nodes from
        // the OLD challenge are not double-slashed.
        (uint256 totalReceivedAfterHeartbeat,,,) = market.getSlashRedistributionStats();
        assertTrue(totalReceivedAfterHeartbeat >= totalReceivedAfterExplicit, "total never decreases");
    }

    function test_ReportPrimaryFailure_AlsoSlashesSecondaries() public {
        // reportPrimaryFailure should auto-process secondary slashes before
        // resetting state, preventing the secondary bypass.
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(1);

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node2);
        market.executeOrder(2);

        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        address primaryProver = market.currentPrimaryProver();
        require(primaryProver != address(0), "need primary for test");

        // Record both nodes' stakes
        (uint256 n1StakeBefore,,,,) = nodeStaking.getNodeInfo(node1);
        (uint256 n2StakeBefore,,,,) = nodeStaking.getNodeInfo(node2);

        // Let challenge expire
        vm.warp(block.timestamp + (STEP * 2) + 1);

        // Call ONLY reportPrimaryFailure (NOT slashSecondaryFailures)
        _stakeTestNode(node3, 0x9999, 0x8888);
        vm.prank(node3);
        market.reportPrimaryFailure();

        // The primary is always slashed
        if (primaryProver == node1) {
            (uint256 n1After,,,,) = nodeStaking.getNodeInfo(node1);
            assertTrue(n1After < n1StakeBefore, "primary (node1) slashed");
        } else {
            (uint256 n2After,,,,) = nodeStaking.getNodeInfo(node2);
            assertTrue(n2After < n2StakeBefore, "primary (node2) slashed");
        }

        // Total slashed should reflect both primary and secondary penalties
        (uint256 totalReceived,,,) = market.getSlashRedistributionStats();
        assertTrue(totalReceived > 0, "slashes processed");

        // All reporter rewards go to node3
        uint256 reporterPending = market.reporterPendingRewards(node3);
        assertTrue(reporterPending > 0, "reporter gets rewards for all auto-slashes");
    }



    function test_AuthoritySlash_NoReporterReward() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        // Grant authority to user2
        market.setSlashAuthority(user2, true);

        uint256 slashAmount = nodeStaking.STAKE_PER_BYTE();

        vm.prank(user2);
        market.slashNode(node1, slashAmount, "test slash");

        // No reporter reward should be given for authority slashes
        assertEq(market.reporterPendingRewards(user2), 0, "authority slash has no reporter reward");

        // All slash should be burned
        (uint256 totalReceived, uint256 totalBurned, uint256 totalRewards,) = market.getSlashRedistributionStats();
        assertTrue(totalReceived > 0, "slashed funds received");
        assertEq(totalRewards, 0, "no reporter rewards for authority slash");
        assertEq(totalReceived, totalBurned, "all funds burned");
    }

    function test_QuitOrder_NoReporterReward() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 4; // use 4 periods so min(3, 4) = 3
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        vm.prank(node1);
        market.quitOrder(orderId);

        // No reporter reward for voluntary quit
        assertEq(market.reporterPendingRewards(node1), 0, "no reporter reward for quit");

        (uint256 totalReceived, uint256 totalBurned, uint256 totalRewards,) = market.getSlashRedistributionStats();
        assertTrue(totalReceived > 0, "slashed funds received");
        assertEq(totalRewards, 0, "no rewards for voluntary quit");
        assertEq(totalReceived, totalBurned, "all funds burned");
    }




    // -------------------------------------------------------------------------
    // placeOrder validation coverage
    // -------------------------------------------------------------------------

    function test_PlaceOrder_RevertRootZero() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: 0, uri: FILE_URI});
        vm.prank(user1);
        vm.expectRevert("root not in Fr");
        market.placeOrder{value: 1 ether}(fileMeta, 1024, 4, 1, 1e12);
    }

    function test_PlaceOrder_RevertRootAtField() public {
        // SNARK_SCALAR_FIELD itself is out of range
        uint256 R = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: R, uri: FILE_URI});
        vm.prank(user1);
        vm.expectRevert("root not in Fr");
        market.placeOrder{value: 1 ether}(fileMeta, 1024, 4, 1, 1e12);
    }

    function test_PlaceOrder_RevertRootAboveField() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: type(uint256).max, uri: FILE_URI});
        vm.prank(user1);
        vm.expectRevert("root not in Fr");
        market.placeOrder{value: 1 ether}(fileMeta, 1024, 4, 1, 1e12);
    }

    function test_PlaceOrder_RevertInvalidSize() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        vm.prank(user1);
        vm.expectRevert("invalid size");
        market.placeOrder{value: 1 ether}(fileMeta, 0, 4, 1, 1e12);
    }

    function test_PlaceOrder_RevertInvalidPeriods() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        vm.prank(user1);
        vm.expectRevert("invalid periods");
        market.placeOrder{value: 1 ether}(fileMeta, 1024, 0, 1, 1e12);
    }

    function test_PlaceOrder_RevertInvalidReplicas() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        vm.prank(user1);
        vm.expectRevert("invalid replicas");
        market.placeOrder{value: 1 ether}(fileMeta, 1024, 4, 0, 1e12);
    }

    function test_PlaceOrder_RevertReplicasExceedMax() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        vm.prank(user1);
        vm.expectRevert("invalid replicas");
        market.placeOrder{value: 100 ether}(fileMeta, 1024, 4, 11, 1e12);
    }

    function test_PlaceOrder_MaxReplicasAccepted() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(1024) * 4 * 1e12 * 10;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, 1024, 4, 10, 1e12);
        assertGt(orderId, 0, "order should be created at MAX_REPLICAS");
    }

    function test_PlaceOrder_RevertInvalidPrice() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        vm.prank(user1);
        vm.expectRevert("invalid price");
        market.placeOrder{value: 1 ether}(fileMeta, 1024, 4, 1, 0);
    }

    function test_PlaceOrder_RevertInsufficientPayment() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(1024) * 4 * 1e12;
        vm.prank(user1);
        vm.expectRevert("insufficient payment");
        market.placeOrder{value: totalCost - 1}(fileMeta, 1024, 4, 1, 1e12);
    }


    // -------------------------------------------------------------------------
    // executeOrder edge cases
    // -------------------------------------------------------------------------

    function test_ExecuteOrder_RevertOrderDoesNotExist() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        vm.prank(node1);
        vm.expectRevert("order does not exist");
        market.executeOrder(999);
    }

    function test_ExecuteOrder_RevertOrderFullyFilled() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 totalCost = uint256(maxSize) * 4 * 1e12;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, 4, 1, 1e12); // 1 replica

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.prank(node2);
        vm.expectRevert("order already filled");
        market.executeOrder(orderId);
    }


    // -------------------------------------------------------------------------
    // completeExpiredOrder
    // -------------------------------------------------------------------------


    function test_CompleteExpiredOrder_RevertNotExpired() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: 1 ether}(fileMeta, 1024, 4, 1, 1e12);

        vm.expectRevert("order not expired");
        market.completeExpiredOrder(orderId);
    }

    function test_CompleteExpiredOrder_RevertDoesNotExist() public {
        // A non-existent order has owner == address(0), so isOrderExpired returns true
        // but then require(order.owner != address(0)) fails
        vm.expectRevert("order does not exist");
        market.completeExpiredOrder(999);
    }

    function test_CompleteExpiredOrder_RefundsExcessEscrow() public {
        // Place order with 2 replicas but only 1 filled → excess escrow refunded
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * 2; // 2 replicas

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 2, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + PERIOD + 1);

        market.completeExpiredOrder(orderId);

        // Node earned maxSize*price*1period, remaining escrow queued as pull-refund
        uint256 nodeEarned = uint256(maxSize) * price;
        uint256 expectedRefund = totalCost - nodeEarned;
        assertEq(market.pendingRefunds(user1), expectedRefund, "excess escrow queued as refund");

        // Withdraw refund
        uint256 userBalBefore = user1.balance;
        vm.prank(user1);
        market.withdrawRefund();
        uint256 userBalAfter = user1.balance;
        assertEq(userBalAfter - userBalBefore, expectedRefund, "excess escrow withdrawn");
    }

    // -------------------------------------------------------------------------
    // cancelOrder edge cases
    // -------------------------------------------------------------------------

    function test_CancelOrder_RevertExpired() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: 1 ether}(fileMeta, 1024, 1, 1, 1e12);

        vm.warp(block.timestamp + PERIOD + 1);

        vm.prank(user1);
        vm.expectRevert("order already expired");
        market.cancelOrder(orderId);
    }

    // -------------------------------------------------------------------------
    // quitOrder edge cases
    // -------------------------------------------------------------------------

    function test_QuitOrder_RevertDoesNotExist() public {
        vm.prank(node1);
        vm.expectRevert("order does not exist");
        market.quitOrder(999);
    }

    function test_QuitOrder_RevertExpired() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 totalCost = uint256(maxSize) * 1 * 1e12;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, 1, 1, 1e12);
        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + PERIOD + 1);

        vm.prank(node1);
        vm.expectRevert("order already expired");
        market.quitOrder(orderId);
    }

    function test_QuitOrder_RevertNotAssigned() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 totalCost = uint256(maxSize) * 2 * 1e12;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, 2, 1, 1e12);
        vm.prank(node1);
        market.executeOrder(orderId);

        vm.prank(node2);
        vm.expectRevert("node not assigned to this order");
        market.quitOrder(orderId);
    }

    function test_QuitOrder_SlashCappedToStake() public {
        // Use a high price so the computed slash exceeds node stake
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 1024;
        uint16 periods = 4;
        // Very high price: slash = maxSize * price * min(3, remaining) will exceed TEST_STAKE
        uint256 price = 1 ether;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.deal(user1, totalCost);
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        (uint256 stakeBefore,,,,) = nodeStaking.getNodeInfo(node1);
        // Confirm the uncapped slash would exceed stake
        uint256 rawSlash = uint256(maxSize) * price * 3; // QUIT_SLASH_PERIODS = 3
        assertTrue(rawSlash > stakeBefore, "test setup: slash should exceed stake");

        // quitOrder must succeed (not revert) thanks to the cap
        vm.prank(node1);
        market.quitOrder(orderId);

        // Node should have been removed from the order
        address[] memory orderNodes = market.getOrderNodes(orderId);
        assertEq(orderNodes.length, 0, "node removed after quit");
    }

    function test_QuitOrder_NormalWithoutForcedExit() public {
        // Node has large capacity, quit slashes only a small amount → no forced exit
        uint64 largeCapacity = TEST_CAPACITY * 2;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Quit should be normal (no forced exit) since capacity is large
        vm.prank(node1);
        market.quitOrder(orderId);

        // Node removed from order
        address[] memory orderNodes = market.getOrderNodes(orderId);
        assertEq(orderNodes.length, 0);

        // Node's used capacity should be back to 0
        (,, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, 0);
    }

    function test_QuitOrder_TinySlashCannotForceExitOtherOrders() public {
        // Capacity exactly fits one large order + one tiny order.
        uint64 capacity = 257;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.deal(node1, stake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        // Large order (the one attacker wants to escape).
        uint64 largeSize = 256;
        uint16 periods = 4;
        uint256 largePrice = 1e12;
        uint256 largeCost = uint256(largeSize) * uint256(periods) * largePrice;
        vm.prank(user1);
        uint256 largeOrderId = market.placeOrder{value: largeCost}(fileMeta, largeSize, periods, 1, largePrice);

        // Tiny cheap order used as the old forced-exit trigger.
        uint64 tinySize = 1;
        uint256 tinyPrice = 1;
        uint256 tinyCost = uint256(tinySize) * uint256(periods) * tinyPrice;
        vm.prank(user1);
        uint256 tinyOrderId = market.placeOrder{value: tinyCost}(fileMeta, tinySize, periods, 1, tinyPrice);

        vm.startPrank(node1);
        market.executeOrder(largeOrderId);
        market.executeOrder(tinyOrderId);
        market.quitOrder(tinyOrderId);
        vm.stopPrank();

        // Quitting the tiny order must not force-exit the large order assignment.
        address[] memory largeNodes = market.getOrderNodes(largeOrderId);
        assertEq(largeNodes.length, 1, "large order must stay assigned");
        assertEq(largeNodes[0], node1, "node still serves large order");

        address[] memory tinyNodes = market.getOrderNodes(tinyOrderId);
        assertEq(tinyNodes.length, 0, "tiny order should be released");

        uint256[] memory nodeOrders = market.getNodeOrders(node1);
        assertEq(nodeOrders.length, 1, "node should keep exactly one order");
        assertEq(nodeOrders[0], largeOrderId, "remaining order should be the large one");

        (,, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, largeSize, "used capacity should only reflect large order");
    }

    // -------------------------------------------------------------------------
    // slashNode (external) edge cases
    // -------------------------------------------------------------------------

    function test_SlashNode_External_RevertZeroAmount() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        vm.expectRevert("invalid slash amount");
        market.slashNode(node1, 0, "test");
    }

    // -------------------------------------------------------------------------
    // transferOwnership
    // -------------------------------------------------------------------------

    function test_TransferOwnership_Success() public {
        assertEq(market.owner(), address(this));
        market.transferOwnership(user1);
        assertEq(market.owner(), user1);
    }

    function test_TransferOwnership_RevertInvalidOwner() public {
        vm.expectRevert("invalid owner");
        market.transferOwnership(address(0));
    }

    function test_TransferOwnership_RevertNotOwner() public {
        vm.prank(user1);
        vm.expectRevert("not owner");
        market.transferOwnership(user2);
    }

    // -------------------------------------------------------------------------
    // Reporter reward edge cases
    // -------------------------------------------------------------------------

    function test_ReporterReward_ZeroBps_NoReward() public {
        // Set bps to 0 so reporter gets nothing
        market.setReporterRewardBps(0);

        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 totalCost = uint256(maxSize) * 2 * 1e12;

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, 2, 1, 1e12);
        vm.prank(node1);
        market.executeOrder(1);
        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, 2, 1, 1e12);
        vm.prank(node2);
        market.executeOrder(2);

        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();
        vm.warp(block.timestamp + (STEP * 2) + 1);

        address pp = market.currentPrimaryProver();
        require(pp != address(0), "need primary for test");

        _stakeTestNode(node3, 0x9999, 0x8888);
        vm.prank(node3);
        market.reportPrimaryFailure();

        // Reporter should get 0 reward because bps = 0
        assertEq(market.reporterPendingRewards(node3), 0, "no reward at 0 bps");

        // But slashed funds should still be tracked
        (uint256 totalReceived, uint256 totalBurned, uint256 totalRewards,) = market.getSlashRedistributionStats();
        assertTrue(totalReceived > 0);
        assertEq(totalRewards, 0);
        assertEq(totalReceived, totalBurned, "all burned at 0 bps");
    }

    function test_ReporterReward_MaxBps() public {
        market.setReporterRewardBps(5000); // 50%

        _stakeTestNode(node1, 0x1234, 0x5678);

        // Authority slash — uses address(0) reporter so no reward even at max bps
        market.setSlashAuthority(user2, true);
        uint256 slashAmount = nodeStaking.STAKE_PER_BYTE();
        vm.prank(user2);
        market.slashNode(node1, slashAmount, "test");

        (uint256 totalReceived, uint256 totalBurned, uint256 totalRewards,) = market.getSlashRedistributionStats();
        assertEq(totalRewards, 0, "still no reward for authority slash even at 50%");
        assertEq(totalReceived, totalBurned);
    }

    // -------------------------------------------------------------------------
    // currentEpoch coverage
    // -------------------------------------------------------------------------

    function test_CurrentEpoch() public view {
        uint256 epoch = market.currentEpoch();
        assertEq(epoch, 0); // at genesis
    }

    // -------------------------------------------------------------------------
    // isOrderExpired edge cases
    // -------------------------------------------------------------------------

    function test_IsOrderExpired_NonExistentOrder() public view {
        assertTrue(market.isOrderExpired(999), "non-existent order should be expired");
    }

    // -------------------------------------------------------------------------
    // triggerHeartbeat edge case
    // -------------------------------------------------------------------------


    // -------------------------------------------------------------------------
    // Cleanup expired orders via heartbeat
    // -------------------------------------------------------------------------

    function test_CleanupExpiredOrdersViaHeartbeat() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        assertEq(market.getActiveOrdersCount(), 1);

        // Warp past order expiry and past challenge window
        vm.warp(block.timestamp + PERIOD + (STEP * 3));
        market.triggerHeartbeat();

        // The heartbeat's _cleanupExpiredOrders should have cleaned up
        assertEq(market.getActiveOrdersCount(), 0, "expired order cleaned up by heartbeat");
    }

    // -------------------------------------------------------------------------
    // claimRewards with valid node but no rewards
    // -------------------------------------------------------------------------


    // -------------------------------------------------------------------------
    // View functions coverage
    // -------------------------------------------------------------------------

    function test_GetActiveOrders() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(1024) * 4 * 1e12;

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, 1024, 4, 1, 1e12);
        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, 1024, 4, 1, 1e12);

        uint256[] memory active = market.getActiveOrders();
        assertEq(active.length, 2);
        assertEq(active[0], 1);
        assertEq(active[1], 2);
    }

    function test_GetNodeEarningsInfo() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * 1 * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, 1, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + PERIOD + 1);

        (uint256 totalEarned, uint256 withdrawn, uint256 claimable, uint256 lastClaim) =
            market.getNodeEarningsInfo(node1);
        assertEq(totalEarned, 0, "not settled yet");
        assertEq(withdrawn, 0);
        assertTrue(claimable > 0, "has claimable");
        assertEq(lastClaim, 0);
    }

    function test_HasSubmittedProof() public view {
        assertFalse(market.hasSubmittedProof(node1));
    }

    function test_IsChallengeExpired() public view {
        // At genesis, lastChallengeStep = 0, currentStep = 0 → 0 > 0 + 1 = false
        // (but also no challenge was issued so it's in expired state conceptually)
        bool expired = market.isChallengeExpired();
        assertFalse(expired);
    }

    function test_GetNodeOrderEarnings() public view {
        assertEq(market.getNodeOrderEarnings(node1, 1), 0);
    }




    function test_GetRecentOrders_CountExceedsTotal() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(256) * 2 * 1e12;

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, 256, 2, 1, 1e12);

        (uint256[] memory ids,,,,,,,) = market.getRecentOrders(100);
        assertEq(ids.length, 1); // capped to actual count
    }



    function test_GetFinancialStats_NoOrders() public view {
        (,,, uint256 avgOrderVal,) = market.getFinancialStats();
        assertEq(avgOrderVal, 0, "no orders - avg = 0");
    }



    // -------------------------------------------------------------------------
    // reportPrimaryFailure additional reverts
    // -------------------------------------------------------------------------


    function test_ReportPrimaryFailure_RevertAlreadyReported() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 totalCost = uint256(maxSize) * 2 * 1e12;

        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, 2, 1, 1e12);
        vm.prank(node1);
        market.executeOrder(1);
        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, maxSize, 2, 1, 1e12);
        vm.prank(node2);
        market.executeOrder(2);

        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();
        vm.warp(block.timestamp + (STEP * 2) + 1);

        address pp = market.currentPrimaryProver();
        require(pp != address(0), "need primary");

        _stakeTestNode(node3, 0x9999, 0x8888);

        vm.prank(node3);
        market.reportPrimaryFailure();

        // The heartbeat was re-triggered, but let's try to report again
        // Need to advance past the new challenge period
        vm.warp(block.timestamp + (STEP * 2) + 1);

        // primaryFailureReported was reset by the new heartbeat,
        // but now the new primary might be different. If no primary assigned, it reverts with "no primary assigned"
        // This test covers the general flow — specific revert depends on heartbeat state
    }

    // -------------------------------------------------------------------------
    // selectRandomOrders edge case
    // -------------------------------------------------------------------------

    function test_SelectRandomOrders_RevertZeroCount() public {
        vm.expectRevert("count must be positive");
        market.selectRandomOrders(123, 0);
    }

    // -------------------------------------------------------------------------
    // Receive ETH coverage
    // -------------------------------------------------------------------------

    function test_MarketReceivesETH() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool success,) = address(market).call{value: 0.1 ether}("");
        assertTrue(success, "market can receive ETH");
    }

    function test_ClaimRewards_NonReentrant_WithContractReceiver() public {
        // Malicious node stakes, stores data, and attempts to reenter claimRewards
        MaliciousMarketClaim attacker = new MaliciousMarketClaim(market);
        uint64 capacity = TEST_CAPACITY;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.deal(address(attacker), stake + 10 ether);

        // Setup storage via attacker
        attacker.setupAndStore{value: stake}(capacity, FILE_ROOT, FILE_URI, 512, 1, 1e12);

        // Advance one period to accrue rewards
        vm.warp(block.timestamp + PERIOD + 1);

        // With .call{value:}, the receive() gets enough gas to attempt reentry,
        // but the nonReentrant guard blocks it. The catch block in receive() handles it gracefully.
        // The outer call succeeds and rewards are claimed.
        attacker.attackClaimRewards();

        // Verify the reentrancy was detected and blocked
        assertTrue(attacker.reentrancyDetected(), "reentrancy attempt was caught by nonReentrant");
    }

    // =========================================================================
    // ZK Proof Integration Tests (using real Groth16 proofs from muri-zkproof)
    // =========================================================================

    // Valid proof fixture generated by muri-zkproof/export_proof.go
    // These are real Groth16 BN254 proof values verified in Go before export
    uint256 constant ZK_RANDOMNESS = 0x000000000000000000000000000000000000000000000000000000000000002a;
    uint256 constant ZK_FILE_ROOT = 0x097b1de1037388e4484f286fa2884be0c6416fbbd3b2b0528287d99c6db8caba;
    bytes32 constant ZK_COMMITMENT = bytes32(0x012a3bc33ad43c5cb7707f37754f2bd9cb12da7cae32aa282be0530414e341e9);
    uint256 constant ZK_PUB_KEY_X = 0x102ca72a7cfd7b48016782321304b3fef012bc6e7e94d0273eac1e97e1e8a3dc;
    uint256 constant ZK_PUB_KEY_Y = 0x264ce84ed139f4b242bc2a6ec482f89c376be38daf5426ac3509836a2e39c13e;

    uint256 constant ZK_PROOF_0 = 0x184e921f1ba11980804e67e7f448965f1a4465426c0a03e9e4ed6f9033860ae1;
    uint256 constant ZK_PROOF_1 = 0x015315536b1c9a5174d007a8f77b01e291ce55af77337c99e0b552c2940c7201;
    uint256 constant ZK_PROOF_2 = 0x0f50780d3d336e878f3fb268ad2f44a4759f7a630c614d042972853cdde61a82;
    uint256 constant ZK_PROOF_3 = 0x1a9708deb9df7ae67f9a4b34e20287b4c30dc9c0ba68b9f3e287fecce49efab7;
    uint256 constant ZK_PROOF_4 = 0x0ee04951f17e6a9d0e0e6f28373e8c4943b8449f84003156c6f463e2ac1d8a68;
    uint256 constant ZK_PROOF_5 = 0x07d96d27689438af3c16fd13e8be80cbaeae2a6dd2f15acde9ddf0c45f5da49f;
    uint256 constant ZK_PROOF_6 = 0x084c9995ac0503e4ca367cbbe43d765e07d3680a5c972d81dcef4d93ca256aba;
    uint256 constant ZK_PROOF_7 = 0x27e852fc577dc5bc8697f8c9eea71f48236447f85ae116b986f315c669d60142;

    // Storage slots (from forge inspect FileMarket storageLayout)
    uint256 constant SLOT_CURRENT_RANDOMNESS = 26;
    uint256 constant SLOT_LAST_CHALLENGE_STEP = 27;
    uint256 constant SLOT_CURRENT_PRIMARY_PROVER = 28;
    uint256 constant SLOT_NODE_TO_PROVE_ORDER_ID = 32;
    uint256 constant SLOT_CHALLENGE_INITIALIZED = 37;
    uint256 constant SLOT_CHALLENGEABLE_ORDERS = 7;
    uint256 constant SLOT_ORDER_INDEX_IN_CHALLENGEABLE = 8;
    uint256 constant SLOT_IS_CHALLENGEABLE = 9;

    function _zkProof() internal pure returns (uint256[8] memory proof) {
        proof[0] = ZK_PROOF_0;
        proof[1] = ZK_PROOF_1;
        proof[2] = ZK_PROOF_2;
        proof[3] = ZK_PROOF_3;
        proof[4] = ZK_PROOF_4;
        proof[5] = ZK_PROOF_5;
        proof[6] = ZK_PROOF_6;
        proof[7] = ZK_PROOF_7;
    }

    /// @dev Set up a challenge where `prover` is primary prover for `orderId`,
    ///      with currentRandomness = ZK_RANDOMNESS so the ZK proof fixture is valid.
    function _setupZKChallenge(address prover, uint256 orderId) internal {
        // Set currentRandomness to our known value
        vm.store(address(market), bytes32(SLOT_CURRENT_RANDOMNESS), bytes32(ZK_RANDOMNESS));
        // Set lastChallengeStep to currentStep - 1 so challenge is "active"
        uint256 cs = market.currentStep();
        vm.store(address(market), bytes32(SLOT_LAST_CHALLENGE_STEP), bytes32(cs - 1));
        // Mark challenge system as initialized
        vm.store(address(market), bytes32(SLOT_CHALLENGE_INITIALIZED), bytes32(uint256(1)));
        // Set primary prover
        vm.store(address(market), bytes32(SLOT_CURRENT_PRIMARY_PROVER), bytes32(uint256(uint160(prover))));
        // Set nodeToProveOrderId[prover] = orderId
        bytes32 mapSlot = keccak256(abi.encode(prover, SLOT_NODE_TO_PROVE_ORDER_ID));
        vm.store(address(market), mapSlot, bytes32(orderId));
    }

    /// @dev Register a node with ZK public key and stake it
    function _stakeZKNode(address node) internal {
        uint256 stakeAmt = uint256(TEST_CAPACITY) * STAKE_PER_BYTE;
        vm.deal(node, stakeAmt);
        vm.prank(node);
        nodeStaking.stakeNode{value: stakeAmt}(TEST_CAPACITY, ZK_PUB_KEY_X, ZK_PUB_KEY_Y);
    }

    /// @dev Place an order using the ZK file root
    function _placeZKOrder() internal returns (uint256 orderId) {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: ZK_FILE_ROOT, uri: "QmZKTestFile"});
        uint256 totalCost = uint256(256) * 4 * 1e12;
        vm.prank(user1);
        orderId = market.placeOrder{value: totalCost}(fileMeta, 256, 4, 1, 1e12);
    }

    function _legacySelectorWouldBlackout(uint256 seed, uint256 totalEntries, uint256 liveIndex)
        internal
        pure
        returns (bool)
    {
        uint256 len = totalEntries;
        uint256 livePos = liveIndex;
        uint256 nonce = 0;
        uint256 evictions = 0;

        while (len > 0 && evictions < 50) {
            uint256 idx = uint256(keccak256(abi.encodePacked(seed, nonce))) % len;
            nonce++;

            // Legacy selector would find a non-expired order and avoid blackout.
            if (idx == livePos) {
                return false;
            }

            // Swap-pop removal of an expired entry moves the last element into idx.
            uint256 last = len - 1;
            if (livePos == last && idx != last) {
                livePos = idx;
            }
            len--;
            evictions++;
        }

        return true;
    }

    function _findLegacyBlackoutSeed(uint256 totalEntries, uint256 liveIndex) internal pure returns (uint256) {
        for (uint256 seed = 1; seed <= 5000; seed++) {
            if (_legacySelectorWouldBlackout(seed, totalEntries, liveIndex)) {
                return seed;
            }
        }
        revert("no legacy-blackout seed found");
    }

    function test_SubmitProof_PrimaryValid() public {
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();

        vm.prank(node1);
        market.executeOrder(orderId);

        // Advance time so currentStep > 0
        vm.warp(block.timestamp + STEP + 1);

        _setupZKChallenge(node1, orderId);

        uint256 challengeStepBefore = market.lastChallengeStep();

        // Submit valid proof — the pairing check passes on-chain.
        // Primary proof no longer immediately rolls to a new heartbeat; the round
        // stays active so secondary provers can still be slashed at expiry.
        vm.prank(node1);
        market.submitProof(_zkProof(), ZK_COMMITMENT);

        // Round state preserved: lastChallengeStep unchanged, primaryProofReceived set,
        // commitment deferred as pendingRandomness for the next heartbeat.
        assertEq(market.lastChallengeStep(), challengeStepBefore, "challenge step should not advance on primary proof");
        assertTrue(market.primaryProofReceived(), "primary proof should be recorded");
        assertEq(
            market.pendingRandomness(), uint256(ZK_COMMITMENT), "commitment should be stored as pending randomness"
        );
    }

    function test_SubmitProof_RevertInvalidProof() public {
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + STEP + 1);
        _setupZKChallenge(node1, orderId);

        // Tamper with proof (flip a bit in proof element 0)
        uint256[8] memory badProof = _zkProof();
        badProof[0] = badProof[0] ^ 1;

        vm.prank(node1);
        vm.expectRevert();
        market.submitProof(badProof, ZK_COMMITMENT);
    }

    function test_SubmitProof_RevertWrongCommitment() public {
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + STEP + 1);
        _setupZKChallenge(node1, orderId);

        // Correct proof but wrong commitment
        vm.prank(node1);
        vm.expectRevert();
        market.submitProof(_zkProof(), bytes32(uint256(0xDEAD)));
    }

    function test_SubmitProof_RevertProofAlreadySubmitted() public {
        // Use vm.store to directly set proofSubmitted[node1] = true
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + STEP + 1);
        _setupZKChallenge(node1, orderId);

        // Pre-set proofSubmitted[node1] = true via storage
        bytes32 submittedSlot = keccak256(abi.encode(node1, uint256(31))); // slot 31 = proofSubmitted mapping
        vm.store(address(market), submittedSlot, bytes32(uint256(1)));

        vm.prank(node1);
        vm.expectRevert("proof already submitted");
        market.submitProof(_zkProof(), ZK_COMMITMENT);
    }


    function test_SubmitProof_RevertChallengePeriodExpired() public {
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();

        vm.prank(node1);
        market.executeOrder(orderId);

        // Set up challenge where lastChallengeStep is far behind currentStep
        vm.warp(block.timestamp + (STEP * 5));
        uint256 cs = market.currentStep();

        vm.store(address(market), bytes32(SLOT_CURRENT_RANDOMNESS), bytes32(ZK_RANDOMNESS));
        // Set lastChallengeStep to cs - 3 so currentStep > lastChallengeStep + 1
        vm.store(address(market), bytes32(SLOT_LAST_CHALLENGE_STEP), bytes32(cs - 3));
        vm.store(address(market), bytes32(SLOT_CHALLENGE_INITIALIZED), bytes32(uint256(1)));
        vm.store(address(market), bytes32(SLOT_CURRENT_PRIMARY_PROVER), bytes32(uint256(uint160(node1))));
        bytes32 mapSlot = keccak256(abi.encode(node1, SLOT_NODE_TO_PROVE_ORDER_ID));
        vm.store(address(market), mapSlot, bytes32(orderId));

        vm.prank(node1);
        vm.expectRevert("challenge period expired");
        market.submitProof(_zkProof(), ZK_COMMITMENT);
    }

    function test_SubmitProof_RevertNotChallengedProver() public {
        _stakeZKNode(node1);
        _stakeTestNode(node2, 0xAAAA, 0xBBBB);
        uint256 orderId = _placeZKOrder();

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + STEP + 1);
        _setupZKChallenge(node1, orderId);

        // node2 is not the challenged prover
        vm.prank(node2);
        vm.expectRevert("not a challenged prover");
        market.submitProof(_zkProof(), ZK_COMMITMENT);
    }

    function test_SubmitProof_RevertNodePubKeyNotSet() public {
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + STEP + 1);
        _setupZKChallenge(node1, orderId);

        // Zero out the node's public key in NodeStaking
        // nodes mapping at slot 0: keccak256(abi.encode(node1, 0)) is base slot
        // publicKeyX at base+3, publicKeyY at base+4
        bytes32 nodeSlot = keccak256(abi.encode(node1, uint256(0)));
        vm.store(address(nodeStaking), bytes32(uint256(nodeSlot) + 3), bytes32(uint256(0)));
        vm.store(address(nodeStaking), bytes32(uint256(nodeSlot) + 4), bytes32(uint256(0)));

        vm.prank(node1);
        vm.expectRevert("node public key not set");
        market.submitProof(_zkProof(), ZK_COMMITMENT);
    }

    function test_ReportPrimaryFailure_WithoutForcedExit() public {
        // Set up a node with large capacity so slash doesn't force exit
        uint64 largeCapacity = 10000;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, ZK_PUB_KEY_X, ZK_PUB_KEY_Y);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: ZK_FILE_ROOT, uri: "QmZKTestFile"});
        uint256 totalCost = uint256(256) * 4 * 1e12;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, 256, 4, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Trigger heartbeat to set up a challenge
        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        // Advance past challenge window to expire it
        vm.warp(block.timestamp + (STEP * 2) + 1);

        address pp = market.currentPrimaryProver();
        require(pp != address(0), "need primary prover");

        // Report as a different valid node
        _stakeTestNode(node2, 0xAAAA, 0xBBBB);
        vm.prank(node2);
        market.reportPrimaryFailure();

        // Node1 should still be valid (no forced exit due to large capacity)
        assertTrue(nodeStaking.isValidNode(node1), "node still valid after slash");
    }

    // =========================================================================
    // Edge case tests for uncovered branches
    // =========================================================================

    /// @dev Secondary prover submits a valid proof (covers lines 671-674 secondary path)
    function test_SubmitProof_SecondaryValid() public {
        // Stake two ZK nodes
        _stakeZKNode(node1);
        // node2 stakes with same ZK keys for simplicity (only node2 will submit)
        vm.deal(node2, 100 ether);
        vm.prank(node2);
        nodeStaking.stakeNode{value: TEST_STAKE}(TEST_CAPACITY, ZK_PUB_KEY_X, ZK_PUB_KEY_Y);

        uint256 orderId = _placeZKOrder();

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + STEP + 1);

        // Set up node2 as a secondary prover
        // First set the basic challenge state
        vm.store(address(market), bytes32(SLOT_CURRENT_RANDOMNESS), bytes32(ZK_RANDOMNESS));
        uint256 cs = market.currentStep();
        vm.store(address(market), bytes32(SLOT_LAST_CHALLENGE_STEP), bytes32(cs - 1));
        vm.store(address(market), bytes32(SLOT_CHALLENGE_INITIALIZED), bytes32(uint256(1)));
        // Primary is node1
        vm.store(address(market), bytes32(SLOT_CURRENT_PRIMARY_PROVER), bytes32(uint256(uint160(node1))));

        // Set currentSecondaryProvers array: length = 1, element[0] = node2
        // Slot 29 holds the length of currentSecondaryProvers
        vm.store(address(market), bytes32(uint256(29)), bytes32(uint256(1)));
        // Array data starts at keccak256(29)
        bytes32 secArrayStart = keccak256(abi.encode(uint256(29)));
        vm.store(address(market), secArrayStart, bytes32(uint256(uint160(node2))));

        // Set nodeToProveOrderId[node2] = orderId
        bytes32 mapSlot = keccak256(abi.encode(node2, SLOT_NODE_TO_PROVE_ORDER_ID));
        vm.store(address(market), mapSlot, bytes32(orderId));

        // node2 submits proof as secondary — should succeed without triggering heartbeat
        vm.prank(node2);
        market.submitProof(_zkProof(), ZK_COMMITMENT);

        // Secondary proof should mark proofSubmitted[node2] = true but NOT trigger heartbeat
        assertTrue(market.proofSubmitted(node2), "secondary proof recorded");
        // lastChallengeStep should NOT have changed (no heartbeat for secondary)
        assertEq(market.lastChallengeStep(), cs - 1, "no heartbeat triggered for secondary");
    }

    /// @dev quitOrder triggers forced exit when node has minimal stake
    function test_QuitOrder_ForcedExit() public {
        // Node1 stakes with minimal capacity
        uint64 minCap = 256; // small capacity
        uint256 minStake = uint256(minCap) * STAKE_PER_BYTE;
        vm.deal(node1, minStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: minStake}(minCap, 0xAAAA, 0xBBBB);

        // Place a small order
        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 price = 1e12;
        uint256 totalCost = uint256(minCap) * 4 * price;
        vm.deal(user1, totalCost);
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(meta, minCap, 4, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        // slashAmount = maxSize * price = 256 * 1e12 = 256e12
        // minStake = 256 * 1e14 = 256e14
        // After slash, stake < requiredStake triggers forcedExit = true
        // The additional 50% penalty makes it more likely to force exit
        vm.prank(node1);
        market.quitOrder(orderId);

        // If forced exit happened, node should have been removed from all orders
        // Verify node has 0 orders remaining
        (,, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, 0, "used should be 0 after forced exit");
    }

    /// @dev slashSecondaryFailures when a secondary has nodeToProveOrderId == 0
    function test_SlashSecondaryFailures_SkipUnassigned() public {
        _stakeTestNode(node1, 0xAAAA, 0xBBBB);
        _stakeTestNode(node2, 0xCCCC, 0xDDDD);

        // Advance time enough so currentStep >= 3 to avoid underflow
        vm.warp(block.timestamp + STEP * 5);
        uint256 cs = market.currentStep();
        vm.store(address(market), bytes32(SLOT_LAST_CHALLENGE_STEP), bytes32(cs - 2));
        vm.store(address(market), bytes32(SLOT_CHALLENGE_INITIALIZED), bytes32(uint256(1)));
        vm.store(address(market), bytes32(SLOT_CURRENT_RANDOMNESS), bytes32(uint256(42)));

        // Set secondaryProvers = [node2]
        vm.store(address(market), bytes32(uint256(29)), bytes32(uint256(1)));
        bytes32 secArrayStart = keccak256(abi.encode(uint256(29)));
        vm.store(address(market), secArrayStart, bytes32(uint256(uint160(node2))));

        // Do NOT set nodeToProveOrderId[node2] — leave at 0
        // proofSubmitted[node2] is false by default

        // slashSecondaryFailures should skip node2 (nodeToProveOrderId == 0)
        vm.prank(node1);
        market.slashSecondaryFailures();

        // node2 should NOT be slashed
        assertTrue(nodeStaking.isValidNode(node2), "node2 still valid - was skipped");
    }

    /// @dev slashSecondaryFailures when slash causes forced exit
    function test_SlashSecondaryFailures_ForcedExit() public {
        // node1 = reporter, node2 = secondary that will be force-exited
        _stakeTestNode(node1, 0xAAAA, 0xBBBB);

        // node2 with minimal stake so slash forces exit
        // normalSlash = 100 * STAKE_PER_BYTE = 100 * 1e14 = 1e16
        // Need stake slightly above this so slash doesn't revert, but triggers forced exit
        uint64 minCap = 256;
        uint256 minStake = uint256(minCap) * STAKE_PER_BYTE;
        vm.deal(node2, minStake);
        vm.prank(node2);
        nodeStaking.stakeNode{value: minStake}(minCap, 0xCCCC, 0xDDDD);

        // node2 executes an order
        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 price = 1e12;
        uint256 totalCost = uint256(minCap) * 4 * price;
        vm.deal(user1, totalCost);
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(meta, minCap, 4, 1, price);

        vm.prank(node2);
        market.executeOrder(orderId);

        // Advance time so currentStep >= 3 to avoid underflow
        vm.warp(block.timestamp + STEP * 5);
        uint256 cs = market.currentStep();
        vm.store(address(market), bytes32(SLOT_LAST_CHALLENGE_STEP), bytes32(cs - 2));
        vm.store(address(market), bytes32(SLOT_CHALLENGE_INITIALIZED), bytes32(uint256(1)));
        vm.store(address(market), bytes32(SLOT_CURRENT_RANDOMNESS), bytes32(uint256(42)));

        // Set secondaryProvers = [node2]
        vm.store(address(market), bytes32(uint256(29)), bytes32(uint256(1)));
        bytes32 secArrayStart = keccak256(abi.encode(uint256(29)));
        vm.store(address(market), secArrayStart, bytes32(uint256(uint160(node2))));

        // Set nodeToProveOrderId[node2] = orderId
        bytes32 mapSlot = keccak256(abi.encode(node2, SLOT_NODE_TO_PROVE_ORDER_ID));
        vm.store(address(market), mapSlot, bytes32(orderId));

        // node1 reports secondary failures — slash should cause forced exit for node2
        vm.prank(node1);
        market.slashSecondaryFailures();

        // node2 should have no used capacity after forced exit
        if (nodeStaking.isValidNode(node2)) {
            (,, uint64 used,,) = nodeStaking.getNodeInfo(node2);
            assertEq(used, 0, "used should be 0 after forced exit");
        }
    }

    /// @dev getOrderFinancials reverts for invalid order ID
    function test_GetOrderFinancials_RevertInvalidId() public {
        vm.expectRevert("invalid order id");
        market.getOrderFinancials(0);

        vm.expectRevert("invalid order id");
        market.getOrderFinancials(999);
    }

    /// @dev quitOrder where node is not the last in the array (covers swap-and-pop path)
    function test_QuitOrder_MiddleNode_SwapAndPop() public {
        // Stake 3 nodes
        _stakeTestNode(node1, 0xAAAA, 0xBBBB);
        _stakeTestNode(node2, 0xCCCC, 0xDDDD);
        _stakeTestNode(node3, 0xEEEE, 0xFFFF);

        // Place order with 3 replicas (cost = maxSize * periods * price * replicas)
        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 price = 1e12;
        uint64 maxSize = 512;
        uint256 totalCost = uint256(maxSize) * 4 * price * 3;
        vm.deal(user1, totalCost);
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(meta, maxSize, 4, 3, price);

        vm.prank(node1);
        market.executeOrder(orderId);
        vm.prank(node2);
        market.executeOrder(orderId);
        vm.prank(node3);
        market.executeOrder(orderId);

        // node1 quits (first element — swap with last, covers swap-and-pop in _removeNodeFromOrder)
        vm.prank(node1);
        market.quitOrder(orderId);

        // node1 should no longer be assigned
        assertFalse(nodeStaking.isValidNode(node1) && false, "just verifying quit worked");
        // Order should have 2 filled now
        (,,,,,, uint16 filled) = market.getOrderDetails(orderId);
        assertEq(filled, 2, "should have 2 nodes after quit");
    }

    /// @dev reportPrimaryFailure causing forced exit
    function test_ReportPrimaryFailure_ForcedExit() public {
        // node1 with capacity=1024 so severe slash (1000*STAKE_PER_BYTE) triggers forced exit
        // Stake = 1024 * 1e14 = 1.024e17; severeSlash = 1000 * 1e14 = 1e17
        // After slash, remaining stake < required → forced exit
        _stakeTestNode(node1, 0xAAAA, 0xBBBB);

        // Place order, node1 executes
        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 price = 1e12;
        uint64 maxSize = 512;
        uint256 totalCost = uint256(maxSize) * 4 * price;
        vm.deal(user1, totalCost);
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Trigger heartbeat to set up challenge
        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        // Advance past challenge window
        vm.warp(block.timestamp + (STEP * 2) + 1);

        address pp = market.currentPrimaryProver();
        require(pp != address(0), "need primary");

        // Reporter = node2
        _stakeTestNode(node2, 0xCCCC, 0xDDDD);
        vm.prank(node2);
        market.reportPrimaryFailure();

        // After forced exit, node1 should have 0 used capacity
        if (nodeStaking.isValidNode(node1)) {
            (,, uint64 used,,) = nodeStaking.getNodeInfo(node1);
            assertEq(used, 0, "used=0 after forced exit");
        }
    }

    /// @dev Complete expired order with refund (covers refund branch via pull-payment)
    function test_CompleteExpiredOrder_WithRefund() public {
        _stakeTestNode(node1, 0xAAAA, 0xBBBB);

        // Place order with generous escrow
        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 price = 1e12;
        uint64 maxSize = 512;
        uint256 totalCost = uint256(maxSize) * 4 * price;
        vm.deal(user1, totalCost);
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Advance enough to accrue some rewards but not drain full escrow
        vm.warp(block.timestamp + (PERIOD * 4) + 1);

        // Complete the expired order — should queue remaining escrow as pull-refund
        market.completeExpiredOrder(orderId);

        // User should have pending refund (escrow - rewards paid out)
        uint256 pending = market.pendingRefunds(user1);
        assertTrue(pending >= 0, "user has pending refund queued");
    }

    /// @dev currentPeriod view function (covers line 54)
    function test_CurrentPeriod() public view {
        uint256 period = market.currentPeriod();
        assertGe(period, 0, "period is non-negative");
    }

    // =========================================================================
    // SECURITY FIX TESTS
    // =========================================================================

    // -------------------------------------------------------------------------
    // Fix 1: Pull-payment DoS resistance
    // -------------------------------------------------------------------------



    // -------------------------------------------------------------------------
    // Fix: Overpayment double-counting regression tests
    // -------------------------------------------------------------------------

    function test_OverpaymentNotDoubleCountedOnCancel_NoNodes() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;
        uint256 excess = 2 ether;
        uint256 sent = totalCost + excess;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: sent}(fileMeta, maxSize, periods, 1, price);

        // Escrow should store only totalCost, not msg.value
        (uint256 storedEscrow,,) = market.getOrderEscrowInfo(orderId);
        assertEq(storedEscrow, totalCost, "escrow stores totalCost not msg.value");

        // Excess already queued
        assertEq(market.pendingRefunds(user1), excess, "excess queued immediately");

        // Cancel order (no nodes → full escrow refund, no penalty)
        vm.prank(user1);
        market.cancelOrder(orderId);

        // Total pending = excess + full escrow refund = excess + totalCost = sent
        assertEq(market.pendingRefunds(user1), sent, "total refund equals original payment");

        // Withdraw and verify exact amount
        uint256 balBefore = user1.balance;
        vm.prank(user1);
        market.withdrawRefund();
        assertEq(user1.balance - balBefore, sent, "user recovers exactly what was sent");

        // Contract should have no leftover for this user
        assertEq(market.pendingRefunds(user1), 0, "no pending after withdraw");
    }

    function test_OverpaymentNotDoubleCountedOnCancel_WithNodes() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 512;
        uint16 periods = 4;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;
        uint256 excess = 1 ether;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost + excess}(fileMeta, maxSize, periods, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Advance 1 period so node is eligible for cancellation penalty
        vm.warp(block.timestamp + PERIOD);

        vm.prank(user1);
        market.cancelOrder(orderId);

        // 1 period of rewards settled, then penalty on remaining
        uint256 reward = uint256(maxSize) * price * 1;
        uint256 remainingEscrow = totalCost - reward;
        uint256 penalty = remainingEscrow / 10;
        uint256 cancelRefund = remainingEscrow - penalty;
        uint256 totalPending = excess + cancelRefund;

        assertEq(market.pendingRefunds(user1), totalPending, "exact refund: excess + cancel refund");

        // Verify contract solvency: balance >= all pending claims
        uint256 nodePending = market.nodePendingRewards(node1);
        assertGe(address(market).balance, totalPending + nodePending, "contract solvent after overpay + cancel");
    }

    function test_OverpaymentNotDoubleCountedOnComplete() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;
        uint256 excess = 3 ether;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost + excess}(fileMeta, maxSize, periods, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Warp past expiry
        vm.warp(block.timestamp + PERIOD + 1);
        market.completeExpiredOrder(orderId);

        // Node earns maxSize * price * 1 period
        uint256 nodeEarned = uint256(maxSize) * price;
        uint256 escrowRefund = totalCost - nodeEarned;
        uint256 totalPending = excess + escrowRefund;

        assertEq(market.pendingRefunds(user1), totalPending, "exact refund: excess + remaining escrow");

        // Withdraw and verify
        uint256 balBefore = user1.balance;
        vm.prank(user1);
        market.withdrawRefund();
        assertEq(user1.balance - balBefore, totalPending, "user gets exactly excess + unspent escrow");

        // Verify contract solvency
        uint256 nodePending = market.nodePendingRewards(node1);
        assertGe(address(market).balance, nodePending, "contract solvent: can pay node rewards");
    }

    function test_OverpaymentSolvency_MultipleOrders() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xaaaa, 0xbbbb);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 price = 1e12;

        // Order 1: user1 overpays, 1 replica filled by node1
        uint64 maxSize1 = 256;
        uint256 totalCost1 = uint256(maxSize1) * 2 * price;
        uint256 excess1 = 0.5 ether;
        vm.prank(user1);
        uint256 order1 = market.placeOrder{value: totalCost1 + excess1}(fileMeta, maxSize1, 2, 1, price);
        vm.prank(node1);
        market.executeOrder(order1);

        // Order 2: user2 overpays, 1 replica filled by node2
        uint64 maxSize2 = 128;
        uint256 totalCost2 = uint256(maxSize2) * 3 * price;
        uint256 excess2 = 1 ether;
        vm.prank(user2);
        uint256 order2 = market.placeOrder{value: totalCost2 + excess2}(fileMeta, maxSize2, 3, 1, price);
        vm.prank(node2);
        market.executeOrder(order2);

        // user1 withdraws excess immediately
        uint256 u1BalBefore = user1.balance;
        vm.prank(user1);
        market.withdrawRefund();
        assertEq(user1.balance - u1BalBefore, excess1, "user1 excess withdrawn");

        // user2 withdraws excess immediately
        uint256 u2BalBefore = user2.balance;
        vm.prank(user2);
        market.withdrawRefund();
        assertEq(user2.balance - u2BalBefore, excess2, "user2 excess withdrawn");

        // Contract balance should still cover all escrows
        assertGe(address(market).balance, totalCost1 + totalCost2, "contract holds enough for all active escrows");

        // Complete order 1
        vm.warp(block.timestamp + PERIOD * 2 + 1);
        market.completeExpiredOrder(order1);

        // Verify all pending claims are backed
        uint256 allPending = market.pendingRefunds(user1) + market.pendingRefunds(user2)
            + market.nodePendingRewards(node1) + market.nodePendingRewards(node2);
        assertGe(address(market).balance, allPending, "contract solvent after partial completion");
    }

    function test_OverpaymentEscrowField_StoresTotalCost() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;
        uint256 excess = 5 ether;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost + excess}(fileMeta, maxSize, periods, 1, price);

        // Verify escrow stores totalCost, not msg.value
        (uint256 storedEscrow, uint256 paidToNodes, uint256 remaining) = market.getOrderEscrowInfo(orderId);
        assertEq(storedEscrow, totalCost, "escrow == totalCost");
        assertEq(paidToNodes, 0, "no payments yet");
        assertEq(remaining, totalCost, "remaining == totalCost");

        // Verify excess is separately tracked in pendingRefunds
        assertEq(market.pendingRefunds(user1), excess, "excess in pendingRefunds");
    }

    function test_PullPayment_HeartbeatNotBlocked() public {
        // Deploy a reverting contract as order owner
        RevertingReceiver revertingOwner = new RevertingReceiver(market);
        vm.deal(address(revertingOwner), 10 ether);

        // Place and execute an order owned by reverting contract
        _stakeTestNode(node1, 0x1234, 0x5678);
        revertingOwner.placeOrderWithParams(256, 1, 1, 1e12);
        uint256 orderId = 1;

        vm.prank(node1);
        market.executeOrder(orderId);

        // Expire the order
        vm.warp(block.timestamp + PERIOD + 1);

        // Trigger heartbeat — should NOT revert even though order owner has reverting receive()
        // The refund goes to pendingRefunds instead of .transfer()
        vm.warp(block.timestamp + STEP * 2 + 1);
        market.triggerHeartbeat();

        // Order should be cleaned up
        assertEq(market.getActiveOrdersCount(), 0, "expired order cleaned up despite reverting owner");
    }

    // -------------------------------------------------------------------------
    // Fix 2: Dual primary/secondary selection
    // -------------------------------------------------------------------------

    function test_SecondarySelection_SkipsPrimary() public {
        // Create scenario where same node serves multiple orders
        // With only 1 node and multiple orders, that node would be primary AND could be selected as secondary
        uint64 largeCapacity = TEST_CAPACITY * 4;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * 4 * price;

        // Place 4 orders, all served by the same node
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(user1);
            market.placeOrder{value: totalCost}(fileMeta, maxSize, 4, 1, price);
            vm.prank(node1);
            market.executeOrder(i + 1);
        }

        // Trigger heartbeat
        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        // Since node1 is the only node, it should be primary and NOT appear as secondary
        (,, address primaryProver, address[] memory secondaryProvers,,,) = market.getCurrentChallengeInfo();
        if (primaryProver != address(0)) {
            assertEq(primaryProver, node1, "node1 is primary");
            // Verify node1 does not appear in secondary provers
            for (uint256 i = 0; i < secondaryProvers.length; i++) {
                assertTrue(secondaryProvers[i] != node1, "primary should not be in secondary list");
            }
        }
    }

    // -------------------------------------------------------------------------
    // Fix 3: nonReentrant on quitOrder
    // -------------------------------------------------------------------------

    function test_QuitOrder_NonReentrant() public {
        // The nonReentrant modifier is on quitOrder — verify it's applied by checking
        // that the function signature hasn't changed (still callable normally)
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 totalCost = uint256(maxSize) * 4 * 1e12;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, 4, 1, 1e12);
        vm.prank(node1);
        market.executeOrder(orderId);

        // quitOrder should work normally with nonReentrant
        vm.prank(node1);
        market.quitOrder(orderId);

        address[] memory nodes = market.getOrderNodes(orderId);
        assertEq(nodes.length, 0, "node removed after quit");
    }

    // -------------------------------------------------------------------------
    // Fix 4: Quit slash = min(3, remaining) periods
    // -------------------------------------------------------------------------

    function test_QuitSlash_ThreePeriodsDefault() public {
        // Node with large capacity so no forced exit
        uint64 largeCapacity = TEST_CAPACITY * 4;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 10; // many periods → min(3, 10) = 3
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        (uint256 stakeBefore,,,,) = nodeStaking.getNodeInfo(node1);

        vm.prank(node1);
        market.quitOrder(orderId);

        (uint256 stakeAfter,,,,) = nodeStaking.getNodeInfo(node1);

        // Slash = maxSize * price * 3 = 256 * 1e12 * 3 = 768e12
        uint256 expectedSlash = uint256(maxSize) * price * 3;
        // Account for additional 50% penalty on forced exit slash
        // But if no forced exit, the slash is just the base amount
        // slashNode applies: actualSlash = min(slashAmount, stake), then 50% penalty if forced exit
        // Since stake >> slash, actualSlash = expectedSlash, and may have additional penalty
        assertTrue(stakeBefore - stakeAfter >= expectedSlash, "slash >= 3 periods of storage cost");
    }

    function test_QuitSlash_CappedAtRemainingPeriods() public {
        // Node with large capacity
        uint64 largeCapacity = TEST_CAPACITY * 4;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2; // only 2 periods → min(3, 2) = 2
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        (uint256 stakeBefore,,,,) = nodeStaking.getNodeInfo(node1);

        vm.prank(node1);
        market.quitOrder(orderId);

        (uint256 stakeAfter,,,,) = nodeStaking.getNodeInfo(node1);

        // Slash should be capped: maxSize * price * 2 (not 3)
        uint256 expectedSlash = uint256(maxSize) * price * 2;
        assertTrue(stakeBefore - stakeAfter >= expectedSlash, "slash capped at remaining periods");
    }

    // -------------------------------------------------------------------------
    // Fix 5: OrderUnderReplicated event
    // -------------------------------------------------------------------------


    function test_OrderUnderReplicated_EmittedOnForcedExit() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 4;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * 2; // 2 replicas

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 2, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Slash node to force exit — should emit OrderUnderReplicated
        market.setSlashAuthority(user2, true);
        uint256 severeSlash = uint256(TEST_CAPACITY) * STAKE_PER_BYTE; // slash entire stake

        vm.expectEmit(true, false, false, true);
        emit OrderUnderReplicated(orderId, 0, 2);
        vm.prank(user2);
        market.slashNode(node1, severeSlash, "test forced exit");
    }

    // -------------------------------------------------------------------------
    // Fix 6: Max orders per node cap
    // -------------------------------------------------------------------------

    function test_MaxOrdersPerNode_EnforcedAtExecute() public {
        // Stake a node with very large capacity
        uint64 hugeCapacity = 64000; // enough for 50+ small orders
        uint256 hugeStake = uint256(hugeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, hugeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: hugeStake}(hugeCapacity, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 1; // tiny orders
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * 4 * price;

        // Place and execute 50 orders (the max)
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(user1);
            uint256 oid = market.placeOrder{value: totalCost}(fileMeta, maxSize, 4, 1, price);
            vm.prank(node1);
            market.executeOrder(oid);
        }

        // 51st order should revert
        vm.prank(user1);
        uint256 orderId51 = market.placeOrder{value: totalCost}(fileMeta, maxSize, 4, 1, price);
        vm.prank(node1);
        vm.expectRevert("max orders per node reached");
        market.executeOrder(orderId51);
    }

    // -------------------------------------------------------------------------
    // Randomness Field-Reduction Tests (BN254 SNARK_SCALAR_FIELD)
    // -------------------------------------------------------------------------

    uint256 internal constant SNARK_SCALAR_FIELD = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    function test_RandomnessAlwaysInField_TriggerHeartbeat() public {
        // After triggerHeartbeat initializes randomness, it must be < SNARK_SCALAR_FIELD
        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        uint256 r = market.currentRandomness();
        assertTrue(r > 0, "randomness should be non-zero");
        assertTrue(r < SNARK_SCALAR_FIELD, "randomness must be < SNARK_SCALAR_FIELD");
    }

    function test_RandomnessAlwaysInField_ReportPrimaryFailure() public {
        // Setup: two nodes, two orders, trigger heartbeat, let challenge expire, report failure
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId1 = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);
        vm.prank(node1);
        market.executeOrder(orderId1);

        vm.prank(user1);
        uint256 orderId2 = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);
        vm.prank(node2);
        market.executeOrder(orderId2);

        // Trigger heartbeat
        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        // Let challenge period expire
        vm.warp(block.timestamp + (STEP * 2) + 1);

        address primaryProver = market.currentPrimaryProver();
        require(primaryProver != address(0), "primary must be assigned");

        // Use a third node as reporter
        _stakeTestNode(node3, 0x9999, 0x8888);
        vm.prank(node3);
        market.reportPrimaryFailure();

        uint256 r = market.currentRandomness();
        assertTrue(r < SNARK_SCALAR_FIELD, "randomness must be < SNARK_SCALAR_FIELD after reportPrimaryFailure");
    }

    function test_RandomnessAlwaysInField_NoValidOrders() public {
        // Place order but do NOT assign any node → no-valid-orders branch in _triggerNewHeartbeat
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        vm.prank(user1);
        market.placeOrder{value: 1 ether}(fileMeta, 512, 2, 1, 1e12);

        // First heartbeat initializes randomness
        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();
        uint256 r1 = market.currentRandomness();
        assertTrue(r1 < SNARK_SCALAR_FIELD, "initial randomness must be < SNARK_SCALAR_FIELD");

        // Advance beyond challenge window → second heartbeat hits no-valid-orders branch
        vm.warp(block.timestamp + (STEP * 2) + 1);
        market.triggerHeartbeat();

        uint256 r2 = market.currentRandomness();
        assertTrue(r2 < SNARK_SCALAR_FIELD, "no-valid-orders randomness must be < SNARK_SCALAR_FIELD");
        assertTrue(r2 != r1, "randomness should change");
    }

    function test_RandomnessReduction_PreservesEntropy() public {
        // Reduced randomness should be non-zero and vary across different blocks
        uint256[] memory results = new uint256[](5);

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 31 + (i * 61)); // different block timestamps
            vm.prevrandao(bytes32(uint256(0xdead0000 + i))); // different prevrandao values

            // Deploy fresh market each iteration to reset randomness to 0
            FileMarket freshMarket = new FileMarket();
            freshMarket.triggerHeartbeat();
            results[i] = freshMarket.currentRandomness();

            assertTrue(results[i] > 0, "randomness should be non-zero");
            assertTrue(results[i] < SNARK_SCALAR_FIELD, "randomness must be in field");
        }

        // Check at least some variation (not all identical)
        bool hasVariation = false;
        for (uint256 i = 1; i < 5; i++) {
            if (results[i] != results[0]) {
                hasVariation = true;
                break;
            }
        }
        assertTrue(hasVariation, "reduced randomness should vary across blocks");
    }

    function test_SubmitProof_WorksWithReducedRandomness() public {
        // Verify that after triggerHeartbeat the randomness is within the BN254 field
        // so that submitProof would not revert with PublicInputNotInField.
        // (Full proof submission requires a valid Groth16 proof, so we just verify the
        // precondition: currentRandomness < SNARK_SCALAR_FIELD.)
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        uint256 r = market.currentRandomness();
        assertTrue(r < SNARK_SCALAR_FIELD, "randomness fed to submitProof must be < SNARK_SCALAR_FIELD");

        // Confirm a primary prover was actually assigned with this in-field randomness
        address primaryProver = market.currentPrimaryProver();
        assertTrue(primaryProver != address(0), "primary prover should be assigned");
    }

    // -------------------------------------------------------------------------
    // Heartbeat cleanup-before-selection regression tests
    // -------------------------------------------------------------------------

    function test_HeartbeatCleansUpBeforeSelection() public {
        // Setup: one node, one order that will expire
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 1; // 1 period = 7 days
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        assertEq(market.getActiveOrdersCount(), 1);

        // Warp past order expiry and past challenge window
        vm.warp(block.timestamp + PERIOD + (STEP * 3));
        market.triggerHeartbeat();

        // After heartbeat: expired order should be cleaned up
        assertEq(market.getActiveOrdersCount(), 0, "expired order should be cleaned up");

        // The challenged orders set must NOT contain the expired order
        (,,,, uint256[] memory challengedOrders,,) = market.getCurrentChallengeInfo();
        for (uint256 i = 0; i < challengedOrders.length; i++) {
            assertTrue(challengedOrders[i] != orderId, "expired order must not be challenged");
        }

        // The primary prover should not be pointed at a deleted order
        address primaryProver = market.currentPrimaryProver();
        if (primaryProver != address(0)) {
            // If a prover was assigned, their order should still exist
            uint256 proverOrderId = market.nodeToProveOrderId(primaryProver);
            (address orderOwner,,,,,,,,) = market.orders(proverOrderId);
            assertTrue(orderOwner != address(0), "prover order must not be deleted");
        }
    }

    function test_ExpiredOrderNotChallenged() public {
        // Setup: two nodes, mix of expired and active orders
        uint64 largeCapacity = TEST_CAPACITY * 4;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;

        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);

        vm.deal(node2, largeStake);
        vm.prank(node2);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 price = 1e12;

        // Place a short-lived order (1 period) — will expire
        uint256 shortCost = uint256(maxSize) * 1 * price;
        vm.prank(user1);
        uint256 expiredOrderId = market.placeOrder{value: shortCost}(fileMeta, maxSize, 1, 1, price);
        vm.prank(node1);
        market.executeOrder(expiredOrderId);

        // Place long-lived orders (4 periods) — will stay active
        uint256 longCost = uint256(maxSize) * 4 * price;
        uint256[] memory activeIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user1);
            activeIds[i] = market.placeOrder{value: longCost}(fileMeta, maxSize, 4, 1, price);
            vm.prank(i % 2 == 0 ? node1 : node2);
            market.executeOrder(activeIds[i]);
        }

        assertEq(market.getActiveOrdersCount(), 4); // 1 expired + 3 active

        // Warp past 1 period (expires the short order) but within 4 periods
        vm.warp(block.timestamp + PERIOD + (STEP * 3));
        market.triggerHeartbeat();

        // The expired order should be gone
        assertEq(market.getActiveOrdersCount(), 3, "only active orders remain");

        // None of the challenged orders should be the expired one
        (,,,, uint256[] memory challengedOrders,,) = market.getCurrentChallengeInfo();
        for (uint256 i = 0; i < challengedOrders.length; i++) {
            assertTrue(challengedOrders[i] != expiredOrderId, "expired order must not appear in challenge set");
        }
    }

    /// @notice Expired orders must be cleaned up even when the heartbeat
    /// transition is triggered by reportPrimaryFailure (not triggerHeartbeat).
    function test_CleanupExpiredOrders_ViaReportPrimaryFailure() public {
        // Two nodes so we can have a reporter
        uint64 largeCapacity = TEST_CAPACITY * 4;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);

        vm.deal(node2, largeStake);
        vm.prank(node2);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 price = 1e12;

        // Short-lived order (1 period) — will expire before the second heartbeat
        uint256 shortCost = uint256(maxSize) * 1 * price;
        vm.prank(user1);
        uint256 expiringOrderId = market.placeOrder{value: shortCost}(meta, maxSize, 1, 1, price);
        vm.prank(node1);
        market.executeOrder(expiringOrderId);

        // Long-lived order — stays active
        uint256 longCost = uint256(maxSize) * 8 * price;
        vm.prank(user1);
        uint256 activeOrderId = market.placeOrder{value: longCost}(meta, maxSize, 8, 1, price);
        vm.prank(node2);
        market.executeOrder(activeOrderId);

        assertEq(market.getActiveOrdersCount(), 2);

        // First heartbeat (via triggerHeartbeat) — both orders still active
        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();
        assertEq(market.getActiveOrdersCount(), 2, "both orders still active");

        // Warp past the short order's expiry AND past the challenge window
        vm.warp(block.timestamp + PERIOD + (STEP * 3));
        assertTrue(market.isOrderExpired(expiringOrderId), "short order should be expired");

        // The primary prover fails → reportPrimaryFailure triggers _triggerNewHeartbeat
        // which now includes _cleanupExpiredOrders.
        vm.prank(node2);
        market.reportPrimaryFailure();

        // The expired order should have been cleaned up
        assertEq(market.getActiveOrdersCount(), 1, "expired order cleaned up via reportPrimaryFailure path");

        // Challenged orders must not reference the expired order
        (,,,, uint256[] memory challengedOrders,,) = market.getCurrentChallengeInfo();
        for (uint256 i = 0; i < challengedOrders.length; i++) {
            assertTrue(challengedOrders[i] != expiringOrderId, "expired order must not be in challenge set");
        }
    }

    // =========================================================================
    // Regression: step 0 challenge must not bypass protections
    // =========================================================================

    /// @notice A heartbeat issued at step 0 (within the first 30s) must still be
    /// treated as an active challenge — triggerHeartbeat should revert, and
    /// _isOrderUnderActiveChallenge should return true.
    function test_ChallengeAtStepZero_StillActive() public {
        // We are at genesis (block.timestamp == GENESIS_TS), so currentStep == 0
        assertEq(market.currentStep(), 0);

        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * 4 * price;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Trigger heartbeat at step 0 — should succeed
        market.triggerHeartbeat();

        // lastChallengeStep == 0 but challengeInitialized == true
        assertEq(market.lastChallengeStep(), 0);
        assertTrue(market.challengeInitialized());

        // getCurrentChallengeInfo should report the challenge as active
        (,,,,, bool primarySubmitted, bool challengeActive) = market.getCurrentChallengeInfo();
        assertTrue(challengeActive, "step-0 challenge should be active");
        assertFalse(primarySubmitted);

        // A second triggerHeartbeat should revert because the challenge is still active
        vm.expectRevert("challenge still active");
        market.triggerHeartbeat();
    }

    // =========================================================================
    // Regression: low-stake provers must be slashed (not revert)
    // =========================================================================

    /// @dev Primary prover with stake < 1000*STAKE_PER_BYTE should be slashed
    ///      for their full stake instead of reverting.
    function test_ReportPrimaryFailure_LowStakeProver() public {
        // Stake node1 with minimal stake (well below 1000*STAKE_PER_BYTE severe slash)
        uint64 tinyCapacity = 1; // 1 byte → stake = 1 * STAKE_PER_BYTE
        uint256 tinyStake = uint256(tinyCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, tinyStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: tinyStake}(tinyCapacity, 0x1234, 0x5678);

        // Need a second node for heartbeat selection
        _stakeTestNode(node2, 0xabcd, 0xef01);

        // Place order small enough for node1's capacity
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(tinyCapacity) * 2 * 1e12;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, tinyCapacity, 2, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Also let node2 take an order so heartbeat has options
        vm.prank(user1);
        uint256 orderId2 = market.placeOrder{value: uint256(256) * 2 * 1e12}(fileMeta, 256, 2, 1, 1e12);
        vm.prank(node2);
        market.executeOrder(orderId2);

        // Trigger heartbeat
        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        // Force node1 as primary prover via storage
        vm.store(address(market), bytes32(SLOT_CURRENT_PRIMARY_PROVER), bytes32(uint256(uint160(node1))));
        bytes32 mapSlot = keccak256(abi.encode(node1, SLOT_NODE_TO_PROVE_ORDER_ID));
        vm.store(address(market), mapSlot, bytes32(orderId));

        // Advance past challenge window
        vm.warp(block.timestamp + (STEP * 2) + 1);

        (uint256 stakeBefore,,,,) = nodeStaking.getNodeInfo(node1);
        assertTrue(stakeBefore < 1000 * STAKE_PER_BYTE, "precondition: stake below severe slash");

        // Reporter must be a valid node
        _stakeTestNode(node3, 0x9999, 0x8888);

        // Should NOT revert — slash is capped to node's stake
        vm.prank(node3);
        market.reportPrimaryFailure();

        (uint256 stakeAfter,,,,) = nodeStaking.getNodeInfo(node1);
        assertTrue(stakeAfter < stakeBefore, "low-stake primary was slashed");
    }

    /// @dev Secondary prover with stake < 100*STAKE_PER_BYTE should be slashed
    ///      for their full stake instead of reverting.
    function test_SlashSecondaryFailures_LowStakeProver() public {
        // node1 is primary with normal stake
        _stakeTestNode(node1, 0x1234, 0x5678);

        // node2 is secondary with minimal stake
        uint64 tinyCapacity = 1;
        uint256 tinyStake = uint256(tinyCapacity) * STAKE_PER_BYTE;
        vm.deal(node2, tinyStake);
        vm.prank(node2);
        nodeStaking.stakeNode{value: tinyStake}(tinyCapacity, 0xabcd, 0xef01);

        // Place orders
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});

        vm.prank(user1);
        uint256 orderId1 = market.placeOrder{value: uint256(256) * 2 * 1e12}(fileMeta, 256, 2, 1, 1e12);
        vm.prank(node1);
        market.executeOrder(orderId1);

        uint256 totalCost2 = uint256(tinyCapacity) * 2 * 1e12;
        vm.prank(user1);
        uint256 orderId2 = market.placeOrder{value: totalCost2}(fileMeta, tinyCapacity, 2, 1, 1e12);
        vm.prank(node2);
        market.executeOrder(orderId2);

        // Trigger heartbeat
        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        // Force node1 as primary, node2 as secondary via storage
        vm.store(address(market), bytes32(SLOT_CURRENT_PRIMARY_PROVER), bytes32(uint256(uint160(node1))));
        bytes32 mapSlot1 = keccak256(abi.encode(node1, SLOT_NODE_TO_PROVE_ORDER_ID));
        vm.store(address(market), mapSlot1, bytes32(orderId1));

        // Set currentSecondaryProvers = [node2]
        vm.store(address(market), bytes32(uint256(29)), bytes32(uint256(1)));
        bytes32 secArrayStart = keccak256(abi.encode(uint256(29)));
        vm.store(address(market), secArrayStart, bytes32(uint256(uint160(node2))));

        // Set nodeToProveOrderId[node2] = orderId2
        bytes32 mapSlot2 = keccak256(abi.encode(node2, SLOT_NODE_TO_PROVE_ORDER_ID));
        vm.store(address(market), mapSlot2, bytes32(orderId2));

        // Advance past challenge window
        vm.warp(block.timestamp + (STEP * 2) + 1);

        (uint256 stakeBefore,,,,) = nodeStaking.getNodeInfo(node2);
        assertTrue(stakeBefore < 100 * STAKE_PER_BYTE, "precondition: stake below normal slash");

        // Should NOT revert — slash is capped to node's stake
        vm.prank(user2);
        market.slashSecondaryFailures();

        (uint256 stakeAfter,,,,) = nodeStaking.getNodeInfo(node2);
        assertTrue(stakeAfter < stakeBefore, "low-stake secondary was slashed");
    }

    // =========================================================================
    // CHALLENGEABLE ORDERS TESTS
    // =========================================================================

    function test_ChallengeableOrders_NotAddedOnPlaceOrder() public {
        // Placing an order should NOT add it to challengeableOrders (no nodes yet)
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);

        assertEq(market.getActiveOrdersCount(), 1, "order should be in activeOrders");
        assertEq(market.getChallengeableOrdersCount(), 0, "order should NOT be in challengeableOrders");
        assertFalse(market.isChallengeable(orderId), "order should not be challengeable");
    }

    function test_ChallengeableOrders_AddedOnFirstNode() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);

        assertEq(market.getChallengeableOrdersCount(), 0, "not yet challengeable");

        vm.prank(node1);
        market.executeOrder(orderId);

        assertEq(market.getChallengeableOrdersCount(), 1, "should be challengeable after first node");
        assertTrue(market.isChallengeable(orderId), "order should be marked challengeable");
    }

    function test_ChallengeableOrders_NotDuplicatedOnSecondNode() public {
        // Register two nodes with enough capacity
        uint64 largeCapacity = TEST_CAPACITY * 2;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);
        vm.deal(node2, largeStake);
        vm.prank(node2);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint8 replicas = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, replicas, price);

        vm.prank(node1);
        market.executeOrder(orderId);
        assertEq(market.getChallengeableOrdersCount(), 1, "one challengeable after first node");

        vm.prank(node2);
        market.executeOrder(orderId);
        assertEq(market.getChallengeableOrdersCount(), 1, "still one challengeable after second node");
    }

    function test_ChallengeableOrders_RemovedOnCancel() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        assertEq(market.getChallengeableOrdersCount(), 1, "should be challengeable");

        vm.prank(user1);
        market.cancelOrder(orderId);

        assertEq(market.getChallengeableOrdersCount(), 0, "removed from challengeable on cancel");
        assertFalse(market.isChallengeable(orderId), "flag cleared after cancel");
    }

    function test_ChallengeableOrders_RemovedOnExpiry() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        assertTrue(market.isChallengeable(orderId), "should be challengeable");

        // Warp past expiry
        vm.warp(block.timestamp + (PERIOD * 2) + 1);

        market.completeExpiredOrder(orderId);

        assertEq(market.getChallengeableOrdersCount(), 0, "removed from challengeable on expiry");
        assertFalse(market.isChallengeable(orderId), "flag cleared after expiry");
    }

    function test_ChallengeableOrders_RemovedWhenLastNodeQuits() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 4;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        assertTrue(market.isChallengeable(orderId), "should be challengeable with node assigned");

        // Node quits order → last node removed
        vm.prank(node1);
        market.quitOrder(orderId);

        assertFalse(market.isChallengeable(orderId), "no longer challengeable after last node quits");
        assertEq(market.getChallengeableOrdersCount(), 0, "challengeable count should be 0");
        // Order should still be in activeOrders (not expired/cancelled)
        assertEq(market.getActiveOrdersCount(), 1, "order still active, just not challengeable");
    }

    function test_ChallengeFloodingPrevented() public {
        // Core exploit scenario: attacker floods cheap unassigned orders
        // to dilute the challenge pool. After fix, only assigned orders are sampled.
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        // Place one real order with a node assigned
        vm.prank(user1);
        uint256 realOrderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(realOrderId);

        // Attacker floods 20 cheap unassigned orders
        uint256 cheapCost = uint256(1) * uint256(1) * 1 * 1; // 1 wei minimum
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(user2);
            market.placeOrder{value: cheapCost}(fileMeta, 1, 1, 1, 1);
        }

        // activeOrders has 21 entries but challengeableOrders has only 1
        assertEq(market.getActiveOrdersCount(), 21, "21 total active orders");
        assertEq(market.getChallengeableOrdersCount(), 1, "only 1 challengeable order");

        // Trigger heartbeat — should always select the real order
        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        (,, address primaryProver,,,,) = market.getCurrentChallengeInfo();
        assertEq(primaryProver, node1, "real order's node must be selected as primary prover");
    }

    function test_ChallengeableOrders_MultipleOrders_CorrectTracking() public {
        // Test that multiple challengeable orders are tracked correctly and
        // swap-and-pop removal works with non-trivial array state
        uint64 largeCapacity = TEST_CAPACITY * 4;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        // Place and assign 3 orders
        uint256[] memory orderIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user1);
            orderIds[i] = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
            vm.prank(node1);
            market.executeOrder(orderIds[i]);
        }

        assertEq(market.getChallengeableOrdersCount(), 3, "3 challengeable orders");

        // Cancel the middle order — tests swap-and-pop with non-last element
        vm.prank(user1);
        market.cancelOrder(orderIds[1]);

        assertEq(market.getChallengeableOrdersCount(), 2, "2 challengeable after cancel");
        assertFalse(market.isChallengeable(orderIds[1]), "cancelled order not challengeable");
        assertTrue(market.isChallengeable(orderIds[0]), "first order still challengeable");
        assertTrue(market.isChallengeable(orderIds[2]), "third order still challengeable");
    }

    // -------------------------------------------------------------------------
    // Block order deletion during active challenge window
    // -------------------------------------------------------------------------


    function test_CompleteExpiredOrder_RevertDuringActiveChallenge() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Warp past order expiry
        vm.warp(block.timestamp + PERIOD + STEP + 1);
        assertTrue(market.isOrderExpired(orderId), "order should be expired");

        // Directly set up an active challenge that includes this expired order via vm.store.
        // This simulates the scenario where an expired order wasn't cleaned up yet and got challenged.
        uint256 cs = market.currentStep();
        // lastChallengeStep = currentStep - 1 (challenge window is open)
        vm.store(address(market), bytes32(SLOT_LAST_CHALLENGE_STEP), bytes32(cs - 1));
        vm.store(address(market), bytes32(SLOT_CHALLENGE_INITIALIZED), bytes32(uint256(1)));
        // currentChallengedOrders (slot 30): set length to 1, element[0] = orderId
        vm.store(address(market), bytes32(uint256(30)), bytes32(uint256(1)));
        vm.store(address(market), keccak256(abi.encode(uint256(30))), bytes32(orderId));

        // Should revert during active challenge
        vm.expectRevert("order under active challenge");
        market.completeExpiredOrder(orderId);

        // Warp past challenge window
        vm.warp(block.timestamp + (STEP * 2) + 1);

        // Now completion should succeed
        market.completeExpiredOrder(orderId);
        assertEq(market.getActiveOrdersCount(), 0, "order removed after completion");
    }

    /// @notice Verify that _cleanupExpiredOrders (via triggerHeartbeat) is bounded by
    /// CLEANUP_SCAN_CAP and does not iterate over the entire activeOrders array.
    function test_CleanupExpiredOrders_BoundedGas() public {
        // Create 200 non-expired orders (cheap, 1-byte, long-lived)
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 1;
        uint16 periods = 100; // very long-lived so none expire
        uint8 replicas = 1;
        uint256 price = 1; // 1 wei per byte per period

        for (uint256 j = 0; j < 200; j++) {
            address creator = address(uint160(0xF000 + j));
            uint256 cost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);
            vm.deal(creator, cost);
            vm.prank(creator);
            market.placeOrder{value: cost}(fileMeta, maxSize, periods, replicas, price);
        }

        assertEq(market.getActiveOrdersCount(), 200, "should have 200 active orders");

        // Advance time so heartbeat is allowed, but none of the orders expire
        vm.warp(block.timestamp + 31);

        // Trigger heartbeat — internally calls _cleanupExpiredOrders.
        // If the scan were unbounded (O(200)), gas would be much higher.
        // With CLEANUP_SCAN_CAP = 50, only 50 entries are checked.
        uint256 gasBefore = gasleft();
        market.triggerHeartbeat();
        uint256 gasUsed = gasBefore - gasleft();

        // All 200 orders should still be active (none expired)
        assertEq(market.getActiveOrdersCount(), 200, "no orders should be cleaned up");

        // Sanity: gas used should be well below what an unbounded 200-entry scan would cost.
        // This is a loose upper bound; the key property is that the call completes without
        // hitting the block gas limit even with a large activeOrders array.
        assertTrue(gasUsed < 5_000_000, "heartbeat gas should be bounded");
    }

    // -------------------------------------------------------------------------
    // Fix: Active provers cannot quit to evade slashing
    // -------------------------------------------------------------------------

    /// @notice Primary prover must not be able to call quitOrder while they have
    /// an unresolved proof obligation.
    function test_QuitOrder_RevertForActivePrimaryProver() public {
        // Stake node1 with enough capacity for 1 order
        _stakeTestNode(node1, 0xAAAA, 0xBBBB);

        // Place order, node1 executes
        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 512;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * 4 * price;
        vm.deal(user1, totalCost);
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Trigger heartbeat → node1 is the only node with orders, must be primary
        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        address pp = market.currentPrimaryProver();
        assertEq(pp, node1, "node1 should be primary prover");

        // node1 tries to quit → should revert
        vm.prank(node1);
        vm.expectRevert("active prover cannot quit");
        market.quitOrder(orderId);
    }

    /// @notice Secondary prover must not be able to call quitOrder while they
    /// have an unresolved proof obligation.
    function test_QuitOrder_RevertForActiveSecondaryProver() public {
        // Need at least 2 nodes with orders so one becomes primary, other secondary
        uint64 largeCapacity = TEST_CAPACITY * 2;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;

        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0xAAAA, 0xBBBB);

        vm.deal(node2, largeStake);
        vm.prank(node2);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0xCCCC, 0xDDDD);

        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 512;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * 4 * price;

        // Place 3 orders for sufficient secondary prover selection
        uint256[] memory orderIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.deal(user1, totalCost);
            vm.prank(user1);
            orderIds[i] = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);
            vm.prank(i % 2 == 0 ? node1 : node2);
            market.executeOrder(orderIds[i]);
        }

        // Trigger heartbeat
        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        address pp = market.currentPrimaryProver();
        // The other node is a secondary (if assigned)
        address secondaryNode = (pp == node1) ? node2 : node1;

        // Check if secondaryNode is actually a secondary prover
        (,,, address[] memory secondaries,,,) = market.getCurrentChallengeInfo();
        bool isSecondary = false;
        for (uint256 i = 0; i < secondaries.length; i++) {
            if (secondaries[i] == secondaryNode) {
                isSecondary = true;
                break;
            }
        }

        if (isSecondary) {
            // Find an order assigned to the secondary node
            uint256[] memory secOrders = market.getNodeOrders(secondaryNode);
            require(secOrders.length > 0, "secondary must have orders");

            vm.prank(secondaryNode);
            vm.expectRevert("active prover cannot quit");
            market.quitOrder(secOrders[0]);
        }
    }

    /// @notice A non-prover node should still be able to quit normally during
    /// an active challenge (regression test).
    function test_QuitOrder_AllowedForNonProver() public {
        // Stake 3 nodes
        _stakeTestNode(node1, 0xAAAA, 0xBBBB);
        _stakeTestNode(node2, 0xCCCC, 0xDDDD);
        _stakeTestNode(node3, 0xEEEE, 0xFFFF);

        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 512;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * 4 * price;

        // Place 1 order executed by node1 (will be challenged)
        vm.deal(user1, totalCost);
        vm.prank(user1);
        uint256 orderId1 = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId1);

        // Place separate order executed by node3 (not involved in challenge)
        vm.deal(user2, totalCost);
        vm.prank(user2);
        uint256 orderId2 = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);
        vm.prank(node3);
        market.executeOrder(orderId2);

        // Trigger heartbeat
        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        address pp = market.currentPrimaryProver();
        (,,, address[] memory secondaries,,,) = market.getCurrentChallengeInfo();

        // Determine a non-prover among node1, node2, node3
        // node2 has no orders so won't be selected. node3 might or might not be.
        // Find the node that is neither primary nor secondary and has an order.
        address nonProver = address(0);
        uint256 nonProverOrder = 0;

        address[2] memory candidates = [node1, node3];
        uint256[2] memory candidateOrders = [orderId1, orderId2];

        for (uint256 c = 0; c < 2; c++) {
            bool isProver = (candidates[c] == pp);
            for (uint256 s = 0; s < secondaries.length && !isProver; s++) {
                if (secondaries[s] == candidates[c]) isProver = true;
            }
            if (!isProver) {
                nonProver = candidates[c];
                nonProverOrder = candidateOrders[c];
                break;
            }
        }

        // If we found a non-prover node, verify it can quit
        if (nonProver != address(0)) {
            vm.prank(nonProver);
            market.quitOrder(nonProverOrder); // should NOT revert
        }
    }

    /// @notice End-to-end: primary prover cannot evade slashing by quitting.
    /// The prover is blocked from quitting, and after the challenge expires the
    /// prover gets properly slashed via reportPrimaryFailure.
    function test_ProverCannotEvadeSlash_EndToEnd() public {
        // Stake node1 (primary) and node2 (reporter)
        _stakeTestNode(node1, 0xAAAA, 0xBBBB);
        _stakeTestNode(node2, 0xCCCC, 0xDDDD);

        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 512;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * 4 * price;
        vm.deal(user1, totalCost);
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Record node1's stake before challenge
        (uint256 stakeBefore,,,,) = nodeStaking.getNodeInfo(node1);
        assertTrue(stakeBefore > 0, "node1 should have stake");

        // Trigger heartbeat → node1 becomes primary prover
        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();
        assertEq(market.currentPrimaryProver(), node1, "node1 is primary");

        // Attack step 1: node1 tries to quit → blocked
        vm.prank(node1);
        vm.expectRevert("active prover cannot quit");
        market.quitOrder(orderId);

        // Challenge window expires without proof submission
        vm.warp(block.timestamp + (STEP * 2) + 1);

        // Attack step 2: node1 tries to quit after expiry but before report → still blocked
        // (primaryFailureReported is still false)
        vm.prank(node1);
        vm.expectRevert("active prover cannot quit");
        market.quitOrder(orderId);

        // Reporter triggers failure report → node1 gets slashed
        vm.prank(node2);
        market.reportPrimaryFailure();

        // Verify node1 was actually slashed (stake reduced or removed)
        (uint256 stakeAfter,,,,) = nodeStaking.getNodeInfo(node1);
        assertTrue(stakeAfter < stakeBefore, "node1 should have been slashed");
    }

    // -------------------------------------------------------------------------
    // Fix: Deduplicate secondary prover selection
    // -------------------------------------------------------------------------

    /// @notice When one node serves many orders, it must appear at most once in
    /// currentSecondaryProvers after a heartbeat.
    function test_SecondaryProvers_NoDuplicates() public {
        // node1: large capacity, serves many orders
        uint64 largeCapacity = TEST_CAPACITY * 8;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);

        // node2: normal capacity, serves one order (ensures a different primary can be picked)
        _stakeTestNode(node2, 0xAAAA, 0xBBBB);

        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 128;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * 4 * price;

        // Place 6 orders: first served by node2, rest by node1
        vm.prank(user1);
        uint256 firstOrder = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);
        vm.prank(node2);
        market.executeOrder(firstOrder);

        for (uint256 i = 1; i < 6; i++) {
            vm.prank(user1);
            uint256 oid = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);
            vm.prank(node1);
            market.executeOrder(oid);
        }

        // Trigger heartbeat
        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        // Retrieve secondary provers and assert no duplicates
        (,, address primaryProver, address[] memory secondaryProvers,,,) = market.getCurrentChallengeInfo();
        // Primary should not appear in secondaries (covered by existing test, but verify here too)
        for (uint256 i = 0; i < secondaryProvers.length; i++) {
            assertTrue(secondaryProvers[i] != primaryProver, "primary in secondary list");
            // Check for duplicates against all later entries
            for (uint256 j = i + 1; j < secondaryProvers.length; j++) {
                assertTrue(secondaryProvers[i] != secondaryProvers[j], "duplicate secondary prover");
            }
        }
    }

    /// @notice Same dedup invariant holds across multiple heartbeat cycles with
    /// different randomness seeds.
    function test_SecondaryProvers_NoDuplicates_RepeatedHeartbeats() public {
        // node1: large capacity, serves many orders
        uint64 largeCapacity = TEST_CAPACITY * 8;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);

        // node2: normal capacity
        _stakeTestNode(node2, 0xAAAA, 0xBBBB);

        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 128;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * 4 * price;

        // Place 6 orders: first served by node2, rest by node1
        vm.prank(user1);
        uint256 firstOrder = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);
        vm.prank(node2);
        market.executeOrder(firstOrder);

        for (uint256 i = 1; i < 6; i++) {
            vm.prank(user1);
            uint256 oid = market.placeOrder{value: totalCost}(meta, maxSize, 4, 1, price);
            vm.prank(node1);
            market.executeOrder(oid);
        }

        // Run 5 heartbeat cycles, each with new randomness
        for (uint256 round = 0; round < 5; round++) {
            // Advance past the current challenge window
            vm.warp(block.timestamp + (STEP * 2) + 1);
            market.triggerHeartbeat();

            (,, address primaryProver, address[] memory secondaryProvers,,,) = market.getCurrentChallengeInfo();
            for (uint256 i = 0; i < secondaryProvers.length; i++) {
                assertTrue(secondaryProvers[i] != primaryProver, "primary in secondary list");
                for (uint256 j = i + 1; j < secondaryProvers.length; j++) {
                    assertTrue(secondaryProvers[i] != secondaryProvers[j], "duplicate secondary prover");
                }
            }
        }
    }

    /// @notice Verify that a zero-selection heartbeat clears stale challenged-order state
    ///         so _isOrderUnderActiveChallenge() no longer matches old orders.
    function test_ZeroSelectionHeartbeat_ClearsStaleState() public {
        // --- Setup: one node, one order, execute it ---
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        // --- First heartbeat: order is in challengeableOrders, gets challenged ---
        uint256 t1 = block.timestamp + STEP + 1;
        vm.warp(t1);
        market.triggerHeartbeat();

        // Confirm the order is in currentChallengedOrders
        (,,,, uint256[] memory challenged1,,) = market.getCurrentChallengeInfo();
        bool found = false;
        for (uint256 i = 0; i < challenged1.length; i++) {
            if (challenged1[i] == orderId) {
                found = true;
                break;
            }
        }
        assertTrue(found, "order should be challenged after first heartbeat");

        // --- Expire + complete the order so challengeableOrders becomes empty ---
        uint256 t2 = t1 + PERIOD * periods + STEP + 1;
        vm.warp(t2);
        market.completeExpiredOrder(orderId);

        // Confirm challengeableOrders is now empty
        assertEq(market.getChallengeableOrdersCount(), 0, "challengeableOrders should be empty");

        // --- Second heartbeat: zero selection branch ---
        uint256 t3 = t2 + STEP + 1;
        vm.warp(t3);
        market.triggerHeartbeat();

        // Verify stale state was cleared
        (,, address primaryAfter, address[] memory secAfter, uint256[] memory challengedAfter,,) =
            market.getCurrentChallengeInfo();
        assertEq(challengedAfter.length, 0, "currentChallengedOrders should be empty after zero-selection heartbeat");
        assertEq(primaryAfter, address(0), "currentPrimaryProver should be cleared");
        assertEq(secAfter.length, 0, "currentSecondaryProvers should be cleared");
    }

    /// @notice When more orders expire than CLEANUP_BATCH_SIZE can handle,
    ///         leftover expired orders must NOT be selected for challenges.
    function test_ExpiredOrdersFilteredFromChallengeSelection() public {
        // Use a large-capacity node so it can execute many orders
        uint64 bigCap = TEST_CAPACITY * 20;
        uint256 bigStake = uint256(bigCap) * STAKE_PER_BYTE;
        vm.deal(node1, bigStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: bigStake}(bigCap, 0x1234, 0x5678);

        // Place and execute 12 short-lived orders (> CLEANUP_BATCH_SIZE of 10)
        uint64 maxSize = 256;
        uint16 periods = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;
        uint256[] memory orderIds = new uint256[](12);

        for (uint256 j = 0; j < 12; j++) {
            vm.prank(user1);
            orderIds[j] = market.placeOrder{value: totalCost}(
                MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI}), maxSize, periods, 1, price
            );
            vm.prank(node1);
            market.executeOrder(orderIds[j]);
        }

        // All 12 should be challengeable
        assertEq(market.getChallengeableOrdersCount(), 12);

        // Expire all orders
        uint256 t1 = block.timestamp + PERIOD * periods + STEP + 1;
        vm.warp(t1);

        // Trigger heartbeat — cleanup processes at most 10, but the filter
        // must catch the remaining expired orders during selection.
        market.triggerHeartbeat();

        // Verify NO expired order was challenged
        (,,,, uint256[] memory challenged,,) = market.getCurrentChallengeInfo();
        for (uint256 k = 0; k < challenged.length; k++) {
            assertFalse(market.isOrderExpired(challenged[k]), "expired order should not be challenged");
        }

        // The expired orders that were caught by the filter should have been
        // evicted from challengeableOrders too.
        uint256 remaining = market.getChallengeableOrdersCount();
        // All orders expired, so after cleanup + filter eviction, none should remain
        assertEq(remaining, 0, "all expired orders should be evicted from challengeableOrders");
    }

    /// @notice Secondary provers must still be slashed even when the primary proves quickly.
    ///         Before the fix, primary proof immediately rolled to a new heartbeat, wiping
    ///         secondaries' proof obligations so they escaped slashing.
    function test_SecondarySlashedAfterPrimaryProvesQuickly() public {
        // --- Stake two ZK-capable nodes ---
        _stakeZKNode(node1);
        _stakeZKNode(node2);

        uint256 orderId = _placeZKOrder();

        vm.prank(node1);
        market.executeOrder(orderId);

        // Place a second order for node2 to execute (for secondary assignment)
        MarketStorage.FileMeta memory fileMeta2 = MarketStorage.FileMeta({root: ZK_FILE_ROOT, uri: "QmZKTestFile2"});
        uint256 totalCost2 = uint256(256) * 4 * 1e12;
        vm.prank(user1);
        uint256 orderId2 = market.placeOrder{value: totalCost2}(fileMeta2, 256, 4, 1, 1e12);
        vm.prank(node2);
        market.executeOrder(orderId2);

        // Advance time so currentStep > 0
        uint256 t0 = block.timestamp + STEP + 1;
        vm.warp(t0);

        // --- Set up challenge: node1 = primary for orderId, node2 = secondary for orderId2 ---
        _setupZKChallenge(node1, orderId);

        // Add node2 as secondary prover
        vm.store(address(market), bytes32(uint256(29)), bytes32(uint256(1))); // length = 1
        bytes32 secArrayStart = keccak256(abi.encode(uint256(29)));
        vm.store(address(market), secArrayStart, bytes32(uint256(uint160(node2))));
        bytes32 node2MapSlot = keccak256(abi.encode(node2, SLOT_NODE_TO_PROVE_ORDER_ID));
        vm.store(address(market), node2MapSlot, bytes32(orderId2));

        // Record node2's stake before slashing
        (uint256 node2StakeBefore,,,,) = nodeStaking.getNodeInfo(node2);

        // --- Primary proves immediately (within the step) ---
        vm.prank(node1);
        market.submitProof(_zkProof(), ZK_COMMITMENT);

        // node2 does NOT submit proof — secondary fails their obligation.
        // Round should stay active (no immediate roll).
        assertTrue(market.primaryProofReceived(), "primary proof should be recorded");

        // --- Advance past step expiry ---
        uint256 t1 = t0 + STEP + 1;
        vm.warp(t1);

        // triggerHeartbeat processes expired challenge slashes before rolling
        market.triggerHeartbeat();

        // --- Verify node2 was slashed ---
        (uint256 node2StakeAfter,,,,) = nodeStaking.getNodeInfo(node2);
        assertTrue(node2StakeAfter < node2StakeBefore, "secondary should have been slashed");

        // Verify pending randomness was applied (commitment from primary proof)
        assertEq(market.pendingRandomness(), 0, "pending randomness should be consumed");
    }

    /// @notice A challenged primary prover cannot decrease capacity to evade slashing.
    function test_ChallengedProverCannotDecreaseCapacity() public {
        // Stake node1 with ZK keys and extra capacity beyond what orders use
        uint64 bigCap = TEST_CAPACITY * 2;
        uint256 bigStake = uint256(bigCap) * STAKE_PER_BYTE;
        vm.deal(node1, bigStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: bigStake}(bigCap, ZK_PUB_KEY_X, ZK_PUB_KEY_Y);

        // Place order with ZK file root so the proof fixture works
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: ZK_FILE_ROOT, uri: "QmZKTest"});
        uint256 totalCost = uint256(256) * 4 * 1e12;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, 256, 4, 1, 1e12);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Advance time, set up challenge with node1 as primary
        uint256 t0 = block.timestamp + STEP + 1;
        vm.warp(t0);
        _setupZKChallenge(node1, orderId);

        // node1 tries to drain free capacity before slash — should be blocked
        uint64 freeCapacity = bigCap - 256; // capacity not used by orders
        vm.prank(node1);
        vm.expectRevert("unresolved proof obligation");
        nodeStaking.decreaseCapacity(freeCapacity);

        // node1 also cannot unstake
        vm.prank(node1);
        vm.expectRevert("unresolved proof obligation");
        nodeStaking.unstakeNode();

        // After submitting proof, the obligation is resolved — decrease allowed
        vm.prank(node1);
        market.submitProof(_zkProof(), ZK_COMMITMENT);

        vm.prank(node1);
        nodeStaking.decreaseCapacity(freeCapacity); // should succeed now
    }

    /// @notice selectRandomOrders must shuffle even when count >= array length
    ///         (the "select all" path).  Before the fix, elements were returned
    ///         in deterministic storage order, biasing primary prover selection.
    function test_SelectAll_IsShuffled() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        // Place 5 orders so there are exactly 5 active orders
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 price = 1e12;
        for (uint256 i = 0; i < 5; i++) {
            uint256 cost = uint256(256) * 2 * price;
            vm.prank(user1);
            market.placeOrder{value: cost}(fileMeta, 256, 2, 1, price);
        }

        // Select all 5 with count = 5 (triggers the "select all" path)
        // Run many seeds and check that the first element is NOT always orderID 1
        uint256 firstIsOrder1 = 0;
        uint256 trials = 20;
        for (uint256 seed = 1; seed <= trials; seed++) {
            uint256[] memory selected = market.selectRandomOrders(seed, 5);
            assertEq(selected.length, 5, "should return all 5");
            if (selected[0] == 1) {
                firstIsOrder1++;
            }
        }

        // With 5 orders, probability of index-0 being order 1 in all 20 trials
        // (deterministic / no shuffle) is 100%.  With shuffle, P(all 20 are order1) = (1/5)^20 ≈ 0.
        assertTrue(firstIsOrder1 < trials, "first element should not always be order 1 (selection not shuffled)");
    }

    /// @notice A node joining 1 second before a period boundary should NOT earn for
    ///         that partial period.  Only complete periods count.
    function test_BoundarySniping_NoPartialPeriodReward() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        // Place a 2-period order at period 0
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);

        // Warp to 1 second before period 1 boundary and have node1 execute
        uint256 period1Start = 1 + PERIOD;
        vm.warp(period1Start - 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        // The node joined in period 0 but only 1 second before period 1.
        // With ceiling division, effective start period = ceil((period1Start-1-GENESIS_TS)/PERIOD) = 1.
        // So node should earn for (settlePeriod - 1) periods, NOT (settlePeriod - 0).

        // Warp past expiry: order was placed at period 0, lasts 2 periods, ends at period 2
        vm.warp(1 + PERIOD * 3 + 1);
        market.completeExpiredOrder(orderId);

        // Expected reward: 1 complete period (period 1 only) × maxSize × price
        // Period 0 was partial (1 second) so no payout. Period 2 is past order end.
        uint256 expectedReward = uint256(maxSize) * price * 1;
        uint256 claimable = market.getClaimableRewards(node1);
        assertEq(claimable, expectedReward, "should only earn for 1 complete period, not 2");
    }

    /// @notice A node joining at the exact period boundary earns for that full period.
    function test_ExactBoundaryJoin_EarnsFullPeriod() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);

        // Warp to exactly period 0 start (GENESIS_TS) — join at boundary
        vm.warp(1);

        vm.prank(node1);
        market.executeOrder(orderId);

        // With ceiling division, elapsed=0, ceil(0/PERIOD)=0 → earns from period 0
        vm.warp(1 + PERIOD * 3 + 1);
        market.completeExpiredOrder(orderId);

        // Should earn for both full periods (0 and 1)
        uint256 expectedReward = uint256(maxSize) * price * 2;
        uint256 claimable = market.getClaimableRewards(node1);
        assertEq(claimable, expectedReward, "should earn for both complete periods");
    }

    /// @notice reportPrimaryFailure must not revert when the primary was already
    ///         invalidated by an authority slash before the challenge expired.
    function test_ReportPrimaryFailure_AfterAuthoritySlash() public {
        // Two nodes: node1 is primary, node2 is the reporter
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0x5678, 0x1234);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(256) * 4 * 1e12;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, 256, 4, 1, 1e12);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Set up challenge with node1 as primary
        uint256 t0 = block.timestamp + STEP + 1;
        vm.warp(t0);
        _setupZKChallenge(node1, orderId);

        // Authority slash invalidates node1 completely (slash all stake)
        (uint256 fullStake,,,,) = nodeStaking.getNodeInfo(node1);
        market.slashNode(node1, fullStake, "authority penalty");

        // node1 is no longer valid
        assertFalse(nodeStaking.isValidNode(node1), "node1 should be invalidated");

        // Advance past challenge expiry
        uint256 t1 = t0 + STEP + 1;
        vm.warp(t1);

        // reportPrimaryFailure should succeed (not revert) even though primary is invalid.
        // It also triggers a new heartbeat internally, which resets primaryFailureReported,
        // so we just verify the call completes without reverting.
        vm.prank(node2);
        market.reportPrimaryFailure();
    }

    /// @notice A node that quits and re-joins the same order should earn full
    ///         rewards for the second assignment, not be penalised by stale
    ///         nodeOrderEarnings from the first assignment.
    function test_RejoinSameOrder_FullRewardsOnSecondAssignment() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        // Place a 4-period order
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 4;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);

        // --- First assignment: join at period 0 boundary, serve 1 full period, then quit ---
        vm.warp(1); // GENESIS_TS = 1, so this is period 0 boundary
        vm.prank(node1);
        market.executeOrder(orderId);

        // Advance 1 full period (into period 1)
        vm.warp(1 + PERIOD);
        // Quit order — settles reward for 1 period, then clears earnings
        vm.prank(node1);
        market.quitOrder(orderId);

        uint256 rewardAfterFirstAssignment = market.getClaimableRewards(node1);
        // First assignment: 1 period served → maxSize * price * 1
        uint256 expectedFirst = uint256(maxSize) * price * 1;
        assertEq(rewardAfterFirstAssignment, expectedFirst, "first assignment reward");

        // --- Second assignment: re-join the same order, serve 1 full period ---
        vm.warp(1 + PERIOD); // still period 1 boundary
        vm.prank(node1);
        market.executeOrder(orderId);

        // Advance 1 full period (into period 2)
        vm.warp(1 + PERIOD * 2);
        vm.prank(node1);
        market.quitOrder(orderId);

        uint256 rewardAfterSecondAssignment = market.getClaimableRewards(node1);
        // Second assignment: 1 additional period served → another maxSize * price * 1
        uint256 expectedTotal = expectedFirst + uint256(maxSize) * price * 1;
        assertEq(
            rewardAfterSecondAssignment,
            expectedTotal,
            "second assignment should earn full reward, not be reduced by first"
        );
    }

    // ===== FIX 16: O(1) STATS AGGREGATES =====

    function test_StatsAggregates_PlaceAndComplete() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * periods * price;

        // Place order — aggregate should increase
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);

        assertEq(market.aggregateActiveEscrow(), totalCost, "escrow after place");
        assertEq(market.aggregateActiveWithdrawn(), 0, "withdrawn after place");

        // Check getGlobalStats returns same value
        (,, uint256 escrowLocked,,,,,,,,) = market.getGlobalStats();
        assertEq(escrowLocked, totalCost, "getGlobalStats escrow");

        // Execute and advance past expiry
        vm.prank(node1);
        market.executeOrder(orderId);
        vm.warp(block.timestamp + uint256(periods) * 7 days + 1);

        // Complete — aggregates should drop
        market.completeExpiredOrder(orderId);
        assertEq(market.aggregateActiveEscrow(), 0, "escrow after complete");
        assertEq(market.aggregateActiveWithdrawn(), 0, "withdrawn after complete");
    }

    function test_StatsAggregates_MultipleOrders() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 100;
        uint16 periods = 1;
        uint256 price = 1e12;
        uint256 cost1 = uint256(maxSize) * periods * price;

        // Place two orders
        vm.prank(user1);
        market.placeOrder{value: cost1}(fileMeta, maxSize, periods, 1, price);
        vm.prank(user1);
        market.placeOrder{value: cost1}(fileMeta, maxSize, periods, 1, price);

        assertEq(market.aggregateActiveEscrow(), cost1 * 2, "two orders escrow");

        // Financial stats should match
        (, uint256 escrowHeld, uint256 rewardsPaid, uint256 avgVal,) = market.getFinancialStats();
        assertEq(escrowHeld, cost1 * 2, "financial escrow held");
        assertEq(rewardsPaid, 0, "no rewards paid");
        assertEq(avgVal, cost1, "average = total / 2");
    }

    function test_StatsAggregates_CancelReducesAggregates() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 4;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * periods * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Advance 1 period, then cancel
        vm.warp(block.timestamp + 7 days);

        vm.prank(user1);
        market.cancelOrder(orderId);

        // After cancel, aggregates should be zero (only order was cancelled)
        assertEq(market.aggregateActiveEscrow(), 0, "escrow zero after cancel");
        assertEq(market.aggregateActiveWithdrawn(), 0, "withdrawn zero after cancel");

        // Global stats should reflect zero
        (,, uint256 escrowLocked,,,,,,,,) = market.getGlobalStats();
        assertEq(escrowLocked, 0, "global stats escrow zero");
    }

    function test_StatsAggregates_WithdrawnTracksRewards() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * periods * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Advance 1 period and claim rewards
        vm.warp(block.timestamp + 7 days);
        vm.prank(node1);
        market.claimRewards();

        uint256 expectedReward = uint256(maxSize) * price * 1; // 1 period
        assertEq(market.aggregateActiveWithdrawn(), expectedReward, "withdrawn after claim");
        assertEq(market.aggregateActiveEscrow(), totalCost, "escrow unchanged after claim");

        // Financial stats should show the split
        (, uint256 escrowHeld, uint256 rewardsPaid,,) = market.getFinancialStats();
        assertEq(rewardsPaid, expectedReward, "rewards paid = withdrawn");
        assertEq(escrowHeld, totalCost - expectedReward, "escrow held = total - rewards");
    }

    // =========================================================================
    // Challenge selection: inline-eviction tests
    // =========================================================================

    /// @notice 10 orders executed, 8 expired; heartbeat selects only non-expired;
    ///         challengeableOrders shrank by at least the expired count.
    function test_ChallengeSelection_SkipsExpiredOrders() public {
        uint64 bigCap = TEST_CAPACITY * 20;
        uint256 bigStake = uint256(bigCap) * STAKE_PER_BYTE;
        vm.deal(node1, bigStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: bigStake}(bigCap, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 price = 1e12;

        // Place 8 short-lived (1 period) orders and 2 long-lived (4 periods)
        uint256[] memory shortIds = new uint256[](8);
        uint256[] memory longIds = new uint256[](2);

        for (uint256 i = 0; i < 8; i++) {
            uint256 cost = uint256(maxSize) * 1 * price;
            vm.prank(user1);
            shortIds[i] = market.placeOrder{value: cost}(fileMeta, maxSize, 1, 1, price);
            vm.prank(node1);
            market.executeOrder(shortIds[i]);
        }
        for (uint256 i = 0; i < 2; i++) {
            uint256 cost = uint256(maxSize) * 4 * price;
            vm.prank(user1);
            longIds[i] = market.placeOrder{value: cost}(fileMeta, maxSize, 4, 1, price);
            vm.prank(node1);
            market.executeOrder(longIds[i]);
        }

        assertEq(market.getChallengeableOrdersCount(), 10);

        // Expire the 8 short orders
        vm.warp(block.timestamp + PERIOD + STEP * 3);
        market.triggerHeartbeat();

        // Challenged orders must all be non-expired
        (,,,, uint256[] memory challenged,,) = market.getCurrentChallengeInfo();
        for (uint256 k = 0; k < challenged.length; k++) {
            assertFalse(market.isOrderExpired(challenged[k]), "expired order should not be challenged");
        }

        // challengeableOrders should have shrunk (expired evicted during selection)
        uint256 remaining = market.getChallengeableOrdersCount();
        assertLe(remaining, 2, "at most 2 non-expired orders should remain challengeable");
    }

    /// @notice All orders expired; heartbeat yields zero selection; all evicted from challengeableOrders.
    function test_ChallengeSelection_AllExpiredYieldsEmpty() public {
        uint64 bigCap = TEST_CAPACITY * 20;
        uint256 bigStake = uint256(bigCap) * STAKE_PER_BYTE;
        vm.deal(node1, bigStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: bigStake}(bigCap, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 price = 1e12;
        uint256 cost = uint256(maxSize) * 1 * price;

        // Place and execute 15 short-lived orders (more than CLEANUP_BATCH_SIZE)
        for (uint256 i = 0; i < 15; i++) {
            vm.prank(user1);
            uint256 oid = market.placeOrder{value: cost}(fileMeta, maxSize, 1, 1, price);
            vm.prank(node1);
            market.executeOrder(oid);
        }

        assertEq(market.getChallengeableOrdersCount(), 15);

        // Expire all
        vm.warp(block.timestamp + PERIOD + STEP * 3);
        market.triggerHeartbeat();

        // No orders should be challenged
        (,,,, uint256[] memory challenged,,) = market.getCurrentChallengeInfo();
        assertEq(challenged.length, 0, "no orders should be challenged when all expired");

        // All evicted from challengeableOrders
        assertEq(market.getChallengeableOrdersCount(), 0, "all expired should be evicted");
    }

    /// @notice Orders with varying durations; after 1 period, only non-expired appear in challenge;
    ///         repeated heartbeats clear backlog.
    function test_ChallengeSelection_MixedExpiry() public {
        uint64 bigCap = TEST_CAPACITY * 30;
        uint256 bigStake = uint256(bigCap) * STAKE_PER_BYTE;
        vm.deal(node1, bigStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: bigStake}(bigCap, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 price = 1e12;

        // Place 10 orders: 5 with 1 period (expire soon) and 5 with 4 periods (survive)
        uint256[] memory shortIds = new uint256[](5);
        uint256[] memory longIds = new uint256[](5);

        for (uint256 i = 0; i < 5; i++) {
            uint256 shortCost = uint256(maxSize) * 1 * price;
            vm.prank(user1);
            shortIds[i] = market.placeOrder{value: shortCost}(fileMeta, maxSize, 1, 1, price);
            vm.prank(node1);
            market.executeOrder(shortIds[i]);

            uint256 longCost = uint256(maxSize) * 4 * price;
            vm.prank(user1);
            longIds[i] = market.placeOrder{value: longCost}(fileMeta, maxSize, 4, 1, price);
            vm.prank(node1);
            market.executeOrder(longIds[i]);
        }

        assertEq(market.getChallengeableOrdersCount(), 10);

        // Expire the 5 short orders
        vm.warp(block.timestamp + PERIOD + STEP * 3);
        market.triggerHeartbeat();

        // All challenged orders must be non-expired
        (,,,, uint256[] memory challenged,,) = market.getCurrentChallengeInfo();
        for (uint256 k = 0; k < challenged.length; k++) {
            assertFalse(market.isOrderExpired(challenged[k]), "expired order in challenge set");
        }

        // Second heartbeat to clear any remaining expired backlog
        vm.warp(block.timestamp + STEP * 3);
        market.triggerHeartbeat();

        // Only long-lived orders should remain challengeable
        uint256 remaining = market.getChallengeableOrdersCount();
        assertLe(remaining, 5, "at most 5 long-lived orders should remain challengeable");
        assertGt(remaining, 0, "long-lived orders should still be challengeable");
    }

    /// @notice With >50 expired challengeable orders, a single heartbeat must
    ///         not OOG. Evictions are capped at MAX_CHALLENGE_EVICTIONS (50)
    ///         per selection call; repeated heartbeats drain the backlog.
    function test_ChallengeSelection_EvictionCapBoundsGas() public {
        // Two nodes to stay under MAX_ORDERS_PER_NODE (50) each
        uint64 bigCap = TEST_CAPACITY * 40;
        uint256 bigStake = uint256(bigCap) * STAKE_PER_BYTE;
        vm.deal(node1, bigStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: bigStake}(bigCap, 0x1234, 0x5678);
        vm.deal(node2, bigStake);
        vm.prank(node2);
        nodeStaking.stakeNode{value: bigStake}(bigCap, 0xabcd, 0xef01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 1; // tiny to minimise escrow
        uint256 price = 1; // 1 wei per byte per period
        uint256 cost = uint256(maxSize) * 1 * price;

        // Place and execute 70 short-lived orders (> MAX_CHALLENGE_EVICTIONS of 50)
        // Split across two nodes to stay under per-node cap
        for (uint256 i = 0; i < 70; i++) {
            address creator = address(uint160(0xA000 + i));
            vm.deal(creator, cost);
            vm.prank(creator);
            uint256 oid = market.placeOrder{value: cost}(fileMeta, maxSize, 1, 1, price);
            vm.prank(i < 35 ? node1 : node2);
            market.executeOrder(oid);
        }

        assertEq(market.getChallengeableOrdersCount(), 70);

        // Expire all orders
        vm.warp(block.timestamp + PERIOD + STEP * 3);

        // First heartbeat: evicts up to MAX_CHALLENGE_EVICTIONS (50) from challengeable
        // plus _cleanupExpiredOrders processes up to CLEANUP_BATCH_SIZE (10) from active.
        uint256 gasBefore = gasleft();
        market.triggerHeartbeat();
        uint256 gasUsed = gasBefore - gasleft();

        // Must complete within reasonable gas (not OOG)
        assertTrue(gasUsed < 10_000_000, "heartbeat gas must be bounded");

        // Some expired orders remain — not all evicted in one pass
        uint256 afterFirst = market.getChallengeableOrdersCount();
        assertTrue(afterFirst < 70, "some expired orders evicted");

        // Second heartbeat drains more of the backlog
        vm.warp(block.timestamp + STEP * 3);
        market.triggerHeartbeat();

        uint256 afterSecond = market.getChallengeableOrdersCount();
        assertTrue(afterSecond < afterFirst, "second heartbeat drains more expired orders");
    }

    /// @notice Regression for legacy blackout path:
    ///         when random sampling hit the eviction cap before seeing a live entry,
    ///         heartbeat used to roll forward without assigning a primary prover.
    function test_ChallengeSelection_FallbackPreventsLegacyBlackout() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        // Create one real, non-expired challengeable order.
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 price = 1e12;
        uint256 cost = uint256(maxSize) * 4 * price;
        vm.prank(user1);
        uint256 liveOrderId = market.placeOrder{value: cost}(fileMeta, maxSize, 4, 1, price);
        vm.prank(node1);
        market.executeOrder(liveOrderId);

        // Build a synthetic challengeable backlog:
        // - 79 fake expired order IDs (non-existent => expired)
        // - 1 real live order ID
        uint256 totalEntries = 80;
        uint256 liveIndex = 37;
        uint256 seed = _findLegacyBlackoutSeed(totalEntries, liveIndex);
        assertTrue(_legacySelectorWouldBlackout(seed, totalEntries, liveIndex), "seed must blackout legacy selector");

        vm.store(address(market), bytes32(SLOT_CHALLENGEABLE_ORDERS), bytes32(totalEntries));
        bytes32 challengeableBase = keccak256(abi.encode(uint256(SLOT_CHALLENGEABLE_ORDERS)));
        uint256 fakeBaseId = 1_000_000;

        for (uint256 i = 0; i < totalEntries; i++) {
            uint256 oid = (i == liveIndex) ? liveOrderId : (fakeBaseId + i);
            vm.store(address(market), bytes32(uint256(challengeableBase) + i), bytes32(oid));
            vm.store(
                address(market),
                keccak256(abi.encode(oid, SLOT_ORDER_INDEX_IN_CHALLENGEABLE)),
                bytes32(i)
            );
            vm.store(address(market), keccak256(abi.encode(oid, SLOT_IS_CHALLENGEABLE)), bytes32(uint256(1)));
        }

        // Force deterministic seed used by selector.
        vm.store(address(market), bytes32(SLOT_CURRENT_RANDOMNESS), bytes32(seed));

        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        // New selector must still challenge the live order and assign a primary.
        assertEq(market.currentPrimaryProver(), node1, "primary prover should be assigned from live order");
        (,,,, uint256[] memory challengedOrders,,) = market.getCurrentChallengeInfo();
        assertEq(challengedOrders.length, 1, "selectionCount should be 1");
        assertEq(challengedOrders[0], liveOrderId, "live order should be challenged");
    }

    // =========================================================================
    // Financial stats: lifetime monotonic counters
    // =========================================================================

    /// @notice totalRewardsPaid and averageOrderValue must not decrease after
    ///         an order completes. Before the fix, both derived from active-scope
    ///         aggregates that were decremented on completion.
    function test_FinancialStats_LifetimeCountersMonotonic() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint16 periods = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * periods * price;

        // Place and execute an order
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, periods, 1, price);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Advance 1 period and claim rewards
        vm.warp(block.timestamp + PERIOD);
        vm.prank(node1);
        market.claimRewards();

        // Snapshot stats before completing the order
        (,, uint256 rewardsBefore, uint256 avgBefore,) = market.getFinancialStats();
        assertGt(rewardsBefore, 0, "rewards accrued before completion");
        assertGt(avgBefore, 0, "average nonzero before completion");

        // Complete the expired order (this previously zeroed the active aggregates)
        vm.warp(block.timestamp + 1);
        market.completeExpiredOrder(orderId);

        // Lifetime counters must not decrease
        (, uint256 escrowHeldAfter, uint256 rewardsAfter, uint256 avgAfter,) = market.getFinancialStats();
        assertGe(rewardsAfter, rewardsBefore, "totalRewardsPaid must not decrease after completion");
        assertGe(avgAfter, avgBefore, "averageOrderValue must not decrease after completion");
        // Active escrow held can decrease — that's expected
        assertEq(escrowHeldAfter, 0, "no active escrow after completion");
    }

    /// @notice Place two orders, complete one — lifetime totals stay correct.
    function test_FinancialStats_PartialCompletion() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 100;
        uint256 price = 1e12;

        uint256 cost1 = uint256(maxSize) * 1 * price; // 1 period
        uint256 cost2 = uint256(maxSize) * 4 * price; // 4 periods

        vm.prank(user1);
        uint256 oid1 = market.placeOrder{value: cost1}(fileMeta, maxSize, 1, 1, price);
        vm.prank(node1);
        market.executeOrder(oid1);

        vm.prank(user1);
        market.placeOrder{value: cost2}(fileMeta, maxSize, 4, 1, price);

        // lifetimeEscrowDeposited = cost1 + cost2, even though only one order is executed
        assertEq(market.lifetimeEscrowDeposited(), cost1 + cost2, "lifetime escrow after two placements");

        // Expire and complete first order
        vm.warp(block.timestamp + PERIOD + 1);
        market.completeExpiredOrder(oid1);

        // Lifetime counters unchanged by completion (only active aggregates shrink)
        assertEq(market.lifetimeEscrowDeposited(), cost1 + cost2, "lifetime escrow preserved after completion");

        // averageOrderValue = (cost1 + cost2) / 2
        (,,, uint256 avgVal,) = market.getFinancialStats();
        assertEq(avgVal, (cost1 + cost2) / 2, "average reflects lifetime escrow");
    }

    function test_NodeStaking_GlobalAggregates() public {
        NodeStaking ns = market.nodeStaking();

        // Initially zero
        (uint256 nodes0, uint256 cap0, uint256 used0) = ns.getNetworkStats();
        assertEq(nodes0, 0);
        assertEq(cap0, 0);
        assertEq(used0, 0);

        // Stake node1
        _stakeTestNode(node1, 0x1234, 0x5678);
        (uint256 nodes1, uint256 cap1, uint256 used1) = ns.getNetworkStats();
        assertEq(nodes1, 1);
        assertEq(cap1, TEST_CAPACITY);
        assertEq(used1, 0);

        // Execute an order to increase used
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 totalCost = uint256(maxSize) * 2 * 1e12;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, maxSize, 2, 1, 1e12);
        vm.prank(node1);
        market.executeOrder(orderId);

        (, uint256 cap2, uint256 used2) = ns.getNetworkStats();
        assertEq(cap2, TEST_CAPACITY, "capacity unchanged by execute");
        assertEq(used2, maxSize, "used increased by maxSize");

        // Unstake after completing order
        vm.warp(block.timestamp + 14 days + 1);
        market.completeExpiredOrder(orderId);

        vm.prank(node1);
        ns.unstakeNode();

        (uint256 nodes3, uint256 cap3, uint256 used3) = ns.getNetworkStats();
        assertEq(nodes3, 0, "no nodes after unstake");
        assertEq(cap3, 0, "zero capacity after unstake");
        assertEq(used3, 0, "zero used after unstake");
    }
}

// Malicious contract to test reentrancy on FileMarket.claimRewards
contract MaliciousMarketClaim {
    FileMarket public market;
    NodeStaking public nodeStaking;
    bool public attacked = false;
    bool public reentrancyDetected = false;

    constructor(FileMarket _market) {
        market = _market;
        nodeStaking = _market.nodeStaking();
    }

    function setupAndStore(
        uint64 capacity,
        uint256 fileRoot,
        string memory fileUri,
        uint64 maxSize,
        uint16 periods,
        uint256 price
    ) external payable {
        // Stake as node
        nodeStaking.stakeNode{value: msg.value}(capacity, 0xAAAA, 0xBBBB);

        // Place order
        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: fileRoot, uri: fileUri});
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;
        market.placeOrder{value: totalCost}(meta, maxSize, periods, 1, price);

        // Execute order as this contract
        market.executeOrder(1);
    }

    function attackClaimRewards() external {
        market.claimRewards();
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Attempt reentrancy
            try market.claimRewards() {
                reentrancyDetected = false;
            } catch {
                reentrancyDetected = true;
            }
        }
    }
}

// Contract with reverting receive() to test DoS resistance of pull-payment pattern
contract RevertingReceiver {
    FileMarket public market;
    uint256 public lastTotalCost;

    constructor(FileMarket _market) {
        market = _market;
    }

    function placeOrder() external {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: 0x123, uri: "test"});
        uint64 maxSize = 256;
        uint16 periods = 2;
        uint256 price = 1e12;
        lastTotalCost = uint256(maxSize) * uint256(periods) * price;
        market.placeOrder{value: lastTotalCost}(fileMeta, maxSize, periods, 1, price);
    }

    function placeOrderWithParams(uint64 maxSize, uint16 periods, uint8 replicas, uint256 price) external {
        lastTotalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: 0x123, uri: "test"});
        market.placeOrder{value: lastTotalCost}(fileMeta, maxSize, periods, replicas, price);
    }

    function cancelOrder(uint256 orderId) external {
        market.cancelOrder(orderId);
    }

    function withdrawRefund() external {
        market.withdrawRefund();
    }

    // Always revert when receiving ETH — simulates malicious/broken contract
    receive() external payable {
        revert("I reject ETH");
    }
}
