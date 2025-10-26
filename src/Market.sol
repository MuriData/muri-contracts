// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Verifier} from "./utils/poi_verifier.sol";
import {NodeStaking} from "./NodeStaking.sol";

contract FileMarket {
    uint256 constant PERIOD = 7 days; // single billing unit
    uint256 constant EPOCH = 4 * PERIOD;
    uint256 constant STEP = 30 seconds; // proof submission period
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

    // Node assignments
    mapping(uint256 => address[]) public orderToNodes; // order ID -> assigned nodes
    mapping(address => uint256[]) public nodeToOrders; // node -> assigned order IDs

    // Node rewards system
    mapping(address => uint256) public nodePendingRewards; // rewards owed after assignment removal
    mapping(address => uint256) public nodeEarnings; // total earnings accumulated
    mapping(address => uint256) public nodeWithdrawn; // total amount withdrawn
    mapping(address => uint256) public nodeLastClaimPeriod; // last period when rewards were claimed
    mapping(address => mapping(uint256 => uint256)) public nodeOrderStartPeriod; // node -> orderId -> period when started storing
    
    // Escrow tracking for proper payment distribution
    mapping(uint256 => uint256) public orderEscrowWithdrawn; // orderId -> amount already paid to nodes
    mapping(uint256 => mapping(address => uint256)) public nodeOrderEarnings; // orderId -> node -> earned amount
    
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
    bool public secondarySlashProcessed; // secondary slashing already handled for current challenge

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
    ) external payable nonReentrant returns (uint256 orderId) {
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
        require(!isOrderExpired(_orderId), "order expired");
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
    function completeExpiredOrder(uint256 _orderId) external nonReentrant {
        require(isOrderExpired(_orderId), "order not expired");
        FileOrder storage order = orders[_orderId];
        require(order.owner != address(0), "order does not exist");

        uint256 settlePeriod = order.startPeriod + order.periods;
        _settleAndReleaseNodes(order, _orderId, settlePeriod);

        // Remove from active orders and clean up
        _removeFromActiveOrders(_orderId);
        uint256 refundAmount = order.escrow - orderEscrowWithdrawn[_orderId];
        address orderOwner = order.owner;

        delete orders[_orderId];
        delete orderToNodes[_orderId];

        // Refund any remaining escrow to order owner
        if (refundAmount > 0) {
            payable(orderOwner).transfer(refundAmount);
        }

        emit OrderCompleted(_orderId);
    }

    // User cancels order with refund (minus any penalties)
    function cancelOrder(uint256 _orderId) external nonReentrant {
        FileOrder storage order = orders[_orderId];
        require(order.owner == msg.sender, "not order owner");
        require(!isOrderExpired(_orderId), "order already expired");

        uint256 settlePeriod = currentPeriod();
        ( , uint256 assignmentCount) = _settleAndReleaseNodes(order, _orderId, settlePeriod);

        // Clean up order data
        uint256 remainingEscrow = order.escrow - orderEscrowWithdrawn[_orderId];
        uint256 refundAmount = remainingEscrow;
        if (assignmentCount > 0 && remainingEscrow > 0) {
            uint256 penalty = remainingEscrow / 10; // 10% penalty
            refundAmount -= penalty;
        }

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
    function slashNode(address _node, uint256 _slashAmount, string calldata _reason) external onlySlashAuthority nonReentrant {
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
        
        // Get node's new capacity and previous usage after slashing
        (, uint64 newCapacity, uint64 usedBefore,,) = nodeStaking.getNodeInfo(_node);
        uint64 totalFreed = 0;
        uint256 settlePeriod = currentPeriod();

        // Remove node from all its orders (starting from the end to avoid index issues)
        uint256 i = nodeOrders.length;
        while (i > 0) {
            i--;
            uint256 exitOrderId = nodeOrders[i];
            uint64 freed = _removeAssignmentDuringForcedExit(
                _node,
                exitOrderId,
                settlePeriod
            );

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
        nodeStaking.forceReduceUsed(_node, newUsed);
        
        // Resize the exited orders array to actual count
        uint256[] memory actualExitedOrders = new uint256[](exitCount);
        for (uint256 idx = 0; idx < exitCount; idx++) {
            actualExitedOrders[idx] = exitedOrders[idx];
        }
        
        emit ForcedOrderExits(_node, actualExitedOrders, totalFreed);
    }

    function _removeAssignmentDuringForcedExit(
        address _node,
        uint256 _orderId,
        uint256 _settlePeriod
    ) internal returns (uint64 freed) {
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
                delete nodeOrderStartPeriod[_node][_orderId];

                if (j != assignedNodes.length - 1) {
                    assignedNodes[j] = assignedNodes[assignedNodes.length - 1];
                }
                assignedNodes.pop();
                order.filled--;

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
        delete nodeOrderStartPeriod[_node][_orderId];
        
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

    function _settleAndReleaseNodes(
        FileOrder storage order,
        uint256 _orderId,
        uint256 _settlePeriod
    ) internal returns (uint256 totalSettled, uint256 initialAssignments) {
        address[] storage assignedNodes = orderToNodes[_orderId];
        initialAssignments = assignedNodes.length;
        while (assignedNodes.length > 0) {
            address node = assignedNodes[assignedNodes.length - 1];
            uint256 settledReward = _settleOrderReward(node, _orderId, _settlePeriod);
            if (settledReward > 0) {
                nodePendingRewards[node] += settledReward;
                totalSettled += settledReward;
            }
            delete nodeOrderStartPeriod[node][_orderId];

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
        require(nodeStaking.isValidNode(node), "not a valid node");

        uint256 activeClaimable = _settleActiveOrders(node);
        uint256 pendingClaimable = nodePendingRewards[node];

        if (pendingClaimable > 0) {
            nodePendingRewards[node] = 0;
        }

        uint256 totalClaimable = activeClaimable + pendingClaimable;
        require(totalClaimable > 0, "no rewards to claim");

        nodeLastClaimPeriod[node] = currentPeriod();
        nodeWithdrawn[node] += totalClaimable;

        payable(node).transfer(totalClaimable);

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
    function _calculateOrderClaimableUpTo(
        address _node,
        uint256 _orderId,
        uint256 _settlePeriod
    ) internal view returns (uint256) {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) return 0;

        uint256 nodeStartPeriod = nodeOrderStartPeriod[_node][_orderId];

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
    function _settleOrderReward(
        address _node,
        uint256 _orderId,
        uint256 _settlePeriod
    ) internal returns (uint256 claimableFromOrder) {
        claimableFromOrder = _calculateOrderClaimableUpTo(_node, _orderId, _settlePeriod);
        if (claimableFromOrder == 0) {
            return 0;
        }

        nodeOrderEarnings[_orderId][_node] += claimableFromOrder;
        orderEscrowWithdrawn[_orderId] += claimableFromOrder;
        nodeEarnings[_node] += claimableFromOrder;
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
    function reportPrimaryFailure() external nonReentrant {
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
    function slashSecondaryFailures() external nonReentrant {
        require(currentStep() > lastChallengeStep + 1, "challenge period not expired");
        require(!secondarySlashProcessed, "secondary slash settled");
        secondarySlashProcessed = true;
        
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
                proofSubmitted[secondaryProver] = true;
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
    
    /// @notice Cleanup expired orders automatically
    function _cleanupExpiredOrders() internal {
        uint256 batchSize = 10; // Process up to 10 orders per heartbeat to avoid gas limits
        uint256 processed = 0;
        
        for (uint256 i = 0; i < activeOrders.length && processed < batchSize; i++) {
            uint256 activeOrderId = activeOrders[i];
            if (isOrderExpired(activeOrderId)) {
                _completeExpiredOrderInternal(activeOrderId);
                processed++;
                i--; // Adjust index since array was modified
            }
        }
    }

    /// @notice Manual heartbeat trigger (can be called by anyone if no challenge active)
    function triggerHeartbeat() external nonReentrant {
        require(
            currentStep() > lastChallengeStep + 1 || lastChallengeStep == 0,
            "challenge still active"
        );
        
        // If no randomness set, initialize with block data
        if (currentRandomness == 0) {
            currentRandomness = uint256(keccak256(abi.encodePacked(
                block.timestamp,
                block.prevrandao,
                msg.sender
            )));
        }
        
        _triggerNewHeartbeat();
        _cleanupExpiredOrders();
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

        delete orders[_orderId];
        delete orderToNodes[_orderId];
        
        if (refundAmount > 0) {
            payable(orderOwner).transfer(refundAmount);
        }
        
        emit OrderCompleted(_orderId);
    }
    
    /// @notice Get node earnings info
    function getNodeEarningsInfo(address _node) external view returns (
        uint256 totalEarned,
        uint256 withdrawn,
        uint256 claimable,
        uint256 lastClaimPeriod
    ) {
        totalEarned = nodeEarnings[_node];
        withdrawn = nodeWithdrawn[_node];
        claimable = this.getClaimableRewards(_node);
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

    /// @notice Get order escrow info
    function getOrderEscrowInfo(uint256 _orderId) external view returns (
        uint256 totalEscrow,
        uint256 paidToNodes,
        uint256 remainingEscrow
    ) {
        FileOrder storage order = orders[_orderId];
        totalEscrow = order.escrow;
        paidToNodes = orderEscrowWithdrawn[_orderId];
        remainingEscrow = totalEscrow > paidToNodes ? totalEscrow - paidToNodes : 0;
    }

    /// @notice Get node's earnings from a specific order
    function getNodeOrderEarnings(address _node, uint256 _orderId) external view returns (uint256) {
        return nodeOrderEarnings[_orderId][_node];
    }
    
    /// @notice Allow contract to receive ETH from slashed nodes
    receive() external payable {}
    
    // =============================================================================
    // NETWORK MONITORING FUNCTIONS FOR WEB DASHBOARD
    // =============================================================================
    
    /// @notice Get comprehensive global marketplace statistics
    function getGlobalStats() external view returns (
        uint256 totalOrders,
        uint256 activeOrdersCount,
        uint256 totalEscrowLocked,
        uint256 totalNodes,
        uint256 totalCapacityStaked,
        uint256 totalCapacityUsed,
        uint256 currentRandomnessValue,
        uint256 lastHeartbeatStep,
        uint256 currentPeriod_,
        uint256 currentStep_
    ) {
        totalOrders = nextOrderId - 1;
        activeOrdersCount = activeOrders.length;
        
        // Calculate total escrow locked across all active orders
        for (uint256 i = 1; i < nextOrderId; i++) {
            if (orders[i].owner != address(0)) {
                totalEscrowLocked += orders[i].escrow - orderEscrowWithdrawn[i];
            }
        }
        
        // Get node network statistics
        (totalNodes, totalCapacityStaked, totalCapacityUsed) = nodeStaking.getNetworkStats();
        
        currentRandomnessValue = currentRandomness;
        lastHeartbeatStep = lastChallengeStep;
        currentPeriod_ = currentPeriod();
        currentStep_ = currentStep();
    }
    
    /// @notice Get recent order activity for dashboard
    function getRecentOrders(uint256 count) external view returns (
        uint256[] memory orderIds,
        address[] memory owners,
        uint64[] memory sizes,
        uint16[] memory periods,
        uint8[] memory replicas,
        uint8[] memory filled,
        uint256[] memory escrows,
        bool[] memory isActive
    ) {
        uint256 totalOrders = nextOrderId - 1;
        uint256 returnCount = count > totalOrders ? totalOrders : count;
        if (returnCount == 0) {
            return (new uint256[](0), new address[](0), new uint64[](0), new uint16[](0), 
                    new uint8[](0), new uint8[](0), new uint256[](0), new bool[](0));
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
    function getProofSystemStats() external view returns (
        uint256 totalChallengeRounds,
        uint256 currentStepValue,
        uint256 lastChallengeStepValue,
        bool challengeActive,
        address currentPrimaryProverAddress,
        uint256 challengedOrdersCount,
        uint256[] memory currentChallengedOrderIds,
        address[] memory secondaryProversList
    ) {
        totalChallengeRounds = lastChallengeStep;
        currentStepValue = currentStep();
        lastChallengeStepValue = lastChallengeStep;
        challengeActive = (currentStepValue <= lastChallengeStep + 1) && (lastChallengeStep > 0);
        currentPrimaryProverAddress = currentPrimaryProver;
        challengedOrdersCount = currentChallengedOrders.length;
        currentChallengedOrderIds = currentChallengedOrders;
        secondaryProversList = currentSecondaryProvers;
    }
    
    /// @notice Get financial overview for the marketplace
    function getFinancialStats() external view returns (
        uint256 totalContractBalance,
        uint256 totalEscrowHeld,
        uint256 totalRewardsPaid,
        uint256 averageOrderValue,
        uint256 totalStakeValue
    ) {
        totalContractBalance = address(this).balance;
        
        // Calculate total escrow and rewards paid
        for (uint256 i = 1; i < nextOrderId; i++) {
            if (orders[i].owner != address(0)) {
                totalEscrowHeld += orders[i].escrow - orderEscrowWithdrawn[i];
                totalRewardsPaid += orderEscrowWithdrawn[i];
            }
        }
        
        uint256 totalOrders = nextOrderId - 1;
        averageOrderValue = totalOrders > 0 ? (totalEscrowHeld + totalRewardsPaid) / totalOrders : 0;
        
        (, uint256 totalCapacity,) = nodeStaking.getNetworkStats();
        totalStakeValue = totalCapacity * nodeStaking.STAKE_PER_BYTE();
    }
    
    /// @notice Get order details by ID for dashboard
    function getOrderDetails(uint256 _orderId) external view returns (
        address,
        string memory,
        uint256,
        uint64,
        uint16,
        uint8,
        uint8,
        uint256,
        uint256,
        uint64,
        bool,
        address[] memory
    ) {
        require(_orderId > 0 && _orderId < nextOrderId, "invalid order id");
        FileOrder storage order = orders[_orderId];
        return (
            order.owner,
            order.file.uri,
            order.file.root,
            order.maxSize,
            order.periods,
            order.replicas,
            order.filled,
            order.escrow,
            orderEscrowWithdrawn[_orderId],
            order.startPeriod,
            isOrderExpired(_orderId),
            orderToNodes[_orderId]
        );
    }
}
