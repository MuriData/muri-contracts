// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketAccounting} from "./MarketAccounting.sol";

/// @notice Event-driven parallel challenge slots for Avalanche C-Chain.
/// N independent challenge slots run in parallel. Each slot challenges one node
/// to prove one order. Expired slots are slashed as a side effect of any submitProof call.
abstract contract MarketChallenge is MarketAccounting {
    /// @notice Submit proof for a specific challenge slot — the ONLY function nodes call.
    /// Phase 1: sweep expired slots (slash lazy nodes), using commitment-derived randomness.
    /// Phase 2: validate caller is the challenged node for this slot.
    /// Phase 3: verify ZK proof.
    /// Phase 4: advance slot to next challenge.
    function submitProof(uint256 _slotIndex, uint256[8] calldata _proof, bytes32 _commitment) external nonReentrant {
        require(_slotIndex < NUM_CHALLENGE_SLOTS, "invalid slot index");

        // Phase 1: sweep expired slots — slashes expired nodes, earns reporter rewards for caller.
        // Uses the commitment as a high-quality randomness seed for re-advancing expired slots,
        // since the commitment is a ZK proof nonce that the prover cannot bias without invalidating the proof.
        uint256 commitmentRandomness = uint256(_commitment) % SNARK_SCALAR_FIELD;
        _sweepExpiredSlots(msg.sender, MAX_SWEEP_PER_CALL, commitmentRandomness);

        // Phase 2: validate this slot is active and caller is the challenged node
        ChallengeSlot storage slot = challengeSlots[_slotIndex];
        require(slot.orderId != 0, "slot is idle");
        require(slot.challengedNode == msg.sender, "not the challenged node");
        require(block.number <= slot.deadlineBlock, "slot deadline passed");

        // Phase 3: verify ZK proof
        FileOrder storage order = orders[slot.orderId];
        uint256 fileRootHash = order.file.root;

        (,,, uint256 publicKey) = nodeStaking.getNodeInfo(msg.sender);
        require(publicKey != 0, "node public key not set");

        uint256[4] memory publicInputs = [uint256(_commitment), slot.randomness, publicKey, fileRootHash];

        poiVerifier.verifyProof(_proof, publicInputs);

        emit SlotProofSubmitted(_slotIndex, msg.sender, _commitment);

        // Phase 4: advance slot using commitment-derived randomness (same seed as Phase 1)
        _advanceSlot(_slotIndex, commitmentRandomness);
    }

    /// @notice Maintenance function: anyone can call to slash expired slots and earn reporter rewards.
    /// Needed when no nodes are submitting proofs (dead network scenario).
    /// Uses chain pseudorandomness (prevrandao) for re-advancing slots since no proof commitment is available.
    function processExpiredSlots() external nonReentrant {
        uint256 processed = _sweepExpiredSlots(msg.sender, MAX_SWEEP_PER_CALL, 0);
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

        // Rotate global seed and emit only when new slots were filled
        if (activated > 0) {
            globalSeedRandomness = uint256(
                keccak256(abi.encodePacked(globalSeedRandomness, block.number, block.prevrandao, msg.sender))
            ) % SNARK_SCALAR_FIELD;

            emit SlotsActivated(activated);
        }
    }

    /// @notice Advance a slot to challenge a new random order/node.
    /// Prefers unchallenged order+node pairs for coverage diversity, but falls back
    /// to already-challenged pairs when no fresh alternatives exist.
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
        uint256 dedupProbes = 0;
        uint256 fallbackOrderId = 0;
        address fallbackNode = address(0);

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

            // Found a valid order — select a node preferring unchallenged ones
            address[] storage nodes = orderToNodes[candidateOrderId];
            if (nodes.length == 0) continue;

            address selectedNode = _selectUnchallengedNode(nodes, _randomness, candidateOrderId, nonce);

            // Ideal: fully fresh pair — commit immediately
            if (orderActiveChallengeCount[candidateOrderId] == 0 && nodeActiveChallengeCount[selectedNode] == 0) {
                _commitSlot(slot, _slotIndex, candidateOrderId, selectedNode, _randomness);
                return true;
            }

            // Save first valid-but-duplicate pair as fallback
            if (fallbackOrderId == 0) {
                fallbackOrderId = candidateOrderId;
                fallbackNode = selectedNode;
            }

            // Once we have a fallback, only spend a bounded budget looking for a fresh pair
            if (fallbackOrderId != 0) {
                dedupProbes++;
                if (dedupProbes >= MAX_DEDUP_PROBES) break;
            }
        }

        // No fresh pair found — use fallback if available
        if (fallbackOrderId != 0) {
            _commitSlot(slot, _slotIndex, fallbackOrderId, fallbackNode, _randomness);
            return true;
        }

        // No valid orders found — deactivate slot
        _deactivateSlot(_slotIndex);
        return false;
    }

    /// @notice Select a node from an order's node list, preferring nodes not already under challenge.
    /// @dev Bounded by MAX_REPLICAS (10) — at most 1 + 10 SLOADs for the linear scan.
    function _selectUnchallengedNode(
        address[] storage _nodes,
        uint256 _randomness,
        uint256 _orderId,
        uint256 _nonce
    ) internal view returns (address) {
        uint256 idx = uint256(keccak256(abi.encodePacked(_randomness, _orderId, _nonce))) % _nodes.length;
        address candidate = _nodes[idx];
        if (nodeActiveChallengeCount[candidate] == 0) return candidate;
        // Linear scan for an unchallenged node (bounded by MAX_REPLICAS = 10)
        for (uint256 i = 0; i < _nodes.length; i++) {
            if (nodeActiveChallengeCount[_nodes[i]] == 0) return _nodes[i];
        }
        return candidate; // all challenged — fall back to random pick
    }

    /// @notice Commit a challenge slot: write state, increment counters, emit event.
    function _commitSlot(
        ChallengeSlot storage _slot,
        uint256 _slotIndex,
        uint256 _orderId,
        address _node,
        uint256 _randomness
    ) internal {
        // Randomness must be non-zero — the ZK circuit multiplies chunk data by
        // randomness, so zero collapses message hash to a constant for all chunks.
        uint256 safeRandomness = _randomness == 0 ? 1 : _randomness;
        _slot.orderId = _orderId;
        _slot.challengedNode = _node;
        _slot.randomness = safeRandomness;
        _slot.deadlineBlock = block.number + CHALLENGE_WINDOW_BLOCKS;

        nodeActiveChallengeCount[_node]++;
        orderActiveChallengeCount[_orderId]++;

        emit SlotChallengeIssued(_slotIndex, _orderId, _node, _slot.deadlineBlock);
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
    /// @param _reporter Address that triggered the sweep (earns reporter rewards).
    /// @param _maxSweep Maximum number of expired slots to process.
    /// @param _proofRandomness When non-zero, commitment-derived randomness from a verified proof
    ///        (used by submitProof). When zero, falls back to chain pseudorandomness (used by processExpiredSlots).
    /// @return processed Number of expired slots processed.
    function _sweepExpiredSlots(address _reporter, uint256 _maxSweep, uint256 _proofRandomness)
        internal
        returns (uint256 processed)
    {
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
                (uint256 nodeStake,,,) = nodeStaking.getNodeInfo(failedNode);
                if (slashAmount > nodeStake) {
                    slashAmount = nodeStake;
                }

                if (slashAmount > 0) {
                    (bool forcedExit, uint256 totalSlashed) = nodeStaking.slashNode(failedNode, slashAmount);
                    _distributeSlashFunds(_reporter, failedNode, totalSlashed);
                    if (forcedExit) {
                        _handleForcedOrderExits(failedNode);
                        forcedExitCount++;
                    }
                    emit NodeSlashed(failedNode, slashAmount, "failed challenge proof");
                }
            }

            emit SlotExpired(i, failedNode, slashAmount);

            // Derive randomness for re-advancing the expired slot.
            // When triggered by submitProof, use the proof commitment (unbiasable by the prover).
            // When triggered by processExpiredSlots (manual maintenance), fall back to chain data.
            uint256 advanceRandomness;
            if (_proofRandomness != 0) {
                advanceRandomness =
                    uint256(keccak256(abi.encodePacked(_proofRandomness, slot.randomness, i))) % SNARK_SCALAR_FIELD;
            } else {
                advanceRandomness = uint256(
                    keccak256(abi.encodePacked(slot.randomness, block.number, block.prevrandao, _reporter, i))
                ) % SNARK_SCALAR_FIELD;
            }

            _advanceSlot(i, advanceRandomness);

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
        if (_isOrderUnderActiveChallenge(_orderId)) return;

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
