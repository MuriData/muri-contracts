// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketAccounting} from "./MarketAccounting.sol";

/// @notice Event-driven parallel challenge slots for Avalanche C-Chain.
/// N independent challenge slots run in parallel. Each slot challenges one node
/// to prove one order. Expired slots are slashed as a side effect of any submitProof call.
abstract contract MarketChallenge is MarketAccounting {
    /// @notice Submit proof for a specific challenge slot — the ONLY function nodes call.
    /// Phase 1: sweep expired slots (slash lazy nodes).
    /// Phase 2: validate caller is the challenged node for this slot.
    /// Phase 3: verify ZK proof.
    /// Phase 4: advance slot to next challenge.
    function submitProof(uint256 _slotIndex, uint256[8] calldata _proof, bytes32 _commitment) external nonReentrant {
        require(_slotIndex < NUM_CHALLENGE_SLOTS, "invalid slot index");

        // Phase 1: sweep expired slots — slashes expired nodes, earns reporter rewards for caller
        _sweepExpiredSlots(msg.sender, MAX_SWEEP_PER_CALL);

        // Phase 2: validate this slot is active and caller is the challenged node
        ChallengeSlot storage slot = challengeSlots[_slotIndex];
        require(slot.orderId != 0, "slot is idle");
        require(slot.challengedNode == msg.sender, "not the challenged node");
        require(block.number <= slot.deadlineBlock, "slot deadline passed");

        // Phase 3: verify ZK proof
        FileOrder storage order = orders[slot.orderId];
        uint256 fileRootHash = order.file.root;

        (,,, uint256 publicKeyX, uint256 publicKeyY) = nodeStaking.getNodeInfo(msg.sender);
        require(publicKeyX != 0 && publicKeyY != 0, "node public key not set");

        uint256[5] memory publicInputs = [uint256(_commitment), slot.randomness, publicKeyX, publicKeyY, fileRootHash];

        poiVerifier.verifyProof(_proof, publicInputs);

        emit SlotProofSubmitted(_slotIndex, msg.sender, _commitment);

        // Phase 4: advance slot using commitment-derived randomness
        uint256 newRandomness = uint256(_commitment) % SNARK_SCALAR_FIELD;
        _advanceSlot(_slotIndex, newRandomness);
    }

    /// @notice Maintenance function: anyone can call to slash expired slots and earn reporter rewards.
    /// Needed when no nodes are submitting proofs (dead network scenario).
    function processExpiredSlots() external nonReentrant {
        uint256 processed = _sweepExpiredSlots(msg.sender, MAX_SWEEP_PER_CALL);
        require(processed > 0, "no expired slots");
        emit ExpiredSlotsProcessed(processed, msg.sender);
    }

    /// @notice Bootstrap or refill idle challenge slots with challengeable orders.
    /// Anyone can call. First call initializes globalSeedRandomness.
    function activateSlots() external nonReentrant {
        // Bootstrap randomness on first call
        if (!challengeSlotsInitialized) {
            globalSeedRandomness = uint256(
                keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender, block.number))
            ) % SNARK_SCALAR_FIELD;
            challengeSlotsInitialized = true;
        }

        // Clean up expired orders before filling slots
        _cleanupExpiredOrders();

        uint256 activated = 0;
        for (uint256 i = 0; i < NUM_CHALLENGE_SLOTS; i++) {
            if (challengeSlots[i].orderId != 0) continue; // slot already active

            // Derive per-slot randomness from global seed
            uint256 slotRandomness = uint256(
                keccak256(abi.encodePacked(globalSeedRandomness, i, block.number, block.prevrandao))
            ) % SNARK_SCALAR_FIELD;

            if (_advanceSlot(i, slotRandomness)) {
                activated++;
            }
        }

        require(activated > 0, "no slots activated");

        // Rotate global seed
        globalSeedRandomness = uint256(
            keccak256(abi.encodePacked(globalSeedRandomness, block.number, block.prevrandao, msg.sender))
        ) % SNARK_SCALAR_FIELD;

        emit SlotsActivated(activated);
    }

    /// @notice Advance a slot to challenge a new random order/node.
    /// @return success True if a valid order+node was found and the slot was activated.
    function _advanceSlot(uint256 _slotIndex, uint256 _randomness) internal returns (bool success) {
        ChallengeSlot storage slot = challengeSlots[_slotIndex];

        // Decrement old counters if slot was active
        if (slot.orderId != 0) {
            nodeActiveChallengeCount[slot.challengedNode]--;
            orderActiveChallengeCount[slot.orderId]--;
        }

        // Random-probe challengeableOrders[] to find a valid order
        uint256 len = challengeableOrders.length;
        if (len == 0) {
            _deactivateSlot(_slotIndex);
            return false;
        }

        uint256 nonce = 0;
        uint256 probes = 0;
        uint256 evictions = 0;

        while (probes < MAX_CHALLENGE_SELECTION_PROBES && len > 0) {
            uint256 idx = uint256(keccak256(abi.encodePacked(_randomness, nonce))) % len;
            uint256 candidateOrderId = challengeableOrders[idx];
            nonce++;
            probes++;

            // Inline eviction of expired orders
            if (isOrderExpired(candidateOrderId)) {
                if (evictions < MAX_CHALLENGE_EVICTIONS) {
                    _removeFromChallengeableOrders(candidateOrderId);
                    evictions++;
                    len = challengeableOrders.length;
                }
                continue;
            }

            // Found a valid order — select a random node from it
            address[] storage nodes = orderToNodes[candidateOrderId];
            if (nodes.length == 0) continue;

            uint256 nodeIdx = uint256(keccak256(abi.encodePacked(_randomness, candidateOrderId, nonce))) % nodes.length;
            address selectedNode = nodes[nodeIdx];

            // Set slot state
            slot.orderId = candidateOrderId;
            slot.challengedNode = selectedNode;
            slot.randomness = _randomness;
            slot.deadlineBlock = block.number + CHALLENGE_WINDOW_BLOCKS;

            // Increment counters
            nodeActiveChallengeCount[selectedNode]++;
            orderActiveChallengeCount[candidateOrderId]++;

            emit SlotChallengeIssued(_slotIndex, candidateOrderId, selectedNode, slot.deadlineBlock);
            return true;
        }

        // No valid orders found — deactivate slot
        _deactivateSlot(_slotIndex);
        return false;
    }

    /// @notice Deactivate a slot (set orderId = 0)
    function _deactivateSlot(uint256 _slotIndex) internal {
        ChallengeSlot storage slot = challengeSlots[_slotIndex];
        slot.orderId = 0;
        slot.challengedNode = address(0);
        slot.randomness = 0;
        slot.deadlineBlock = 0;
        emit SlotDeactivated(_slotIndex);
    }

    /// @notice Sweep expired slots: slash failed nodes, advance or deactivate.
    /// @return processed Number of expired slots processed.
    function _sweepExpiredSlots(address _reporter, uint256 _maxSweep) internal returns (uint256 processed) {
        uint256 forcedExitCount = 0;

        for (uint256 i = 0; i < NUM_CHALLENGE_SLOTS && processed < _maxSweep; i++) {
            ChallengeSlot storage slot = challengeSlots[i];

            // Skip idle or non-expired slots
            if (slot.orderId == 0) continue;
            if (block.number <= slot.deadlineBlock) continue;

            address failedNode = slot.challengedNode;

            // Slash the failed node
            uint256 slashAmount = PROOF_FAILURE_SLASH_BYTES * nodeStaking.STAKE_PER_BYTE();

            if (nodeStaking.isValidNode(failedNode)) {
                (uint256 nodeStake,,,,) = nodeStaking.getNodeInfo(failedNode);
                if (slashAmount > nodeStake) {
                    slashAmount = nodeStake;
                }

                if (slashAmount > 0) {
                    (bool forcedExit, uint256 totalSlashed) = nodeStaking.slashNode(failedNode, slashAmount);
                    _distributeSlashFunds(_reporter, failedNode, totalSlashed);
                    if (forcedExit && forcedExitCount < MAX_FORCED_EXITS_PER_SWEEP) {
                        _handleForcedOrderExits(failedNode);
                        forcedExitCount++;
                    }
                    emit NodeSlashed(failedNode, slashAmount, "failed challenge proof");
                }
            }

            emit SlotExpired(i, failedNode, slashAmount);

            // Advance slot with fallback randomness
            uint256 fallbackRandomness = uint256(
                keccak256(abi.encodePacked(slot.randomness, block.number, block.prevrandao, _reporter, i))
            ) % SNARK_SCALAR_FIELD;

            _advanceSlot(i, fallbackRandomness);

            processed++;

            if (forcedExitCount >= MAX_FORCED_EXITS_PER_SWEEP) break;
        }
    }

    /// @notice Cleanup expired orders automatically using a persistent cursor.
    function _cleanupExpiredOrders() internal {
        uint256 len = activeOrders.length;
        if (len == 0) {
            cleanupCursor = 0;
            return;
        }

        uint256 processed = 0;
        uint256 checked = 0;
        uint256 maxChecks = len < CLEANUP_SCAN_CAP ? len : CLEANUP_SCAN_CAP;

        if (cleanupCursor >= len) cleanupCursor = 0;
        uint256 i = cleanupCursor;

        while (checked < maxChecks && processed < CLEANUP_BATCH_SIZE) {
            if (len == 0) break;

            uint256 activeOrderId = activeOrders[i];
            if (isOrderExpired(activeOrderId)) {
                _completeExpiredOrderInternal(activeOrderId);
                processed++;
                len = activeOrders.length;
                if (len == 0) break;
                if (i >= len) i = 0;
            } else {
                i++;
                if (i >= len) i = 0;
            }
            checked++;
        }

        cleanupCursor = (len == 0) ? 0 : i;
    }

    /// @notice Internal version of completeExpiredOrder for cleanup use
    function _completeExpiredOrderInternal(uint256 _orderId) internal {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) return;

        uint256 settlePeriod = order.startPeriod + order.periods;
        _settleAndReleaseNodes(order, _orderId, settlePeriod);

        _removeFromActiveOrders(_orderId);
        uint256 refundAmount = order.escrow - orderEscrowWithdrawn[_orderId];
        address orderOwner = order.owner;

        aggregateActiveEscrow -= order.escrow;
        aggregateActiveWithdrawn -= orderEscrowWithdrawn[_orderId];

        delete orders[_orderId];
        delete orderToNodes[_orderId];

        if (refundAmount > 0) {
            pendingRefunds[orderOwner] += refundAmount;
            emit RefundQueued(orderOwner, refundAmount);
        }

        emit OrderCompleted(_orderId);
    }
}
