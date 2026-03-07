// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketHelpers} from "./MarketHelpers.sol";

/// @notice Order lifecycle, assignment, settlement, and slashing mechanics.
abstract contract MarketOrders is MarketHelpers {
    // Place a new file storage order with ZK-verified file size
    function placeOrder(
        FileMeta calldata _file,
        uint32 _numChunks,
        uint16 _periods,
        uint8 _replicas,
        uint256 _pricePerChunkPerPeriod,
        uint256[8] calldata _fspProof
    ) external payable nonReentrant returns (uint256 orderId) {
        require(_file.root > 0 && _file.root < SNARK_SCALAR_FIELD, "root not in Fr");
        require(_numChunks > 0, "invalid size");
        require(_periods > 0, "invalid periods");
        require(_replicas > 0 && _replicas <= MAX_REPLICAS, "invalid replicas");
        require(_pricePerChunkPerPeriod > 0, "invalid price");

        // Verify file size proof: proves numChunks is the exact boundary in the SMT
        uint256[2] memory fspInputs = [_file.root, uint256(_numChunks)];
        fspVerifier.verifyProof(_fspProof, fspInputs);

        uint256 totalCost = uint256(_numChunks) * uint256(_periods) * _pricePerChunkPerPeriod * uint256(_replicas);
        require(msg.value >= totalCost, "insufficient payment");

        orderId = nextOrderId++;

        orders[orderId] = FileOrder({
            owner: msg.sender,
            file: _file,
            numChunks: _numChunks,
            periods: _periods,
            replicas: _replicas,
            price: _pricePerChunkPerPeriod,
            filled: 0,
            startPeriod: uint64(currentPeriod()),
            escrow: totalCost
        });

        // Add to active orders for random selection
        activeOrders.push(orderId);
        orderIndexInActive[orderId] = activeOrders.length - 1;

        aggregateActiveEscrow += totalCost;
        lifetimeEscrowDeposited += totalCost;

        emit OrderPlaced(orderId, msg.sender, _numChunks, _periods, _replicas);

        // Queue excess payment as pull-refund
        if (msg.value > totalCost) {
            uint256 excess = msg.value - totalCost;
            pendingRefunds[msg.sender] += excess;
            emit RefundQueued(msg.sender, excess);
        }
    }

    // Node executes an order (claims a replica slot) with PoI proof of data possession
    function executeOrder(uint256 _orderId, uint256[8] calldata _proof, bytes32 _commitment)
        external
        nonReentrant
    {
        require(nodeStaking.isValidNode(msg.sender), "not a valid node");

        FileOrder storage order = orders[_orderId];
        require(order.owner != address(0), "order does not exist");
        require(!isOrderExpired(_orderId), "order expired");
        require(order.filled < order.replicas, "order already filled");
        require(nodeStaking.hasCapacity(msg.sender, order.numChunks), "insufficient capacity");

        // Check if node is already assigned to this order
        address[] storage assignedNodes = orderToNodes[_orderId];
        for (uint256 i = 0; i < assignedNodes.length; i++) {
            require(assignedNodes[i] != msg.sender, "already assigned to this order");
        }

        // Enforce per-node order cap to bound forced-exit iteration
        require(nodeToOrders[msg.sender].length < MAX_ORDERS_PER_NODE, "max orders per node reached");

        // Verify PoI proof — node must prove data possession before claiming slot
        (,,, uint256 publicKey) = nodeStaking.getNodeInfo(msg.sender);
        require(publicKey != 0, "node public key not set");
        uint256 randomness = uint256(keccak256(abi.encodePacked(order.file.root, publicKey))) % SNARK_SCALAR_FIELD;
        uint256[4] memory publicInputs = [uint256(_commitment), randomness, publicKey, order.file.root];
        poiVerifier.verifyProof(_proof, publicInputs);

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
        (,, uint64 used,) = nodeStaking.getNodeInfo(msg.sender);
        nodeStaking.updateNodeUsed(msg.sender, used + order.numChunks);

        emit OrderFulfilled(_orderId, msg.sender);

        // Order stays active until periods expire, not when filled
    }

    // Get active orders count
    function getActiveOrdersCount() external view returns (uint256) {
        return activeOrders.length;
    }

    // Get a paginated slice of active order IDs
    function getActiveOrdersPage(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds, uint256 total)
    {
        total = activeOrders.length;
        if (offset >= total) {
            return (new uint256[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;
        orderIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            orderIds[i] = activeOrders[offset + i];
        }
    }

    // Get challengeable orders count
    function getChallengeableOrdersCount() external view returns (uint256) {
        return challengeableOrders.length;
    }

    // Get a paginated slice of challengeable order IDs
    function getChallengeableOrdersPage(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds, uint256 total)
    {
        total = challengeableOrders.length;
        if (offset >= total) {
            return (new uint256[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;
        orderIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            orderIds[i] = challengeableOrders[offset + i];
        }
    }

    // Get nodes assigned to an order
    function getOrderNodes(uint256 _orderId) external view returns (address[] memory) {
        return orderToNodes[_orderId];
    }

    // Get orders assigned to a node
    function getNodeOrders(address _node) external view returns (uint256[] memory) {
        return nodeToOrders[_node];
    }

    // Complete expired orders and free up node capacity
    function completeExpiredOrder(uint256 _orderId) external nonReentrant {
        FileOrder storage order = orders[_orderId];
        require(order.owner != address(0), "order does not exist");
        require(currentPeriod() >= uint256(order.startPeriod) + uint256(order.periods), "order not expired");
        require(!_isOrderUnderActiveChallenge(_orderId), "order under active challenge");

        uint256 settlePeriod = order.startPeriod + order.periods;
        _settleAndReleaseNodes(order, _orderId, settlePeriod);

        // Remove from active orders and clean up
        _removeFromActiveOrders(_orderId);
        uint256 escrow = order.escrow;
        uint256 withdrawn = orderEscrowWithdrawn[_orderId];
        uint256 refundAmount = escrow - withdrawn;
        address orderOwner = order.owner;

        // Update aggregates before delete zeroes the struct
        aggregateActiveEscrow -= escrow;
        aggregateActiveWithdrawn -= withdrawn;

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
        require(currentPeriod() < uint256(order.startPeriod) + uint256(order.periods), "order already expired");
        require(!_isOrderUnderActiveChallenge(_orderId), "order under active challenge");

        // Snapshot assigned nodes before settlement empties the array
        address[] memory assignedNodes = orderToNodes[_orderId];

        // Identify nodes eligible for cancellation penalty (served >= 1 full period).
        uint256 settlePeriod = currentPeriod();
        uint256 eligibleCount = 0;
        address[] memory eligibleNodes = new address[](assignedNodes.length);
        for (uint256 i = 0; i < assignedNodes.length; i++) {
            uint256 startTs = nodeOrderStartTimestamp[assignedNodes[i]][_orderId];
            uint256 elapsed = startTs - genesisTs;
            uint256 nodeStartPeriod = (elapsed + PERIOD - 1) / PERIOD;
            if (settlePeriod > nodeStartPeriod) {
                eligibleNodes[eligibleCount] = assignedNodes[i];
                eligibleCount++;
            }
        }

        _settleAndReleaseNodes(order, _orderId, settlePeriod);

        // Clean up order data
        uint256 escrow = order.escrow;
        uint256 withdrawn = orderEscrowWithdrawn[_orderId];
        uint256 remainingEscrow = escrow - withdrawn;
        uint256 refundAmount = remainingEscrow;
        if (eligibleCount > 0 && remainingEscrow > 0) {
            // Scaled cancellation penalty: 25% at start → 5% near end
            uint256 elapsedPeriods = settlePeriod - order.startPeriod;
            uint256 penaltyRange = CANCEL_PENALTY_MAX_BPS - CANCEL_PENALTY_MIN_BPS; // 2000
            uint256 penaltyBps = CANCEL_PENALTY_MAX_BPS - (penaltyRange * elapsedPeriods / order.periods);
            uint256 penalty = remainingEscrow * penaltyBps / 10000;
            refundAmount -= penalty;

            // Distribute penalty only to nodes that actually served
            assembly {
                mstore(eligibleNodes, eligibleCount)
            }
            _distributeCancellationPenalty(_orderId, penalty, eligibleNodes);
        }

        _removeFromActiveOrders(_orderId);

        // Update aggregates before delete zeroes the struct
        aggregateActiveEscrow -= escrow;
        aggregateActiveWithdrawn -= withdrawn;

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
        require(currentPeriod() < uint256(order.startPeriod) + uint256(order.periods), "order already expired");
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

        // Calculate slash amount using scaled quit penalty formula
        uint256 remainingPeriods = (order.startPeriod + order.periods) - currentPeriod();
        uint256 slashPeriods;
        if (remainingPeriods <= QUIT_SLASH_BASE_PERIODS) {
            slashPeriods = remainingPeriods; // full remaining if short
        } else {
            slashPeriods =
                QUIT_SLASH_BASE_PERIODS + (remainingPeriods - QUIT_SLASH_BASE_PERIODS) / QUIT_SLASH_EXCESS_DIVISOR;
        }
        uint256 slashAmount = uint256(order.numChunks) * order.price * slashPeriods;

        // Cap to available stake to prevent revert.
        (uint256 nodeStake,, uint64 usedBeforeQuit,) = nodeStaking.getNodeInfo(msg.sender);
        if (slashAmount > nodeStake) {
            slashAmount = nodeStake;
        }
        require(usedBeforeQuit >= order.numChunks, "invalid node usage");

        uint64 usedAfterQuit = usedBeforeQuit - order.numChunks;
        uint256 requiredStakeAfterQuit = uint256(usedAfterQuit) * STAKE_PER_CHUNK;
        uint256 maxSafeSlash = nodeStake > requiredStakeAfterQuit ? nodeStake - requiredStakeAfterQuit : 0;
        if (slashAmount > maxSafeSlash) {
            slashAmount = maxSafeSlash;
        }

        // Remove the specific assignment
        _removeNodeFromOrder(msg.sender, _orderId, nodeIndex);

        // Apply slash to node's stake (no reporter reward or client comp for voluntary quit)
        (bool forcedOrderExit, uint256 totalSlashed) = nodeStaking.slashNode(msg.sender, slashAmount);
        _distributeSlashFunds(address(0), msg.sender, totalSlashed, 0);

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
        _distributeSlashFunds(address(0), _node, totalSlashed, 0);

        if (forcedOrderExit) {
            _handleForcedOrderExits(_node);
        }

        emit NodeSlashed(_node, _slashAmount, _reason);
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
}
