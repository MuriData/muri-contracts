// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FileMarket} from "../../src/Market.sol";
import {FileMarketExtension} from "../../src/FileMarketExtension.sol";
import {NodeStaking} from "../../src/NodeStaking.sol";
import {IGroth16Precompile} from "../../src/interfaces/IGroth16Precompile.sol";
import {IPlonkPrecompile} from "../../src/interfaces/IPlonkPrecompile.sol";

/// @notice FSP (File Size Proof) order lifecycle tests.
/// Proof verification is handled by the Groth16 precompile (mocked in Foundry).
/// For real proof validation tests, run against a chain with native precompiles.
contract MarketFSPTest is Test {
    FileMarket internal market;
    NodeStaking internal nodeStaking;

    address internal user1 = address(0x1111);
    address internal node1 = address(0x3333);

    uint256 internal constant STAKE_PER_CHUNK = 4 * 10 ** 14;

    address internal constant GROTH16_PRECOMPILE = 0x0300000000000000000000000000000000000001;
    address internal constant PLONK_PRECOMPILE = 0x0300000000000000000000000000000000000004;

    // --- Fixture values from fsp_proof_fixture.json ---
    uint256 constant FSP_ROOT = 0x18b3b3b2725896132b5bc40a1046132880775d2160f1fbf5dc70ffc58a9228c7;
    uint32 constant FSP_NUM_CHUNKS = 8;

    function _emptyFspProof() internal pure returns (uint256[4] memory proof) {}
    function _emptyPoiProof() internal pure returns (uint256[4] memory proof) {}

    function setUp() public {
        // Deploy NodeStaking impl + proxy (uninitialized)
        NodeStaking stakingImpl = new NodeStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");

        // Deploy FileMarketExtension + FileMarket impl + proxy (initialized)
        FileMarketExtension ext = new FileMarketExtension();
        FileMarket marketImpl = new FileMarket(address(ext));
        bytes memory marketInitData = abi.encodeCall(
            FileMarket.initialize,
            (address(this), address(stakingProxy))
        );
        ERC1967Proxy marketProxy = new ERC1967Proxy(address(marketImpl), marketInitData);

        // Initialize NodeStaking with market proxy
        NodeStaking(address(stakingProxy)).initialize(address(marketProxy));

        market = FileMarket(payable(address(marketProxy)));
        nodeStaking = NodeStaking(address(stakingProxy));

        // Mock Groth16 precompile (PoI + FSP)
        vm.mockCall(
            GROTH16_PRECOMPILE,
            abi.encodeWithSelector(IGroth16Precompile.verifyCompressedProof.selector),
            abi.encode(true)
        );

        // Mock PLONK precompile (KeyLeak)
        vm.mockCall(
            PLONK_PRECOMPILE,
            abi.encodeWithSelector(IPlonkPrecompile.verifyProof.selector),
            abi.encode(true)
        );

        vm.deal(user1, 100 ether);
        vm.deal(node1, 100 ether);
    }

    function test_ValidFSPProof_PlacesOrder() public {
        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(FSP_ROOT, "QmFSPTestHash", FSP_NUM_CHUNKS, 4, 1, 1e12, _emptyFspProof());
        assertGt(orderId, 0);
    }

    function test_ValidFSPProof_EscrowCorrect() public {
        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        market.placeOrder{value: totalCost}(FSP_ROOT, "QmFSPTestHash", FSP_NUM_CHUNKS, 4, 1, 1e12, _emptyFspProof());
        assertEq(market.aggregateActiveEscrow(), totalCost);
    }

    function test_InvalidFSPProof_Reverts() public {
        // Mock the precompile to reject this specific call
        vm.mockCallRevert(
            GROTH16_PRECOMPILE,
            abi.encodeWithSelector(IGroth16Precompile.verifyCompressedProof.selector),
            "proof invalid"
        );

        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        vm.expectRevert();
        market.placeOrder{value: totalCost}(FSP_ROOT, "QmFSPTestHash", FSP_NUM_CHUNKS, 4, 1, 1e12, _emptyFspProof());
    }

    function test_ValidFSPProof_FullOrderLifecycle() public {
        // Stake a node
        uint256 stake = uint256(1024) * STAKE_PER_CHUNK;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(1024, 0x1234);

        // Place order with FSP proof
        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(FSP_ROOT, "QmFSPTestHash", FSP_NUM_CHUNKS, 4, 1, 1e12, _emptyFspProof());

        // Execute order
        vm.prank(node1);
        market.executeOrder(orderId, _emptyPoiProof(), bytes32(0));

        // Verify node capacity updated by numChunks
        (, uint64 capacity, uint64 used,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, FSP_NUM_CHUNKS);
        assertEq(capacity, 1024);
    }
}
