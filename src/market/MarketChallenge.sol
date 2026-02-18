// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketAccounting} from "./MarketAccounting.sol";

/// @notice Rolling challenge, proof submission, and heartbeat orchestration.
abstract contract MarketChallenge is MarketAccounting {
    /// @notice Submit proof for current challenge
    function submitProof(uint256[8] calldata _proof, bytes32 _commitment) external nonReentrant {
        require(currentStep() > lastChallengeStep, "no active challenge");
        require(currentStep() <= lastChallengeStep + 1, "challenge period expired");

        bool isPrimary = (msg.sender == currentPrimaryProver);
        bool isSecondary = false;

        // Check if sender is a secondary prover
        for (uint256 i = 0; i < currentSecondaryProvers.length; i++) {
            if (currentSecondaryProvers[i] == msg.sender) {
                isSecondary = true;
                break;
            }
        }

        require(isPrimary || isSecondary, "not a challenged prover");
        require(!proofSubmitted[msg.sender], "proof already submitted");

        // Get the order this node should prove (set during challenge assignment)
        uint256 proverOrderId = nodeToProveOrderId[msg.sender];
        require(proverOrderId != 0, "no order assigned to node");

        // Get file root hash from the order
        FileOrder storage order = orders[proverOrderId];
        uint256 fileRootHash = order.file.root;

        // Get node's public key from NodeStaking contract
        (,,, uint256 publicKeyX, uint256 publicKeyY) = nodeStaking.getNodeInfo(msg.sender);
        require(publicKeyX != 0 && publicKeyY != 0, "node public key not set");

        // Prepare public inputs for POI verifier matching gnark circuit field order:
        // [commitment, randomness, publicKeyX, publicKeyY, rootHash]
        uint256[5] memory publicInputs = [uint256(_commitment), currentRandomness, publicKeyX, publicKeyY, fileRootHash];

        // Verify proof using POI verifier - reverts on invalid proof
        poiVerifier.verifyProof(_proof, publicInputs);

        proofSubmitted[msg.sender] = true;

        if (isPrimary) {
            primaryProofReceived = true;
            // Defer commitment as next round's randomness seed so that
            // currentRandomness stays valid for secondary proof verification
            // during the remainder of this step.
            pendingRandomness = uint256(_commitment);
        }

        emit ProofSubmitted(msg.sender, isPrimary, _commitment);
    }

    /// @notice Report primary prover failure (callable after STEP period)
    function reportPrimaryFailure() external nonReentrant {
        require(nodeStaking.isValidNode(msg.sender), "not a valid node");
        require(currentStep() > lastChallengeStep + 1, "challenge period not expired");
        require(!primaryProofReceived, "primary proof was submitted");
        require(!primaryFailureReported, "primary failure already reported");
        require(currentPrimaryProver != address(0), "no primary assigned");

        // Mark failure as reported to prevent duplicate reports
        primaryFailureReported = true;

        // Slash primary prover severely (skip if already invalidated by authority slash)
        address primaryProver = currentPrimaryProver;
        require(nodeToProveOrderId[primaryProver] != 0, "primary not assigned to order");

        if (nodeStaking.isValidNode(primaryProver)) {
            uint256 severeSlashAmount = 1000 * nodeStaking.STAKE_PER_BYTE(); // Much higher than normal

            // Cap to available stake to prevent revert
            (uint256 nodeStake,,,,) = nodeStaking.getNodeInfo(primaryProver);
            if (severeSlashAmount > nodeStake) {
                severeSlashAmount = nodeStake;
            }

            if (severeSlashAmount > 0) {
                (bool forcedExit, uint256 totalSlashed) = nodeStaking.slashNode(primaryProver, severeSlashAmount);
                _distributeSlashFunds(msg.sender, primaryProver, totalSlashed);
                if (forcedExit) {
                    _handleForcedOrderExits(primaryProver);
                }
                emit NodeSlashed(primaryProver, severeSlashAmount, "failed primary proof");
            }
        }

        // Generate fallback randomness using reporter's signature and block data
        uint256 fallbackRandomness =
            uint256(keccak256(abi.encodePacked(msg.sender, block.timestamp, block.prevrandao, currentRandomness)));

        currentRandomness = fallbackRandomness % SNARK_SCALAR_FIELD;

        // Auto-slash secondaries before resetting state (primary already slashed above)
        _processExpiredChallengeSlashes(msg.sender);

        _triggerNewHeartbeat();

        emit PrimaryProverFailed(primaryProver, msg.sender, fallbackRandomness);
    }

    /// @notice Check and slash secondary provers who failed to submit proofs
    function slashSecondaryFailures() external nonReentrant {
        require(currentStep() > lastChallengeStep + 1, "challenge period not expired");
        require(!secondarySlashProcessed, "secondary slash settled");
        secondarySlashProcessed = true;

        for (uint256 i = 0; i < currentSecondaryProvers.length; i++) {
            address secondaryProver = currentSecondaryProvers[i];
            if (!proofSubmitted[secondaryProver]) {
                // Ensure still assigned to an order for this challenge
                if (nodeToProveOrderId[secondaryProver] == 0) {
                    continue;
                }
                if (!nodeStaking.isValidNode(secondaryProver)) {
                    continue;
                }
                // Normal slashing for secondary provers
                uint256 normalSlashAmount = 100 * nodeStaking.STAKE_PER_BYTE();

                // Cap to available stake to prevent revert
                (uint256 nodeStake,,,,) = nodeStaking.getNodeInfo(secondaryProver);
                if (normalSlashAmount > nodeStake) {
                    normalSlashAmount = nodeStake;
                }

                if (normalSlashAmount > 0) {
                    (bool forcedExit, uint256 totalSlashed) = nodeStaking.slashNode(secondaryProver, normalSlashAmount);
                    _distributeSlashFunds(msg.sender, secondaryProver, totalSlashed);
                    if (forcedExit) {
                        _handleForcedOrderExits(secondaryProver);
                    }
                    emit NodeSlashed(secondaryProver, normalSlashAmount, "failed secondary proof");
                }
                proofSubmitted[secondaryProver] = true;
            }
        }
    }

    /// @notice Trigger new heartbeat with challenge selection
    function _triggerNewHeartbeat() internal {
        // Clean up expired orders before selecting challenges so stale orders
        // are evicted from challengeableOrders regardless of the calling path
        // (triggerHeartbeat or reportPrimaryFailure).
        _cleanupExpiredOrders();

        // Apply deferred randomness from primary proof if available
        if (pendingRandomness != 0) {
            currentRandomness = pendingRandomness;
            pendingRandomness = 0;
        }

        uint256 currentStep_ = currentStep();
        challengeInitialized = true;

        // Reset proof tracking
        _resetProofTracking();

        // Determine desired number of secondary provers using alpha * log2(total orders)
        uint256 totalOrders = nextOrderId - 1;
        uint256 desiredSecondaryCount = SECONDARY_ALPHA * _log2(totalOrders);
        uint256 selectionCount = desiredSecondaryCount + 1; // +1 for primary order
        if (selectionCount == 0) {
            selectionCount = 1; // ensure we request at least one order
        }

        // Select random non-expired orders for challenge, evicting expired entries on contact
        uint256[] memory selectedOrders = _selectChallengeableOrders(currentRandomness, selectionCount);

        if (selectedOrders.length == 0) {
            // Clear stale challenge state so _isOrderUnderActiveChallenge() doesn't
            // match orders from a previous heartbeat.
            delete currentChallengedOrders;
            currentPrimaryProver = address(0);
            // Secondary prover mappings already cleared by _resetProofTracking();
            // zero out the array itself.
            assembly {
                sstore(currentSecondaryProvers.slot, 0)
            }

            // Advance randomness even without challengeable orders to keep the beacon moving
            currentRandomness = uint256(
                keccak256(abi.encodePacked(currentRandomness, block.timestamp, block.prevrandao, msg.sender))
            ) % SNARK_SCALAR_FIELD;
            lastChallengeStep = currentStep_;
            emit HeartbeatTriggered(currentRandomness, currentStep_);
            return;
        }

        // Set up new challenge
        currentChallengedOrders = selectedOrders;

        // Select a primary prover: choose a random node from the first order that has at least one node
        address primary;
        uint256 primaryOrderId;
        for (uint256 idx = 0; idx < selectedOrders.length; idx++) {
            uint256 candidateOrderId = selectedOrders[idx];
            address[] storage candidateNodes = orderToNodes[candidateOrderId];
            if (candidateNodes.length == 0) {
                continue;
            }
            uint256 r = uint256(keccak256(abi.encodePacked(currentRandomness, candidateOrderId, idx)));
            primary = candidateNodes[r % candidateNodes.length];
            primaryOrderId = candidateOrderId;
            break;
        }

        // If no orders had nodes, clear provers, advance randomness, emit heartbeat and exit
        if (primary == address(0)) {
            // Clear any stale provers
            if (currentPrimaryProver != address(0)) {
                proofSubmitted[currentPrimaryProver] = false;
                nodeToProveOrderId[currentPrimaryProver] = 0;
            }
            if (currentSecondaryProvers.length > 0) {
                for (uint256 i = 0; i < currentSecondaryProvers.length; i++) {
                    address s = currentSecondaryProvers[i];
                    proofSubmitted[s] = false;
                    nodeToProveOrderId[s] = 0;
                }
                assembly {
                    sstore(currentSecondaryProvers.slot, 0)
                }
            }
            currentPrimaryProver = address(0);

            // Advance randomness even without a selection to keep the beacon moving
            currentRandomness = uint256(
                keccak256(abi.encodePacked(currentRandomness, block.timestamp, block.prevrandao, msg.sender))
            ) % SNARK_SCALAR_FIELD;
            lastChallengeStep = currentStep_;
            emit HeartbeatTriggered(currentRandomness, currentStep_);
            return;
        }

        currentPrimaryProver = primary;
        nodeToProveOrderId[currentPrimaryProver] = primaryOrderId;

        // Reset secondary provers array length to 0 (more efficient than delete)
        uint256 secondaryCount = 0;
        if (currentSecondaryProvers.length > 0) {
            assembly {
                sstore(currentSecondaryProvers.slot, 0)
            }
        }

        // Assign secondary provers from remaining orders, selecting a random node per order
        for (uint256 i = 0; i < selectedOrders.length; i++) {
            uint256 orderId = selectedOrders[i];
            if (orderId == primaryOrderId) {
                continue;
            }
            address[] storage orderNodes = orderToNodes[orderId];
            if (orderNodes.length > 0) {
                uint256 r = uint256(keccak256(abi.encodePacked(currentRandomness, orderId, i)));
                address secondaryNode = orderNodes[r % orderNodes.length];
                // Skip if this node is already the primary prover
                if (secondaryNode == primary) {
                    continue;
                }
                // Skip if this node was already assigned (primary or earlier secondary)
                if (nodeToProveOrderId[secondaryNode] != 0) {
                    continue;
                }
                currentSecondaryProvers.push(secondaryNode);
                nodeToProveOrderId[secondaryNode] = orderId;
                secondaryCount++;
                if (secondaryCount >= desiredSecondaryCount) {
                    break;
                }
            }
        }

        lastChallengeStep = currentStep_;

        emit ChallengeIssued(
            currentRandomness, currentPrimaryProver, currentSecondaryProvers, selectedOrders, currentStep_
        );
        emit HeartbeatTriggered(currentRandomness, currentStep_);
    }

    // Compute floor(log2(value)); returns 0 for value == 0 or 1
    function _log2(uint256 value) internal pure returns (uint256 result) {
        if (value <= 1) {
            return 0;
        }
        while (value > 1) {
            value >>= 1;
            result++;
        }
    }

    /// @notice Reset proof submission tracking for new challenge
    function _resetProofTracking() internal {
        // Reset primary prover proof status
        primaryProofReceived = false;
        primaryFailureReported = false;
        secondarySlashProcessed = false;

        // Reset primary prover submission and order assignment
        if (currentPrimaryProver != address(0)) {
            proofSubmitted[currentPrimaryProver] = false;
            nodeToProveOrderId[currentPrimaryProver] = 0;
        }

        // Reset secondary provers submissions and order assignments
        for (uint256 i = 0; i < currentSecondaryProvers.length; i++) {
            address secondaryNode = currentSecondaryProvers[i];
            proofSubmitted[secondaryNode] = false;
            nodeToProveOrderId[secondaryNode] = 0;
        }
    }

    /// @notice Auto-process all pending slashes for an expired challenge before state reset.
    /// @param _reporter Address that triggered processing (receives reporter rewards)
    function _processExpiredChallengeSlashes(address _reporter) internal {
        if (!challengeInitialized) return;

        // --- Primary prover slash ---
        if (!primaryProofReceived && !primaryFailureReported && currentPrimaryProver != address(0)) {
            address primaryProver = currentPrimaryProver;
            if (nodeToProveOrderId[primaryProver] != 0 && nodeStaking.isValidNode(primaryProver)) {
                primaryFailureReported = true;
                uint256 severeSlashAmount = 1000 * nodeStaking.STAKE_PER_BYTE();

                // Cap to available stake to prevent revert
                (uint256 nodeStake,,,,) = nodeStaking.getNodeInfo(primaryProver);
                if (severeSlashAmount > nodeStake) {
                    severeSlashAmount = nodeStake;
                }

                if (severeSlashAmount > 0) {
                    (bool forcedExit, uint256 totalSlashed) = nodeStaking.slashNode(primaryProver, severeSlashAmount);
                    _distributeSlashFunds(_reporter, primaryProver, totalSlashed);
                    if (forcedExit) {
                        _handleForcedOrderExits(primaryProver);
                    }
                    emit NodeSlashed(primaryProver, severeSlashAmount, "failed primary proof (auto)");
                }
            }
        }

        // --- Secondary prover slashes ---
        if (!secondarySlashProcessed) {
            secondarySlashProcessed = true;

            for (uint256 i = 0; i < currentSecondaryProvers.length; i++) {
                address secondaryProver = currentSecondaryProvers[i];
                if (!proofSubmitted[secondaryProver] && nodeToProveOrderId[secondaryProver] != 0) {
                    if (!nodeStaking.isValidNode(secondaryProver)) {
                        continue;
                    }
                    uint256 normalSlashAmount = 100 * nodeStaking.STAKE_PER_BYTE();

                    (uint256 nodeStake,,,,) = nodeStaking.getNodeInfo(secondaryProver);
                    if (normalSlashAmount > nodeStake) {
                        normalSlashAmount = nodeStake;
                    }

                    if (normalSlashAmount > 0) {
                        (bool forcedExit, uint256 totalSlashed) =
                            nodeStaking.slashNode(secondaryProver, normalSlashAmount);
                        _distributeSlashFunds(_reporter, secondaryProver, totalSlashed);
                        if (forcedExit) {
                            _handleForcedOrderExits(secondaryProver);
                        }
                        emit NodeSlashed(secondaryProver, normalSlashAmount, "failed secondary proof");
                    }
                    proofSubmitted[secondaryProver] = true;
                }
            }
        }
    }

    /// @notice Cleanup expired orders automatically using a persistent cursor.
    /// Scans at most CLEANUP_SCAN_CAP entries per call, processing up to batchSize expired orders.
    /// The cursor persists across heartbeats so each call resumes where the last left off,
    /// amortising full-array scans across multiple heartbeats.
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
                // swap-and-pop: re-check position i (new element swapped in)
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

    /// @notice Manual heartbeat trigger (can be called by anyone if no challenge active)
    function triggerHeartbeat() external nonReentrant {
        require(currentStep() > lastChallengeStep + 1 || !challengeInitialized, "challenge still active");

        // If no randomness set, initialize with block data
        if (currentRandomness == 0) {
            currentRandomness =
                uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender))) % SNARK_SCALAR_FIELD;
        }

        // Process any pending slashes from the expired challenge before resetting state
        _processExpiredChallengeSlashes(msg.sender);

        _triggerNewHeartbeat();
    }

    /// @notice Internal version of completeExpiredOrder for heartbeat use
    function _completeExpiredOrderInternal(uint256 _orderId) internal {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) return; // Already completed

        uint256 settlePeriod = order.startPeriod + order.periods;
        _settleAndReleaseNodes(order, _orderId, settlePeriod);

        // Remove from active orders and clean up
        _removeFromActiveOrders(_orderId);
        uint256 refundAmount = order.escrow - orderEscrowWithdrawn[_orderId];
        address orderOwner = order.owner;

        // Update aggregates before delete zeroes the struct
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
