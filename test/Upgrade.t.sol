// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FileMarket} from "../src/Market.sol";
import {FileMarketExtension} from "../src/FileMarketExtension.sol";
import {NodeStaking} from "../src/NodeStaking.sol";
import {IGroth16Precompile} from "../src/interfaces/IGroth16Precompile.sol";
import {IPlonkPrecompile} from "../src/interfaces/IPlonkPrecompile.sol";
import {FileMarketV2} from "./mocks/FileMarketV2.sol";
import {NodeStakingV2} from "./mocks/NodeStakingV2.sol";

/// @notice Self-contained upgrade tests — does NOT inherit MarketTestBase.
contract UpgradeTest is Test {
    /// @dev ERC-1967 implementation slot
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    FileMarket internal market;
    FileMarketExtension internal marketExt;
    NodeStaking internal nodeStaking;

    address internal user1 = address(0x1111);
    address internal node1 = address(0x3333);
    address internal node2 = address(0x4444);
    address internal nonOwner = address(0x9999);

    uint64 internal constant TEST_CAPACITY = 1024;
    uint256 internal constant STAKE_PER_CHUNK = 4 * 10 ** 14;
    uint256 internal constant PERIOD = 7 days;
    uint256 internal constant FILE_ROOT = 0x123456789abcdef;
    string internal constant FILE_URI = "QmTestHash123";

    // Precompile addresses
    address internal constant GROTH16_PRECOMPILE = 0x0300000000000000000000000000000000000001;
    address internal constant PLONK_PRECOMPILE = 0x0300000000000000000000000000000000000004;

    function setUp() public {
        NodeStaking stakingImpl = new NodeStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");

        FileMarketExtension ext = new FileMarketExtension();
        FileMarket marketImpl = new FileMarket(address(ext));
        bytes memory marketInitData = abi.encodeCall(
            FileMarket.initialize,
            (address(this), address(stakingProxy))
        );
        ERC1967Proxy marketProxy = new ERC1967Proxy(address(marketImpl), marketInitData);

        NodeStaking(address(stakingProxy)).initialize(address(marketProxy));

        market = FileMarket(payable(address(marketProxy)));
        marketExt = FileMarketExtension(payable(address(marketProxy)));
        nodeStaking = NodeStaking(address(stakingProxy));

        // Mock precompiles to always succeed
        vm.mockCall(
            GROTH16_PRECOMPILE,
            abi.encodeWithSelector(IGroth16Precompile.verifyCompressedProof.selector),
            abi.encode(true)
        );
        vm.mockCall(
            PLONK_PRECOMPILE,
            abi.encodeWithSelector(IPlonkPrecompile.verifyProof.selector),
            abi.encode(true)
        );

        vm.deal(user1, 100 ether);
        vm.deal(node1, 100 ether);
        vm.deal(node2, 100 ether);
        vm.deal(nonOwner, 100 ether);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _stakeNode(address node, uint64 capacity, uint256 key) internal {
        uint256 stake = uint256(capacity) * STAKE_PER_CHUNK;
        vm.deal(node, node.balance + stake);
        vm.prank(node);
        nodeStaking.stakeNode{value: stake}(capacity, key);
    }

    function _placeOrder(address owner_, uint32 numChunks, uint16 periods, uint8 replicas, uint256 price)
        internal
        returns (uint256 orderId, uint256 totalCost)
    {
        totalCost = uint256(numChunks) * uint256(periods) * price * uint256(replicas);
        uint256[4] memory fspProof;
        vm.prank(owner_);
        orderId = market.placeOrder{value: totalCost}(FILE_ROOT, FILE_URI, numChunks, periods, replicas, price, fspProof);
    }

    function _executeOrder(address node, uint256 orderId) internal {
        uint256[4] memory proof;
        vm.prank(node);
        market.executeOrder(orderId, proof, bytes32(0));
    }

    function _getImplAddress(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    // ---------------------------------------------------------------
    // Authorization tests
    // ---------------------------------------------------------------

    function test_UpgradeFileMarket_OwnerSucceeds() public {
        FileMarketExtension newExt = new FileMarketExtension();
        FileMarketV2 newImpl = new FileMarketV2(address(newExt));
        address oldImpl = _getImplAddress(address(market));

        market.upgradeToAndCall(address(newImpl), "");

        address currentImpl = _getImplAddress(address(market));
        assertNotEq(currentImpl, oldImpl, "impl should have changed");
        assertEq(currentImpl, address(newImpl), "impl should be V2");
        assertEq(FileMarketV2(payable(address(market))).version(), 2, "version should be 2");
    }

    function test_UpgradeFileMarket_NonOwnerReverts() public {
        FileMarketExtension newExt = new FileMarketExtension();
        FileMarketV2 newImpl = new FileMarketV2(address(newExt));

        vm.prank(nonOwner);
        vm.expectRevert("not owner");
        market.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeNodeStaking_MarketOwnerSucceeds() public {
        NodeStakingV2 newImpl = new NodeStakingV2();
        address oldImpl = _getImplAddress(address(nodeStaking));

        // This test contract is the market owner (set as owner in setUp)
        nodeStaking.upgradeToAndCall(address(newImpl), "");

        address currentImpl = _getImplAddress(address(nodeStaking));
        assertNotEq(currentImpl, oldImpl, "impl should have changed");
        assertEq(currentImpl, address(newImpl), "impl should be V2");
        assertEq(NodeStakingV2(address(nodeStaking)).version(), 2, "version should be 2");
    }

    function test_UpgradeNodeStaking_NonMarketOwnerReverts() public {
        NodeStakingV2 newImpl = new NodeStakingV2();

        vm.prank(nonOwner);
        vm.expectRevert("not market owner");
        nodeStaking.upgradeToAndCall(address(newImpl), "");
    }

    // ---------------------------------------------------------------
    // Storage preservation tests
    // ---------------------------------------------------------------

    function test_UpgradeFileMarket_PreservesState() public {
        // Build up state: stake nodes, place order, execute
        _stakeNode(node1, TEST_CAPACITY, 0x1234);
        _stakeNode(node2, TEST_CAPACITY, 0x5678);
        (uint256 orderId, uint256 totalCost) = _placeOrder(user1, 1024, 4, 2, 1e12);
        _executeOrder(node1, orderId);

        // Snapshot pre-upgrade state
        address preOwner = market.owner();
        uint256 preGenesisTs = market.genesisTs();
        uint256 preNextOrderId = market.nextOrderId();
        address preNodeStaking = address(market.nodeStaking());
        (
            address orderOwner,
            uint8 filled,
            uint8 replicas,
            uint32 numChunks,
            uint16 periods,,
            uint256 fileRoot,
            uint256 escrow
        ) = market.orders(orderId);

        // Upgrade
        FileMarketExtension newExt = new FileMarketExtension();
        FileMarketV2 newImpl = new FileMarketV2(address(newExt));
        market.upgradeToAndCall(address(newImpl), "");

        // Verify all state preserved
        assertEq(market.owner(), preOwner, "owner changed");
        assertEq(market.genesisTs(), preGenesisTs, "genesisTs changed");
        assertEq(market.nextOrderId(), preNextOrderId, "nextOrderId changed");
        assertEq(address(market.nodeStaking()), preNodeStaking, "nodeStaking changed");

        // Verify order details preserved
        (
            address postOrderOwner,
            uint8 postFilled,
            uint8 postReplicas,
            uint32 postNumChunks,
            uint16 postPeriods,,
            uint256 postFileRoot,
            uint256 postEscrow
        ) = market.orders(orderId);
        assertEq(postOrderOwner, orderOwner, "order owner changed");
        assertEq(postNumChunks, numChunks, "numChunks changed");
        assertEq(postPeriods, periods, "periods changed");
        assertEq(postReplicas, replicas, "replicas changed");
        assertEq(postFileRoot, fileRoot, "fileRoot changed");
        assertEq(postFilled, filled, "filled changed");
        assertEq(postEscrow, escrow, "escrow changed");
    }

    function test_UpgradeNodeStaking_PreservesState() public {
        _stakeNode(node1, TEST_CAPACITY, 0x1234);
        _stakeNode(node2, TEST_CAPACITY, 0x5678);

        // Snapshot pre-upgrade state
        address preMarket = nodeStaking.market();
        uint256 preGlobalCapacity = nodeStaking.globalTotalCapacity();
        uint256 preGlobalUsed = nodeStaking.globalTotalUsed();
        (uint256 preStake, uint64 preCap, uint64 preUsed, uint256 prePubKey) = nodeStaking.getNodeInfo(node1);

        // Upgrade
        NodeStakingV2 newImpl = new NodeStakingV2();
        nodeStaking.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(nodeStaking.market(), preMarket, "market changed");
        assertEq(nodeStaking.globalTotalCapacity(), preGlobalCapacity, "globalTotalCapacity changed");
        assertEq(nodeStaking.globalTotalUsed(), preGlobalUsed, "globalTotalUsed changed");

        (uint256 postStake, uint64 postCap, uint64 postUsed, uint256 postPubKey) = nodeStaking.getNodeInfo(node1);
        assertEq(postStake, preStake, "node1 stake changed");
        assertEq(postCap, preCap, "node1 capacity changed");
        assertEq(postUsed, preUsed, "node1 used changed");
        assertEq(postPubKey, prePubKey, "node1 publicKey changed");
    }

    // ---------------------------------------------------------------
    // Reinitializer tests
    // ---------------------------------------------------------------

    function test_ReinitializerV2_Works() public {
        FileMarketExtension newExt = new FileMarketExtension();
        FileMarketV2 newImpl = new FileMarketV2(address(newExt));
        bytes memory reinitData = abi.encodeCall(FileMarketV2.initializeV2, (42));
        market.upgradeToAndCall(address(newImpl), reinitData);

        assertEq(FileMarketV2(payable(address(market))).v2ExampleParam(), 42, "v2ExampleParam not set");
        assertEq(FileMarketV2(payable(address(market))).version(), 2);
    }

    function test_ReinitializerV2_CannotRunTwice() public {
        FileMarketExtension newExt = new FileMarketExtension();
        FileMarketV2 newImpl = new FileMarketV2(address(newExt));
        bytes memory reinitData = abi.encodeCall(FileMarketV2.initializeV2, (42));
        market.upgradeToAndCall(address(newImpl), reinitData);

        FileMarketV2 marketV2 = FileMarketV2(payable(address(market)));
        vm.expectRevert();
        marketV2.initializeV2(99);
    }

    function test_CannotReInitializeV1_AfterUpgrade() public {
        FileMarketExtension newExt = new FileMarketExtension();
        FileMarketV2 newImpl = new FileMarketV2(address(newExt));
        market.upgradeToAndCall(address(newImpl), "");

        vm.expectRevert();
        market.initialize(address(this), address(nodeStaking));
    }

    // ---------------------------------------------------------------
    // Functional regression test
    // ---------------------------------------------------------------

    function test_FunctionalRegression_AfterUpgrade() public {
        // Build up pre-upgrade state
        _stakeNode(node1, TEST_CAPACITY, 0x1234);
        (uint256 orderId,) = _placeOrder(user1, 512, 4, 1, 1e12);
        _executeOrder(node1, orderId);

        // Upgrade both contracts
        FileMarketExtension newExt = new FileMarketExtension();
        FileMarketV2 newMarketImpl = new FileMarketV2(address(newExt));
        market.upgradeToAndCall(address(newMarketImpl), "");

        NodeStakingV2 newStakingImpl = new NodeStakingV2();
        nodeStaking.upgradeToAndCall(address(newStakingImpl), "");

        // Precompile mocks from setUp() still apply — no extra mocking needed.

        // --- Verify core operations still work post-upgrade ---

        // stakeNode still works
        _stakeNode(node2, TEST_CAPACITY, 0x5678);
        (uint256 stake2, uint64 cap2,,) = nodeStaking.getNodeInfo(node2);
        assertGt(stake2, 0, "stakeNode failed post-upgrade");
        assertEq(cap2, TEST_CAPACITY);

        // placeOrder still works
        (uint256 orderId2,) = _placeOrder(user1, 256, 2, 1, 1e12);
        assertGt(orderId2, orderId, "placeOrder failed post-upgrade");

        // executeOrder still works
        _executeOrder(node2, orderId2);

        // claimRewards still works (fast-forward 1 period)
        vm.warp(block.timestamp + PERIOD);
        vm.prank(node1);
        market.claimRewards();

        // Admin: transferOwnership still works
        address newOwner = address(0xBEEF);
        market.transferOwnership(newOwner);
        assertEq(market.owner(), newOwner, "transferOwnership failed post-upgrade");
    }

    // ---------------------------------------------------------------
    // Safety tests
    // ---------------------------------------------------------------

    function test_CannotUpgradeToNonUUPS() public {
        // Deploy a contract that is not UUPS-compatible (no proxiableUUID)
        NonUUPSContract badImpl = new NonUUPSContract();

        vm.expectRevert();
        market.upgradeToAndCall(address(badImpl), "");
    }

    function test_NewStorageVariable_AfterUpgrade() public {
        // Build up state
        _stakeNode(node1, TEST_CAPACITY, 0x1234);
        (uint256 orderId,) = _placeOrder(user1, 512, 4, 1, 1e12);
        _executeOrder(node1, orderId);

        // Snapshot existing state
        address preOwner = market.owner();
        uint256 preNextOrderId = market.nextOrderId();

        // Upgrade with reinitializer that sets new V2 param
        FileMarketExtension newExt = new FileMarketExtension();
        FileMarketV2 newImpl = new FileMarketV2(address(newExt));
        bytes memory reinitData = abi.encodeCall(FileMarketV2.initializeV2, (777));
        market.upgradeToAndCall(address(newImpl), reinitData);

        FileMarketV2 marketV2 = FileMarketV2(payable(address(market)));

        // New storage variable is readable
        assertEq(marketV2.v2ExampleParam(), 777, "new param not set");
        assertEq(marketV2.version(), 2, "version not 2");

        // Existing state unaffected
        assertEq(marketV2.owner(), preOwner, "owner changed");
        assertEq(marketV2.nextOrderId(), preNextOrderId, "nextOrderId changed");

        // Existing order data intact
        (address orderOwner,,,,,,, uint256 escrow) = marketV2.orders(orderId);
        assertEq(orderOwner, user1, "order owner changed");
        assertGt(escrow, 0, "escrow zeroed");
    }
}

/// @notice Dummy contract without UUPS — used to test upgrade rejection.
contract NonUUPSContract {
    uint256 public value;
}
