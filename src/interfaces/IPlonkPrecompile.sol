// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Interface for the PLONK BN254 verifier precompile at 0x0300000000000000000000000000000000000004.
interface IPlonkPrecompile {
    /// @notice Verify a PLONK BN254 proof with the given verification key.
    /// @param proof Serialized PLONK proof (768 bytes, gnark MarshalSolidity format)
    /// @param publicInputs The public input scalars (each must be < R)
    /// @param vkDomainSize Domain size (power of 2)
    /// @param vkNbPublicInputs Expected number of public inputs
    /// @param vkOmega Primitive n-th root of unity
    /// @param vkQL QL gate selector commitment [x, y]
    /// @param vkQR QR gate selector commitment [x, y]
    /// @param vkQM QM gate selector commitment [x, y]
    /// @param vkQO QO gate selector commitment [x, y]
    /// @param vkQK QK gate selector commitment [x, y]
    /// @param vkS1 S1 permutation commitment [x, y]
    /// @param vkS2 S2 permutation commitment [x, y]
    /// @param vkS3 S3 permutation commitment [x, y]
    /// @param vkG2Srs0 G2 SRS point 0 [x1, x0, y1, y0] (EIP-197 order)
    /// @param vkG2Srs1 G2 SRS point 1 [x1, x0, y1, y0] (EIP-197 order)
    /// @param vkCosetShift Coset shift value
    /// @return valid True if the proof is valid
    function verifyProof(
        bytes calldata proof,
        uint256[] calldata publicInputs,
        uint64 vkDomainSize,
        uint64 vkNbPublicInputs,
        uint256 vkOmega,
        uint256[2] calldata vkQL,
        uint256[2] calldata vkQR,
        uint256[2] calldata vkQM,
        uint256[2] calldata vkQO,
        uint256[2] calldata vkQK,
        uint256[2] calldata vkS1,
        uint256[2] calldata vkS2,
        uint256[2] calldata vkS3,
        uint256[4] calldata vkG2Srs0,
        uint256[4] calldata vkG2Srs1,
        uint256 vkCosetShift
    ) external view returns (bool valid);
}
