// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Interface for the Groth16 BN254 verifier precompile at 0x0300000000000000000000000000000000000001.
interface IGroth16Precompile {
    /// @notice Verify a compressed Groth16 BN254 proof with the given verification key.
    /// @param compressedProof Compressed proof [compressed_A, B_c1, B_c0, compressed_C]
    /// @param publicInputs The public input scalars (variable length, each must be < R)
    /// @param vkAlpha Alpha G1 point [x, y]
    /// @param vkBetaNeg Negated Beta G2 point [x1, x0, y1, y0] (EIP-197 order)
    /// @param vkGammaNeg Negated Gamma G2 point [x1, x0, y1, y0]
    /// @param vkDeltaNeg Negated Delta G2 point [x1, x0, y1, y0]
    /// @param vkIC Verification key IC G1 points, length must equal publicInputs.length + 1
    /// @return valid True if the proof is valid
    function verifyCompressedProof(
        uint256[4] calldata compressedProof,
        uint256[] calldata publicInputs,
        uint256[2] calldata vkAlpha,
        uint256[4] calldata vkBetaNeg,
        uint256[4] calldata vkGammaNeg,
        uint256[4] calldata vkDeltaNeg,
        uint256[2][] calldata vkIC
    ) external view returns (bool valid);
}
