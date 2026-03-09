// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IGroth16Precompile} from "../interfaces/IGroth16Precompile.sol";
import {IPlonkPrecompile} from "../interfaces/IPlonkPrecompile.sol";
import {PoiVK} from "muri-artifacts/poi/poi_vk.sol";
import {FspVK} from "muri-artifacts/fsp/fsp_vk.sol";
import {KeyleakVK} from "muri-artifacts/keyleak/keyleak_vk.sol";

/// @notice Thin verification helpers that call native precompiles with VK constants
///         imported from muri-artifacts. Replaces the ~500-line generated Solidity verifiers.
library PrecompileVerifiers {
    IGroth16Precompile internal constant GROTH16 =
        IGroth16Precompile(0x0300000000000000000000000000000000000001);
    IPlonkPrecompile internal constant PLONK =
        IPlonkPrecompile(0x0300000000000000000000000000000000000004);

    error ProofInvalid();

    // ═════════════════════════════════════════════════════════════════════════
    //  PoI (Proof of Integrity) — Groth16, 5 public inputs
    // ═════════════════════════════════════════════════════════════════════════

    function verifyPoiProof(uint256[4] calldata proof, uint256[5] memory inputs) internal view {
        uint256[] memory dynInputs = new uint256[](5);
        dynInputs[0] = inputs[0];
        dynInputs[1] = inputs[1];
        dynInputs[2] = inputs[2];
        dynInputs[3] = inputs[3];
        dynInputs[4] = inputs[4];

        bool valid = GROTH16.verifyCompressedProof(
            proof,
            dynInputs,
            [PoiVK.ALPHA_X, PoiVK.ALPHA_Y],
            [PoiVK.BETA_NEG_X1, PoiVK.BETA_NEG_X0, PoiVK.BETA_NEG_Y1, PoiVK.BETA_NEG_Y0],
            [PoiVK.GAMMA_NEG_X1, PoiVK.GAMMA_NEG_X0, PoiVK.GAMMA_NEG_Y1, PoiVK.GAMMA_NEG_Y0],
            [PoiVK.DELTA_NEG_X1, PoiVK.DELTA_NEG_X0, PoiVK.DELTA_NEG_Y1, PoiVK.DELTA_NEG_Y0],
            _poiIC()
        );
        if (!valid) revert ProofInvalid();
    }

    function _poiIC() private pure returns (uint256[2][] memory ic) {
        ic = new uint256[2][](6);
        ic[0] = [PoiVK.IC_0_X, PoiVK.IC_0_Y];
        ic[1] = [PoiVK.IC_1_X, PoiVK.IC_1_Y];
        ic[2] = [PoiVK.IC_2_X, PoiVK.IC_2_Y];
        ic[3] = [PoiVK.IC_3_X, PoiVK.IC_3_Y];
        ic[4] = [PoiVK.IC_4_X, PoiVK.IC_4_Y];
        ic[5] = [PoiVK.IC_5_X, PoiVK.IC_5_Y];
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FSP (File-Size Proof) — Groth16, 2 public inputs
    // ═════════════════════════════════════════════════════════════════════════

    function verifyFspProof(uint256[4] calldata proof, uint256[2] memory inputs) internal view {
        uint256[] memory dynInputs = new uint256[](2);
        dynInputs[0] = inputs[0];
        dynInputs[1] = inputs[1];

        bool valid = GROTH16.verifyCompressedProof(
            proof,
            dynInputs,
            [FspVK.ALPHA_X, FspVK.ALPHA_Y],
            [FspVK.BETA_NEG_X1, FspVK.BETA_NEG_X0, FspVK.BETA_NEG_Y1, FspVK.BETA_NEG_Y0],
            [FspVK.GAMMA_NEG_X1, FspVK.GAMMA_NEG_X0, FspVK.GAMMA_NEG_Y1, FspVK.GAMMA_NEG_Y0],
            [FspVK.DELTA_NEG_X1, FspVK.DELTA_NEG_X0, FspVK.DELTA_NEG_Y1, FspVK.DELTA_NEG_Y0],
            _fspIC()
        );
        if (!valid) revert ProofInvalid();
    }

    function _fspIC() private pure returns (uint256[2][] memory ic) {
        ic = new uint256[2][](3);
        ic[0] = [FspVK.IC_0_X, FspVK.IC_0_Y];
        ic[1] = [FspVK.IC_1_X, FspVK.IC_1_Y];
        ic[2] = [FspVK.IC_2_X, FspVK.IC_2_Y];
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  KeyLeak — PLONK, 2 public inputs
    // ═════════════════════════════════════════════════════════════════════════

    function verifyKeyLeakProof(bytes calldata proof, uint256[] memory inputs) internal view {
        bool valid = PLONK.verifyProof(
            proof,
            inputs,
            KeyleakVK.DOMAIN_SIZE,
            KeyleakVK.NB_PUBLIC_INPUTS,
            KeyleakVK.OMEGA,
            [KeyleakVK.QL_X, KeyleakVK.QL_Y],
            [KeyleakVK.QR_X, KeyleakVK.QR_Y],
            [KeyleakVK.QM_X, KeyleakVK.QM_Y],
            [KeyleakVK.QO_X, KeyleakVK.QO_Y],
            [KeyleakVK.QK_X, KeyleakVK.QK_Y],
            [KeyleakVK.S1_X, KeyleakVK.S1_Y],
            [KeyleakVK.S2_X, KeyleakVK.S2_Y],
            [KeyleakVK.S3_X, KeyleakVK.S3_Y],
            [KeyleakVK.G2_SRS_0_X1, KeyleakVK.G2_SRS_0_X0, KeyleakVK.G2_SRS_0_Y1, KeyleakVK.G2_SRS_0_Y0],
            [KeyleakVK.G2_SRS_1_X1, KeyleakVK.G2_SRS_1_X0, KeyleakVK.G2_SRS_1_Y1, KeyleakVK.G2_SRS_1_Y0],
            KeyleakVK.COSET_SHIFT
        );
        if (!valid) revert ProofInvalid();
    }
}
