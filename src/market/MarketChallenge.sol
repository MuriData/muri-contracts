// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketHelpers} from "./MarketHelpers.sol";
import {PrecompileVerifiers} from "../verifiers/PrecompileVerifiers.sol";

/// @notice Event-driven parallel challenge slots for Avalanche C-Chain.
/// N independent challenge slots run in parallel. Each slot challenges one node
/// to prove one order. Expired slots are slashed as a side effect of any submitProof call.
abstract contract MarketChallenge is MarketHelpers {
    /// @notice Submit proof for a specific challenge slot — the ONLY function nodes call.
    /// Phase 1: sweep expired slots (slash lazy nodes), using commitment-derived randomness.
    /// Phase 2: validate caller is the challenged node for this slot.
    /// Phase 3: verify ZK proof.
    /// Phase 4: advance slot to next challenge.
    function submitProof(uint256 _slotIndex, uint256[4] calldata _proof, bytes32 _commitment) external nonReentrant {
        require(_slotIndex < numChallengeSlots, "invalid slot index");

        // Phase 1: sweep expired slots — slashes expired nodes, earns reporter rewards for caller.
        // Uses the commitment as a high-quality randomness seed for re-advancing expired slots,
        // since the commitment is a ZK proof nonce that the prover cannot bias without invalidating the proof.
        uint256 commitmentRandomness = uint256(_commitment) % SNARK_SCALAR_FIELD;
        _sweepExpiredSlots(msg.sender, MAX_SWEEP_PER_CALL, commitmentRandomness);

        // Phase 2: validate this slot is active and caller is the challenged node
        ChallengeSlot storage slot = challengeSlots[_slotIndex];
        uint256 slotOrderId = slot.orderId;
        require(slotOrderId != 0, "slot is idle");
        require(slot.challengedNode == msg.sender, "not the challenged node");
        require(block.number <= slot.deadlineBlock, "slot deadline passed");

        // Phase 3: verify ZK proof
        FileOrder storage order = orders[slotOrderId];
        uint256 fileRootHash = order.fileRoot;

        (,,, uint256 publicKey) = nodeStaking.getNodeInfo(msg.sender);
        require(publicKey != 0, "node public key not set");

        uint256 slotRandomness = slot.randomness;
        uint256[5] memory publicInputs =
            [uint256(_commitment), slotRandomness, publicKey, fileRootHash, uint256(order.numChunks)];

        PrecompileVerifiers.verifyPoiProof(_proof, publicInputs);

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
    /// Automatically scales slot count via ceil(N / ordersPerSlot) clamped to [MIN, maxChallengeSlots].
    function activateSlots() external nonReentrant {
        // Grace period: suppress challenges until challengeStartBlock
        if (challengeStartBlock > 0 && block.number < challengeStartBlock) return;

        // Bootstrap randomness on first call
        if (!challengeSlotsInitialized) {
            globalSeedRandomness = uint256(
                keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender, block.number))
            ) % SNARK_SCALAR_FIELD;
            challengeSlotsInitialized = true;
        }

        // Clean up expired orders before filling slots
        _cleanupExpiredOrders();

        // --- Auto-scale slot count via ceil(N / ordersPerSlot) ---
        uint256 orderCount = challengeableOrders.length;
        uint256 targetSlots;
        if (orderCount == 0) {
            targetSlots = 0;
        } else {
            uint256 divisor = ordersPerSlot > 0 ? ordersPerSlot : DEFAULT_ORDERS_PER_SLOT;
            targetSlots = (orderCount + divisor - 1) / divisor; // ceil division
            if (targetSlots < MIN_CHALLENGE_SLOTS) targetSlots = MIN_CHALLENGE_SLOTS;
            uint256 maxSlots_ = maxChallengeSlots > 0 ? maxChallengeSlots : DEFAULT_MAX_CHALLENGE_SLOTS;
            if (targetSlots > maxSlots_) targetSlots = maxSlots_;
        }

        uint256 currentCount = numChallengeSlots;

        // Growth: new mapping entries default to zero (idle)
        if (targetSlots > currentCount) {
            emit ChallengeSlotsScaled(currentCount, targetSlots);
            numChallengeSlots = targetSlots;
            currentCount = targetSlots;
        }

        // Shrinkage: deactivate excess high-index slots (only idle or expired)
        if (targetSlots < currentCount) {
            uint256 newCount = currentCount;
            for (uint256 i = currentCount; i > targetSlots;) {
                i--;
                ChallengeSlot storage slot = challengeSlots[i];
                if (slot.orderId == 0) {
                    newCount = i;
                } else if (block.number > slot.deadlineBlock) {
                    nodeActiveChallengeCount[slot.challengedNode]--;
                    orderActiveChallengeCount[slot.orderId]--;
                    _deactivateSlot(i);
                    newCount = i;
                } else {
                    break; // active mid-flight — stop shrinking
                }
            }
            if (newCount != currentCount) {
                emit ChallengeSlotsScaled(currentCount, newCount);
                numChallengeSlots = newCount;
                currentCount = newCount;
            }
        }

        // Cap active slots at the number of challengeable orders to avoid
        // filling multiple slots with the same order during cold-start
        uint256 maxSlots = orderCount < currentCount ? orderCount : currentCount;

        uint256 activated = 0;
        for (uint256 i = 0; i < maxSlots && activated < MAX_ACTIVATE_PER_CALL; i++) {
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
            NodeAssignment[] storage assignments_ = orderAssignments[candidateOrderId];
            if (assignments_.length == 0) continue;

            address selectedNode = _selectUnchallengedNode(assignments_, _randomness, candidateOrderId, nonce);

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

    /// @notice Select a node from an order's assignment list, preferring nodes not already under challenge.
    /// @dev Bounded by MAX_REPLICAS (10) — at most 1 + 10 SLOADs for the linear scan.
    function _selectUnchallengedNode(
        NodeAssignment[] storage _assignments,
        uint256 _randomness,
        uint256 _orderId,
        uint256 _nonce
    ) internal view returns (address) {
        uint256 idx =
            uint256(keccak256(abi.encodePacked(_randomness, _orderId, _nonce))) % _assignments.length;
        address candidate = _assignments[idx].node;
        if (nodeActiveChallengeCount[candidate] == 0) return candidate;
        // Linear scan for an unchallenged node (bounded by MAX_REPLICAS = 10)
        for (uint256 i = 0; i < _assignments.length; i++) {
            if (nodeActiveChallengeCount[_assignments[i].node] == 0) return _assignments[i].node;
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
        uint64 deadline = uint64(block.number + CHALLENGE_WINDOW_BLOCKS);
        _slot.orderId = _orderId;
        _slot.challengedNode = _node;
        _slot.deadlineBlock = deadline;
        _slot.randomness = safeRandomness;

        nodeActiveChallengeCount[_node]++;
        orderActiveChallengeCount[_orderId]++;

        emit SlotChallengeIssued(_slotIndex, _orderId, _node, deadline);
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
    /// Uses a persistent cursor to amortize work across calls.
    /// @param _reporter Address that triggered the sweep (earns reporter rewards).
    /// @param _maxSweep Maximum number of expired slots to process.
    /// @param _proofRandomness When non-zero, commitment-derived randomness from a verified proof
    ///        (used by submitProof). When zero, falls back to chain pseudorandomness (used by processExpiredSlots).
    /// @return processed Number of expired slots processed.
    function _sweepExpiredSlots(address _reporter, uint256 _maxSweep, uint256 _proofRandomness)
        internal
        returns (uint256 processed)
    {
        uint256 slotCount = numChallengeSlots;
        if (slotCount == 0) return 0;

        uint256 forcedExitCount = 0;
        uint256 cursor = sweepCursor;
        if (cursor >= slotCount) cursor = 0;

        uint256 checked = 0;
        while (checked < slotCount && processed < _maxSweep) {
            ChallengeSlot storage slot = challengeSlots[cursor];

            if (slot.orderId != 0 && block.number > slot.deadlineBlock) {
                address failedNode = slot.challengedNode;

                // Slash the failed node — proportional to order value * multiplier, floored at MIN_PROOF_FAILURE_SLASH
                uint256 slotOrderId_ = slot.orderId;
                FileOrder storage order = orders[slotOrderId_];
                uint256 scaledSlash = uint256(order.numChunks) * _orderPrice(order) * proofFailureSlashMultiplier;
                uint256 slashAmount = scaledSlash > MIN_PROOF_FAILURE_SLASH ? scaledSlash : MIN_PROOF_FAILURE_SLASH;

                if (nodeStaking.isValidNode(failedNode)) {
                    (uint256 nodeStake,,,) = nodeStaking.getNodeInfo(failedNode);
                    if (slashAmount > nodeStake) {
                        slashAmount = nodeStake;
                    }

                    if (slashAmount > 0) {
                        (bool forcedExit, uint256 totalSlashed) = nodeStaking.slashNode(failedNode, slashAmount);
                        _distributeSlashFunds(_reporter, failedNode, totalSlashed, slotOrderId_);
                        if (forcedExit) {
                            _handleForcedOrderExits(failedNode);
                            forcedExitCount++;
                        }
                        emit NodeSlashed(failedNode, slashAmount, "failed challenge proof");
                    }
                }

                emit SlotExpired(cursor, failedNode, slashAmount);

                // Derive randomness for re-advancing the expired slot.
                // When triggered by submitProof, use the proof commitment (unbiasable by the prover).
                // When triggered by processExpiredSlots (manual maintenance), fall back to chain data.
                uint256 advanceRandomness;
                if (_proofRandomness != 0) {
                    advanceRandomness = uint256(keccak256(abi.encodePacked(_proofRandomness, slot.randomness, cursor)))
                        % SNARK_SCALAR_FIELD;
                } else {
                    advanceRandomness = uint256(
                        keccak256(abi.encodePacked(slot.randomness, block.number, block.prevrandao, _reporter, cursor))
                    ) % SNARK_SCALAR_FIELD;
                }

                _advanceSlot(cursor, advanceRandomness);

                processed++;

                if (forcedExitCount >= MAX_FORCED_EXITS_PER_SWEEP) break;
            }

            cursor++;
            if (cursor >= slotCount) cursor = 0;
            checked++;
        }
        sweepCursor = cursor;
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

        uint256 settlePeriod = uint256(order.startPeriod) + uint256(order.periods);
        _settleAndReleaseNodes(order, _orderId, settlePeriod);

        _removeFromActiveOrders(_orderId);
        uint256 escrow = order.escrow;
        uint256 withdrawn = orderEscrowWithdrawn[_orderId];
        uint256 refundAmount = escrow - withdrawn;
        address orderOwner = order.owner;

        aggregateActiveEscrow -= escrow;
        aggregateActiveWithdrawn -= withdrawn;

        delete orders[_orderId];
        delete orderAssignments[_orderId];
        delete orderUri[_orderId];

        if (refundAmount > 0) {
            pendingRefunds[orderOwner] += refundAmount;
            emit RefundQueued(orderOwner, refundAmount);
        }

        emit OrderCompleted(_orderId);
    }
}
