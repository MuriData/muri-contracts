// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IPoiVerifier {
    function verifyCompressedProof(uint256[4] calldata compressedProof, uint256[5] calldata input) external view;
}

interface IFspVerifier {
    function verifyCompressedProof(uint256[4] calldata compressedProof, uint256[2] calldata input) external view;
}

interface IKeyLeakVerifier {
    function Verify(bytes calldata proof, uint256[] calldata publicInputs) external view returns (bool success);
}
