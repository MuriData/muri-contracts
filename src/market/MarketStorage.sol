// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Verifier} from "muri-artifacts/poi_verifier.sol";
import {NodeStaking} from "../NodeStaking.sol";

/// @notice Shared storage, constants, modifiers, and events for FileMarket modules.
abstract contract MarketStorage {
    uint256 internal constant PERIOD = 7 days; // single billing unit
    uint256 internal constant EPOCH = 4 * PERIOD;
    uint256 internal constant STEP = 30 seconds; // proof submission period
    uint256 internal constant QUIT_SLASH_PERIODS = 3; // periods of storage cost charged on voluntary quit
    uint256 internal constant MAX_ORDERS_PER_NODE = 50; // cap orders per node to bound forced-exit iteration
    uint8 internal constant MAX_REPLICAS = 10; // cap replicas per order to bound settlement loop gas
    uint256 internal constant CLEANUP_BATCH_SIZE = 10; // expired orders processed per cleanup call
    uint256 internal constant CLEANUP_SCAN_CAP = 50; // max entries scanned per _cleanupExpiredOrders call
    uint256 internal constant MAX_CHALLENGE_SELECTION_PROBES = 200; // cap non-eviction probes in challenge selection
    uint256 internal constant MAX_CHALLENGE_EVICTIONS = 50; // max expired-order evictions per selection call
    uint256 internal immutable GENESIS_TS; // contract deploy timestamp
    address public owner;
    mapping(address => bool) public slashAuthorities;
    uint256 private _marketLock = 1;

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

    // Lifetime monotonic counters for dashboard accuracy (placed at end to preserve storage layout)
    uint256 public lifetimeEscrowDeposited; // cumulative escrow deposited across all orders ever placed
    uint256 public lifetimeRewardsPaid; // cumulative escrow paid to nodes as rewards

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SlashAuthorityUpdated(address indexed authority, bool allowed);

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
}
