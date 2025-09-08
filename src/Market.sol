// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Verifier} from "./utils/poi_verifier.sol";
import {NodeStaking} from "./NodeStaking.sol";

contract FileMarket {
    uint256 constant PERIOD = 7 days; // single billing unit
    uint256 constant EPOCH = 4 * PERIOD;
    uint256 constant STEP = 30 seconds; // proof submission period
    uint256 immutable GENESIS_TS; // contract deploy timestamp

    constructor() {
        GENESIS_TS = block.timestamp;
        nodeStaking = new NodeStaking(address(this));
        poiVerifier = new Verifier();
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

    // Node assignments
    mapping(uint256 => address[]) public orderToNodes; // order ID -> assigned nodes
    mapping(address => uint256[]) public nodeToOrders; // node -> assigned order IDs

    // Node rewards system
    mapping(address => uint256) public nodeEarnings; // total earnings accumulated
    mapping(address => uint256) public nodeWithdrawn; // total amount withdrawn
    mapping(address => uint256) public nodeLastClaimPeriod; // last period when rewards were claimed
    mapping(address => mapping(uint256 => uint256)) public nodeOrderStartPeriod; // node -> orderId -> period when started storing

    // Proof system - stateless rolling challenges
    uint256 public currentRandomness; // current heartbeat randomness
    uint256 public lastChallengeStep; // last step when challenge was issued
    address public currentPrimaryProver; // current primary prover
    address[] public currentSecondaryProvers; // current secondary provers
    uint256[] public currentChallengedOrders; // current orders being challenged
    uint256 public constant CHALLENGE_COUNT = 5; // orders to challenge per heartbeat
    
    // Proof submission tracking (reset each heartbeat)
    mapping(address => bool) public proofSubmitted; // current round proof submissions
    mapping(address => uint256) public nodeToProveOrderId; // node -> order they're proving (current challenge)
    bool public primaryProofReceived; // primary proof received for current challenge
    bool public primaryFailureReported; // primary failure already reported for current step

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
    event ChallengeIssued(uint256 randomness, address primaryProver, address[] secondaryProvers, uint256[] orderIds, uint256 challengeStep);
    event ProofSubmitted(address indexed prover, bool isPrimary, bytes32 commitment);
    event PrimaryProverFailed(address indexed primaryProver, address indexed reporter, uint256 newRandomness);
    event HeartbeatTriggered(uint256 newRandomness, uint256 step);

    // Place a new file storage order
    function placeOrder(
        FileMeta memory _file,
        uint64 _maxSize,
        uint16 _periods,
        uint8 _replicas,
        uint256 _pricePerBytePerPeriod
    ) external payable returns (uint256 orderId) {
        require(_maxSize > 0, "invalid size");
        require(_periods > 0, "invalid periods");
        require(_replicas > 0, "invalid replicas");
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
            escrow: msg.value
        });

        // Add to active orders for random selection
        activeOrders.push(orderId);
        orderIndexInActive[orderId] = activeOrders.length - 1;

        emit OrderPlaced(orderId, msg.sender, _maxSize, _periods, _replicas);

        // Refund excess payment
        if (msg.value > totalCost) {
            payable(msg.sender).transfer(msg.value - totalCost);
        }
    }

    // Node executes an order (claims a replica slot)
    function executeOrder(uint256 _orderId) external {
        require(nodeStaking.isValidNode(msg.sender), "not a valid node");
        
        FileOrder storage order = orders[_orderId];
        require(order.owner != address(0), "order does not exist");
        require(order.filled < order.replicas, "order already filled");
        require(nodeStaking.hasCapacity(msg.sender, order.maxSize), "insufficient capacity");

        // Check if node is already assigned to this order
        address[] storage assignedNodes = orderToNodes[_orderId];
        for (uint256 i = 0; i < assignedNodes.length; i++) {
            require(assignedNodes[i] != msg.sender, "already assigned to this order");
        }

        // Assign node to order
        assignedNodes.push(msg.sender);
        nodeToOrders[msg.sender].push(_orderId);
        order.filled++;

        // Record when this node started storing this order
        nodeOrderStartPeriod[msg.sender][_orderId] = currentPeriod();

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
    }

    // Random order selection function
    function selectRandomOrders(uint256 _randomSeed, uint256 _count) 
        public 
        view 
        returns (uint256[] memory selectedOrders) 
    {
        require(_count > 0, "count must be positive");
        
        uint256 totalActive = activeOrders.length;
        if (totalActive == 0) {
            return new uint256[](0);
        }
        
        uint256 actualCount = _count > totalActive ? totalActive : _count;
        selectedOrders = new uint256[](actualCount);
        
        if (actualCount == totalActive) {
            // If requesting all orders, return them all
            for (uint256 i = 0; i < totalActive; i++) {
                selectedOrders[i] = activeOrders[i];
            }
        } else {
            // Use Fisher-Yates shuffle algorithm for uniform random selection
            uint256[] memory indices = new uint256[](totalActive);
            for (uint256 i = 0; i < totalActive; i++) {
                indices[i] = i;
            }
            
            for (uint256 i = 0; i < actualCount; i++) {
                uint256 randomIndex = uint256(keccak256(abi.encodePacked(_randomSeed, i))) % (totalActive - i);
                selectedOrders[i] = activeOrders[indices[randomIndex]];
                
                // Swap the selected index with the last unselected one
                indices[randomIndex] = indices[totalActive - 1 - i];
            }
        }
    }


    // Get active orders count
    function getActiveOrdersCount() external view returns (uint256) {
        return activeOrders.length;
    }

    // Get all active order IDs
    function getActiveOrders() external view returns (uint256[] memory) {
        return activeOrders;
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
    function completeExpiredOrder(uint256 _orderId) external {
        require(isOrderExpired(_orderId), "order not expired");
        FileOrder storage order = orders[_orderId];
        require(order.owner != address(0), "order does not exist");

        // Free up capacity from all assigned nodes
        address[] storage assignedNodes = orderToNodes[_orderId];
        for (uint256 i = 0; i < assignedNodes.length; i++) {
            address node = assignedNodes[i];
            (,, uint64 used,,) = nodeStaking.getNodeInfo(node);
            nodeStaking.updateNodeUsed(node, used - order.maxSize);
            
            // Remove order from node's order list
            _removeOrderFromNode(node, _orderId);
        }

        // Remove from active orders and clean up
        _removeFromActiveOrders(_orderId);
        delete orders[_orderId];
        delete orderToNodes[_orderId];

        emit OrderCompleted(_orderId);
    }

    // User cancels order with refund (minus any penalties)
    function cancelOrder(uint256 _orderId) external {
        FileOrder storage order = orders[_orderId];
        require(order.owner == msg.sender, "not order owner");
        require(!isOrderExpired(_orderId), "order already expired");

        uint256 refundAmount = order.escrow;
        
        // If nodes are already storing, apply penalty (e.g., 10%)
        if (order.filled > 0) {
            uint256 penalty = refundAmount / 10; // 10% penalty
            refundAmount -= penalty;
        }

        // Free up capacity from all assigned nodes
        address[] storage assignedNodes = orderToNodes[_orderId];
        for (uint256 i = 0; i < assignedNodes.length; i++) {
            address node = assignedNodes[i];
            (,, uint64 used,,) = nodeStaking.getNodeInfo(node);
            nodeStaking.updateNodeUsed(node, used - order.maxSize);
            
            // Remove order from node's order list
            _removeOrderFromNode(node, _orderId);
        }

        // Clean up order data
        _removeFromActiveOrders(_orderId);
        delete orders[_orderId];
        delete orderToNodes[_orderId];

        // Refund to user
        payable(msg.sender).transfer(refundAmount);

        emit OrderCancelled(_orderId, refundAmount);
    }

    // Node quits from an order with slashing
    function quitOrder(uint256 _orderId) external {
        FileOrder storage order = orders[_orderId];
        require(order.owner != address(0), "order does not exist");
        require(!isOrderExpired(_orderId), "order already expired");

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

        // Calculate slash amount (equivalent to 1 period of storage cost)
        uint256 slashAmount = uint256(order.maxSize) * order.price;
        
        // Apply slash to node's stake
        bool forcedOrderExit = nodeStaking.slashNode(msg.sender, slashAmount);
        
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
    function slashNode(address _node, uint256 _slashAmount, string calldata _reason) external {
        // TODO: Add proper access control (e.g., only challenge system)
        require(_slashAmount > 0, "invalid slash amount");
        
        bool forcedOrderExit = nodeStaking.slashNode(_node, _slashAmount);
        
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
        
        // Get node's new capacity after slashing
        (, uint64 newCapacity,,,) = nodeStaking.getNodeInfo(_node);
        uint64 totalFreed = 0;
        
        // Remove node from all its orders (starting from the end to avoid index issues)
        for (int256 i = int256(nodeOrders.length) - 1; i >= 0; i--) {
            uint256 orderId = nodeOrders[uint256(i)];
            FileOrder storage order = orders[orderId];
            
            if (order.owner != address(0)) { // Order still exists
                // Find node in order's assigned nodes and remove
                address[] storage assignedNodes = orderToNodes[orderId];
                for (uint256 j = 0; j < assignedNodes.length; j++) {
                    if (assignedNodes[j] == _node) {
                        // Remove node from order
                        if (j != assignedNodes.length - 1) {
                            assignedNodes[j] = assignedNodes[assignedNodes.length - 1];
                        }
                        assignedNodes.pop();
                        order.filled--;
                        totalFreed += order.maxSize;
                        exitedOrders[exitCount++] = orderId;
                        break;
                    }
                }
            }
        }
        
        // Clear node's order list
        delete nodeToOrders[_node];
        
        // Update node's used capacity to match new capacity
        nodeStaking.forceReduceUsed(_node, newCapacity);
        
        // Resize the exited orders array to actual count
        uint256[] memory actualExitedOrders = new uint256[](exitCount);
        for (uint256 i = 0; i < exitCount; i++) {
            actualExitedOrders[i] = exitedOrders[i];
        }
        
        emit ForcedOrderExits(_node, actualExitedOrders, totalFreed);
    }

    // Helper function to remove node from a single order
    function _removeNodeFromOrder(address _node, uint256 _orderId, uint256 _nodeIndex) internal {
        FileOrder storage order = orders[_orderId];
        address[] storage assignedNodes = orderToNodes[_orderId];
        
        // Remove node from order assignments
        if (_nodeIndex != assignedNodes.length - 1) {
            assignedNodes[_nodeIndex] = assignedNodes[assignedNodes.length - 1];
        }
        assignedNodes.pop();
        order.filled--;

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

    // Get order details including expiration status
    function getOrderDetails(uint256 _orderId) external view returns (
        address owner,
        uint64 maxSize,
        uint16 periods,
        uint8 replicas,
        uint8 filled,
        uint64 startPeriod,
        uint256 escrow,
        bool expired
    ) {
        FileOrder storage order = orders[_orderId];
        return (
            order.owner,
            order.maxSize,
            order.periods,
            order.replicas,
            order.filled,
            order.startPeriod,
            order.escrow,
            isOrderExpired(_orderId)
        );
    }

    // Node reward system
    
    /// @notice Calculate and claim accumulated rewards for a node
    function claimRewards() external {
        address node = msg.sender;
        require(nodeStaking.isValidNode(node), "not a valid node");
        
        uint256 totalRewards = _calculateNodeRewards(node);
        uint256 claimable = totalRewards - nodeWithdrawn[node];
        require(claimable > 0, "no rewards to claim");
        
        nodeWithdrawn[node] = totalRewards;
        nodeLastClaimPeriod[node] = currentPeriod();
        
        payable(node).transfer(claimable);
        
        emit RewardsClaimed(node, claimable);
    }
    
    /// @notice Calculate total rewards earned by a node up to current period
    function _calculateNodeRewards(address _node) internal returns (uint256 totalRewards) {
        uint256[] storage nodeOrders = nodeToOrders[_node];
        uint256 currentPer = currentPeriod();
        uint256 periodsCalculated = 0;
        
        for (uint256 i = 0; i < nodeOrders.length; i++) {
            uint256 orderId = nodeOrders[i];
            FileOrder storage order = orders[orderId];
            
            if (order.owner == address(0)) continue; // Order doesn't exist anymore
            
            uint256 nodeStartPeriod = nodeOrderStartPeriod[_node][orderId];
            uint256 orderEndPeriod = order.startPeriod + order.periods;
            
            // Calculate how many periods this node has been storing this order
            uint256 storageEndPeriod = currentPer > orderEndPeriod ? orderEndPeriod : currentPer;
            
            if (storageEndPeriod > nodeStartPeriod) {
                uint256 storagePeriods = storageEndPeriod - nodeStartPeriod;
                // Reward = maxSize * price * periods stored
                uint256 orderReward = uint256(order.maxSize) * order.price * storagePeriods;
                totalRewards += orderReward;
                periodsCalculated += storagePeriods;
            }
        }
        
        // Update node earnings tracking
        if (totalRewards > nodeEarnings[_node]) {
            uint256 newEarnings = totalRewards - nodeEarnings[_node];
            nodeEarnings[_node] = totalRewards;
            emit RewardsCalculated(_node, newEarnings, periodsCalculated);
        }
    }
    
    /// @notice View function to check claimable rewards without state changes
    function getClaimableRewards(address _node) external view returns (uint256 claimable) {
        uint256 totalRewards = _calculateNodeRewardsView(_node);
        claimable = totalRewards > nodeWithdrawn[_node] ? totalRewards - nodeWithdrawn[_node] : 0;
    }
    
    /// @notice View-only version of reward calculation
    function _calculateNodeRewardsView(address _node) internal view returns (uint256 totalRewards) {
        uint256[] storage nodeOrders = nodeToOrders[_node];
        uint256 currentPer = currentPeriod();
        
        for (uint256 i = 0; i < nodeOrders.length; i++) {
            uint256 orderId = nodeOrders[i];
            FileOrder storage order = orders[orderId];
            
            if (order.owner == address(0)) continue;
            
            uint256 nodeStartPeriod = nodeOrderStartPeriod[_node][orderId];
            uint256 orderEndPeriod = order.startPeriod + order.periods;
            uint256 storageEndPeriod = currentPer > orderEndPeriod ? orderEndPeriod : currentPer;
            
            if (storageEndPeriod > nodeStartPeriod) {
                uint256 storagePeriods = storageEndPeriod - nodeStartPeriod;
                uint256 orderReward = uint256(order.maxSize) * order.price * storagePeriods;
                totalRewards += orderReward;
            }
        }
    }
    
    /// @notice Submit proof for current challenge
    function submitProof(
        uint256[8] calldata _proof, 
        bytes32 _commitment
    ) external {
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
        
        // Prepare public inputs for POI verifier: [randomness, rootHash, commitment, publicKeyX, publicKeyY]
        uint256[5] memory publicInputs = [
            currentRandomness,
            fileRootHash,
            uint256(_commitment),
            publicKeyX,
            publicKeyY
        ];
        
        // Verify proof using POI verifier - reverts on invalid proof
        poiVerifier.verifyProof(_proof, publicInputs);
        
        proofSubmitted[msg.sender] = true;
        
        if (isPrimary) {
            primaryProofReceived = true;
            // Primary prover's commitment becomes next randomness
            currentRandomness = uint256(_commitment);
            _triggerNewHeartbeat();
        }
        
        emit ProofSubmitted(msg.sender, isPrimary, _commitment);
    }
    
    /// @notice Report primary prover failure (callable after STEP period)
    function reportPrimaryFailure() external {
        require(nodeStaking.isValidNode(msg.sender), "not a valid node");
        require(currentStep() > lastChallengeStep + 1, "challenge period not expired");
        require(!primaryProofReceived, "primary proof was submitted");
        require(!primaryFailureReported, "primary failure already reported");
        
        // Mark failure as reported to prevent duplicate reports
        primaryFailureReported = true;
        
        // Slash primary prover severely
        address primaryProver = currentPrimaryProver;
        uint256 severeSlashAmount = 1000 * nodeStaking.STAKE_PER_BYTE(); // Much higher than normal
        
        bool forcedExit = nodeStaking.slashNode(primaryProver, severeSlashAmount);
        if (forcedExit) {
            _handleForcedOrderExits(primaryProver);
        }
        
        // Generate fallback randomness using reporter's signature and block data
        uint256 fallbackRandomness = uint256(keccak256(abi.encodePacked(
            msg.sender, 
            block.timestamp, 
            block.prevrandao,
            currentRandomness
        )));
        
        currentRandomness = fallbackRandomness;
        _triggerNewHeartbeat();
        
        emit PrimaryProverFailed(primaryProver, msg.sender, fallbackRandomness);
    }
    
    /// @notice Check and slash secondary provers who failed to submit proofs
    function slashSecondaryFailures() external {
        require(currentStep() > lastChallengeStep + 1, "challenge period not expired");
        
        for (uint256 i = 0; i < currentSecondaryProvers.length; i++) {
            address secondaryProver = currentSecondaryProvers[i];
            if (!proofSubmitted[secondaryProver]) {
                // Normal slashing for secondary provers
                uint256 normalSlashAmount = 100 * nodeStaking.STAKE_PER_BYTE();
                
                bool forcedExit = nodeStaking.slashNode(secondaryProver, normalSlashAmount);
                if (forcedExit) {
                    _handleForcedOrderExits(secondaryProver);
                }
                
                emit NodeSlashed(secondaryProver, normalSlashAmount, "failed secondary proof");
            }
        }
    }
    
    /// @notice Trigger new heartbeat with challenge selection
    function _triggerNewHeartbeat() internal {
        uint256 currentStep_ = currentStep();
        
        // Reset proof tracking
        _resetProofTracking();
        
        // Select random orders for challenge
        uint256[] memory selectedOrders = selectRandomOrders(currentRandomness, CHALLENGE_COUNT);
        
        if (selectedOrders.length == 0) {
            lastChallengeStep = currentStep_;
            emit HeartbeatTriggered(currentRandomness, currentStep_);
            return;
        }
        
        // Set up new challenge
        currentChallengedOrders = selectedOrders;
        
        // Primary prover is from first order's first node
        address[] storage firstOrderNodes = orderToNodes[selectedOrders[0]];
        require(firstOrderNodes.length > 0, "no nodes for first order");
        currentPrimaryProver = firstOrderNodes[0];
        nodeToProveOrderId[currentPrimaryProver] = selectedOrders[0];
        
        // Reset secondary provers array length to 0 (more efficient than delete)
        uint256 secondaryCount = 0;
        if (currentSecondaryProvers.length > 0) {
            assembly {
                sstore(currentSecondaryProvers.slot, 0)
            }
        }
        
        // Assign secondary provers from other orders
        for (uint256 i = 1; i < selectedOrders.length; i++) {
            address[] storage orderNodes = orderToNodes[selectedOrders[i]];
            if (orderNodes.length > 0) {
                address secondaryNode = orderNodes[0];
                currentSecondaryProvers.push(secondaryNode);
                nodeToProveOrderId[secondaryNode] = selectedOrders[i];
                secondaryCount++;
            }
        }
        
        lastChallengeStep = currentStep_;
        
        emit ChallengeIssued(
            currentRandomness,
            currentPrimaryProver,
            currentSecondaryProvers,
            selectedOrders,
            currentStep_
        );
        emit HeartbeatTriggered(currentRandomness, currentStep_);
    }
    
    /// @notice Reset proof submission tracking for new challenge
    function _resetProofTracking() internal {
        // Reset primary prover proof status
        primaryProofReceived = false;
        primaryFailureReported = false;
        
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
    
    /// @notice Cleanup expired orders automatically
    function _cleanupExpiredOrders() internal {
        uint256 batchSize = 10; // Process up to 10 orders per heartbeat to avoid gas limits
        uint256 processed = 0;
        
        for (uint256 i = 0; i < activeOrders.length && processed < batchSize; i++) {
            uint256 orderId = activeOrders[i];
            if (isOrderExpired(orderId)) {
                _completeExpiredOrderInternal(orderId);
                processed++;
                i--; // Adjust index since array was modified
            }
        }
    }
    
    /// @notice Internal version of completeExpiredOrder for heartbeat use
    function _completeExpiredOrderInternal(uint256 _orderId) internal {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) return; // Already completed
        
        // Free up capacity from all assigned nodes
        address[] storage assignedNodes = orderToNodes[_orderId];
        for (uint256 i = 0; i < assignedNodes.length; i++) {
            address node = assignedNodes[i];
            (,, uint64 used,,) = nodeStaking.getNodeInfo(node);
            nodeStaking.updateNodeUsed(node, used - order.maxSize);
            
            // Remove order from node's order list
            _removeOrderFromNode(node, _orderId);
        }
        
        // Remove from active orders and clean up
        _removeFromActiveOrders(_orderId);
        delete orders[_orderId];
        delete orderToNodes[_orderId];
        
        emit OrderCompleted(_orderId);
    }
    
    /// @notice Get node earnings info
    function getNodeEarningsInfo(address _node) external view returns (
        uint256 totalEarned,
        uint256 withdrawn,
        uint256 claimable,
        uint256 lastClaimPeriod
    ) {
        totalEarned = _calculateNodeRewardsView(_node);
        withdrawn = nodeWithdrawn[_node];
        claimable = totalEarned > withdrawn ? totalEarned - withdrawn : 0;
        lastClaimPeriod = nodeLastClaimPeriod[_node];
    }

    /// @notice Get current challenge info
    function getCurrentChallengeInfo() external view returns (
        uint256 randomness,
        uint256 challengeStep,
        address primaryProver,
        address[] memory secondaryProvers,
        uint256[] memory challengedOrders,
        bool primarySubmitted,
        bool challengeActive
    ) {
        randomness = currentRandomness;
        challengeStep = lastChallengeStep;
        primaryProver = currentPrimaryProver;
        secondaryProvers = currentSecondaryProvers;
        challengedOrders = currentChallengedOrders;
        primarySubmitted = primaryProofReceived;
        challengeActive = (currentStep() <= lastChallengeStep + 1) && (lastChallengeStep > 0);
    }

    /// @notice Check if a node has submitted proof for current challenge
    function hasSubmittedProof(address _node) external view returns (bool) {
        return proofSubmitted[_node];
    }

    /// @notice Check if challenge period has expired
    function isChallengeExpired() external view returns (bool) {
        return currentStep() > lastChallengeStep + 1;
    }
}
