// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Verifier} from "muri-artifacts/poi/poi_verifier.sol";
import {Verifier as FspVerifier} from "muri-artifacts/fsp/fsp_verifier.sol";
import {PlonkVerifier as KeyLeakVerifier} from "muri-artifacts/keyleak/keyleak_verifier.sol";
import {NodeStaking} from "../NodeStaking.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Shared storage, constants, modifiers, and events for FileMarket modules.
abstract contract MarketStorage is Initializable, UUPSUpgradeable {
    uint256 internal constant PERIOD = 7 days; // single billing unit
    uint256 internal constant EPOCH = 4 * PERIOD;
    uint256 internal constant QUIT_SLASH_BASE_PERIODS = 4; // base periods charged on voluntary quit (full slash if remaining <= this)
    uint256 internal constant QUIT_SLASH_EXCESS_DIVISOR = 4; // 25% of remaining periods beyond base
    uint256 internal constant MAX_ORDERS_PER_NODE = 50; // cap orders per node to bound forced-exit iteration
    uint8 internal constant MAX_REPLICAS = 10; // cap replicas per order to bound settlement loop gas
    uint256 internal constant CLEANUP_BATCH_SIZE = 10; // expired orders processed per cleanup call
    uint256 internal constant CLEANUP_SCAN_CAP = 50; // max entries scanned per _cleanupExpiredOrders call
    uint256 internal constant MAX_CHALLENGE_SELECTION_PROBES = 200; // cap non-eviction probes in challenge selection
    uint256 internal constant MAX_DEDUP_PROBES = 10; // extra probes after first valid candidate to find a fresh pair
    uint256 internal constant MAX_CHALLENGE_EVICTIONS = 50; // max expired-order evictions per selection call

    // --- Former immutables, now regular storage (slots 0–4) ---
    uint256 public genesisTs;
    NodeStaking public nodeStaking;
    Verifier public poiVerifier;
    FspVerifier public fspVerifier;
    KeyLeakVerifier public keyleakVerifier;

    address public owner;
    mapping(address => bool) public slashAuthorities;
    uint256 private _marketLock;

    struct FileMeta {
        uint256 root; // Merkle root hash of the file for POI verification
        string uri;
    }

    struct FileOrder {
        address owner;
        FileMeta file;
        uint32 numChunks; // ZK-verified chunk count
        uint16 periods; // billing periods to store
        uint8 replicas; // desired redundancy
        uint256 price; // wei / chunk / period (quoting module can update global price curves)
        uint8 filled; // replica slots already taken
        uint64 startPeriod; // when storage begins
        uint256 escrow; // prepaid funds held in contract
    }

    // --- Challenge slot struct for parallel event-driven challenges ---
    struct ChallengeSlot {
        uint256 orderId; // order being challenged (0 = idle)        — Slot 0
        address challengedNode; // node that must submit proof       — Slot 1 (20 bytes)
        uint64 deadlineBlock; // block.number deadline               — Slot 1 (packed, +8 bytes)
        uint256 randomness; // per-slot randomness for proof verification — Slot 2
    }

    // On-demand challenge struct for client-triggered challenges
    struct OnDemandChallenge {
        uint64 deadlineBlock; // block.number deadline
        uint256 randomness; // randomness for proof verification
        address challenger; // who issued the challenge
    }

    // Order management
    uint256 public nextOrderId;
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
    uint256 public reporterRewardBps;
    uint256 public constant MAX_REPORTER_REWARD_BPS = 5000; // cap at 50%
    mapping(address => uint256) public reporterPendingRewards;
    mapping(address => uint256) public reporterEarnings;
    mapping(address => uint256) public reporterWithdrawn;
    uint256 public totalSlashedReceived;
    uint256 public totalBurnedFromSlash;
    uint256 public totalReporterRewards;

    // --- Challenge slot system (variable slots with sqrt(N) scaling) ---
    uint256 public constant MIN_CHALLENGE_SLOTS = 1;
    uint256 public constant MAX_CHALLENGE_SLOTS = 50;
    uint256 internal constant MAX_ACTIVATE_PER_CALL = 10; // bounds activation loop gas
    // Timing budget (Avalanche C-Chain, ~2s/block):
    //   50 blocks = ~100 seconds
    //   - Event detection: ~2-4s (1-2 blocks)
    //   - Witness preparation: <1s (precomputed SMT + parallel hashing)
    //   - Groth16 proving (CPU): ~5-10s
    //   - Groth16 proving (GPU): ~1-2s (icicle-gnark)
    //   - Transaction submission + confirmation: ~4-6s (2-3 blocks)
    //   - Safety margin: ~78-88s
    //
    // For larger files or slower hardware, consider increasing this value.
    // GPU-accelerated proving (icicle-gnark) reduces proving to ~1-2s.
    uint256 public constant CHALLENGE_WINDOW_BLOCKS = 50; // ~100s at 2s/block on C-Chain
    uint256 public constant MIN_PROOF_FAILURE_SLASH = 1500 * STAKE_PER_CHUNK; // floor for proof-failure slash (0.15 MURI)
    uint256 public constant MAX_PROOF_FAILURE_SLASH_MULTIPLIER = 10; // cap for admin-tunable multiplier
    uint256 public constant MAX_SWEEP_PER_CALL = 5; // bounds gas per sweep
    uint256 public constant MAX_FORCED_EXITS_PER_SWEEP = 3; // caps forced exit cascades during a single sweep
    uint256 internal constant SNARK_SCALAR_FIELD = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
    uint256 internal constant STAKE_PER_CHUNK = 10 ** 14; // mirrors NodeStaking.STAKE_PER_CHUNK
    uint256 public constant CANCEL_PENALTY_MAX_BPS = 2500; // 25% at order start
    uint256 public constant CANCEL_PENALTY_MIN_BPS = 500; // 5% near order end
    // Was: ChallengeSlot[5] public challengeSlots; — 15 storage words (slots 31–45)
    // Now: mapping + counter = 2 words + 13-word padding to preserve layout
    mapping(uint256 => ChallengeSlot) public challengeSlots; // slot 31
    uint256 public numChallengeSlots; // slot 32
    uint256[13] private __challengeSlotsPadding; // slots 33–45 (layout preservation)
    bool public challengeSlotsInitialized;
    uint256 public globalSeedRandomness; // rolling seed for bootstrapping slot randomness
    mapping(address => uint256) public nodeActiveChallengeCount; // O(1) prover check
    mapping(uint256 => uint256) public orderActiveChallengeCount; // O(1) order-under-challenge check

    // Cleanup cursor for amortised expired-order scanning
    uint256 public cleanupCursor;

    // Cancellation penalty tracking
    uint256 public totalCancellationPenalties; // total early-cancellation penalties distributed to nodes

    // Pull-payment refunds
    mapping(address => uint256) public pendingRefunds;

    // Incremental escrow aggregates for O(1) stats
    uint256 public aggregateActiveEscrow; // sum of order.escrow for all non-deleted orders
    uint256 public aggregateActiveWithdrawn; // sum of orderEscrowWithdrawn for all non-deleted orders

    // Lifetime monotonic counters for dashboard accuracy
    uint256 public lifetimeEscrowDeposited; // cumulative escrow deposited across all orders ever placed
    uint256 public lifetimeRewardsPaid; // cumulative escrow paid to nodes as rewards

    // Cold-start: block number before which challenges are suppressed
    uint256 public challengeStartBlock;

    // --- Economic redesign storage (Change 1, 2, 5) ---
    uint256 public proofFailureSlashMultiplier; // multiplier for challenge failure slash (default 3)
    uint256 public clientCompensationBps; // basis points of slash going to affected client (default 2000 = 20%)
    uint256 public constant MAX_CLIENT_COMPENSATION_BPS = 5000; // cap at 50%
    uint256 public totalClientCompensation; // aggregate client compensation distributed
    mapping(bytes32 => OnDemandChallenge) public onDemandChallenges; // keccak256(orderId, node) => challenge

    // Persistent cursor for amortized expired-slot sweep
    uint256 public sweepCursor;

    // Reserve 195 slots for future storage variables (200 - 5 new slots)
    uint256[195] private __gap;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SlashAuthorityUpdated(address indexed authority, bool allowed);

    event OrderPlaced(uint256 indexed orderId, address indexed owner, uint32 numChunks, uint16 periods, uint8 replicas);
    event OrderFulfilled(uint256 indexed orderId, address indexed node);
    event OrderCompleted(uint256 indexed orderId);
    event OrderCancelled(uint256 indexed orderId, uint256 refundAmount);
    event NodeQuit(uint256 indexed orderId, address indexed node, uint256 slashAmount);
    event NodeSlashed(address indexed node, uint256 slashAmount, string reason);
    event ForcedOrderExits(address indexed node, uint256[] orderIds, uint64 totalFreed);
    event RewardsCalculated(address indexed node, uint256 amount, uint256 periods);
    event RewardsClaimed(address indexed node, uint256 amount);
    event ReporterRewardAccrued(address indexed reporter, uint256 rewardAmount, uint256 slashedAmount);
    event ReporterRewardsClaimed(address indexed reporter, uint256 amount);
    event ReporterRewardBpsUpdated(uint256 oldBps, uint256 newBps);
    event CancellationPenaltyDistributed(uint256 indexed orderId, uint256 penaltyAmount, uint256 nodeCount);
    event RefundQueued(address indexed recipient, uint256 amount);
    event RefundWithdrawn(address indexed recipient, uint256 amount);
    event OrderUnderReplicated(uint256 indexed orderId, uint8 currentFilled, uint8 desiredReplicas);
    event KeyLeakReported(address indexed node, address indexed reporter, uint256 slashAmount);

    // Client compensation events
    event ClientCompensationAccrued(address indexed client, uint256 amount, uint256 orderId);
    event ClientCompensationBpsUpdated(uint256 oldBps, uint256 newBps);
    event ProofFailureSlashMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);

    // On-demand challenge events
    event OnDemandChallengeIssued(
        uint256 indexed orderId, address indexed node, address challenger, uint256 deadlineBlock
    );
    event OnDemandProofSubmitted(uint256 indexed orderId, address indexed node, bytes32 commitment);
    event OnDemandChallengeExpired(uint256 indexed orderId, address indexed node, uint256 slashAmount);

    // Challenge slot events
    event SlotChallengeIssued(
        uint256 indexed slotIndex, uint256 orderId, address challengedNode, uint256 deadlineBlock
    );
    event SlotProofSubmitted(uint256 indexed slotIndex, address indexed prover, bytes32 commitment);
    event SlotExpired(uint256 indexed slotIndex, address indexed failedNode, uint256 slashAmount);
    event SlotDeactivated(uint256 indexed slotIndex);
    event SlotsActivated(uint256 activatedCount);
    event ChallengeSlotsScaled(uint256 oldCount, uint256 newCount);
    event ExpiredSlotsProcessed(uint256 processedCount, address indexed reporter);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function __MarketStorage_init(
        address _owner,
        address _nodeStaking,
        address _poiVerifier,
        address _fspVerifier,
        address _keyleakVerifier
    ) internal onlyInitializing {
        owner = _owner;
        nodeStaking = NodeStaking(_nodeStaking);
        poiVerifier = Verifier(_poiVerifier);
        fspVerifier = FspVerifier(_fspVerifier);
        keyleakVerifier = KeyLeakVerifier(_keyleakVerifier);
        genesisTs = block.timestamp;
        _marketLock = 1;
        nextOrderId = 1;
        reporterRewardBps = 1000; // 10% default (basis points)
        proofFailureSlashMultiplier = 3; // 3x order period cost for challenge failure
        clientCompensationBps = 2000; // 20% of slash to affected client
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
