// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FileMarket} from "../../src/Market.sol";
import {FileMarketExtension} from "../../src/FileMarketExtension.sol";
import {NodeStaking} from "../../src/NodeStaking.sol";
import {MarketStorage} from "../../src/market/MarketStorage.sol";
import {Verifier} from "muri-artifacts/poi/poi_verifier.sol";
import {Verifier as FspVerifier} from "muri-artifacts/fsp/fsp_verifier.sol";
import {PlonkVerifier as KeyLeakVerifier} from "muri-artifacts/keyleak/keyleak_verifier.sol";

/// @notice FSP (File Size Proof) integration tests using real proof fixture.
/// These tests do NOT mock the FSP verifier — they use the actual Groth16 verifier
/// with the deterministic fixture from `fsp_proof_fixture.json`.
contract MarketFSPTest is Test {
    FileMarket internal market;
    NodeStaking internal nodeStaking;

    address internal user1 = address(0x1111);
    address internal node1 = address(0x3333);

    uint256 internal constant STAKE_PER_CHUNK = 4 * 10 ** 14;

    // --- Fixture values from fsp_proof_fixture.json ---
    uint256 constant FSP_ROOT = 0x18b3b3b2725896132b5bc40a1046132880775d2160f1fbf5dc70ffc58a9228c7;
    uint32 constant FSP_NUM_CHUNKS = 8;

    function _fspProof() internal view returns (uint256[4] memory proof) {
        uint256[8] memory rawProof;
        rawProof[0] = 0x2989e4633aeca515c82251fc0a8a52519693a79a55a5d3a877ab47b283a1ebc9;
        rawProof[1] = 0x2070e6ac3ac6034e5ce8334a596a425e47537675598fc2decd97e7582339d45f;
        rawProof[2] = 0x1d95ea80d2976f97741177a5f78b174bf02f4f0f9c6df24f16632bafb50df800;
        rawProof[3] = 0x2d5d5701c35e1c2427e9349848ae445d2eb935940ad7147208bde96707993e55;
        rawProof[4] = 0x173f8e924fa8a6f18e5026186aec9f7ec6743c404f8e6dd46ff77e744eb885d1;
        rawProof[5] = 0x1120ed653a041099aad35e811f2aa93ac7a87add3368a2ce3fa4aef7aa92b3ee;
        rawProof[6] = 0x1796e53b378dd58e5d5790054c9557263982416763fb2707a021463ec330d816;
        rawProof[7] = 0x28b86dfdd8b99565d108f4f78b460e3a546e3c2c646d3e1903e2f4a859b1e703;
        proof = FspVerifier(address(market.fspVerifier())).compressProof(rawProof);
    }

    function _fspFileMeta() internal pure returns (MarketStorage.FileMeta memory) {
        return MarketStorage.FileMeta({root: FSP_ROOT, uri: "QmFSPTestHash"});
    }

    function setUp() public {
        // Deploy verifiers
        Verifier poiVerifier = new Verifier();
        FspVerifier fspVerifierContract = new FspVerifier();
        KeyLeakVerifier keyleakVerifier = new KeyLeakVerifier();

        // Deploy NodeStaking impl + proxy (uninitialized)
        NodeStaking stakingImpl = new NodeStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");

        // Deploy FileMarketExtension + FileMarket impl + proxy (initialized)
        FileMarketExtension ext = new FileMarketExtension();
        FileMarket marketImpl = new FileMarket(address(ext));
        bytes memory marketInitData = abi.encodeCall(
            FileMarket.initialize,
            (
                address(this),
                address(stakingProxy),
                address(poiVerifier),
                address(fspVerifierContract),
                address(keyleakVerifier)
            )
        );
        ERC1967Proxy marketProxy = new ERC1967Proxy(address(marketImpl), marketInitData);

        // Initialize NodeStaking with market proxy
        NodeStaking(address(stakingProxy)).initialize(address(marketProxy));

        market = FileMarket(payable(address(marketProxy)));
        nodeStaking = NodeStaking(address(stakingProxy));

        // Mock PoI verifier to always succeed (FSP tests don't test PoI proofs)
        vm.mockCall(
            address(market.poiVerifier()), abi.encodeWithSelector(Verifier.verifyCompressedProof.selector), abi.encode()
        );

        vm.deal(user1, 100 ether);
        vm.deal(node1, 100 ether);
    }

    function _emptyPoiProof() internal pure returns (uint256[4] memory proof) {}

    function test_ValidFSPProof_PlacesOrder() public {
        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(_fspFileMeta(), FSP_NUM_CHUNKS, 4, 1, 1e12, _fspProof());
        assertGt(orderId, 0);
    }

    function test_ValidFSPProof_EscrowCorrect() public {
        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        market.placeOrder{value: totalCost}(_fspFileMeta(), FSP_NUM_CHUNKS, 4, 1, 1e12, _fspProof());
        assertEq(market.aggregateActiveEscrow(), totalCost);
    }

    function test_InvalidFSPProof_Reverts() public {
        uint256[4] memory badProof = _fspProof();
        badProof[0] ^= 1; // flip one bit

        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        vm.expectRevert();
        market.placeOrder{value: totalCost}(_fspFileMeta(), FSP_NUM_CHUNKS, 4, 1, 1e12, badProof);
    }

    function test_WrongNumChunks_Reverts() public {
        uint32 wrongChunks = 16; // proof was generated for 8 chunks
        uint256 totalCost = uint256(wrongChunks) * 4 * 1e12 * 1;
        uint256[4] memory proof = _fspProof();

        vm.prank(user1);
        vm.expectRevert();
        market.placeOrder{value: totalCost}(_fspFileMeta(), wrongChunks, 4, 1, 1e12, proof);
    }

    function test_WrongRootHash_Reverts() public {
        MarketStorage.FileMeta memory wrongMeta = MarketStorage.FileMeta({
            root: 0x1111111111111111111111111111111111111111111111111111111111111111, uri: "QmWrongRoot"
        });
        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        uint256[4] memory proof = _fspProof();

        vm.prank(user1);
        vm.expectRevert();
        market.placeOrder{value: totalCost}(wrongMeta, FSP_NUM_CHUNKS, 4, 1, 1e12, proof);
    }

    function test_ValidFSPProof_FullOrderLifecycle() public {
        // Stake a node
        uint256 stake = uint256(1024) * STAKE_PER_CHUNK;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(1024, 0x1234);

        // Place order with valid FSP proof
        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(_fspFileMeta(), FSP_NUM_CHUNKS, 4, 1, 1e12, _fspProof());

        // Execute order
        vm.prank(node1);
        market.executeOrder(orderId, _emptyPoiProof(), bytes32(0));

        // Verify node capacity updated by numChunks
        (, uint64 capacity, uint64 used,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, FSP_NUM_CHUNKS);
        assertEq(capacity, 1024);
    }
}
