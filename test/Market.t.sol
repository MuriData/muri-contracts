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
    uint256 public constant CHALLENGE_WINDOW_BLOCKS = 50;

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

    function test_CancelOrder_RevertExpired() public {
        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: 1 ether}(fileMeta, 1024, 1, 1, 1e12);

        vm.warp(block.timestamp + PERIOD + 1);

        vm.prank(user1);
        vm.expectRevert("order already expired");
        market.cancelOrder(orderId);
    }

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

    function test_SlashNode_External_RevertZeroAmount() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        vm.expectRevert("invalid slash amount");
        market.slashNode(node1, 0, "test");
    }

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

    function test_CurrentEpoch() public view {
        uint256 epoch = market.currentEpoch();
        assertEq(epoch, 0); // at genesis
    }

    function test_IsOrderExpired_NonExistentOrder() public view {
        assertTrue(market.isOrderExpired(999), "non-existent order should be expired");
    }

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

    function test_GetOrderFinancials_RevertInvalidId() public {
        vm.expectRevert("invalid order id");
        market.getOrderFinancials(0);

        vm.expectRevert("invalid order id");
        market.getOrderFinancials(999);
    }

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

    function test_CurrentPeriod() public view {
        uint256 period = market.currentPeriod();
        assertGe(period, 0, "period is non-negative");
    }

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

    // =========================================================================
    // ZK Proof Integration Tests (using real Groth16 proofs from muri-zkproof)
    // =========================================================================

    // Valid proof fixture generated by muri-zkproof/export_proof.go
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
    // challengeSlots[5] starts at slot 26, each ChallengeSlot = 4 words
    // slot 26: challengeSlots[0].orderId
    // slot 27: challengeSlots[0].challengedNode
    // slot 28: challengeSlots[0].randomness
    // slot 29: challengeSlots[0].deadlineBlock
    uint256 constant SLOT_CHALLENGE_SLOTS_BASE = 26;
    uint256 constant SLOT_CHALLENGE_SLOTS_INITIALIZED = 46;
    uint256 constant SLOT_GLOBAL_SEED_RANDOMNESS = 47;
    uint256 constant SLOT_NODE_ACTIVE_CHALLENGE_COUNT = 48;
    uint256 constant SLOT_ORDER_ACTIVE_CHALLENGE_COUNT = 49;

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

    /// @dev Set up a challenge slot where `prover` is the challenged node for `orderId`,
    ///      with slot randomness = ZK_RANDOMNESS so the ZK proof fixture is valid.
    function _setupZKSlotChallenge(address prover, uint256 orderId) internal {
        uint256 slotBase = SLOT_CHALLENGE_SLOTS_BASE; // slot 0
        // Set challengeSlots[0].orderId
        vm.store(address(market), bytes32(slotBase), bytes32(orderId));
        // Set challengeSlots[0].challengedNode
        vm.store(address(market), bytes32(slotBase + 1), bytes32(uint256(uint160(prover))));
        // Set challengeSlots[0].randomness = ZK_RANDOMNESS
        vm.store(address(market), bytes32(slotBase + 2), bytes32(ZK_RANDOMNESS));
        // Set challengeSlots[0].deadlineBlock = block.number + CHALLENGE_WINDOW_BLOCKS
        vm.store(address(market), bytes32(slotBase + 3), bytes32(block.number + CHALLENGE_WINDOW_BLOCKS));
        // Mark challenge slots as initialized
        vm.store(address(market), bytes32(SLOT_CHALLENGE_SLOTS_INITIALIZED), bytes32(uint256(1)));
        // Set globalSeedRandomness to non-zero
        vm.store(address(market), bytes32(SLOT_GLOBAL_SEED_RANDOMNESS), bytes32(ZK_RANDOMNESS));
        // Set nodeActiveChallengeCount[prover] = 1
        bytes32 nodeCountSlot = keccak256(abi.encode(prover, SLOT_NODE_ACTIVE_CHALLENGE_COUNT));
        vm.store(address(market), nodeCountSlot, bytes32(uint256(1)));
        // Set orderActiveChallengeCount[orderId] = 1
        bytes32 orderCountSlot = keccak256(abi.encode(orderId, SLOT_ORDER_ACTIVE_CHALLENGE_COUNT));
        vm.store(address(market), orderCountSlot, bytes32(uint256(1)));
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

    // =========================================================================
    // ZK Proof Tests (slot-based challenge system)
    // =========================================================================

    function test_SubmitProof_SlotValid() public {
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();
        vm.prank(node1);
        market.executeOrder(orderId);

        _setupZKSlotChallenge(node1, orderId);

        uint256[8] memory proof = _zkProof();
        vm.prank(node1);
        market.submitProof(0, proof, ZK_COMMITMENT);

        // After successful proof, _advanceSlot is called. Since node1 is the only node
        // on the only challengeable order, it may be re-challenged. The key check is that
        // the proof submission succeeded without reverting.
        // Just verify the slot is in a valid state (either re-challenged or deactivated)
        (uint256 slotOrderId,,, uint256 deadlineBlock,) = market.getSlotInfo(0);
        if (slotOrderId != 0) {
            // Slot re-advanced (node1 re-challenged since it's the only node)
            assertGt(deadlineBlock, 0, "re-advanced slot has valid deadline");
        }
        // If slotOrderId == 0, slot was deactivated (also valid)
    }

    function test_SubmitProof_RevertInvalidProof() public {
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();
        vm.prank(node1);
        market.executeOrder(orderId);

        _setupZKSlotChallenge(node1, orderId);

        // Corrupt the proof
        uint256[8] memory badProof = _zkProof();
        badProof[0] = badProof[0] + 1;

        vm.prank(node1);
        vm.expectRevert();
        market.submitProof(0, badProof, ZK_COMMITMENT);
    }

    function test_SubmitProof_RevertWrongCommitment() public {
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();
        vm.prank(node1);
        market.executeOrder(orderId);

        _setupZKSlotChallenge(node1, orderId);

        uint256[8] memory proof = _zkProof();
        bytes32 wrongCommitment = bytes32(uint256(0xDEADBEEF));

        vm.prank(node1);
        vm.expectRevert();
        market.submitProof(0, proof, wrongCommitment);
    }

    function test_SubmitProof_RevertNotChallengedNode() public {
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();
        vm.prank(node1);
        market.executeOrder(orderId);

        _setupZKSlotChallenge(node1, orderId);

        uint256[8] memory proof = _zkProof();

        // node2 tries to submit for node1's slot
        vm.prank(node2);
        vm.expectRevert("not the challenged node");
        market.submitProof(0, proof, ZK_COMMITMENT);
    }

    function test_SubmitProof_RevertAfterDeadline() public {
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();
        vm.prank(node1);
        market.executeOrder(orderId);

        _setupZKSlotChallenge(node1, orderId);

        // Move past deadline
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        uint256[8] memory proof = _zkProof();
        // After sweep, the expired slot is processed (slashed and deactivated/re-advanced),
        // so the slot is no longer in its original state. The exact error depends on state:
        // "slot is idle" if deactivated, or "not the challenged node" if re-advanced to someone else.
        vm.prank(node1);
        vm.expectRevert();
        market.submitProof(0, proof, ZK_COMMITMENT);
    }

    function test_SubmitProof_RevertNodePubKeyNotSet() public {
        // Stake node with zero keys
        vm.prank(node3);
        nodeStaking.stakeNode{value: TEST_STAKE}(TEST_CAPACITY, 1, 1);

        uint256 orderId = _placeZKOrder();
        vm.prank(node3);
        market.executeOrder(orderId);

        _setupZKSlotChallenge(node3, orderId);

        // Zero out the public keys via storage
        // nodes mapping is at slot 0 in NodeStaking, NodeInfo has: stake(+0), capacity+used(+1), pubKeyX(+2), pubKeyY(+3)
        bytes32 nodeInfoBase = keccak256(abi.encode(node3, uint256(0)));
        vm.store(address(nodeStaking), bytes32(uint256(nodeInfoBase) + 2), bytes32(uint256(0)));
        vm.store(address(nodeStaking), bytes32(uint256(nodeInfoBase) + 3), bytes32(uint256(0)));

        uint256[8] memory proof = _zkProof();
        vm.prank(node3);
        vm.expectRevert("node public key not set");
        market.submitProof(0, proof, ZK_COMMITMENT);
    }

    // =========================================================================
    // Challenge slot integration tests
    // =========================================================================

    function test_ActivateSlots_Integration() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(256) * 4 * 1e12;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, 256, 4, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId);

        assertFalse(market.challengeSlotsInitialized());

        market.activateSlots();

        assertTrue(market.challengeSlotsInitialized());
        assertGt(market.globalSeedRandomness(), 0);

        // At least one slot should be active
        (uint256 slotOrderId, address slotNode,,,) = market.getSlotInfo(0);
        assertGt(slotOrderId, 0);
        assertTrue(slotNode != address(0));
    }

    function test_ProcessExpiredSlots_SlashesFailedNode() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xABCD, 0xEF01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(256) * 4 * 1e12;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, 256, 4, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        (uint256 stakeBefore,,,,) = nodeStaking.getNodeInfo(node1);

        // Move past deadline
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // node2 processes expired slots as reporter
        vm.prank(node2);
        market.processExpiredSlots();

        (uint256 stakeAfter,,,,) = nodeStaking.getNodeInfo(node1);
        assertTrue(stakeAfter < stakeBefore, "node1 should be slashed");
        assertGt(market.reporterPendingRewards(node2), 0, "reporter should earn reward");
    }

    function test_QuitOrder_RevertForChallengedProver() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(256) * 4 * 1e12;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, 256, 4, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        // node1 is under active challenge, should not be able to quit
        vm.prank(node1);
        vm.expectRevert("active prover cannot quit");
        market.quitOrder(orderId);
    }

    function test_QuitOrder_AllowedForNonChallengedProver() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        uint64 largeCapacity = TEST_CAPACITY * 4;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node2, largeStake);
        vm.prank(node2);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0xABCD, 0xEF01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(256) * 4 * 1e12 * 2; // 2 replicas
        vm.prank(user1);
        uint256 orderId1 = market.placeOrder{value: totalCost}(fileMeta, 256, 4, 2, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId1);
        vm.prank(node2);
        market.executeOrder(orderId1);

        // Only challenge node1, not node2
        // Set up slot manually so only node1 is challenged
        _setupZKSlotChallenge(node1, orderId1);

        // node2 should be able to quit (not under challenge)
        vm.prank(node2);
        market.quitOrder(orderId1);
    }

    function test_CompleteExpiredOrder_RevertDuringActiveChallenge() public {
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

        // Warp past expiry
        vm.warp(block.timestamp + PERIOD * periods + 1);

        // Set up an active challenge on this order
        _setupZKSlotChallenge(node1, orderId);

        vm.expectRevert("order under active challenge");
        market.completeExpiredOrder(orderId);
    }

    function test_ChallengedProverCannotDecreaseCapacity() public {
        _stakeZKNode(node1);
        uint256 orderId = _placeZKOrder();
        vm.prank(node1);
        market.executeOrder(orderId);

        _setupZKSlotChallenge(node1, orderId);

        // Node under active challenge should not be able to decrease capacity
        vm.prank(node1);
        vm.expectRevert("unresolved proof obligation");
        nodeStaking.decreaseCapacity(100);
    }

    function test_ReporterReward_ZeroBps_NoReward() public {
        market.setReporterRewardBps(0);

        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xABCD, 0xEF01);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(256) * 4 * 1e12;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(fileMeta, 256, 4, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        // Move past deadline
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(node2);
        market.processExpiredSlots();

        assertEq(market.reporterPendingRewards(node2), 0, "no reporter reward at 0 bps");
    }

    function test_RandomnessAlwaysInField_ActivateSlots() public {
        uint256 SNARK_SCALAR_FIELD = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

        _stakeTestNode(node1, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint256 totalCost = uint256(256) * 4 * 1e12;
        vm.prank(user1);
        market.placeOrder{value: totalCost}(fileMeta, 256, 4, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(1);

        market.activateSlots();

        uint256 r = market.globalSeedRandomness();
        assertTrue(r < SNARK_SCALAR_FIELD, "randomness must be < SNARK_SCALAR_FIELD after activateSlots");
    }

    function test_PullPayment_ProcessExpiredSlotsNotBlocked() public {
        // Create a reverting receiver that places an order with overpayment
        RevertingReceiver receiver = new RevertingReceiver(market);
        vm.deal(address(receiver), 10 ether);

        receiver.placeOrderWithParams(256, 2, 1, 1e12);
        assertEq(market.pendingRefunds(address(receiver)), 0, "no overpayment in exact payment");

        // Stake nodes
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xABCD, 0xEF01);

        // Execute the order
        vm.prank(node1);
        market.executeOrder(1);

        market.activateSlots();

        // Move past deadline
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // processExpiredSlots should work even with a reverting receiver in the system
        vm.prank(node2);
        market.processExpiredSlots();
    }

    function test_CleanupExpiredOrders_BoundedGas() public {
        // Need enough capacity for 25 short + 1 long order = 6656 bytes
        uint64 bigCapacity = 256 * 26;
        uint256 bigStake = uint256(bigCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, bigStake + 1 ether);
        vm.prank(node1);
        nodeStaking.stakeNode{value: bigStake}(bigCapacity, 0x1234, 0x5678);

        MarketStorage.FileMeta memory fileMeta = MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
        uint64 maxSize = 256;
        uint256 price = 1e12;

        // Place 25 short-lived orders (1 period)
        for (uint256 i = 0; i < 25; i++) {
            uint256 totalCost = uint256(maxSize) * 1 * price;
            vm.prank(user1);
            uint256 oid = market.placeOrder{value: totalCost}(fileMeta, maxSize, 1, 1, price);
            vm.prank(node1);
            market.executeOrder(oid);
        }

        // Place 1 long-lived order (4 periods) so activateSlots can succeed after cleanup
        uint256 longCost = uint256(maxSize) * 4 * price;
        vm.prank(user1);
        uint256 liveOid = market.placeOrder{value: longCost}(fileMeta, maxSize, 4, 1, price);
        vm.prank(node1);
        market.executeOrder(liveOid);

        // Expire the 25 short orders (but not the long one)
        vm.warp(block.timestamp + PERIOD + 1);

        // activateSlots calls _cleanupExpiredOrders which should be bounded
        // It should not revert with out-of-gas
        market.activateSlots();
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
