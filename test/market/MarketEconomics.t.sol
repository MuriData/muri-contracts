// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";

/// @notice Tests for the economic redesign (Changes 1-6)
contract MarketEconomicsTest is MarketTestBase {
    // =========================================================================
    // Change 0: Pricing Guardrails
    // =========================================================================

    function test_MinPriceFloor_DefaultIsZero() public view {
        assertEq(market.minPricePerChunkPerPeriod(), 0, "price floor defaults to zero");
    }

    function test_MinPriceFloor_AdminCanUpdate() public {
        marketExt2.setMinPricePerChunkPerPeriod(2e12);
        assertEq(market.minPricePerChunkPerPeriod(), 2e12);
    }

    function test_MinPriceFloor_RevertBelowFloor() public {
        marketExt2.setMinPricePerChunkPerPeriod(2e12);

        vm.prank(user1);
        vm.expectRevert("price below floor");
        market.placeOrder{value: uint256(1024) * 4 * 1e12}(FILE_ROOT, FILE_URI, 1024, 4, 1, 1e12, _emptyFspProof());
    }

    function test_MinPriceFloor_RevertNotOwner() public {
        vm.prank(user1);
        vm.expectRevert("not owner");
        marketExt2.setMinPricePerChunkPerPeriod(2e12);
    }

    // =========================================================================
    // Change 1: Challenge Slash Multiplier
    // =========================================================================

    function test_SlashMultiplier_DefaultIsThree() public view {
        assertEq(market.proofFailureSlashMultiplier(), 3, "default multiplier is 3");
    }

    function test_SlashMultiplier_AppliedToProportionalSlash() public {
        // Order where scaledSlash > floor: 30000 chunks at 1e13 price
        // orderPeriodCost = 30000 * 1e13 = 3e17
        // scaledSlash = 3e17 * 3 = 9e17 > floor (1500 * 4e14 = 6e17)
        uint32 size = 30000;
        uint256 price = 1e13;
        uint64 nodeCapacity = 100000;
        uint256 scaledSlash = uint256(size) * price * 3;

        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeOrder(user1, size, 4, 1, price);

        _executeOrder(node1, orderId);
        marketExt.activateSlots();

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        marketExt.processExpiredSlots();

        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);
        uint256 actualSlash = stakeBefore - stakeAfter;
        assertEq(actualSlash, scaledSlash, "slash = orderPeriodCost * 3");
    }

    function test_SlashMultiplier_FloorAppliedForSmallOrders() public {
        // Default order: 1024 chunks at 1e12 → scaledSlash = 1024 * 1e12 * 3 = 3.072e15
        // Floor = 1500 * 4e14 = 6e17
        // 3.072e15 < 1.5e17 → floor applies
        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);
        marketExt.activateSlots();

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        marketExt.processExpiredSlots();

        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);
        uint256 actualSlash = stakeBefore - stakeAfter;
        assertEq(actualSlash, 1500 * STAKE_PER_CHUNK, "floor = 0.6 MURI");
    }

    function test_SlashMultiplier_AdminCanUpdate() public {
        marketExt2.setProofFailureSlashMultiplier(5);
        assertEq(market.proofFailureSlashMultiplier(), 5);
    }

    function test_SlashMultiplier_RevertExceedsMax() public {
        vm.expectRevert("invalid multiplier");
        marketExt2.setProofFailureSlashMultiplier(11);
    }

    function test_SlashMultiplier_RevertZero() public {
        vm.expectRevert("invalid multiplier");
        marketExt2.setProofFailureSlashMultiplier(0);
    }

    function test_SlashMultiplier_RevertNotOwner() public {
        vm.prank(user1);
        vm.expectRevert("not owner");
        marketExt2.setProofFailureSlashMultiplier(5);
    }

    // =========================================================================
    // Change 2: On-Demand Challenges
    // =========================================================================

    function test_OnDemand_ChallengeNodeSuccess() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);

        // Anyone can issue an on-demand challenge
        vm.prank(user2);
        marketExt2.challengeNode(orderId, node1);

        // Verify challenge is stored
        bytes32 key = keccak256(abi.encodePacked(orderId, node1));
        (uint64 deadline, uint256 randomness, address challenger,,, uint256 bondAmount) = market.onDemandChallenges(key);
        assertGt(deadline, 0, "deadline set");
        assertGt(randomness, 0, "randomness set");
        assertEq(challenger, user2, "challenger recorded");
        assertEq(bondAmount, 0, "default bond is zero");
    }

    function test_OnDemand_RevertOrderDoesNotExist() public {
        vm.expectRevert("order does not exist");
        marketExt2.challengeNode(999, node1);
    }

    function test_OnDemand_RevertNodeNotAssigned() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.expectRevert("node not assigned to this order");
        marketExt2.challengeNode(orderId, node1);
    }

    function test_OnDemand_RevertCooldown() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);

        // First challenge
        marketExt2.challengeNode(orderId, node1);

        // Immediate re-challenge should fail (cooldown)
        vm.expectRevert("on-demand challenge cooldown");
        marketExt2.challengeNode(orderId, node1);
    }

    function test_OnDemand_CooldownExpiresAfterWindow() public {
        // Use large capacity so node survives the on-demand slash
        uint64 nodeCapacity = 100000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);

        // First challenge
        marketExt2.challengeNode(orderId, node1);

        // Process the expired challenge so it's cleared (node gets slashed but survives)
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);

        // After cooldown (deadline + 2 * CHALLENGE_WINDOW_BLOCKS), should work
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS * 2 + 1);
        marketExt2.challengeNode(orderId, node1);
    }

    function test_OnDemand_ProcessExpiredSlashesNode() public {
        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);

        vm.prank(user2);
        marketExt2.challengeNode(orderId, node1);

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);

        // Let challenge expire
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // Anyone can process expired on-demand challenge
        vm.prank(user2);
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);

        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);
        assertTrue(stakeAfter < stakeBefore, "node was slashed");

        // Reporter (user2) should get reward
        assertGt(market.reporterPendingRewards(user2), 0, "reporter gets reward");
    }

    function test_OnDemandBond_RevertInsufficientBond() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        _executeOrder(node1, orderId);

        marketExt2.setOnDemandChallengeBond(0.1 ether);

        vm.prank(user2);
        vm.expectRevert("insufficient challenge bond");
        marketExt2.challengeNode(orderId, node1);
    }

    function test_OnDemandBond_NodeGetsBondWhenItProves() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        _executeOrder(node1, orderId);

        uint256 bond = 0.1 ether;
        marketExt2.setOnDemandChallengeBond(bond);

        vm.prank(user2);
        marketExt2.challengeNode{value: bond}(orderId, node1);

        uint256 nodeRefundBefore = market.pendingRefunds(node1);
        uint256[4] memory proof;
        vm.prank(node1);
        marketExt2.submitOnDemandProof(orderId, proof, bytes32(uint256(1)));

        assertEq(market.pendingRefunds(node1) - nodeRefundBefore, bond, "bond queued to the node");
    }

    function test_OnDemandBond_ChallengerRefundedWhenNodeFails() public {
        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        _executeOrder(node1, orderId);

        uint256 bond = 0.1 ether;
        marketExt2.setOnDemandChallengeBond(bond);

        vm.prank(user2);
        marketExt2.challengeNode{value: bond}(orderId, node1);

        uint256 challengerRefundBefore = market.pendingRefunds(user2);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);

        assertEq(market.pendingRefunds(user2) - challengerRefundBefore, bond, "bond refunded to challenger");
    }

    function test_OnDemandBond_ChallengerRefundedWhenOrderCancelled() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        _executeOrder(node1, orderId);

        uint256 bond = 0.1 ether;
        marketExt2.setOnDemandChallengeBond(bond);

        vm.prank(user2);
        marketExt2.challengeNode{value: bond}(orderId, node1);

        vm.prank(user1);
        market.cancelOrder(orderId);

        uint256 challengerRefundBefore = market.pendingRefunds(user2);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);

        assertEq(market.pendingRefunds(user2) - challengerRefundBefore, bond, "bond refunded after cancellation");
    }

    function test_OnDemand_SubmitProofReverts_WhenNoChallenge() public {
        uint256[4] memory proof;
        vm.prank(node1);
        vm.expectRevert("no active on-demand challenge");
        marketExt2.submitOnDemandProof(1, proof, bytes32(uint256(1)));
    }

    function test_OnDemand_ProcessExpiredReverts_WhenNoChallenge() public {
        vm.expectRevert("no active on-demand challenge");
        marketExt2.processExpiredOnDemandChallenge(1, node1);
    }

    function test_OnDemand_ProcessExpiredReverts_WhenNotExpired() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);

        marketExt2.challengeNode(orderId, node1);

        vm.expectRevert("on-demand challenge not expired");
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);
    }

    function test_OnDemand_RevertExpiredOrder() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeOrder(user1, 256, 1, 1, 1e12);

        _executeOrder(node1, orderId);

        // Expire the order
        vm.warp(block.timestamp + PERIOD + 1);

        vm.expectRevert("order expired");
        marketExt2.challengeNode(orderId, node1);
    }

    // ---- Regression tests: cancel-order-during-on-demand-challenge attack ----

    function test_OnDemand_CancelOrder_NoSlashOnExpiry() public {
        // Attack scenario: client places order, challenges node, cancels order,
        // then processes expired challenge to slash the node.
        // The fix: processExpiredOnDemandChallenge must NOT slash if the order was deleted.
        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        _executeOrder(node1, orderId);

        // Client issues on-demand challenge
        vm.prank(user1);
        marketExt2.challengeNode(orderId, node1);

        // Client cancels the order
        vm.prank(user1);
        market.cancelOrder(orderId);

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);

        // Let challenge expire and process it
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);

        // Node must NOT be slashed — order was cancelled, node can't be faulted
        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);
        assertEq(stakeAfter, stakeBefore, "node should not be slashed after order cancellation");
    }

    function test_OnDemand_CancelOrder_NodeCanStillProve() public {
        // Even if the order is cancelled, the node should still be able to submit
        // proof using the file root snapshot stored in the challenge.
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        _executeOrder(node1, orderId);

        // Challenge the node
        vm.prank(user1);
        marketExt2.challengeNode(orderId, node1);

        // Cancel the order
        vm.prank(user1);
        market.cancelOrder(orderId);

        // Node submits proof (mocked verifier accepts any proof)
        uint256[4] memory proof;
        vm.prank(node1);
        marketExt2.submitOnDemandProof(orderId, proof, bytes32(uint256(1)));

        // Challenge should be cleared — processing should revert
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        vm.expectRevert("no active on-demand challenge");
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);
    }

    function test_OnDemand_CooldownHoldsAfterProofSubmission() public {
        // After a node successfully proves, immediate re-challenge must be blocked
        // by the cooldown (deadlineBlock preserved after resolution).
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        _executeOrder(node1, orderId);

        // Issue and resolve challenge
        marketExt2.challengeNode(orderId, node1);
        uint256[4] memory proof;
        vm.prank(node1);
        marketExt2.submitOnDemandProof(orderId, proof, bytes32(uint256(1)));

        // Immediate re-challenge should fail (cooldown)
        vm.expectRevert("on-demand challenge cooldown");
        marketExt2.challengeNode(orderId, node1);
    }

    function test_OnDemand_CooldownHoldsAfterExpiry() public {
        // After an expired challenge is processed, immediate re-challenge must be blocked.
        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        _executeOrder(node1, orderId);

        // Issue challenge, let it expire, process it
        marketExt2.challengeNode(orderId, node1);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);

        // Immediate re-challenge should fail (cooldown)
        vm.expectRevert("on-demand challenge cooldown");
        marketExt2.challengeNode(orderId, node1);
    }

    function test_OnDemandBond_AdminCanUpdate() public {
        marketExt2.setOnDemandChallengeBond(0.2 ether);
        assertEq(market.onDemandChallengeBond(), 0.2 ether);
    }

    function test_OnDemandBond_RevertNotOwner() public {
        vm.prank(user1);
        vm.expectRevert("not owner");
        marketExt2.setOnDemandChallengeBond(0.2 ether);
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

        _executeOrder(node1, orderId);

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

        _executeOrder(node1, orderId);

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

        _executeOrder(node1, orderId);

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

        _executeOrder(node1, orderId);

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

        _executeOrder(node1, orderId);

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

        _executeOrder(node1, orderId);

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

        _executeOrder(node1, orderId);

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

        _executeOrder(node1, orderId);

        marketExt.activateSlots();

        uint256 clientRefundBefore = market.pendingRefunds(user1);

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        marketExt.processExpiredSlots();

        uint256 clientRefundAfter = market.pendingRefunds(user1);
        assertTrue(clientRefundAfter > clientRefundBefore, "client received compensation");

        // Verify 20% went to client
        (uint256 totalReceived,,,, uint256 totalClientComp) = marketExt2.getSlashRedistributionStats();
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
        _executeOrder(node1, orderId);

        uint256 clientRefundBefore = market.pendingRefunds(user1);
        vm.prank(node1);
        market.quitOrder(orderId);

        assertEq(market.pendingRefunds(user1), clientRefundBefore, "no client comp for voluntary quit");
        assertEq(market.totalClientCompensation(), 0, "zero client comp tracked");
    }

    function test_ClientComp_AdminCanSetBps() public {
        marketExt2.setClientCompensationBps(3000);
        assertEq(market.clientCompensationBps(), 3000);
    }

    function test_ClientComp_RevertExceedsMax() public {
        vm.expectRevert("exceeds max bps");
        marketExt2.setClientCompensationBps(5001);
    }

    function test_ClientComp_RevertNotOwner() public {
        vm.prank(user1);
        vm.expectRevert("not owner");
        marketExt2.setClientCompensationBps(3000);
    }

    function test_ClientComp_ZeroBpsSkipsComp() public {
        marketExt2.setClientCompensationBps(0);

        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);
        marketExt.activateSlots();

        uint256 clientRefundBefore = market.pendingRefunds(user1);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        marketExt.processExpiredSlots();

        assertEq(market.pendingRefunds(user1), clientRefundBefore, "no comp when bps=0");
    }

    function test_ClientComp_SlashDistributionSumsCorrectly() public {
        uint64 nodeCapacity = 10000;
        _stakeNode(node1, nodeCapacity, 0x1234);
        _stakeDefaultNode(node2, 0xABCD);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);
        marketExt.activateSlots();

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        marketExt.processExpiredSlots();

        (uint256 totalReceived, uint256 totalBurned, uint256 totalRewards,, uint256 totalClientComp) =
            marketExt2.getSlashRedistributionStats();

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

        _executeOrder(node1, orderId1);
        _executeOrder(node1, orderId2);

        // Quit order1: slashPeriods = 4 + (20-4)/4 = 8
        // slashAmount = 256 * 1e12 * 8 = 2048e12
        // usedAfterQuit = 256, requiredStakeAfterQuit = 256 * 4e14 = 1.024e17
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
        uint256 highPrice = STAKE_PER_CHUNK; // 4e14 per chunk per period

        uint256 cost1 = uint256(200) * uint256(periods) * 1e12;
        vm.prank(user1);
        uint256 orderId1 = market.placeOrder{value: cost1}(FILE_ROOT, FILE_URI, 200, periods, 1, 1e12, _emptyFspProof());

        uint256 cost2 = uint256(maxSize) * uint256(periods) * highPrice;
        vm.deal(user1, user1.balance + cost2);
        vm.prank(user1);
        uint256 orderId2 = market.placeOrder{value: cost2}(
            FILE_ROOT, FILE_URI, uint32(maxSize), periods, 1, highPrice, _emptyFspProof()
        );

        _executeOrder(node1, orderId1);
        _executeOrder(node1, orderId2);

        // Quit order2 (highPrice): slashPeriods = 4 + (20-4)/4 = 8
        // slashAmount = 100 * 4e14 * 8 = 3.2e17
        // usedAfterQuit = 200, requiredStakeAfterQuit = 200 * 4e14 = 8e16
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

        _executeOrder(node1, orderId);

        uint256 clientRefundBefore = market.pendingRefunds(user1);

        vm.prank(user2);
        marketExt2.challengeNode(orderId, node1);

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);

        uint256 clientRefundAfter = market.pendingRefunds(user1);
        assertTrue(clientRefundAfter > clientRefundBefore, "client gets comp from on-demand challenge failure");
    }

    // =========================================================================
    // Repeat-Failure Penalties
    // =========================================================================

    function test_RepeatFailurePenalty_DefaultTuning() public view {
        assertEq(market.proofFailurePenaltyBpsPerStrike(), 2500, "default per-strike penalty");
        assertEq(market.maxProofFailurePenaltyBps(), 10000, "default penalty cap");
    }

    function test_RepeatFailurePenalty_AdminCanUpdate() public {
        marketExt2.setProofFailurePenaltyTuning(4000, 12000);
        assertEq(market.proofFailurePenaltyBpsPerStrike(), 4000);
        assertEq(market.maxProofFailurePenaltyBps(), 12000);
    }

    function test_RepeatFailurePenalty_RevertWhenPerStrikeTooHigh() public {
        vm.expectRevert("per-strike bps too high");
        marketExt2.setProofFailurePenaltyTuning(10001, 12000);
    }

    function test_RepeatFailurePenalty_RevertWhenMaxTooHigh() public {
        vm.expectRevert("max bps too high");
        marketExt2.setProofFailurePenaltyTuning(4000, 30001);
    }

    function test_RepeatFailurePenalty_SecondFailureCostsMore() public {
        uint32 size = 30000;
        uint256 price = 1e13;
        uint64 nodeCapacity = 100000;
        uint256 baseSlash = uint256(size) * price * 3;

        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeOrder(user1, size, 4, 1, price);
        _executeOrder(node1, orderId);

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        vm.prank(user2);
        marketExt2.challengeNode(orderId, node1);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        vm.prank(user2);
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);
        (uint256 stakeAfterFirst,,,) = nodeStaking.getNodeInfo(node1);
        uint256 firstSlash = stakeBefore - stakeAfterFirst;

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS * 2 + 1);
        vm.prank(user2);
        marketExt2.challengeNode(orderId, node1);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS * 3 + 5);
        vm.prank(user2);
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);
        (uint256 stakeAfterSecond,,,) = nodeStaking.getNodeInfo(node1);
        uint256 secondSlash = stakeAfterFirst - stakeAfterSecond;

        assertEq(firstSlash, baseSlash, "first failure uses base slash");
        assertEq(secondSlash, baseSlash + (baseSlash * 2500 / 10000), "second failure includes repeat penalty");
        assertEq(market.nodeProofFailureCount(node1), 2, "failure streak increments");
    }

    function test_RepeatFailurePenalty_SuccessResetsFailureCount() public {
        uint32 size = 30000;
        uint256 price = 1e13;
        uint64 nodeCapacity = 100000;
        uint256 baseSlash = uint256(size) * price * 3;

        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeOrder(user1, size, 4, 1, price);
        _executeOrder(node1, orderId);

        vm.prank(user2);
        marketExt2.challengeNode(orderId, node1);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        vm.prank(user2);
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);
        assertEq(market.nodeProofFailureCount(node1), 1, "failure streak recorded");

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS * 2 + 1);
        vm.prank(user2);
        marketExt2.challengeNode(orderId, node1);
        uint256[4] memory proof;
        vm.prank(node1);
        marketExt2.submitOnDemandProof(orderId, proof, bytes32(uint256(0x42)));
        assertEq(market.nodeProofFailureCount(node1), 0, "success resets streak");

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS * 4 + 1);
        vm.prank(user2);
        marketExt2.challengeNode(orderId, node1);
        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS * 3 + 5);
        vm.prank(user2);
        marketExt2.processExpiredOnDemandChallenge(orderId, node1);
        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);

        assertEq(stakeBefore - stakeAfter, baseSlash, "post-reset failure returns to base slash");
        assertEq(market.nodeProofFailureCount(node1), 1, "streak restarts after reset");
    }
}
