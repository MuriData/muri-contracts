// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Verifier} from "muri-artifacts/poi_verifier.sol";
import {NodeStaking} from "./NodeStaking.sol";

contract FileMarket {
    uint256 constant PERIOD = 7 days; // single billing unit
    uint256 constant EPOCH = 4 * PERIOD;
    uint256 constant STEP = 30 seconds; // proof submission period
    uint256 constant QUIT_SLASH_PERIODS = 3; // periods of storage cost charged on voluntary quit
    uint256 constant MAX_ORDERS_PER_NODE = 50; // cap orders per node to bound forced-exit iteration
    uint8 constant MAX_REPLICAS = 10; // cap replicas per order to bound settlement loop gas
    uint256 constant CLEANUP_BATCH_SIZE = 10; // expired orders processed per cleanup call
    uint256 constant CLEANUP_SCAN_CAP = 50; // max entries scanned per _cleanupExpiredOrders call
    uint256 immutable GENESIS_TS; // contract deploy timestamp
    address public owner;
    mapping(address => bool) public slashAuthorities;
    uint256 private _marketLock = 1;

    constructor() {
        GENESIS_TS = block.timestamp;
        owner = msg.sender;
        nodeStaking = new NodeStaking(address(this));
        poiVerifier = new Verifier();
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlySlashAuthority() {
        require(msg.sender == owner || slashAuthorities[msg.sender], "not authorized");
        _;
    }

    modifier nonReentrant() {
        require(_marketLock == 1, "reentrant");
        _marketLock = 2;
        _;
        _marketLock = 1;
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SlashAuthorityUpdated(address indexed authority, bool allowed);

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "invalid owner");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    function setSlashAuthority(address _authority, bool _allowed) external onlyOwner {
        slashAuthorities[_authority] = _allowed;
        emit SlashAuthorityUpdated(_authority, _allowed);
    }

    function currentPeriod() public view returns (uint256) {
        return (block.timestamp - GENESIS_TS) / PERIOD;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - GENESIS_TS) / EPOCH;
    }

    function currentStep() public view returns (uint256) {
        return (block.timestamp - GENESIS_TS) / STEP;
    }

    struct FileMeta {
        uint256 root; // Merkle root hash of the file for POI verification
        string uri;
    }

    struct FileOrder {
        address owner;
        FileMeta file;
        uint64 maxSize; // bytes the client is willing to pay for
        uint16 periods; // billing periods to store
        uint8 replicas; // desired redundancy
        uint256 price; // wei / byte / period (quoting module can update global price curves)
        uint8 filled; // replica slots already taken
        uint64 startPeriod; // when storage begins
        uint256 escrow; // prepaid funds held in contract
    }

    // Staking contract for managing node stakes and capacity
    NodeStaking public immutable nodeStaking;

    // Proof of Integrity verifier contract
    Verifier public immutable poiVerifier;

    // Order management
    uint256 public nextOrderId = 1;
    mapping(uint256 => FileOrder) public orders;
    uint256[] public activeOrders; // Array of active order IDs for random selection
    mapping(uint256 => uint256) public orderIndexInActive; // Maps order ID to its index in activeOrders
    uint256[] public challengeableOrders; // Orders with >= 1 assigned node, used for heartbeat sampling
    mapping(uint256 => uint256) public orderIndexInChallengeable; // Maps order ID to index in challengeableOrders
    mapping(uint256 => bool) public isChallengeable; // Whether order is currently in challengeableOrders

    // Node assignments
    mapping(uint256 => address[]) public orderToNodes; // order ID -> assigned nodes
    mapping(address => uint256[]) public nodeToOrders; // node -> assigned order IDs

    // Node rewards system
    mapping(address => uint256) public nodePendingRewards; // rewards owed after assignment removal
    mapping(address => uint256) public nodeEarnings; // total earnings accumulated
    mapping(address => uint256) public nodeWithdrawn; // total amount withdrawn
    mapping(address => uint256) public nodeLastClaimPeriod; // last period when rewards were claimed
    mapping(address => mapping(uint256 => uint256)) public nodeOrderStartTimestamp; // node -> orderId -> block.timestamp when assigned

    // Escrow tracking for proper payment distribution
    mapping(uint256 => uint256) public orderEscrowWithdrawn; // orderId -> amount already paid to nodes
    mapping(uint256 => mapping(address => uint256)) public nodeOrderEarnings; // orderId -> node -> earned amount

    // Reporter reward system for slash redistribution
    uint256 public reporterRewardBps = 1000; // 10% default (basis points)
    uint256 public constant MAX_REPORTER_REWARD_BPS = 5000; // cap at 50%
    mapping(address => uint256) public reporterPendingRewards;
    mapping(address => uint256) public reporterEarnings;
    mapping(address => uint256) public reporterWithdrawn;
    uint256 public totalSlashedReceived;
    uint256 public totalBurnedFromSlash;
    uint256 public totalReporterRewards;

    // Proof system - stateless rolling challenges
    uint256 public currentRandomness; // current heartbeat randomness
    uint256 public lastChallengeStep; // last step when challenge was issued
    address public currentPrimaryProver; // current primary prover
    address[] public currentSecondaryProvers; // current secondary provers
    uint256[] public currentChallengedOrders; // current orders being challenged
    uint256 public constant CHALLENGE_COUNT = 5; // orders to challenge per heartbeat
    uint256 public constant SECONDARY_ALPHA = 2; // alpha multiplier for secondary provers
    uint256 internal constant SNARK_SCALAR_FIELD = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    // Proof submission tracking (reset each heartbeat)
    mapping(address => bool) public proofSubmitted; // current round proof submissions
    mapping(address => uint256) public nodeToProveOrderId; // node -> order they're proving (current challenge)
    bool public primaryProofReceived; // primary proof received for current challenge
    bool public primaryFailureReported; // primary failure already reported for current step
    bool public secondarySlashProcessed; // secondary slashing already handled for current challenge

    // Cleanup cursor for amortised expired-order scanning
    uint256 public cleanupCursor;

    // Cancellation penalty tracking (placed after proof system to preserve storage layout)
    uint256 public totalCancellationPenalties; // total early-cancellation penalties distributed to nodes

    // Pull-payment refunds (placed after totalCancellationPenalties to preserve storage layout)
    mapping(address => uint256) public pendingRefunds;

    // Challenge initialization flag (placed at end to preserve storage layout)
    bool public challengeInitialized; // true after the first heartbeat has been issued

    // Deferred randomness from primary proof submission (applied at next heartbeat start)
    uint256 public pendingRandomness;

    // Incremental escrow aggregates for O(1) stats (placed at end to preserve storage layout)
    uint256 public aggregateActiveEscrow; // sum of order.escrow for all non-deleted orders
    uint256 public aggregateActiveWithdrawn; // sum of orderEscrowWithdrawn for all non-deleted orders

    // Events
    event OrderPlaced(uint256 indexed orderId, address indexed owner, uint64 maxSize, uint16 periods, uint8 replicas);
    event OrderFulfilled(uint256 indexed orderId, address indexed node);
    event OrderCompleted(uint256 indexed orderId);
    event OrderCancelled(uint256 indexed orderId, uint256 refundAmount);
    event NodeQuit(uint256 indexed orderId, address indexed node, uint256 slashAmount);
    event NodeSlashed(address indexed node, uint256 slashAmount, string reason);
    event ForcedOrderExits(address indexed node, uint256[] orderIds, uint64 totalFreed);
    event RewardsCalculated(address indexed node, uint256 amount, uint256 periods);
    event RewardsClaimed(address indexed node, uint256 amount);
    event ChallengeIssued(
        uint256 randomness, address primaryProver, address[] secondaryProvers, uint256[] orderIds, uint256 challengeStep
    );
    event ProofSubmitted(address indexed prover, bool isPrimary, bytes32 commitment);
    event PrimaryProverFailed(address indexed primaryProver, address indexed reporter, uint256 newRandomness);
    event HeartbeatTriggered(uint256 newRandomness, uint256 step);
    event ReporterRewardAccrued(address indexed reporter, uint256 rewardAmount, uint256 slashedAmount);
    event ReporterRewardsClaimed(address indexed reporter, uint256 amount);
    event ReporterRewardBpsUpdated(uint256 oldBps, uint256 newBps);
    event CancellationPenaltyDistributed(uint256 indexed orderId, uint256 penaltyAmount, uint256 nodeCount);
    event RefundQueued(address indexed recipient, uint256 amount);
    event RefundWithdrawn(address indexed recipient, uint256 amount);
    event OrderUnderReplicated(uint256 indexed orderId, uint8 currentFilled, uint8 desiredReplicas);

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

        uint256 settlePeriod = currentPeriod();
        _settleAndReleaseNodes(order, _orderId, settlePeriod);

        // Clean up order data
        uint256 remainingEscrow = order.escrow - orderEscrowWithdrawn[_orderId];
        uint256 refundAmount = remainingEscrow;
        if (assignedNodes.length > 0 && remainingEscrow > 0) {
            uint256 penalty = remainingEscrow / 10; // 10% penalty
            refundAmount -= penalty;

            // Distribute penalty to nodes that were serving this order
            _distributeCancellationPenalty(_orderId, penalty, assignedNodes);
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

        // Cap to available stake to prevent revert
        (uint256 nodeStake,,,,) = nodeStaking.getNodeInfo(msg.sender);
        if (slashAmount > nodeStake) {
            slashAmount = nodeStake;
        }

        // Apply slash to node's stake (no reporter reward for voluntary quit)
        (bool forcedOrderExit, uint256 totalSlashed) = nodeStaking.slashNode(msg.sender, slashAmount);
        _distributeSlashFunds(address(0), msg.sender, totalSlashed);

        // If slashing caused forced order exits, handle them
        if (forcedOrderExit) {
            _handleForcedOrderExits(msg.sender);
        } else {
            // Normal quit - just remove this order
            _removeNodeFromOrder(msg.sender, _orderId, nodeIndex);
        }

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

    // Get order details including expiration status

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
        nodeEarnings[_node] += claimableFromOrder;
    }

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

        // Select random orders for challenge from challengeable orders only (orders with assigned nodes)
        uint256[] memory selectedOrders = _selectFromArray(challengeableOrders, currentRandomness, selectionCount);

        // Filter out any expired orders that slipped past the capped cleanup pass,
        // evicting them from challengeableOrders so future heartbeats won't re-select them.
        uint256 validCount = 0;
        for (uint256 i = 0; i < selectedOrders.length; i++) {
            if (!isOrderExpired(selectedOrders[i])) {
                selectedOrders[validCount] = selectedOrders[i];
                validCount++;
            } else {
                _removeFromChallengeableOrders(selectedOrders[i]);
            }
        }
        assembly {
            mstore(selectedOrders, validCount)
        }

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

    /// @notice Get node earnings info
    function getNodeEarningsInfo(address _node)
        external
        view
        returns (uint256 totalEarned, uint256 withdrawn, uint256 claimable, uint256 lastClaimPeriod)
    {
        totalEarned = nodeEarnings[_node];
        withdrawn = nodeWithdrawn[_node];
        claimable = this.getClaimableRewards(_node);
        lastClaimPeriod = nodeLastClaimPeriod[_node];
    }

    /// @notice Get current challenge info
    function getCurrentChallengeInfo()
        external
        view
        returns (
            uint256 randomness,
            uint256 challengeStep,
            address primaryProver,
            address[] memory secondaryProvers,
            uint256[] memory challengedOrders,
            bool primarySubmitted,
            bool challengeActive
        )
    {
        randomness = currentRandomness;
        challengeStep = lastChallengeStep;
        primaryProver = currentPrimaryProver;
        secondaryProvers = currentSecondaryProvers;
        challengedOrders = currentChallengedOrders;
        primarySubmitted = primaryProofReceived;
        challengeActive = (currentStep() <= lastChallengeStep + 1) && challengeInitialized;
    }

    /// @notice Check if a node has submitted proof for current challenge
    function hasSubmittedProof(address _node) external view returns (bool) {
        return proofSubmitted[_node];
    }

    /// @notice Check if challenge period has expired
    function isChallengeExpired() external view returns (bool) {
        return currentStep() > lastChallengeStep + 1;
    }

    /// @notice Get order escrow info
    function getOrderEscrowInfo(uint256 _orderId)
        external
        view
        returns (uint256 totalEscrow, uint256 paidToNodes, uint256 remainingEscrow)
    {
        FileOrder storage order = orders[_orderId];
        totalEscrow = order.escrow;
        paidToNodes = orderEscrowWithdrawn[_orderId];
        remainingEscrow = totalEscrow > paidToNodes ? totalEscrow - paidToNodes : 0;
    }

    /// @notice Get node's earnings from a specific order
    function getNodeOrderEarnings(address _node, uint256 _orderId) external view returns (uint256) {
        return nodeOrderEarnings[_orderId][_node];
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

    /// @notice Claim accumulated reporter rewards
    function claimReporterRewards() external nonReentrant {
        uint256 amount = reporterPendingRewards[msg.sender];
        require(amount > 0, "no reporter rewards");

        reporterPendingRewards[msg.sender] = 0;
        reporterWithdrawn[msg.sender] += amount;

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "transfer failed");

        emit ReporterRewardsClaimed(msg.sender, amount);
    }

    /// @notice Set the reporter reward percentage (in basis points)
    /// @param _newBps New reward percentage in basis points (max 5000 = 50%)
    function setReporterRewardBps(uint256 _newBps) external onlyOwner {
        require(_newBps <= MAX_REPORTER_REWARD_BPS, "exceeds max bps");
        uint256 oldBps = reporterRewardBps;
        reporterRewardBps = _newBps;
        emit ReporterRewardBpsUpdated(oldBps, _newBps);
    }

    /// @notice Get reporter earnings info
    function getReporterEarningsInfo(address _reporter)
        external
        view
        returns (uint256 earned, uint256 withdrawn, uint256 pending)
    {
        earned = reporterEarnings[_reporter];
        withdrawn = reporterWithdrawn[_reporter];
        pending = reporterPendingRewards[_reporter];
    }

    /// @notice Get slash redistribution statistics
    function getSlashRedistributionStats()
        external
        view
        returns (uint256 totalReceived, uint256 totalBurned, uint256 totalRewards, uint256 currentBps)
    {
        totalReceived = totalSlashedReceived;
        totalBurned = totalBurnedFromSlash;
        totalRewards = totalReporterRewards;
        currentBps = reporterRewardBps;
    }

    /// @notice Withdraw accumulated pull-payment refunds
    function withdrawRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        require(amount > 0, "no refund");
        pendingRefunds[msg.sender] = 0;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "transfer failed");
        emit RefundWithdrawn(msg.sender, amount);
    }

    /// @notice Allow contract to receive ETH from slashed nodes
    receive() external payable {}

    // =============================================================================
    // NETWORK MONITORING FUNCTIONS FOR WEB DASHBOARD
    // =============================================================================

    /// @notice Get comprehensive global marketplace statistics
    function getGlobalStats()
        external
        view
        returns (
            uint256 totalOrders,
            uint256 activeOrdersCount,
            uint256 totalEscrowLocked,
            uint256 totalNodes,
            uint256 totalCapacityStaked,
            uint256 totalCapacityUsed,
            uint256 currentRandomnessValue,
            uint256 lastHeartbeatStep,
            uint256 currentPeriod_,
            uint256 currentStep_,
            uint256 challengeableOrdersCount
        )
    {
        totalOrders = nextOrderId - 1;
        activeOrdersCount = activeOrders.length;
        challengeableOrdersCount = challengeableOrders.length;

        totalEscrowLocked = aggregateActiveEscrow - aggregateActiveWithdrawn;

        // Get node network statistics (O(1) via incremental aggregates)
        (totalNodes, totalCapacityStaked, totalCapacityUsed) = nodeStaking.getNetworkStats();

        currentRandomnessValue = currentRandomness;
        lastHeartbeatStep = lastChallengeStep;
        currentPeriod_ = currentPeriod();
        currentStep_ = currentStep();
    }

    /// @notice Get recent order activity for dashboard
    function getRecentOrders(uint256 count)
        external
        view
        returns (
            uint256[] memory orderIds,
            address[] memory owners,
            uint64[] memory sizes,
            uint16[] memory periods,
            uint8[] memory replicas,
            uint8[] memory filled,
            uint256[] memory escrows,
            bool[] memory isActive
        )
    {
        uint256 totalOrders = nextOrderId - 1;
        uint256 returnCount = count > totalOrders ? totalOrders : count;
        if (returnCount == 0) {
            return (
                new uint256[](0),
                new address[](0),
                new uint64[](0),
                new uint16[](0),
                new uint8[](0),
                new uint8[](0),
                new uint256[](0),
                new bool[](0)
            );
        }

        orderIds = new uint256[](returnCount);
        owners = new address[](returnCount);
        sizes = new uint64[](returnCount);
        periods = new uint16[](returnCount);
        replicas = new uint8[](returnCount);
        filled = new uint8[](returnCount);
        escrows = new uint256[](returnCount);
        isActive = new bool[](returnCount);

        uint256 currentPer = currentPeriod();

        for (uint256 idx = 0; idx < returnCount; idx++) {
            uint256 orderId = totalOrders - idx;
            FileOrder storage order = orders[orderId];

            orderIds[idx] = orderId;
            owners[idx] = order.owner;
            sizes[idx] = order.maxSize;
            periods[idx] = order.periods;
            replicas[idx] = order.replicas;
            filled[idx] = order.filled;
            escrows[idx] = order.escrow;

            if (order.owner != address(0)) {
                uint256 endPeriod = order.startPeriod + order.periods;
                isActive[idx] = currentPer < endPeriod;
            }
        }
    }

    /// @notice Get proof system health and challenge statistics
    function getProofSystemStats()
        external
        view
        returns (
            uint256 totalChallengeRounds,
            uint256 currentStepValue,
            uint256 lastChallengeStepValue,
            bool challengeActive,
            address currentPrimaryProverAddress,
            uint256 challengedOrdersCount,
            uint256[] memory currentChallengedOrderIds,
            address[] memory secondaryProversList
        )
    {
        totalChallengeRounds = lastChallengeStep;
        currentStepValue = currentStep();
        lastChallengeStepValue = lastChallengeStep;
        challengeActive = (currentStepValue <= lastChallengeStep + 1) && challengeInitialized;
        currentPrimaryProverAddress = currentPrimaryProver;
        challengedOrdersCount = currentChallengedOrders.length;
        currentChallengedOrderIds = currentChallengedOrders;
        secondaryProversList = currentSecondaryProvers;
    }

    /// @notice Get financial overview for the marketplace
    function getFinancialStats()
        external
        view
        returns (
            uint256 totalContractBalance,
            uint256 totalEscrowHeld,
            uint256 totalRewardsPaid,
            uint256 averageOrderValue,
            uint256 totalStakeValue
        )
    {
        totalContractBalance = address(this).balance;

        totalEscrowHeld = aggregateActiveEscrow - aggregateActiveWithdrawn;
        totalRewardsPaid = aggregateActiveWithdrawn;

        uint256 totalOrders = nextOrderId - 1;
        averageOrderValue = totalOrders > 0 ? aggregateActiveEscrow / totalOrders : 0;

        (, uint256 totalCapacity,) = nodeStaking.getNetworkStats();
        totalStakeValue = totalCapacity * nodeStaking.STAKE_PER_BYTE();
    }

    /// @notice Get order core details by ID
    function getOrderDetails(uint256 _orderId)
        external
        view
        returns (
            address owner_,
            string memory uri_,
            uint256 root_,
            uint64 maxSize_,
            uint16 periods_,
            uint8 replicas_,
            uint8 filled_
        )
    {
        require(_orderId > 0 && _orderId < nextOrderId, "invalid order id");
        FileOrder storage order = orders[_orderId];
        owner_ = order.owner;
        uri_ = order.file.uri;
        root_ = order.file.root;
        maxSize_ = order.maxSize;
        periods_ = order.periods;
        replicas_ = order.replicas;
        filled_ = order.filled;
    }

    /// @notice Get order financial and status details by ID
    function getOrderFinancials(uint256 _orderId)
        external
        view
        returns (uint256 escrow_, uint256 withdrawn_, uint64 startPeriod_, bool expired_, address[] memory nodes_)
    {
        require(_orderId > 0 && _orderId < nextOrderId, "invalid order id");
        FileOrder storage order = orders[_orderId];
        escrow_ = order.escrow;
        withdrawn_ = orderEscrowWithdrawn[_orderId];
        startPeriod_ = order.startPeriod;
        expired_ = isOrderExpired(_orderId);
        nodes_ = orderToNodes[_orderId];
    }
}
