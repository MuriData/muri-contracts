// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketAdmin} from "./MarketAdmin.sol";

/// @notice Order lifecycle, assignment, settlement, and slashing mechanics.
abstract contract MarketOrders is MarketAdmin {
    // Place a new file storage order
    function placeOrder(
        FileMeta memory _file,
        uint64 _maxSize,
        uint16 _periods,
        uint8 _replicas,
        uint256 _pricePerBytePerPeriod
    ) external payable nonReentrant returns (uint256 orderId) {
        require(_file.root > 0 && _file.root < SNARK_SCALAR_FIELD, "root not in Fr");
        require(_maxSize > 0, "invalid size");
        require(_periods > 0, "invalid periods");
        require(_replicas > 0 && _replicas <= MAX_REPLICAS, "invalid replicas");
        require(_pricePerBytePerPeriod > 0, "invalid price");

        uint256 totalCost = uint256(_maxSize) * uint256(_periods) * _pricePerBytePerPeriod * uint256(_replicas);
        require(msg.value >= totalCost, "insufficient payment");

        orderId = nextOrderId++;

        orders[orderId] = FileOrder({
            owner: msg.sender,
            file: _file,
            maxSize: _maxSize,
            periods: _periods,
            replicas: _replicas,
            price: _pricePerBytePerPeriod,
            filled: 0,
            startPeriod: uint64(currentPeriod()),
            escrow: totalCost
        });

        // Add to active orders for random selection
        activeOrders.push(orderId);
        orderIndexInActive[orderId] = activeOrders.length - 1;

        aggregateActiveEscrow += totalCost;
        lifetimeEscrowDeposited += totalCost;

        emit OrderPlaced(orderId, msg.sender, _maxSize, _periods, _replicas);

        // Queue excess payment as pull-refund
        if (msg.value > totalCost) {
            uint256 excess = msg.value - totalCost;
            pendingRefunds[msg.sender] += excess;
            emit RefundQueued(msg.sender, excess);
        }
    }

    // Node executes an order (claims a replica slot)
    function executeOrder(uint256 _orderId) external nonReentrant {
        require(nodeStaking.isValidNode(msg.sender), "not a valid node");

        FileOrder storage order = orders[_orderId];
        require(order.owner != address(0), "order does not exist");
        require(!isOrderExpired(_orderId), "order expired");
        require(order.filled < order.replicas, "order already filled");
        require(nodeStaking.hasCapacity(msg.sender, order.maxSize), "insufficient capacity");

        // Check if node is already assigned to this order
        address[] storage assignedNodes = orderToNodes[_orderId];
        for (uint256 i = 0; i < assignedNodes.length; i++) {
            require(assignedNodes[i] != msg.sender, "already assigned to this order");
        }

        // Enforce per-node order cap to bound forced-exit iteration
        require(nodeToOrders[msg.sender].length < MAX_ORDERS_PER_NODE, "max orders per node reached");

        // Assign node to order
        assignedNodes.push(msg.sender);
        nodeToOrders[msg.sender].push(_orderId);
        order.filled++;

        // First node assigned — order becomes challengeable
        if (order.filled == 1) {
            _addToChallengeableOrders(_orderId);
        }

        // Record when this node started storing this order (timestamp, not period)
        nodeOrderStartTimestamp[msg.sender][_orderId] = block.timestamp;

        // Update node's used capacity
        (,, uint64 used,,) = nodeStaking.getNodeInfo(msg.sender);
        nodeStaking.updateNodeUsed(msg.sender, used + order.maxSize);

        emit OrderFulfilled(_orderId, msg.sender);

        // Order stays active until periods expire, not when filled
    }

    // Internal function to remove order from active orders array
    function _removeFromActiveOrders(uint256 _orderId) internal {
        uint256 index = orderIndexInActive[_orderId];
        uint256 lastIndex = activeOrders.length - 1;

        if (index != lastIndex) {
            uint256 lastOrderId = activeOrders[lastIndex];
            activeOrders[index] = lastOrderId;
            orderIndexInActive[lastOrderId] = index;
        }

        activeOrders.pop();
        delete orderIndexInActive[_orderId];

        // Also remove from challengeable orders if present
        if (isChallengeable[_orderId]) {
            _removeFromChallengeableOrders(_orderId);
        }
    }

    // Internal function to add order to challengeable orders (called when first node is assigned)
    function _addToChallengeableOrders(uint256 _orderId) internal {
        challengeableOrders.push(_orderId);
        orderIndexInChallengeable[_orderId] = challengeableOrders.length - 1;
        isChallengeable[_orderId] = true;
    }

    // Internal function to remove order from challengeable orders
    function _removeFromChallengeableOrders(uint256 _orderId) internal {
        uint256 index = orderIndexInChallengeable[_orderId];
        uint256 lastIndex = challengeableOrders.length - 1;

        if (index != lastIndex) {
            uint256 lastOrderId = challengeableOrders[lastIndex];
            challengeableOrders[index] = lastOrderId;
            orderIndexInChallengeable[lastOrderId] = index;
        }

        challengeableOrders.pop();
        delete orderIndexInChallengeable[_orderId];
        isChallengeable[_orderId] = false;
    }

    /// @notice Check if a node has an unresolved proof obligation from the current challenge.
    /// Returns true if the node is a primary or secondary prover that hasn't submitted proof
    /// and hasn't been slashed yet. Used to prevent provers from escaping slashing by quitting.
    /// @notice Check if a node has an unresolved proof obligation (used by NodeStaking to block withdrawals)
    function hasUnresolvedProofObligation(address _node) external view returns (bool) {
        return _isUnresolvedProver(_node);
    }

    function _isUnresolvedProver(address _node) internal view returns (bool) {
        if (!challengeInitialized) return false;

        // Primary prover with unresolved obligation
        if (_node == currentPrimaryProver && !proofSubmitted[_node] && !primaryFailureReported) {
            return true;
        }

        // Secondary prover with unresolved obligation
        if (!secondarySlashProcessed && !proofSubmitted[_node]) {
            for (uint256 i = 0; i < currentSecondaryProvers.length; i++) {
                if (currentSecondaryProvers[i] == _node) {
                    return true;
                }
            }
        }

        return false;
    }

    /// @notice Check if an order is currently under active challenge
    function _isOrderUnderActiveChallenge(uint256 _orderId) internal view returns (bool) {
        if (!challengeInitialized || currentStep() > lastChallengeStep + 1) {
            return false;
        }
        for (uint256 i = 0; i < currentChallengedOrders.length; i++) {
            if (currentChallengedOrders[i] == _orderId) {
                return true;
            }
        }
        return false;
    }

    // Internal random selection from a given array (shared logic for active and challengeable orders)
    // Uses virtual Fisher-Yates: O(K) storage reads and O(K^2) memory ops instead of O(N).
    function _selectFromArray(uint256[] storage arr, uint256 _randomSeed, uint256 _count)
        internal
        view
        returns (uint256[] memory selectedOrders)
    {
        require(_count > 0, "count must be positive");

        uint256 total = arr.length;
        if (total == 0) {
            return new uint256[](0);
        }

        uint256 actualCount = _count > total ? total : _count;
        selectedOrders = new uint256[](actualCount);

        // Always shuffle via virtual Fisher-Yates so the output ordering is
        // randomised even when actualCount == total.  This prevents primary
        // prover selection from being biased toward whichever order sits at
        // index 0 of the storage array.
        uint256[] memory mapKeys = new uint256[](actualCount);
        uint256[] memory mapVals = new uint256[](actualCount);
        uint256 mapLen = 0;

        for (uint256 i = 0; i < actualCount; i++) {
            uint256 j = (uint256(keccak256(abi.encodePacked(_randomSeed, i))) % (total - i)) + i;

            // Lookup mapped value for j (unmapped positions map to themselves)
            uint256 valJ = j;
            for (uint256 k = 0; k < mapLen; k++) {
                if (mapKeys[k] == j) {
                    valJ = mapVals[k];
                    break;
                }
            }

            // Lookup mapped value for i
            uint256 valI = i;
            for (uint256 k = 0; k < mapLen; k++) {
                if (mapKeys[k] == i) {
                    valI = mapVals[k];
                    break;
                }
            }

            selectedOrders[i] = arr[valJ];

            // Record swap: map[j] = valI
            bool found = false;
            for (uint256 k = 0; k < mapLen; k++) {
                if (mapKeys[k] == j) {
                    mapVals[k] = valI;
                    found = true;
                    break;
                }
            }
            if (!found) {
                mapKeys[mapLen] = j;
                mapVals[mapLen] = valI;
                mapLen++;
            }
        }
    }

    /// @notice Select non-expired challengeable orders with inline eviction of expired entries.
    /// Uses random probing bounded by MAX_CHALLENGE_SELECTION_PROBES to limit gas.
    /// Evictions are capped by MAX_CHALLENGE_EVICTIONS to prevent OOG when the
    /// expired backlog is large; remaining evictions are deferred to later heartbeats.
    function _selectChallengeableOrders(uint256 _randomSeed, uint256 _desiredCount)
        internal
        returns (uint256[] memory result)
    {
        result = new uint256[](_desiredCount);
        uint256 found = 0;
        uint256 nonce = 0; // hash seed (always increments)
        uint256 attempts = 0; // bounded random attempts
        uint256 evictions = 0; // expired-order evictions (bounded by cap)
        uint256 maxAttempts = MAX_CHALLENGE_SELECTION_PROBES + MAX_CHALLENGE_EVICTIONS;

        while (found < _desiredCount && challengeableOrders.length > 0 && attempts < maxAttempts) {
            attempts++;
            uint256 idx = uint256(keccak256(abi.encodePacked(_randomSeed, nonce))) % challengeableOrders.length;
            uint256 orderId = challengeableOrders[idx];
            nonce++;

            if (isOrderExpired(orderId)) {
                if (evictions < MAX_CHALLENGE_EVICTIONS) {
                    _removeFromChallengeableOrders(orderId);
                    evictions++;
                }
                continue;
            }

            // Duplicate check (selection count is small, O(found) scan is fine)
            bool dup = false;
            for (uint256 j = 0; j < found; j++) {
                if (result[j] == orderId) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            result[found] = orderId;
            found++;
        }

        // Deterministic fallback scan reduces challenge-blackout risk when random
        // sampling misses sparse live entries behind an expired backlog.
        if (found < _desiredCount && challengeableOrders.length > 0) {
            uint256 checks = 0;
            uint256 idx = uint256(keccak256(abi.encodePacked(_randomSeed, nonce, challengeableOrders.length)))
                % challengeableOrders.length;

            while (found < _desiredCount && challengeableOrders.length > 0 && checks < MAX_CHALLENGE_SELECTION_PROBES) {
                checks++;

                if (idx >= challengeableOrders.length) {
                    idx = 0;
                }

                uint256 orderId = challengeableOrders[idx];
                if (isOrderExpired(orderId)) {
                    if (evictions < MAX_CHALLENGE_EVICTIONS) {
                        _removeFromChallengeableOrders(orderId);
                        evictions++;
                        continue;
                    }
                    idx++;
                    continue;
                }

                bool dup = false;
                for (uint256 j = 0; j < found; j++) {
                    if (result[j] == orderId) {
                        dup = true;
                        break;
                    }
                }

                if (!dup) {
                    result[found] = orderId;
                    found++;
                }
                idx++;
            }
        }

        assembly {
            mstore(result, found)
        }
    }

    // Random order selection function (public wrapper for backward compatibility)
    function selectRandomOrders(uint256 _randomSeed, uint256 _count)
        public
        view
        returns (uint256[] memory selectedOrders)
    {
        return _selectFromArray(activeOrders, _randomSeed, _count);
    }

    // Get active orders count
    function getActiveOrdersCount() external view returns (uint256) {
        return activeOrders.length;
    }

    // Get all active order IDs
    function getActiveOrders() external view returns (uint256[] memory) {
        return activeOrders;
    }

    // Get challengeable orders count
    function getChallengeableOrdersCount() external view returns (uint256) {
        return challengeableOrders.length;
    }

    // Get all challengeable order IDs
    function getChallengeableOrders() external view returns (uint256[] memory) {
        return challengeableOrders;
    }

    // Get nodes assigned to an order
    function getOrderNodes(uint256 _orderId) external view returns (address[] memory) {
        return orderToNodes[_orderId];
    }

    // Get orders assigned to a node
    function getNodeOrders(address _node) external view returns (uint256[] memory) {
        return nodeToOrders[_node];
    }

    // Check if an order is expired (periods have passed)
    function isOrderExpired(uint256 _orderId) public view returns (bool) {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) return true; // non-existent order
        uint256 endPeriod = order.startPeriod + order.periods;
        return currentPeriod() >= endPeriod;
    }

    // Complete expired orders and free up node capacity
    function completeExpiredOrder(uint256 _orderId) external nonReentrant {
        require(isOrderExpired(_orderId), "order not expired");
        FileOrder storage order = orders[_orderId];
        require(order.owner != address(0), "order does not exist");
        require(!_isOrderUnderActiveChallenge(_orderId), "order under active challenge");

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

        // Queue remaining escrow as pull-refund
        if (refundAmount > 0) {
            pendingRefunds[orderOwner] += refundAmount;
            emit RefundQueued(orderOwner, refundAmount);
        }

        emit OrderCompleted(_orderId);
    }

    // User cancels order with refund (minus any penalties)
    function cancelOrder(uint256 _orderId) external nonReentrant {
        FileOrder storage order = orders[_orderId];
        require(order.owner == msg.sender, "not order owner");
        require(!isOrderExpired(_orderId), "order already expired");
        require(!_isOrderUnderActiveChallenge(_orderId), "order under active challenge");

        // Snapshot assigned nodes before settlement empties the array
        address[] memory assignedNodes = orderToNodes[_orderId];

        // Identify nodes eligible for cancellation penalty (served >= 1 full period).
        // Must be computed before _settleAndReleaseNodes deletes timestamps.
        // Uses the same ceiling-division start period as reward math to prevent
        // MEV nodes from front-running cancelOrder to siphon penalty funds.
        uint256 settlePeriod = currentPeriod();
        uint256 eligibleCount = 0;
        address[] memory eligibleNodes = new address[](assignedNodes.length);
        for (uint256 i = 0; i < assignedNodes.length; i++) {
            uint256 startTs = nodeOrderStartTimestamp[assignedNodes[i]][_orderId];
            uint256 elapsed = startTs - GENESIS_TS;
            uint256 nodeStartPeriod = (elapsed + PERIOD - 1) / PERIOD;
            if (settlePeriod > nodeStartPeriod) {
                eligibleNodes[eligibleCount] = assignedNodes[i];
                eligibleCount++;
            }
        }

        _settleAndReleaseNodes(order, _orderId, settlePeriod);

        // Clean up order data
        uint256 remainingEscrow = order.escrow - orderEscrowWithdrawn[_orderId];
        uint256 refundAmount = remainingEscrow;
        if (eligibleCount > 0 && remainingEscrow > 0) {
            uint256 penalty = remainingEscrow / 10; // 10% penalty
            refundAmount -= penalty;

            // Distribute penalty only to nodes that actually served
            assembly {
                mstore(eligibleNodes, eligibleCount)
            }
            _distributeCancellationPenalty(_orderId, penalty, eligibleNodes);
        }

        _removeFromActiveOrders(_orderId);

        // Update aggregates before delete zeroes the struct
        aggregateActiveEscrow -= order.escrow;
        aggregateActiveWithdrawn -= orderEscrowWithdrawn[_orderId];

        delete orders[_orderId];
        delete orderToNodes[_orderId];

        // Queue refund as pull-payment
        if (refundAmount > 0) {
            pendingRefunds[msg.sender] += refundAmount;
            emit RefundQueued(msg.sender, refundAmount);
        }

        emit OrderCancelled(_orderId, refundAmount);
    }

    // Node quits from an order with slashing
    function quitOrder(uint256 _orderId) external nonReentrant {
        FileOrder storage order = orders[_orderId];
        require(order.owner != address(0), "order does not exist");
        require(!isOrderExpired(_orderId), "order already expired");
        require(!_isUnresolvedProver(msg.sender), "active prover cannot quit");

        // Verify node is assigned to this order
        address[] storage assignedNodes = orderToNodes[_orderId];
        bool found = false;
        uint256 nodeIndex;
        for (uint256 i = 0; i < assignedNodes.length; i++) {
            if (assignedNodes[i] == msg.sender) {
                found = true;
                nodeIndex = i;
                break;
            }
        }
        require(found, "node not assigned to this order");

        // Calculate slash amount (up to QUIT_SLASH_PERIODS periods of storage cost, capped at remaining)
        uint256 remainingPeriods = (order.startPeriod + order.periods) - currentPeriod();
        uint256 slashPeriods = QUIT_SLASH_PERIODS < remainingPeriods ? QUIT_SLASH_PERIODS : remainingPeriods;
        uint256 slashAmount = uint256(order.maxSize) * order.price * slashPeriods;

        // Cap to available stake to prevent revert.
        // Then enforce that the slash still leaves enough collateral to keep
        // all other assignments (excluding the order being quit).
        (uint256 nodeStake,, uint64 usedBeforeQuit,,) = nodeStaking.getNodeInfo(msg.sender);
        if (slashAmount > nodeStake) {
            slashAmount = nodeStake;
        }
        require(usedBeforeQuit >= order.maxSize, "invalid node usage");

        uint256 stakePerByte = nodeStaking.STAKE_PER_BYTE();
        uint64 usedAfterQuit = usedBeforeQuit - order.maxSize;
        uint256 requiredStakeAfterQuit = uint256(usedAfterQuit) * stakePerByte;
        uint256 maxSafeSlash = nodeStake > requiredStakeAfterQuit ? nodeStake - requiredStakeAfterQuit : 0;
        require(slashAmount <= maxSafeSlash, "insufficient collateral for quit slash");

        // Remove the specific assignment first so slashing cannot be used as a
        // cheap path to force-exit unrelated orders.
        _removeNodeFromOrder(msg.sender, _orderId, nodeIndex);

        // Apply slash to node's stake (no reporter reward for voluntary quit)
        (bool forcedOrderExit, uint256 totalSlashed) = nodeStaking.slashNode(msg.sender, slashAmount);
        _distributeSlashFunds(address(0), msg.sender, totalSlashed);

        require(!forcedOrderExit, "quit caused forced exit");

        emit NodeQuit(_orderId, msg.sender, slashAmount);
    }

    // External slashing function (for challenges/penalties)
    function slashNode(address _node, uint256 _slashAmount, string calldata _reason)
        external
        onlySlashAuthority
        nonReentrant
    {
        require(_slashAmount > 0, "invalid slash amount");

        // No reporter reward for authority slashes
        (bool forcedOrderExit, uint256 totalSlashed) = nodeStaking.slashNode(_node, _slashAmount);
        _distributeSlashFunds(address(0), _node, totalSlashed);

        if (forcedOrderExit) {
            _handleForcedOrderExits(_node);
        }

        emit NodeSlashed(_node, _slashAmount, _reason);
    }

    // Internal function to handle forced order exits due to capacity reduction
    function _handleForcedOrderExits(address _node) internal {
        uint256[] storage nodeOrders = nodeToOrders[_node];
        uint256[] memory exitedOrders = new uint256[](nodeOrders.length);
        uint256 exitCount = 0;

        // Get node's new capacity and previous usage after slashing
        (, uint64 newCapacity, uint64 usedBefore,,) = nodeStaking.getNodeInfo(_node);
        uint64 totalFreed = 0;
        uint256 settlePeriod = currentPeriod();

        // Remove node from all its orders (starting from the end to avoid index issues)
        uint256 i = nodeOrders.length;
        while (i > 0) {
            i--;
            uint256 exitOrderId = nodeOrders[i];
            uint64 freed = _removeAssignmentDuringForcedExit(_node, exitOrderId, settlePeriod);

            if (freed > 0) {
                totalFreed += freed;
                exitedOrders[exitCount++] = exitOrderId;
            }
        }

        // Clear node's order list
        delete nodeToOrders[_node];

        uint64 newUsed = usedBefore > totalFreed ? usedBefore - totalFreed : 0;
        if (newUsed > newCapacity) {
            newUsed = newCapacity;
        }

        // Update node's used capacity to match the data that remains
        // Skip if node was fully slashed (capacity already 0, used already set by slashNode)
        if (newCapacity > 0 || nodeStaking.isValidNode(_node)) {
            nodeStaking.forceReduceUsed(_node, newUsed);
        }

        // Resize the exited orders array to actual count
        uint256[] memory actualExitedOrders = new uint256[](exitCount);
        for (uint256 idx = 0; idx < exitCount; idx++) {
            actualExitedOrders[idx] = exitedOrders[idx];
        }

        emit ForcedOrderExits(_node, actualExitedOrders, totalFreed);
    }

    function _removeAssignmentDuringForcedExit(address _node, uint256 _orderId, uint256 _settlePeriod)
        internal
        returns (uint64 freed)
    {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) {
            return 0;
        }

        address[] storage assignedNodes = orderToNodes[_orderId];
        for (uint256 j = 0; j < assignedNodes.length; j++) {
            if (assignedNodes[j] == _node) {
                uint256 settledReward = _settleOrderReward(_node, _orderId, _settlePeriod);
                if (settledReward > 0) {
                    nodePendingRewards[_node] += settledReward;
                }
                delete nodeOrderStartTimestamp[_node][_orderId];
                delete nodeOrderEarnings[_orderId][_node];

                if (j != assignedNodes.length - 1) {
                    assignedNodes[j] = assignedNodes[assignedNodes.length - 1];
                }
                assignedNodes.pop();
                order.filled--;

                // Last node removed — order no longer challengeable
                if (assignedNodes.length == 0 && isChallengeable[_orderId]) {
                    _removeFromChallengeableOrders(_orderId);
                }

                if (order.filled < order.replicas) {
                    emit OrderUnderReplicated(_orderId, order.filled, order.replicas);
                }

                return order.maxSize;
            }
        }

        return 0;
    }

    // Helper function to remove node from a single order
    function _removeNodeFromOrder(address _node, uint256 _orderId, uint256 _nodeIndex) internal {
        FileOrder storage order = orders[_orderId];
        address[] storage assignedNodes = orderToNodes[_orderId];
        uint256 settlePeriod = currentPeriod();

        uint256 settledReward = _settleOrderReward(_node, _orderId, settlePeriod);
        if (settledReward > 0) {
            nodePendingRewards[_node] += settledReward;
        }
        delete nodeOrderStartTimestamp[_node][_orderId];
        delete nodeOrderEarnings[_orderId][_node];

        // Remove node from order assignments
        if (_nodeIndex != assignedNodes.length - 1) {
            assignedNodes[_nodeIndex] = assignedNodes[assignedNodes.length - 1];
        }
        assignedNodes.pop();
        order.filled--;

        // Last node removed — order no longer challengeable
        if (assignedNodes.length == 0 && isChallengeable[_orderId]) {
            _removeFromChallengeableOrders(_orderId);
        }

        if (order.filled < order.replicas) {
            emit OrderUnderReplicated(_orderId, order.filled, order.replicas);
        }

        // Free up node capacity
        (,, uint64 used,,) = nodeStaking.getNodeInfo(_node);
        nodeStaking.updateNodeUsed(_node, used - order.maxSize);

        // Remove order from node's order list
        _removeOrderFromNode(_node, _orderId);
    }

    // Internal helper to remove order from node's order list
    function _removeOrderFromNode(address _node, uint256 _orderId) internal {
        uint256[] storage nodeOrders = nodeToOrders[_node];
        for (uint256 i = 0; i < nodeOrders.length; i++) {
            if (nodeOrders[i] == _orderId) {
                if (i != nodeOrders.length - 1) {
                    nodeOrders[i] = nodeOrders[nodeOrders.length - 1];
                }
                nodeOrders.pop();
                break;
            }
        }
    }

    function _settleAndReleaseNodes(FileOrder storage order, uint256 _orderId, uint256 _settlePeriod)
        internal
        returns (uint256 totalSettled, uint256 initialAssignments)
    {
        address[] storage assignedNodes = orderToNodes[_orderId];
        initialAssignments = assignedNodes.length;
        while (assignedNodes.length > 0) {
            address node = assignedNodes[assignedNodes.length - 1];
            uint256 settledReward = _settleOrderReward(node, _orderId, _settlePeriod);
            if (settledReward > 0) {
                nodePendingRewards[node] += settledReward;
                totalSettled += settledReward;
            }
            delete nodeOrderStartTimestamp[node][_orderId];
            delete nodeOrderEarnings[_orderId][node];

            (,, uint64 used,,) = nodeStaking.getNodeInfo(node);
            nodeStaking.updateNodeUsed(node, used - order.maxSize);

            assignedNodes.pop();
            if (order.filled > 0) {
                order.filled--;
            }
            _removeOrderFromNode(node, _orderId);
        }
    }

    // Node reward system

    /// @notice Calculate and claim accumulated rewards for a node from order escrows
    function claimRewards() external nonReentrant {
        address node = msg.sender;

        uint256 activeClaimable = _settleActiveOrders(node);
        uint256 pendingClaimable = nodePendingRewards[node];

        if (pendingClaimable > 0) {
            nodePendingRewards[node] = 0;
        }

        uint256 totalClaimable = activeClaimable + pendingClaimable;
        require(totalClaimable > 0, "no rewards to claim");

        nodeLastClaimPeriod[node] = currentPeriod();
        nodeWithdrawn[node] += totalClaimable;

        (bool success,) = node.call{value: totalClaimable}("");
        require(success, "transfer failed");

        emit RewardsClaimed(node, totalClaimable);
    }

    /// @notice Settle rewards for active orders and return the total amount accrued
    function _settleActiveOrders(address _node) internal returns (uint256 totalClaimable) {
        uint256[] storage nodeOrders = nodeToOrders[_node];
        if (nodeOrders.length == 0) {
            return 0;
        }

        uint256 currentPer = currentPeriod();

        for (uint256 i = 0; i < nodeOrders.length; i++) {
            uint256 orderId = nodeOrders[i];
            uint256 settled = _settleOrderReward(_node, orderId, currentPer);
            if (settled > 0) {
                totalClaimable += settled;
            }
        }
    }

    /// @notice View function to check claimable rewards from order escrows
    function getClaimableRewards(address _node) external view returns (uint256 claimable) {
        uint256[] storage nodeOrders = nodeToOrders[_node];
        uint256 currentPer = currentPeriod();

        for (uint256 i = 0; i < nodeOrders.length; i++) {
            claimable += _calculateOrderClaimableUpTo(_node, nodeOrders[i], currentPer);
        }

        claimable += nodePendingRewards[_node];
    }

    /// @notice Calculate claimable earnings for a node/order pair up to a target period
    function _calculateOrderClaimableUpTo(address _node, uint256 _orderId, uint256 _settlePeriod)
        internal
        view
        returns (uint256)
    {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) return 0;

        // Derive effective start period via ceiling division so nodes only earn
        // for periods they were assigned for the ENTIRE duration, preventing
        // boundary-sniping (joining 1 second before a period flip for a full payout).
        uint256 startTs = nodeOrderStartTimestamp[_node][_orderId];
        uint256 elapsed = startTs - GENESIS_TS;
        uint256 nodeStartPeriod = (elapsed + PERIOD - 1) / PERIOD;

        uint256 orderEndPeriod = order.startPeriod + order.periods;
        uint256 storageEndPeriod = _settlePeriod > orderEndPeriod ? orderEndPeriod : _settlePeriod;
        if (storageEndPeriod <= nodeStartPeriod) return 0;

        uint256 storagePeriods = storageEndPeriod - nodeStartPeriod;
        uint256 totalEarnable = uint256(order.maxSize) * order.price * storagePeriods;
        uint256 alreadyEarned = nodeOrderEarnings[_orderId][_node];
        if (totalEarnable <= alreadyEarned) return 0;

        uint256 newEarnings = totalEarnable - alreadyEarned;
        uint256 availableEscrow = order.escrow - orderEscrowWithdrawn[_orderId];
        return newEarnings > availableEscrow ? availableEscrow : newEarnings;
    }

    /// @notice Apply reward settlement for a node/order pair and return the credited amount
    function _settleOrderReward(address _node, uint256 _orderId, uint256 _settlePeriod)
        internal
        returns (uint256 claimableFromOrder)
    {
        claimableFromOrder = _calculateOrderClaimableUpTo(_node, _orderId, _settlePeriod);
        if (claimableFromOrder == 0) {
            return 0;
        }

        nodeOrderEarnings[_orderId][_node] += claimableFromOrder;
        orderEscrowWithdrawn[_orderId] += claimableFromOrder;
        aggregateActiveWithdrawn += claimableFromOrder;
        lifetimeRewardsPaid += claimableFromOrder;
        nodeEarnings[_node] += claimableFromOrder;
    }

    /// @notice Distribute slashed funds: reporter gets a percentage, rest is burned
    /// @param reporter The address that reported the failure (address(0) for no reward)
    /// @param slashedNode The address of the node being slashed (reporter reward skipped if same as reporter)
    /// @param totalSlashed The total slashed amount received from NodeStaking
    function _distributeSlashFunds(address reporter, address slashedNode, uint256 totalSlashed) internal {
        if (totalSlashed == 0) return;

        totalSlashedReceived += totalSlashed;

        uint256 reporterReward = 0;
        if (reporter != address(0) && reporter != slashedNode) {
            reporterReward = totalSlashed * reporterRewardBps / 10000;
            if (reporterReward > 0) {
                reporterPendingRewards[reporter] += reporterReward;
                reporterEarnings[reporter] += reporterReward;
                totalReporterRewards += reporterReward;
                emit ReporterRewardAccrued(reporter, reporterReward, totalSlashed);
            }
        }

        uint256 burnAmount = totalSlashed - reporterReward;
        totalBurnedFromSlash += burnAmount;
        if (burnAmount > 0) {
            payable(address(0)).transfer(burnAmount);
        }
    }

    /// @notice Distribute early-cancellation penalty to the nodes that were serving the order
    function _distributeCancellationPenalty(uint256 _orderId, uint256 _penalty, address[] memory _nodes) internal {
        uint256 count = _nodes.length;
        uint256 perNode = _penalty / count;
        uint256 distributed = 0;

        for (uint256 i = 0; i < count; i++) {
            // Last node receives the remainder to avoid rounding dust
            uint256 share = (i == count - 1) ? _penalty - distributed : perNode;
            nodePendingRewards[_nodes[i]] += share;
            nodeEarnings[_nodes[i]] += share;
            distributed += share;
        }

        totalCancellationPenalties += _penalty;
        emit CancellationPenaltyDistributed(_orderId, _penalty, count);
    }
}
