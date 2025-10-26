// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {FileMarket} from "../src/Market.sol";
import {NodeStaking} from "../src/NodeStaking.sol";

contract MarketTest is Test {
    FileMarket public market;
    NodeStaking public nodeStaking;

    address public user1 = address(0x11);
    address public user2 = address(0x12);
    address public node1 = address(0x13);
    address public node2 = address(0x14);
    address public node3 = address(0x15);

    uint64 public constant TEST_CAPACITY = 1024; // 1KB (smaller for testing)
    uint256 public constant STAKE_PER_BYTE = 10**14;
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

    function test_BasicMarketDeployment() public {
        // Check contract deployment
        assertEq(address(market.nodeStaking()), address(nodeStaking));
        assertEq(market.nextOrderId(), 1);
        assertEq(market.getActiveOrdersCount(), 0);
    }

    function test_NodeRegistration() public {
        // Test node registration with public keys
        uint256 pubKeyX = 0x1234;
        uint256 pubKeyY = 0x5678;

        vm.prank(node1);
        nodeStaking.stakeNode{value: TEST_STAKE}(TEST_CAPACITY, pubKeyX, pubKeyY);

        // Verify node info
        (uint256 stake, uint64 capacity, uint64 used, uint256 keyX, uint256 keyY) = 
            nodeStaking.getNodeInfo(node1);
        
        assertEq(stake, TEST_STAKE);
        assertEq(capacity, TEST_CAPACITY);
        assertEq(used, 0);
        assertEq(keyX, pubKeyX);
        assertEq(keyY, pubKeyY);
        assertTrue(nodeStaking.isValidNode(node1));
    }

    function test_PlaceOrder() public {
        // Create file metadata
        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 1024; // 1KB
        uint16 periods = 4; // 4 periods
        uint8 replicas = 2; // 2 replicas
        uint256 price = 1e12; // price per byte per period

        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(
            fileMeta, maxSize, periods, replicas, price
        );

        assertEq(orderId, 1);
        assertEq(market.getActiveOrdersCount(), 1);

        // Check order details
        (uint256 totalEscrow, uint256 paidToNodes, uint256 remainingEscrow) = market.getOrderEscrowInfo(orderId);
        assertEq(totalEscrow, totalCost);
        assertEq(paidToNodes, 0);
        assertEq(remainingEscrow, totalCost);
        assertFalse(market.isOrderExpired(orderId));
    }

    function test_ExecuteOrder() public {
        // First register a node
        vm.prank(node1);
        nodeStaking.stakeNode{value: TEST_STAKE}(TEST_CAPACITY, 0x1234, 0x5678);

        // Place an order
        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint8 replicas = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(
            fileMeta, maxSize, periods, replicas, price
        );

        // Node executes the order
        vm.prank(node1);
        market.executeOrder(orderId);

        // Check node's used capacity
        (, , uint64 used, ,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, maxSize);

        // Check node is assigned to order
        address[] memory orderNodes = market.getOrderNodes(orderId);
        assertEq(orderNodes.length, 1);
        assertEq(orderNodes[0], node1);

        uint256[] memory nodeOrders = market.getNodeOrders(node1);
        assertEq(nodeOrders.length, 1);
        assertEq(nodeOrders[0], orderId);
    }

    function test_MultipleNodesExecuteOrder() public {
        // Register multiple nodes
        vm.prank(node1);
        nodeStaking.stakeNode{value: TEST_STAKE}(TEST_CAPACITY, 0x1234, 0x5678);
        
        vm.prank(node2);
        nodeStaking.stakeNode{value: TEST_STAKE}(TEST_CAPACITY, 0xabcd, 0xef01);

        // Place an order with 2 replicas
        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint8 replicas = 2;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(
            fileMeta, maxSize, periods, replicas, price
        );

        // First node executes
        vm.prank(node1);
        market.executeOrder(orderId);

        // Second node executes
        vm.prank(node2);
        market.executeOrder(orderId);

        // Check both nodes have used capacity
        (, , uint64 used1, ,) = nodeStaking.getNodeInfo(node1);
        (, , uint64 used2, ,) = nodeStaking.getNodeInfo(node2);
        assertEq(used1, maxSize);
        assertEq(used2, maxSize);

        address[] memory orderNodes = market.getOrderNodes(orderId);
        assertEq(orderNodes.length, 2);
        assertEq(orderNodes[0], node1);
        assertEq(orderNodes[1], node2);
    }

    function test_HeartbeatBootstrap() public {
        // Test heartbeat can be triggered with no orders
        assertEq(market.currentRandomness(), 0);
        assertEq(market.lastChallengeStep(), 0);

        // Move forward in time to get a positive step
        vm.warp(block.timestamp + 31);

        // Trigger heartbeat
        market.triggerHeartbeat();

        // Check randomness was initialized and step was updated
        assertTrue(market.currentRandomness() != 0);
        assertEq(market.lastChallengeStep(), market.currentStep());
    }

    function test_ChallengeSystem() public {
        // Register nodes with double capacity each
        uint64 largeCapacity = TEST_CAPACITY * 2;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);
        
        vm.deal(node2, largeStake);
        vm.prank(node2);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0xabcd, 0xef01);

        // Place multiple orders
        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        // Place 3 orders
        uint256[] memory orderIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user1);
            orderIds[i] = market.placeOrder{value: totalCost}(
                fileMeta, maxSize, periods, replicas, price
            );
            
            // Alternate between nodes
            vm.prank(i % 2 == 0 ? node1 : node2);
            market.executeOrder(orderIds[i]);
        }

        // Move forward to step 1 and trigger heartbeat to start challenge system
        vm.warp(block.timestamp + 31);
        market.triggerHeartbeat();

        // Check challenge was issued
        (
            uint256 randomness,
            uint256 challengeStep,
            address primaryProver,
            address[] memory secondaryProvers,
            uint256[] memory challengedOrders,
            bool primarySubmitted,
            bool challengeActive
        ) = market.getCurrentChallengeInfo();

        assertTrue(randomness != 0);
        assertTrue(challengeStep > 0);
        assertTrue(primaryProver != address(0));
        assertTrue(challengedOrders.length > 0);
        assertFalse(primarySubmitted);
        assertTrue(challengeActive);
    }

    function test_NodeRewardClaiming() public {
        // Register node with double capacity
        uint64 largeCapacity = TEST_CAPACITY * 2;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_BYTE;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234, 0x5678);

        // Place order
        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 1024;
        uint16 periods = 1; // Short period for testing
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(
            fileMeta, maxSize, periods, replicas, price
        );

        // Node executes order
        vm.prank(node1);
        market.executeOrder(orderId);

        // Fast forward time to accumulate rewards
        vm.warp(block.timestamp + 7 days + 1); // After one period

        // Check claimable rewards
        uint256 claimable = market.getClaimableRewards(node1);
        assertEq(claimable, totalCost); // Node should get full payment for single replica

        // Claim rewards
        uint256 balanceBefore = node1.balance;
        vm.prank(node1);
        market.claimRewards();
        
        uint256 balanceAfter = node1.balance;
        assertEq(balanceAfter - balanceBefore, totalCost);
    }

    function test_OrderCancellation() public {
        // Place order
        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(
            fileMeta, maxSize, periods, replicas, price
        );

        uint256 balanceBefore = user1.balance;
        
        // Cancel order (no nodes assigned yet, so full refund)
        vm.prank(user1);
        market.cancelOrder(orderId);

        uint256 balanceAfter = user1.balance;
        assertEq(balanceAfter - balanceBefore, totalCost);

        // Check order is removed
        assertEq(market.getActiveOrdersCount(), 0);
    }

    function test_OrderCancellationWithPenalty() public {
        // Register node and execute order
        vm.prank(node1);
        nodeStaking.stakeNode{value: TEST_STAKE}(TEST_CAPACITY, 0x1234, 0x5678);

        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(
            fileMeta, maxSize, periods, replicas, price
        );

        vm.prank(node1);
        market.executeOrder(orderId);

        uint256 balanceBefore = user1.balance;
        
        // Cancel order (with penalty due to node storage)
        vm.prank(user1);
        market.cancelOrder(orderId);

        uint256 balanceAfter = user1.balance;
        uint256 penalty = totalCost / 10; // 10% penalty
        assertEq(balanceAfter - balanceBefore, totalCost - penalty);
    }

    function test_RandomOrderSelection() public {
        // Place multiple orders first
        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        // Place 10 orders
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user1);
            market.placeOrder{value: totalCost}(
                fileMeta, maxSize, periods, replicas, price
            );
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
        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 1024;
        uint16 periods = 2;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(
            fileMeta, maxSize, periods, replicas, price
        );

        // Node executes order
        vm.prank(node1);
        market.executeOrder(orderId);

        // Check initial escrow state
        (uint256 totalEscrow, uint256 paidToNodes, uint256 remainingEscrow) = 
            market.getOrderEscrowInfo(orderId);
        
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
        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: 1 ether}(
            fileMeta, 1000, 4, 1, 1e12 // 1000 bytes > 100 capacity
        );

        // This should fail
        vm.prank(node1);
        vm.expectRevert("insufficient capacity");
        market.executeOrder(orderId);
    }

    function test_RevertWhen_ClaimRewardsInvalidNode() public {
        // Try to claim rewards without being a registered node
        vm.prank(user1);
        vm.expectRevert("not a valid node");
        market.claimRewards();
    }

    function test_RevertWhen_CancelOrderNotOwner() public {
        // User1 places order
        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: 1 ether}(
            fileMeta, 1024, 4, 1, 1e12
        );

        // User2 tries to cancel (should fail)
        vm.prank(user2);
        vm.expectRevert("not order owner");
        market.cancelOrder(orderId);
    }

    // -------------------------------------------------------------------------
    // Additional security and reward-settlement scenarios
    // -------------------------------------------------------------------------

    function test_RevertWhen_SlashNodeUnauthorized() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        vm.prank(user1);
        vm.expectRevert("not authorized");
        market.slashNode(node1, 1, "grief");
    }

    function test_SlashAuthorityForcesExitAndQueuesRewards() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(
            fileMeta, maxSize, periods, replicas, price
        );

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + PERIOD + 1);

        market.setSlashAuthority(user2, true);
        uint256 slashAmount = nodeStaking.STAKE_PER_BYTE();

        vm.prank(user2);
        market.slashNode(node1, slashAmount, "challenge failure");

        address[] memory orderNodes = market.getOrderNodes(orderId);
        assertEq(orderNodes.length, 0, "node should be removed from order");

        uint256 expectedReward = uint256(maxSize) * price;
        assertEq(market.nodePendingRewards(node1), expectedReward, "pending reward queued");

        uint256 balanceBefore = node1.balance;
        vm.prank(node1);
        market.claimRewards();
        uint256 balanceAfter = node1.balance;

        assertEq(balanceAfter - balanceBefore, expectedReward, "reward paid out");
        assertEq(market.nodePendingRewards(node1), 0, "pending rewards cleared");
    }

    function test_CancelOrderQueuesPendingRewards() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 1024;
        uint16 periods = 4;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(
            fileMeta, maxSize, periods, replicas, price
        );

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + PERIOD + 1);

        uint256 ownerBalanceBefore = user1.balance;

        vm.prank(user1);
        market.cancelOrder(orderId);

        uint256 nodePending = market.nodePendingRewards(node1);
        uint256 expectedReward = uint256(maxSize) * price;
        assertEq(nodePending, expectedReward, "reward queued for node");

        uint256 expectedRemaining = totalCost - expectedReward;
        uint256 expectedPenalty = expectedRemaining / 10;
        uint256 expectedRefund = expectedRemaining - expectedPenalty;
        uint256 ownerBalanceAfter = user1.balance;
        assertEq(ownerBalanceAfter - ownerBalanceBefore, expectedRefund, "owner refund accounts for rewards and penalty");

        uint256 nodeBalanceBefore = node1.balance;
        vm.prank(node1);
        market.claimRewards();
        uint256 nodeBalanceAfter = node1.balance;
        assertEq(nodeBalanceAfter - nodeBalanceBefore, expectedReward, "node reward paid after cancellation");
        assertEq(market.nodePendingRewards(node1), 0, "pending rewards cleared after claim");
    }

    function test_RevertWhen_ExecuteOrderAfterExpiry() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint16 periods = 1;

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: 1 ether}(
            fileMeta, 1024, periods, 1, 1e12
        );

        vm.warp(block.timestamp + PERIOD * uint256(periods) + 1);

        vm.prank(node1);
        vm.expectRevert("order expired");
        market.executeOrder(orderId);
    }

    function test_RevertWhen_NodeExecutesSameOrderTwice() public {
        _stakeTestNode(node1, 0x1234, 0x5678);

        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: 1 ether}(
            fileMeta, 512, 2, 2, 1e12
        );

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.prank(node1);
        vm.expectRevert("already assigned to this order");
        market.executeOrder(orderId);
    }

    function test_SlashSecondaryFailuresOnlyOnce() public {
        _stakeTestNode(node1, 0x1234, 0x5678);
        _stakeTestNode(node2, 0xabcd, 0xef01);

        FileMarket.FileMeta memory fileMeta = FileMarket.FileMeta({
            root: FILE_ROOT,
            uri: FILE_URI
        });

        uint64 maxSize = 256;
        uint16 periods = 2;
        uint8 replicas = 1;
        uint256 price = 1e12;
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price;

        vm.prank(user1);
        uint256 orderId1 = market.placeOrder{value: totalCost}(
            fileMeta, maxSize, periods, replicas, price
        );
        vm.prank(node1);
        market.executeOrder(orderId1);

        vm.prank(user1);
        uint256 orderId2 = market.placeOrder{value: totalCost}(
            fileMeta, maxSize, periods, replicas, price
        );
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
}
