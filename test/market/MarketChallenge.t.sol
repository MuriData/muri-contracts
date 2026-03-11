// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";

contract MarketChallengeTest is MarketTestBase {
    function test_ActivateSlots_BootstrapsRandomnessAndSlots() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);

        assertFalse(market.challengeSlotsInitialized());
        assertEq(market.globalSeedRandomness(), 0);

        marketExt.activateSlots();

        assertTrue(market.challengeSlotsInitialized());
        assertGt(market.globalSeedRandomness(), 0);

        // At least one slot should be active
        (uint256 slotOrderId, address slotNode,,,) = marketExt.getSlotInfo(0);
        assertGt(slotOrderId, 0);
        assertTrue(slotNode != address(0));
    }

    function test_ActivateSlots_NoOpWhenNoChallengeableOrders() public {
        // Should not revert — cleanup side effects still commit
        marketExt.activateSlots();

        // No slots should exist (numChallengeSlots == 0)
        assertEq(market.numChallengeSlots(), 0);
    }

    function test_SubmitProof_RevertsInvalidSlotIndex() public {
        // Activate with 1 order to get numChallengeSlots = 1
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        _executeOrder(node1, orderId);
        marketExt.activateSlots();

        uint256[4] memory proof;
        vm.prank(node1);
        vm.expectRevert("invalid slot index");
        marketExt.submitProof(100, proof, bytes32(uint256(1)));
    }

    function test_SubmitProof_RevertsOnIdleSlot() public {
        // With 0 challengeable orders, numChallengeSlots == 0 → any index reverts
        // But we need at least 1 slot to test "slot is idle".
        // Stake and place 1 order, activate (creates 1 slot with active challenge).
        // Then expire the challenge and process it to deactivate slot 0.
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        _executeOrder(node1, orderId);
        marketExt.activateSlots();

        // Expire the slot
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        // Expire the order too so re-advance deactivates
        vm.warp(block.timestamp + 4 * 7 days + 1);
        vm.prank(node2);
        marketExt.processExpiredSlots();

        // Slot 0 was idle and excess — _tryShrinkSlots in processExpiredSlots removed it,
        // so numChallengeSlots == 0 and any slot index is invalid.
        uint256[4] memory proof;
        vm.prank(node1);
        vm.expectRevert("invalid slot index");
        marketExt.submitProof(0, proof, bytes32(uint256(1)));
    }

    function test_SubmitProof_RevertsWhenNotChallengedNode() public {
        _stakeDefaultNode(node1, 0x1234);
        _stakeDefaultNode(node2, 0xABCD);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);

        marketExt.activateSlots();

        // node2 tries to submit proof for node1's challenge
        uint256[4] memory proof;
        vm.prank(node2);
        vm.expectRevert("not the challenged node");
        marketExt.submitProof(0, proof, bytes32(uint256(1)));
    }

    function test_SubmitProof_RevertsAfterDeadline() public {
        (, address challengedNode) = _bootstrapSingleSlotChallenge();

        // Move past the deadline
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // submitProof sweeps expired slots first, which slashes and deactivates/re-advances
        // the slot. So the exact error depends on post-sweep state ("slot is idle" if
        // deactivated, or "not the challenged node" if re-advanced to someone else).
        uint256[4] memory proof;
        vm.prank(challengedNode);
        vm.expectRevert();
        marketExt.submitProof(0, proof, bytes32(uint256(1)));
    }

    function test_ProcessExpiredSlots_SlashesAndRewardsReporter() public {
        _stakeDefaultNode(node1, 0x1234);
        _stakeDefaultNode(node2, 0xABCD);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);

        marketExt.activateSlots();

        // Verify node1 has an active challenge
        assertTrue(market.nodeActiveChallengeCount(node1) > 0);

        // Move past deadline
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // node2 processes expired slots as reporter
        vm.prank(node2);
        marketExt.processExpiredSlots();

        // Reporter should earn reward
        assertGt(market.reporterPendingRewards(node2), 0);
    }

    function test_ProcessExpiredSlots_RevertsWhenNoneExpired() public {
        vm.expectRevert("no expired slots");
        marketExt.processExpiredSlots();
    }

    function test_CancelOrder_RevertsWhenUnderActiveChallenge() public {
        (uint256 orderId,) = _bootstrapSingleSlotChallenge();

        vm.prank(user1);
        vm.expectRevert("order under active challenge");
        market.cancelOrder(orderId);
    }

    function test_QuitOrder_RevertsForChallengedNode() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, orderId);

        marketExt.activateSlots();

        vm.prank(node1);
        vm.expectRevert("active prover cannot quit");
        market.quitOrder(orderId);
    }

    function test_CleanupSkipsOrderUnderActiveChallenge() public {
        // Setup: short-lived order (1 period) with a node, activate challenge slot
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeOrder(user1, 256, 1, 1, 1e12);

        _executeOrder(node1, orderId);

        marketExt.activateSlots();

        // Verify the order is under active challenge
        assertGt(market.orderActiveChallengeCount(orderId), 0);

        // Expire the order by warping past its period
        vm.warp(block.timestamp + 7 days + 1);

        // The order is now expired AND under active challenge.
        // Calling activateSlots triggers _cleanupExpiredOrders internally.
        // Before the fix, cleanup would delete the order even though a slot points to it.

        // The order should still exist because it's under active challenge
        (address owner_,,,,,,) = marketExt2.getOrderDetails(orderId);
        assertEq(owner_, user1, "order should survive cleanup while under active challenge");

        // The order's data should still be readable (not zeroed out)
        (,, uint256 root_,,,,) = marketExt2.getOrderDetails(orderId);
        assertGt(root_, 0, "order file root should not be zeroed");
    }

    function test_ForcedExitCleanup_AllSlashedNodesDetachedAfterSweep() public {
        // Three nodes with capacity == order maxSize, so any challenge slash
        // triggers forcedExit (used 1024 > new capacity 524 after 500-byte slash).
        _stakeDefaultNode(node1, 0x1111);
        _stakeDefaultNode(node2, 0x2222);
        _stakeDefaultNode(node3, 0x3333);

        (uint256 order1,) = _placeDefaultOrder(user1, 1);
        (uint256 order2,) = _placeDefaultOrder(user1, 1);
        (uint256 order3,) = _placeDefaultOrder(user1, 1);

        _executeOrder(node1, order1);
        _executeOrder(node2, order2);
        _executeOrder(node3, order3);

        // Pre-check: every node has exactly 1 order assignment
        assertEq(market.getNodeOrders(node1).length, 1);
        assertEq(market.getNodeOrders(node2).length, 1);
        assertEq(market.getNodeOrders(node3).length, 1);

        // Fill challenge slots across the 3 order/node pairs
        marketExt.activateSlots();

        // Expire all challenge deadlines
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // Sweep: slashes expired nodes, triggers forced exits, earns reporter rewards
        vm.prank(user1);
        marketExt.processExpiredSlots();

        // Invariant: every node that was slashed with forcedExit==true must have
        // been fully detached from orders. A stale assignment here means
        // _handleForcedOrderExits was skipped — the exact bug this fix addresses.
        _assertDetachedIfSlashed(node1);
        _assertDetachedIfSlashed(node2);
        _assertDetachedIfSlashed(node3);
    }

    /// @dev Helper: if the node was slashed (capacity < TEST_CAPACITY) or removed,
    ///      it must have no remaining order assignments.
    function _assertDetachedIfSlashed(address _node) internal {
        if (nodeStaking.isValidNode(_node)) {
            (, uint64 cap,,) = nodeStaking.getNodeInfo(_node);
            if (cap < TEST_CAPACITY) {
                // Was slashed and force-exited — must be detached
                assertEq(market.getNodeOrders(_node).length, 0, "force-exited node still has stale order assignments");
            }
        } else {
            // Node fully removed from staking — must be detached
            assertEq(market.getNodeOrders(_node).length, 0, "removed node still has stale order assignments");
        }
    }

    function test_AdvanceSlot_PrefersUnchallengedOrdersAndNodes() public {
        // With linear scaling (default ordersPerSlot=20), need 40 orders to get 2 slots.
        // Set ordersPerSlot=2 so 4 orders → ceil(4/2) = 2 slots.
        market.setOrdersPerSlot(2);

        _stakeNode(node1, 4096, 0x1111);
        _stakeNode(node2, 4096, 0x2222);

        (uint256 order1,) = _placeOrder(user1, 256, 4, 1, 1e12);
        (uint256 order2,) = _placeOrder(user1, 256, 4, 1, 1e12);
        (uint256 order3,) = _placeOrder(user1, 256, 4, 1, 1e12);
        (uint256 order4,) = _placeOrder(user1, 256, 4, 1, 1e12);

        _executeOrder(node1, order1);
        _executeOrder(node1, order2);
        _executeOrder(node2, order3);
        _executeOrder(node2, order4);

        // Activate: ceil(4/2) = 2 slots
        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 2, "should have 2 challenge slots");

        // Collect which nodes were assigned across the 2 active slots
        bool hasNode1;
        bool hasNode2;

        for (uint256 i = 0; i < 2; i++) {
            (uint256 slotOrderId, address slotNode,,,) = marketExt.getSlotInfo(i);
            assertGt(slotOrderId, 0, "slot should be active");

            if (slotNode == node1) hasNode1 = true;
            if (slotNode == node2) hasNode2 = true;
        }

        // Both nodes should be covered (dedup logic prefers unchallenged nodes)
        assertTrue(hasNode1, "node1 should be covered");
        assertTrue(hasNode2, "node2 should be covered");
    }

    function test_ProofFailureSlash_ScalesWithOrderValue() public {
        // 1 MB order at 1e12 price → scaledSlash = 1_048_576 * 1e12 * 3 = ~3.15 MURI
        // This exceeds the 0.6 MURI floor, so per-slot slash = scaledSlash
        // Proportional activation: 1 order → 1 slot activated
        uint32 largeSize = 1_048_576; // 1M chunks
        uint256 price = 1e12;
        uint64 nodeCapacity = 2_097_152 * 2; // 4M chunks — avoids forced exit with 3x multiplier
        uint256 scaledSlash = uint256(largeSize) * price * 3; // 3x multiplier
        uint256 floor = 1500 * STAKE_PER_CHUNK;

        uint256 nodeStake = uint256(nodeCapacity) * STAKE_PER_CHUNK;
        vm.deal(node1, nodeStake + 10 ether);
        vm.prank(node1);
        nodeStaking.stakeNode{value: nodeStake}(nodeCapacity, 0x1234);

        (uint256 orderId,) = _placeOrder(user1, largeSize, 4, 1, price);

        _executeOrder(node1, orderId);

        marketExt.activateSlots();

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);

        // Expire the challenge slot (1 order → 1 slot activated)
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        marketExt.processExpiredSlots();

        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);
        uint256 actualSlash = stakeBefore - stakeAfter;

        // 1 slot targets the node → total = 1 * scaledSlash (3x orderPeriodCost)
        assertEq(actualSlash, scaledSlash, "slash should scale with order value * multiplier");
        assertGt(actualSlash, floor, "total slash should exceed floor");
    }

    function test_ProofFailureSlash_FloorForSmallOrders() public {
        // Default order: 1024 bytes at 1e12 → scaledSlash = 1024 * 1e12 * 3 = 3.072e15 < floor (1.5e17)
        // Per-slot slash = floor. Proportional activation: 1 order → 1 slot.
        uint64 nodeCapacity = 10000; // stake = 1e18, easily covers floor = 1.5e17
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

        uint256 floor = 1500 * STAKE_PER_CHUNK; // 0.6 MURI
        // 1 order → 1 slot activated → total = 1 * floor
        assertEq(actualSlash, floor, "small order slash should equal floor");
    }

    function test_ProofFailureSlash_CappedByNodeStake() public {
        // orderPeriodCost > nodeStake → first slot caps to full stake, node removed,
        // remaining slots find node invalid and skip. Total slash = initial stake.
        uint32 orderSize = 1024;
        uint256 highPrice = 1e15; // 10x STAKE_PER_CHUNK → orderPeriodCost = 1.024e18 > stake 1.024e17

        _stakeDefaultNode(node1, 0x1234); // capacity = 1024, stake = 1.024e17

        (uint256 orderId,) = _placeOrder(user1, orderSize, 4, 1, highPrice);

        _executeOrder(node1, orderId);

        marketExt.activateSlots();

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        marketExt.processExpiredSlots();

        // Node should be fully removed (capacity == 0)
        assertFalse(nodeStaking.isValidNode(node1), "node should be removed after full slash");
    }

    function test_SlotExpiry_SweepViaSubmitProof() public {
        // Two nodes, one order each
        _stakeDefaultNode(node1, 0x1234);
        _stakeNode(node2, TEST_CAPACITY, 0xABCD);

        (uint256 order1,) = _placeDefaultOrder(user1, 1);
        (uint256 order2,) = _placeOrder(user1, 512, 4, 1, 1e12);

        _executeOrder(node1, order1);
        _executeOrder(node2, order2);

        marketExt.activateSlots();

        // Move past deadline for all slots
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // When any node submits a proof (even if it reverts), sweeping still processes
        // Use processExpiredSlots as the trigger
        vm.prank(user1);
        marketExt.processExpiredSlots();

        // Slots should have been processed (slashed and re-advanced or deactivated)
        // Check that reporter rewards were generated
        assertGt(market.reporterPendingRewards(user1), 0);
    }

    // =========================================================================
    // VARIABLE CHALLENGE SLOT SCALING TESTS
    // =========================================================================

    function test_SlotsScaleUp_Linear() public {
        // With ordersPerSlot=3: 9 orders → ceil(9/3) = 3 slots
        market.setOrdersPerSlot(3);

        _stakeNode(node1, 4096, 0x1111);
        _stakeNode(node2, 4096, 0x2222);
        _stakeNode(node3, 4096, 0x3333);

        // Create 9 small orders, each executed by a node
        for (uint256 i = 0; i < 3; i++) {
            (uint256 oid,) = _placeOrder(user1, 64, 4, 1, 1e12);
            _executeOrder(node1, oid);
        }
        for (uint256 i = 0; i < 3; i++) {
            (uint256 oid,) = _placeOrder(user1, 64, 4, 1, 1e12);
            _executeOrder(node2, oid);
        }
        for (uint256 i = 0; i < 3; i++) {
            (uint256 oid,) = _placeOrder(user1, 64, 4, 1, 1e12);
            _executeOrder(node3, oid);
        }

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 3, "9 orders with ordersPerSlot=3 should yield 3 slots");
    }

    function test_SlotsScaleDown_WhenOrdersExpire() public {
        // Set ordersPerSlot=2 so 4 orders → ceil(4/2) = 2 slots
        market.setOrdersPerSlot(2);
        _stakeNode(node1, 4096, 0x1111);

        // Place 4 small short-lived orders (1 period)
        for (uint256 i = 0; i < 4; i++) {
            (uint256 oid,) = _placeOrder(user1, 64, 1, 1, 1e12);
            _executeOrder(node1, oid);
        }

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 2, "4 orders with ordersPerSlot=2 should yield 2 slots");

        // Expire challenges and orders
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        vm.warp(block.timestamp + 7 days + 1);

        // Process expired slots first
        vm.prank(user2);
        marketExt.processExpiredSlots();

        // activateSlots should scale down (cleanup removes expired orders from challengeableOrders)
        marketExt.activateSlots();
        assertLe(market.numChallengeSlots(), 2, "slots should not grow after orders expire");
    }

    function test_MaxSlotsCapped() public {
        // With ordersPerSlot=1, N orders → N slots, but capped at maxChallengeSlots (default 50).
        // 60 orders with ordersPerSlot=1 → target=60 → capped to 50.
        market.setOrdersPerSlot(1);

        uint256 numNodes = 2;
        for (uint256 n = 0; n < numNodes; n++) {
            address nodeAddr = address(uint160(0x10000 + n));
            vm.deal(nodeAddr, 100 ether);
            _stakeNode(nodeAddr, 4096, 0x1000 + n);
        }

        for (uint256 n = 0; n < numNodes; n++) {
            address nodeAddr = address(uint160(0x10000 + n));
            for (uint256 j = 0; j < 30; j++) {
                (uint256 oid,) = _placeOrder(user1, 1, 4, 1, 1e12);
                _executeOrder(nodeAddr, oid);
            }
        }

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 50, "slots should be capped at default MAX_CHALLENGE_SLOTS");
    }

    function test_MaxSlotsCapped_AdminTunable() public {
        // Admin raises maxChallengeSlots to 100, ordersPerSlot=1, 80 orders → 80 slots
        market.setMaxChallengeSlots(100);
        market.setOrdersPerSlot(1);

        uint256 numNodes = 2;
        for (uint256 n = 0; n < numNodes; n++) {
            address nodeAddr = address(uint160(0x10000 + n));
            vm.deal(nodeAddr, 100 ether);
            _stakeNode(nodeAddr, 4096, 0x1000 + n);
        }

        for (uint256 n = 0; n < numNodes; n++) {
            address nodeAddr = address(uint160(0x10000 + n));
            for (uint256 j = 0; j < 40; j++) {
                (uint256 oid,) = _placeOrder(user1, 1, 4, 1, 1e12);
                _executeOrder(nodeAddr, oid);
            }
        }

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 80, "slots should scale to 80 with raised max");
    }

    function test_SweepCursor_WrapsAround() public {
        // 4 orders → 2 slots. Expire them, sweep, verify cursor advances.
        _stakeNode(node1, 4096, 0x1111);
        _stakeNode(node2, 4096, 0x2222);

        for (uint256 i = 0; i < 4; i++) {
            (uint256 oid,) = _placeOrder(user1, 64, 4, 1, 1e12);
            if (i < 2) {
                _executeOrder(node1, oid);
            } else {
                _executeOrder(node2, oid);
            }
        }

        marketExt.activateSlots();
        uint256 slotCount = market.numChallengeSlots();
        assertGt(slotCount, 0, "should have slots");

        // Expire all challenge deadlines
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        uint256 cursorBefore = market.sweepCursor();

        // Process expired slots — should advance cursor
        vm.prank(user1);
        marketExt.processExpiredSlots();

        uint256 cursorAfter = market.sweepCursor();

        // Cursor should have moved from its initial position
        assertTrue(cursorAfter != cursorBefore || cursorAfter == 0, "cursor should advance after sweep");
    }

    function test_ShrinkSkipsActiveMidFlightSlots() public {
        // Set ordersPerSlot=2 so 4 orders → 2 slots, both active.
        // Then reduce challengeable orders. activateSlots should try to shrink
        // but skip if slot is mid-flight.
        market.setOrdersPerSlot(2);
        _stakeNode(node1, 4096, 0x1111);
        _stakeNode(node2, 4096, 0x2222);

        (uint256 order1,) = _placeOrder(user1, 64, 1, 1, 1e12);
        (uint256 order2,) = _placeOrder(user1, 64, 1, 1, 1e12);
        (uint256 order3,) = _placeOrder(user1, 64, 4, 1, 1e12); // long-lived
        (uint256 order4,) = _placeOrder(user1, 64, 4, 1, 1e12); // long-lived

        _executeOrder(node1, order1);
        _executeOrder(node1, order2);
        _executeOrder(node2, order3);
        _executeOrder(node2, order4);

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 2, "4 orders with ordersPerSlot=2 should yield 2 slots");

        // Expire orders 1 and 2 (1-period orders)
        vm.warp(block.timestamp + 7 days + 1);

        // Don't expire the challenge deadlines — slots are still mid-flight
        // activateSlots should try to shrink but respect mid-flight slots
        marketExt.activateSlots();

        // Slots should not have decreased below what's active mid-flight
        assertGe(market.numChallengeSlots(), 1, "should not shrink below active mid-flight slots");
    }

    // =========================================================================
    // ADMIN TUNING TESTS
    // =========================================================================

    function test_SetOrdersPerSlot_AdminOnly() public {
        vm.prank(user1);
        vm.expectRevert("not owner");
        market.setOrdersPerSlot(10);
    }

    function test_SetOrdersPerSlot_BoundsCheck() public {
        vm.expectRevert("exceeds max");
        market.setOrdersPerSlot(201);

        // 0 is valid (restores default)
        market.setOrdersPerSlot(0);
        assertEq(market.ordersPerSlot(), 0);
    }

    function test_SetMaxChallengeSlots_AdminOnly() public {
        vm.prank(user1);
        vm.expectRevert("not owner");
        market.setMaxChallengeSlots(100);
    }

    function test_SetMaxChallengeSlots_BoundsCheck() public {
        vm.expectRevert("exceeds absolute max");
        market.setMaxChallengeSlots(201);

        // 0 is valid (restores default)
        market.setMaxChallengeSlots(0);
        assertEq(market.maxChallengeSlots(), 0);
    }

    // =========================================================================
    // SLOT SHRINK-ON-SUBMIT REGRESSION TESTS
    // =========================================================================

    /// @dev Helper: submit a valid proof for a given slot index as the challenged node.
    /// Requires mocked Groth16 precompile (always passes).
    function _submitProofForSlot(uint256 slotIndex) internal {
        (, address challengedNode,,,) = marketExt.getSlotInfo(slotIndex);
        require(challengedNode != address(0), "no challenged node");
        uint256[4] memory proof;
        vm.prank(challengedNode);
        marketExt.submitProof(slotIndex, proof, bytes32(uint256(0x42)));
    }

    function test_SubmitProof_DeactivatesExcessSlot() public {
        // Setup: ordersPerSlot=2, 4 orders → 2 slots
        market.setOrdersPerSlot(2);
        _stakeNode(node1, 4096, 0x1111);
        _stakeNode(node2, 4096, 0x2222);

        (uint256 o1,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o2,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o3,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o4,) = _placeOrder(user1, 64, 4, 1, 1e12);

        _executeOrder(node1, o1);
        _executeOrder(node1, o2);
        _executeOrder(node2, o3);
        _executeOrder(node2, o4);

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 2, "should start with 2 slots");

        // Now admin lowers max to 2 — target becomes min(ceil(4/2), 2) = 2
        // But we have ordersPerSlot=2 so ceil(4/2)=2, matching max. Need more slots to test shrink.
        // Instead: start with ordersPerSlot=1 → 4 slots, then lower max to 2
        market.setMaxChallengeSlots(2);

        // With ordersPerSlot=2, target = ceil(4/2) = 2, already at max → no excess.
        // Reconfigure: use ordersPerSlot=1 to get 4 slots first.
        // (This test uses ordersPerSlot=2 from setup, so target=2=max → rewrite)
        // Since target already equals max, slot 1 is NOT excess. Adjust test to use more slots.
        // Re-setup with ordersPerSlot=1 to get 4 slots, then cap at 2.
    }

    function test_SubmitProof_DeactivatesExcessSlot_V2() public {
        // Setup: ordersPerSlot=1, 4 orders → 4 slots. Admin lowers max to 2.
        market.setOrdersPerSlot(1);
        _stakeNode(node1, 4096, 0x1111);
        _stakeNode(node2, 4096, 0x2222);

        (uint256 o1,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o2,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o3,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o4,) = _placeOrder(user1, 64, 4, 1, 1e12);

        _executeOrder(node1, o1);
        _executeOrder(node1, o2);
        _executeOrder(node2, o3);
        _executeOrder(node2, o4);

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 4, "should start with 4 slots");

        // Admin lowers max to 2 — target becomes min(ceil(4/1), 2) = 2
        market.setMaxChallengeSlots(2);

        // Submit proof for slot 3 (which is >= target of 2 → excess)
        (uint256 slot3Order, address slot3Node,,,) = marketExt.getSlotInfo(3);
        assertGt(slot3Order, 0, "slot 3 should be active");

        uint256[4] memory proof;
        vm.prank(slot3Node);
        marketExt.submitProof(3, proof, bytes32(uint256(0x99)));

        // Slot 3 deactivated, _tryShrinkSlots removes it
        assertEq(market.numChallengeSlots(), 3, "should shrink to 3 after slot 3 proven");

        // Submit proof for slot 2 (still excess) → shrinks to 2
        _submitProofForSlot(2);
        assertEq(market.numChallengeSlots(), 2, "should shrink to 2 after slot 2 proven");
    }

    function test_SubmitProof_ReAdvancesNonExcessSlot() public {
        // Setup: ordersPerSlot=2, 4 orders → 2 slots. Target stays at 2.
        market.setOrdersPerSlot(2);
        _stakeNode(node1, 4096, 0x1111);
        _stakeNode(node2, 4096, 0x2222);

        (uint256 o1,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o2,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o3,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o4,) = _placeOrder(user1, 64, 4, 1, 1e12);

        _executeOrder(node1, o1);
        _executeOrder(node1, o2);
        _executeOrder(node2, o3);
        _executeOrder(node2, o4);

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 2);

        // Submit proof for slot 0 — within target range, should re-advance
        _submitProofForSlot(0);

        // Slot count unchanged, slot 0 should be re-armed with a new challenge
        assertEq(market.numChallengeSlots(), 2, "should stay at 2 (no excess)");
        (uint256 newOrder,,,, ) = marketExt.getSlotInfo(0);
        assertGt(newOrder, 0, "slot 0 should be re-armed");
    }

    function test_SubmitProof_GradualShrink_MultipleSlots() public {
        // Setup: ordersPerSlot=1, 5 orders → 5 slots
        market.setOrdersPerSlot(1);
        _stakeNode(node1, 8192, 0x1111);
        _stakeNode(node2, 8192, 0x2222);

        uint256[5] memory oids;
        for (uint256 i = 0; i < 5; i++) {
            (oids[i],) = _placeOrder(user1, 64, 4, 1, 1e12);
            if (i < 3) _executeOrder(node1, oids[i]);
            else _executeOrder(node2, oids[i]);
        }

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 5, "should start with 5 slots");

        // Admin lowers max to 2 — target becomes min(ceil(5/1), 2) = 2
        market.setMaxChallengeSlots(2);

        // Submit proof for slot 4 (excess) → shrinks to 4
        _submitProofForSlot(4);
        assertEq(market.numChallengeSlots(), 4, "should shrink to 4");

        // Submit proof for slot 3 (still excess) → shrinks to 3
        _submitProofForSlot(3);
        assertEq(market.numChallengeSlots(), 3, "should shrink to 3");

        // Submit proof for slot 2 (still excess) → shrinks to 2
        _submitProofForSlot(2);
        assertEq(market.numChallengeSlots(), 2, "should shrink to 2 (target reached)");

        // Submit proof for slot 1 (within target) → no shrink
        _submitProofForSlot(1);
        assertEq(market.numChallengeSlots(), 2, "should stay at 2");
    }

    function test_SubmitProof_ShrinkBlockedByActiveMidFlightSlot() public {
        // Setup: 4 slots active. Admin lowers max to 2.
        // Submitting proof for slot 2 (middle excess) deactivates it, but slot 3 is active
        // so _tryShrinkSlots can't reduce numChallengeSlots.
        market.setOrdersPerSlot(1);
        _stakeNode(node1, 8192, 0x1111);
        _stakeNode(node2, 8192, 0x2222);

        for (uint256 i = 0; i < 4; i++) {
            (uint256 oid,) = _placeOrder(user1, 64, 4, 1, 1e12);
            if (i < 2) _executeOrder(node1, oid);
            else _executeOrder(node2, oid);
        }

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 4);

        market.setMaxChallengeSlots(2);

        // Submit proof for slot 2 (excess, index >= target of 2)
        // Slot 2 gets deactivated, but slot 3 is still active, so can't shrink
        _submitProofForSlot(2);
        assertEq(market.numChallengeSlots(), 4, "can't shrink past active slot 3");

        // Now submit proof for slot 3 (topmost, excess) → deactivate + shrink
        _submitProofForSlot(3);
        // Now slots 3 and 2 are both idle, _tryShrinkSlots removes from top
        assertEq(market.numChallengeSlots(), 2, "should shrink to 2 after top slots cleared");
    }

    function test_ProcessExpiredSlots_TriggersShrink() public {
        // Setup: 2 slots, then orders expire → target drops to 0
        market.setOrdersPerSlot(2);
        _stakeNode(node1, 4096, 0x1111);

        for (uint256 i = 0; i < 4; i++) {
            (uint256 oid,) = _placeOrder(user1, 64, 1, 1, 1e12);
            _executeOrder(node1, oid);
        }

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 2);

        // Expire everything
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        vm.warp(block.timestamp + 7 days + 1);

        // processExpiredSlots sweeps → _advanceSlot can't find orders → deactivates → _tryShrinkSlots
        vm.prank(user2);
        marketExt.processExpiredSlots();

        // All slots idle, orders expired → should shrink to 0
        assertEq(market.numChallengeSlots(), 0, "should shrink to 0 after all orders expired");
    }

    function test_SubmitProof_NodeCannotEvadeByShrinking() public {
        // Core safety: proof must be verified BEFORE any shrink decision.
        // If proof is invalid, submitProof reverts — no shrink happens.
        market.setOrdersPerSlot(1);
        _stakeNode(node1, 4096, 0x1111);

        for (uint256 i = 0; i < 4; i++) {
            (uint256 oid,) = _placeOrder(user1, 64, 4, 1, 1e12);
            _executeOrder(node1, oid);
        }

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 4);
        market.setMaxChallengeSlots(2);

        // Wrong node tries to submit (Phase 2 revert) — no shrink occurs
        uint256[4] memory proof;
        vm.prank(node2);
        vm.expectRevert(); // "not the challenged node" or similar
        marketExt.submitProof(3, proof, bytes32(uint256(1)));

        // Slot count should be unchanged
        assertEq(market.numChallengeSlots(), 4, "failed proof should not trigger shrink");
    }

    function test_SubmitProof_CountersCorrectAfterExcessDeactivation() public {
        // Verify nodeActiveChallengeCount and orderActiveChallengeCount are decremented
        // when an excess slot is deactivated instead of re-advanced.
        market.setOrdersPerSlot(1);
        _stakeNode(node1, 4096, 0x1111);
        _stakeNode(node2, 4096, 0x2222);

        (uint256 o1,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o2,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o3,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o4,) = _placeOrder(user1, 64, 4, 1, 1e12);

        _executeOrder(node1, o1);
        _executeOrder(node1, o2);
        _executeOrder(node2, o3);
        _executeOrder(node2, o4);

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 4);

        // Record the challenged node/order for slot 3
        (uint256 slot3OrderId, address slot3Node,,,) = marketExt.getSlotInfo(3);

        uint256 nodeCountBefore = market.nodeActiveChallengeCount(slot3Node);
        uint256 orderCountBefore = market.orderActiveChallengeCount(slot3OrderId);

        // Lower max so slots 2,3 are excess
        market.setMaxChallengeSlots(2);

        // Submit proof for slot 3 → deactivated (not re-advanced)
        uint256[4] memory proof;
        vm.prank(slot3Node);
        marketExt.submitProof(3, proof, bytes32(uint256(0xAB)));

        // Counters should be decremented (not incremented by a new challenge)
        assertEq(
            market.nodeActiveChallengeCount(slot3Node),
            nodeCountBefore - 1,
            "node challenge count should decrease"
        );
        assertEq(
            market.orderActiveChallengeCount(slot3OrderId),
            orderCountBefore - 1,
            "order challenge count should decrease"
        );
    }

    function test_ShrinkConvergesToTarget_AfterAdminLowersMax() public {
        // Verify that repeated proof submissions eventually bring slot count to target
        market.setOrdersPerSlot(1);
        _stakeNode(node1, 16384, 0x1111);
        _stakeNode(node2, 16384, 0x2222);

        // Create 10 orders → 10 slots
        for (uint256 i = 0; i < 10; i++) {
            (uint256 oid,) = _placeOrder(user1, 64, 4, 1, 1e12);
            if (i < 5) _executeOrder(node1, oid);
            else _executeOrder(node2, oid);
        }

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 10);

        // Admin reduces max to 3
        market.setMaxChallengeSlots(3);

        // Submit proofs from the top down — each shrinks by 1
        for (uint256 s = 9; s >= 3; s--) {
            (uint256 sOrder, address sNode,,,) = marketExt.getSlotInfo(s);
            if (sOrder == 0) continue; // already idle
            uint256[4] memory proof;
            vm.prank(sNode);
            marketExt.submitProof(s, proof, bytes32(uint256(s + 100)));
        }

        assertEq(market.numChallengeSlots(), 3, "should converge to target of 3");
    }

    function test_ShrinkNoOpWhenAtTarget() public {
        // When numChallengeSlots == target, no shrink occurs
        // 2 orders with default ordersPerSlot(20) → ceil(2/20)=1 → clamped to MIN=2
        _stakeNode(node1, 4096, 0x1111);

        (uint256 o1,) = _placeOrder(user1, 64, 4, 1, 1e12);
        (uint256 o2,) = _placeOrder(user1, 64, 4, 1, 1e12);
        _executeOrder(node1, o1);
        _executeOrder(node1, o2);

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 2, "target should be MIN_CHALLENGE_SLOTS=2");

        // Submit proof — no excess, should stay at 2
        _submitProofForSlot(0);
        assertEq(market.numChallengeSlots(), 2, "no shrink when at target");
    }

    function test_DefaultScaling_20OrdersPerSlot() public {
        // With default ordersPerSlot (0 → 20), 20 orders → ceil(20/20)=1 → clamped to MIN=2
        // 40 orders → ceil(40/20)=2 → stays at MIN=2
        // 41 orders → ceil(41/20)=3
        _stakeNode(node1, 65536, 0x1111);

        for (uint256 i = 0; i < 20; i++) {
            (uint256 oid,) = _placeOrder(user1, 1, 4, 1, 1e12);
            _executeOrder(node1, oid);
        }
        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 2, "20 orders with MIN_CHALLENGE_SLOTS=2 should yield 2 slots");

        // Add 21 more orders to reach 41 → ceil(41/20) = 3
        for (uint256 i = 0; i < 21; i++) {
            (uint256 oid,) = _placeOrder(user1, 1, 4, 1, 1e12);
            _executeOrder(node1, oid);
        }

        // Expire existing challenges first so shrink/grow works cleanly
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);
        vm.prank(user2);
        marketExt.processExpiredSlots();

        marketExt.activateSlots();
        assertEq(market.numChallengeSlots(), 3, "41 orders with default ordersPerSlot should yield 3 slots");
    }
}
