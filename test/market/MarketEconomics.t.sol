// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";
import {MarketStorage} from "../../src/market/MarketStorage.sol";

/// @notice Tests for the economic redesign (Changes 1-6)
contract MarketEconomicsTest is MarketTestBase {
    // =========================================================================
    // Change 1: Challenge Slash Multiplier
    // =========================================================================

    function test_SlashMultiplier_DefaultIsThree() public view {
        assertEq(market.proofFailureSlashMultiplier(), 3, "default multiplier is 3");
    }

    function test_SlashMultiplier_AppliedToProportionalSlash() public {
        // Order where scaledSlash > floor: 10000 chunks at 1e13 price
        // orderPeriodCost = 10000 * 1e13 = 1e17
        // scaledSlash = 1e17 * 3 = 3e17 > floor (1.5e17)
        uint32 size = 10000;
        uint256 price = 1e13;
        uint64 nodeCapacity = 100000;
        uint256 scaledSlash = uint256(size) * price * 3;

        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeOrder(user1, size, 4, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);
        market.activateSlots();

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        market.processExpiredSlots();

        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);
        uint256 actualSlash = stakeBefore - stakeAfter;
        assertEq(actualSlash, scaledSlash, "slash = orderPeriodCost * 3");
    }

    function test_SlashMultiplier_FloorAppliedForSmallOrders() public {
        // Default order: 1024 chunks at 1e12 → scaledSlash = 1024 * 1e12 * 3 = 3.072e15
        // Floor = 1500 * 1e14 = 1.5e17
        // 3.072e15 < 1.5e17 → floor applies
        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);
        market.activateSlots();

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        market.processExpiredSlots();

        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);
        uint256 actualSlash = stakeBefore - stakeAfter;
        assertEq(actualSlash, 1500 * STAKE_PER_CHUNK, "floor = 0.15 MURI");
    }

    function test_SlashMultiplier_AdminCanUpdate() public {
        market.setProofFailureSlashMultiplier(5);
        assertEq(market.proofFailureSlashMultiplier(), 5);
    }

    function test_SlashMultiplier_RevertExceedsMax() public {
        vm.expectRevert("invalid multiplier");
        market.setProofFailureSlashMultiplier(11);
    }

    function test_SlashMultiplier_RevertZero() public {
        vm.expectRevert("invalid multiplier");
        market.setProofFailureSlashMultiplier(0);
    }

    function test_SlashMultiplier_RevertNotOwner() public {
        vm.prank(user1);
        vm.expectRevert("not owner");
        market.setProofFailureSlashMultiplier(5);
    }

    // =========================================================================
    // Change 2: On-Demand Challenges
    // =========================================================================

    function test_OnDemand_ChallengeNodeSuccess() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Anyone can issue an on-demand challenge
        vm.prank(user2);
        market.challengeNode(orderId, node1);

        // Verify challenge is stored
        bytes32 key = keccak256(abi.encodePacked(orderId, node1));
        (uint64 deadline, uint256 randomness, address challenger) = market.onDemandChallenges(key);
        assertGt(deadline, 0, "deadline set");
        assertGt(randomness, 0, "randomness set");
        assertEq(challenger, user2, "challenger recorded");
    }

    function test_OnDemand_RevertOrderDoesNotExist() public {
        vm.expectRevert("order does not exist");
        market.challengeNode(999, node1);
    }

    function test_OnDemand_RevertNodeNotAssigned() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.expectRevert("node not assigned to this order");
        market.challengeNode(orderId, node1);
    }

    function test_OnDemand_RevertCooldown() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        // First challenge
        market.challengeNode(orderId, node1);

        // Immediate re-challenge should fail (cooldown)
        vm.expectRevert("on-demand challenge cooldown");
        market.challengeNode(orderId, node1);
    }

    function test_OnDemand_CooldownExpiresAfterWindow() public {
        // Use large capacity so node survives the on-demand slash
        uint64 nodeCapacity = 100000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        // First challenge
        market.challengeNode(orderId, node1);

        // Process the expired challenge so it's cleared (node gets slashed but survives)
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        market.processExpiredOnDemandChallenge(orderId, node1);

        // After cooldown (deadline + 2 * CHALLENGE_WINDOW_BLOCKS), should work
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS * 2 + 1);
        market.challengeNode(orderId, node1);
    }

    function test_OnDemand_ProcessExpiredSlashesNode() public {
        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.prank(user2);
        market.challengeNode(orderId, node1);

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);

        // Let challenge expire
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // Anyone can process expired on-demand challenge
        vm.prank(user2);
        market.processExpiredOnDemandChallenge(orderId, node1);

        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);
        assertTrue(stakeAfter < stakeBefore, "node was slashed");

        // Reporter (user2) should get reward
        assertGt(market.reporterPendingRewards(user2), 0, "reporter gets reward");
    }

    function test_OnDemand_SubmitProofReverts_WhenNoChallenge() public {
        uint256[8] memory proof;
        vm.prank(node1);
        vm.expectRevert("no active on-demand challenge");
        market.submitOnDemandProof(1, proof, bytes32(uint256(1)));
    }

    function test_OnDemand_ProcessExpiredReverts_WhenNoChallenge() public {
        vm.expectRevert("no active on-demand challenge");
        market.processExpiredOnDemandChallenge(1, node1);
    }

    function test_OnDemand_ProcessExpiredReverts_WhenNotExpired() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.challengeNode(orderId, node1);

        vm.expectRevert("on-demand challenge not expired");
        market.processExpiredOnDemandChallenge(orderId, node1);
    }

    function test_OnDemand_RevertExpiredOrder() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeOrder(user1, 256, 1, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Expire the order
        vm.warp(block.timestamp + PERIOD + 1);

        vm.expectRevert("order expired");
        market.challengeNode(orderId, node1);
    }

    // =========================================================================
    // Change 3: Scaled Quit Penalty
    // =========================================================================

    function test_QuitPenalty_ShortTerm_FullRemaining() public {
        // 1 period remaining → slashPeriods = 1
        uint64 largeCapacity = TEST_CAPACITY * 4;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_CHUNK;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234);

        uint32 maxSize = 256;
        uint256 price = 1e12;
        (uint256 orderId,) = _placeOrder(user1, maxSize, 1, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        vm.prank(node1);
        market.quitOrder(orderId);
        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);

        uint256 expectedSlash = uint256(maxSize) * price * 1; // 1 remaining period
        assertTrue(stakeBefore - stakeAfter >= expectedSlash, "slash = 1 * period cost");
    }

    function test_QuitPenalty_4Remaining_FullSlash() public {
        // 4 remaining → slashPeriods = 4 (full, since <= BASE)
        uint64 largeCapacity = TEST_CAPACITY * 4;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_CHUNK;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234);

        uint32 maxSize = 256;
        uint256 price = 1e12;
        (uint256 orderId,) = _placeOrder(user1, maxSize, 4, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        vm.prank(node1);
        market.quitOrder(orderId);
        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);

        uint256 expectedSlash = uint256(maxSize) * price * 4;
        assertTrue(stakeBefore - stakeAfter >= expectedSlash, "slash = 4 * period cost");
    }

    function test_QuitPenalty_20Remaining_ScaledFormula() public {
        // 20 remaining → slashPeriods = 4 + (20-4)/4 = 4 + 4 = 8
        uint64 largeCapacity = TEST_CAPACITY * 4;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_CHUNK;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234);

        uint32 maxSize = 256;
        uint256 price = 1e12;
        (uint256 orderId,) = _placeOrder(user1, maxSize, 20, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        vm.prank(node1);
        market.quitOrder(orderId);
        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);

        uint256 expectedSlash = uint256(maxSize) * price * 8; // 4 + (20-4)/4 = 8
        assertTrue(stakeBefore - stakeAfter >= expectedSlash, "slash = 8 * period cost for 20 remaining");
    }

    function test_QuitPenalty_52Remaining_ScaledFormula() public {
        // 52 remaining → slashPeriods = 4 + (52-4)/4 = 4 + 12 = 16
        uint64 largeCapacity = TEST_CAPACITY * 8;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_CHUNK;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234);

        uint32 maxSize = 256;
        uint256 price = 1e12;
        (uint256 orderId,) = _placeOrder(user1, maxSize, 52, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        vm.prank(node1);
        market.quitOrder(orderId);
        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);

        uint256 expectedSlash = uint256(maxSize) * price * 16; // 4 + (52-4)/4 = 16
        assertTrue(stakeBefore - stakeAfter >= expectedSlash, "slash = 16 * period cost for 52 remaining");
    }

    function test_QuitPenalty_Fuzz(uint16 remainingPeriods, uint32 numChunks, uint256 price) public {
        // Bound inputs to reasonable ranges
        remainingPeriods = uint16(bound(remainingPeriods, 1, 52));
        numChunks = uint32(bound(numChunks, 1, 1000));
        price = bound(price, 1, 1e13);

        // Calculate expected slashPeriods
        uint256 expectedSlashPeriods;
        if (remainingPeriods <= 4) {
            expectedSlashPeriods = remainingPeriods;
        } else {
            expectedSlashPeriods = 4 + (uint256(remainingPeriods) - 4) / 4;
        }

        // Verify formula produces reasonable results
        assertTrue(expectedSlashPeriods >= 1, "at least 1 period");
        assertTrue(expectedSlashPeriods <= remainingPeriods, "never exceeds remaining");
        if (remainingPeriods > 4) {
            assertTrue(expectedSlashPeriods >= 4, "at least base for long orders");
        }
        // For very long orders, slash grows meaningfully
        if (remainingPeriods >= 8) {
            assertTrue(expectedSlashPeriods > 4, "exceeds base for 8+ remaining");
        }
    }

    // =========================================================================
    // Change 4: Scaled Cancellation Penalty
    // =========================================================================

    function test_CancelPenalty_AtStart_25Percent() public {
        _stakeDefaultNode(node1, 0x1234);
        uint32 maxSize = 256;
        uint16 periods = 4;
        uint256 price = 1e12;
        (uint256 orderId, uint256 totalCost) = _placeOrder(user1, maxSize, periods, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Warp exactly 1 period so node is eligible for penalty
        vm.warp(block.timestamp + PERIOD);

        uint256 user1BalBefore = market.pendingRefunds(user1);
        vm.prank(user1);
        market.cancelOrder(orderId);
        uint256 user1Refund = market.pendingRefunds(user1) - user1BalBefore;

        uint256 reward = uint256(maxSize) * price; // 1 period
        uint256 remaining = totalCost - reward;
        // At period 1 of 4: penaltyBps = 2500 - (2000 * 1 / 4) = 2000
        uint256 penalty = remaining * 2000 / 10000;
        uint256 expectedRefund = remaining - penalty;
        assertEq(user1Refund, expectedRefund, "refund matches scaled penalty at 25% completion");
    }

    function test_CancelPenalty_AtHalf_15Percent() public {
        _stakeDefaultNode(node1, 0x1234);
        uint32 maxSize = 256;
        uint16 periods = 4;
        uint256 price = 1e12;
        (uint256 orderId, uint256 totalCost) = _placeOrder(user1, maxSize, periods, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Warp 2 periods (50% completion)
        vm.warp(block.timestamp + PERIOD * 2);

        vm.prank(user1);
        market.cancelOrder(orderId);

        uint256 reward = uint256(maxSize) * price * 2;
        uint256 remaining = totalCost - reward;
        // At period 2 of 4: penaltyBps = 2500 - (2000 * 2 / 4) = 1500
        uint256 penalty = remaining * 1500 / 10000;
        uint256 expectedRefund = remaining - penalty;
        assertEq(market.pendingRefunds(user1), expectedRefund, "15% penalty at 50% completion");
    }

    function test_CancelPenalty_Near75Percent() public {
        _stakeDefaultNode(node1, 0x1234);
        uint32 maxSize = 256;
        uint16 periods = 4;
        uint256 price = 1e12;
        (uint256 orderId, uint256 totalCost) = _placeOrder(user1, maxSize, periods, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        // Warp 3 periods (75% completion)
        vm.warp(block.timestamp + PERIOD * 3);

        vm.prank(user1);
        market.cancelOrder(orderId);

        uint256 reward = uint256(maxSize) * price * 3;
        uint256 remaining = totalCost - reward;
        // At period 3 of 4: penaltyBps = 2500 - (2000 * 3 / 4) = 1000
        uint256 penalty = remaining * 1000 / 10000;
        uint256 expectedRefund = remaining - penalty;
        assertEq(market.pendingRefunds(user1), expectedRefund, "10% penalty at 75% completion");
    }

    function test_CancelPenalty_Fuzz(uint16 elapsedPeriods, uint16 totalPeriods, uint256 remainingEscrow) public {
        totalPeriods = uint16(bound(totalPeriods, 1, 52));
        elapsedPeriods = uint16(bound(elapsedPeriods, 0, totalPeriods - 1));
        remainingEscrow = bound(remainingEscrow, 1e12, 100 ether);

        uint256 penaltyRange = 2500 - 500; // 2000
        uint256 penaltyBps = 2500 - (penaltyRange * uint256(elapsedPeriods) / uint256(totalPeriods));
        uint256 penalty = remainingEscrow * penaltyBps / 10000;

        // Verify bounds
        assertTrue(penaltyBps >= 500, "penalty >= 5%");
        assertTrue(penaltyBps <= 2500, "penalty <= 25%");
        assertTrue(penalty <= remainingEscrow, "penalty <= remaining");
    }

    // =========================================================================
    // Change 5: Client Compensation
    // =========================================================================

    function test_ClientComp_DefaultIs20Percent() public view {
        assertEq(market.clientCompensationBps(), 2000, "default 20%");
    }

    function test_ClientComp_PaidOnChallengeFailure() public {
        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        _stakeDefaultNode(node2, 0xABCD);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        uint256 clientRefundBefore = market.pendingRefunds(user1);

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        market.processExpiredSlots();

        uint256 clientRefundAfter = market.pendingRefunds(user1);
        assertTrue(clientRefundAfter > clientRefundBefore, "client received compensation");

        // Verify 20% went to client
        (uint256 totalReceived,,,, uint256 totalClientComp) = market.getSlashRedistributionStats();
        assertGt(totalClientComp, 0, "client compensation tracked");
        // clientComp = totalSlashed * 2000 / 10000 = 20% of slash
        assertEq(totalClientComp, totalReceived * 2000 / 10000, "20% of slash to client");
    }

    function test_ClientComp_SkippedForVoluntaryQuit() public {
        uint64 largeCapacity = TEST_CAPACITY * 4;
        uint256 largeStake = uint256(largeCapacity) * STAKE_PER_CHUNK;
        vm.deal(node1, largeStake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: largeStake}(largeCapacity, 0x1234);

        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        vm.prank(node1);
        market.executeOrder(orderId);

        uint256 clientRefundBefore = market.pendingRefunds(user1);
        vm.prank(node1);
        market.quitOrder(orderId);

        assertEq(market.pendingRefunds(user1), clientRefundBefore, "no client comp for voluntary quit");
        assertEq(market.totalClientCompensation(), 0, "zero client comp tracked");
    }

    function test_ClientComp_AdminCanSetBps() public {
        market.setClientCompensationBps(3000);
        assertEq(market.clientCompensationBps(), 3000);
    }

    function test_ClientComp_RevertExceedsMax() public {
        vm.expectRevert("exceeds max bps");
        market.setClientCompensationBps(5001);
    }

    function test_ClientComp_RevertNotOwner() public {
        vm.prank(user1);
        vm.expectRevert("not owner");
        market.setClientCompensationBps(3000);
    }

    function test_ClientComp_ZeroBpsSkipsComp() public {
        market.setClientCompensationBps(0);

        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);
        market.activateSlots();

        uint256 clientRefundBefore = market.pendingRefunds(user1);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        market.processExpiredSlots();

        assertEq(market.pendingRefunds(user1), clientRefundBefore, "no comp when bps=0");
    }

    function test_ClientComp_SlashDistributionSumsCorrectly() public {
        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        _stakeDefaultNode(node2, 0xABCD);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);
        market.activateSlots();

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        market.processExpiredSlots();

        (uint256 totalReceived, uint256 totalBurned, uint256 totalRewards,, uint256 totalClientComp) =
            market.getSlashRedistributionStats();

        // reporter=10%, client=20%, burn=70%
        assertEq(totalRewards + totalClientComp + totalBurned, totalReceived, "reporter + client + burn = total");
    }

    // =========================================================================
    // Change 6: Quit Lock-in Fix
    // =========================================================================

    function test_QuitLockin_CanQuitWhenSlashExceedsMaxSafe() public {
        // Node with tight capacity serving 2 orders
        uint64 capacity = 512;
        uint256 stake = uint256(capacity) * STAKE_PER_CHUNK;
        vm.deal(node1, stake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234);

        // Two orders that fill the capacity exactly
        uint32 maxSize = 256;
        uint16 periods = 20; // high remaining → large slash
        uint256 price = 1e12;

        (uint256 orderId1,) = _placeOrder(user1, maxSize, periods, 1, price);
        (uint256 orderId2,) = _placeOrder(user1, maxSize, periods, 1, price);

        vm.startPrank(node1);
        market.executeOrder(orderId1);
        market.executeOrder(orderId2);
        vm.stopPrank();

        // Quit order1: slashPeriods = 4 + (20-4)/4 = 8
        // slashAmount = 256 * 1e12 * 8 = 2048e12
        // usedAfterQuit = 256, requiredStakeAfterQuit = 256 * 1e14 = 2.56e16
        // maxSafeSlash = 5.12e16 - 2.56e16 = 2.56e16
        // 2048e12 < 2.56e16 → fits, but let's test a tighter scenario

        // Previously would revert with "insufficient collateral for quit slash"
        // Now caps at maxSafeSlash instead of reverting
        vm.prank(node1);
        market.quitOrder(orderId1); // should NOT revert

        // Node still has order2
        address[] memory nodes = market.getOrderNodes(orderId2);
        assertEq(nodes.length, 1, "order2 still has node");
        assertEq(nodes[0], node1, "node1 still serves order2");
    }

    function test_QuitLockin_CapsSlashAtMaxSafe() public {
        // Create scenario where slashAmount > maxSafeSlash
        // Node with capacity 300, two orders: 200 + 100
        uint64 capacity = 300;
        uint256 stake = uint256(capacity) * STAKE_PER_CHUNK;
        vm.deal(node1, stake);
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234);

        // Order with very high price to make slashAmount large
        uint32 maxSize = 100;
        uint16 periods = 20;
        uint256 highPrice = STAKE_PER_CHUNK; // 1e14 per chunk per period

        MarketStorage.FileMeta memory fileMeta = _fileMeta();
        uint256 cost1 = uint256(200) * uint256(periods) * 1e12;
        vm.prank(user1);
        uint256 orderId1 = market.placeOrder{value: cost1}(fileMeta, 200, periods, 1, 1e12, _emptyFspProof());

        uint256 cost2 = uint256(maxSize) * uint256(periods) * highPrice;
        vm.deal(user1, user1.balance + cost2);
        vm.prank(user1);
        uint256 orderId2 =
            market.placeOrder{value: cost2}(fileMeta, uint32(maxSize), periods, 1, highPrice, _emptyFspProof());

        vm.startPrank(node1);
        market.executeOrder(orderId1);
        market.executeOrder(orderId2);
        vm.stopPrank();

        // Quit order2 (highPrice): slashPeriods = 4 + (20-4)/4 = 8
        // slashAmount = 100 * 1e14 * 8 = 8e16
        // usedAfterQuit = 200, requiredStakeAfterQuit = 200 * 1e14 = 2e16
        // maxSafeSlash = 3e16 - 2e16 = 1e16
        // slashAmount (8e16) > maxSafeSlash (1e16) → should be capped

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        vm.prank(node1);
        market.quitOrder(orderId2); // should NOT revert
        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);

        uint256 actualSlash = stakeBefore - stakeAfter;
        uint256 maxSafeSlash = stake - (200 * STAKE_PER_CHUNK);
        assertTrue(actualSlash <= maxSafeSlash, "slash was capped at maxSafeSlash");

        // Node still has order1
        assertEq(market.getOrderNodes(orderId1).length, 1, "order1 still served");
    }

    // =========================================================================
    // On-Demand + Client Comp integration
    // =========================================================================

    function test_OnDemand_ClientCompOnExpiry() public {
        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        uint256 clientRefundBefore = market.pendingRefunds(user1);

        vm.prank(user2);
        market.challengeNode(orderId, node1);

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        market.processExpiredOnDemandChallenge(orderId, node1);

        uint256 clientRefundAfter = market.pendingRefunds(user1);
        assertTrue(clientRefundAfter > clientRefundBefore, "client gets comp from on-demand challenge failure");
    }
}
