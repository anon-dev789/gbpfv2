// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SpreadCurve} from "../src/SpreadCurve.sol";

/// @dev Loads test vectors produced by script/python/generate_curve_vectors.py and asserts
///      the on-chain Solidity output matches the Python reference to within tight tolerance.
///
///      The reference uses double-precision math (~15 decimal digits); the Solidity curve
///      uses Solady's expWad / divWad / mulWad, which have their own rounding rules.
///      Tolerance is set so that any disagreement *larger than 1 part in 1e14* of WAD
///      counts as a divergence — well below anything economically meaningful but tight
///      enough to catch real bugs in the math chain.
contract SpreadCurveDifferentialTest is Test {
    using stdJson for string;

    /// 1 part in 1e14 of WAD = 1e4 wei.
    /// At WAD = 1e18, this is 1e-14 relative precision — comfortably tighter than the
    /// ~1e-15 floor imposed by Solady's WAD-fixed arithmetic, and far tighter than any
    /// bp-scale concern in the protocol.
    uint256 internal constant ABS_TOL_WAD = 1e4;

    struct Vector {
        uint256 solvencyWad;
        int256 expectedSpreadWad;
    }

    Vector[] internal vectors;

    function setUp() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/test/vectors/spread_curve.json");
        string memory raw = vm.readFile(path);

        // Parse the array of {solvency_wad, expected_spread_wad}.
        // forge-std stdJson reads string-encoded ints (we emit them as strings to avoid
        // any precision loss through JSON's number type).
        bytes memory countBytes = raw.parseRaw(".count");
        uint256 count = abi.decode(countBytes, (uint256));
        require(count > 0, "no vectors in file");

        for (uint256 i = 0; i < count; i++) {
            string memory base = string.concat(".vectors[", vm.toString(i), "]");
            string memory sStr = raw.readString(string.concat(base, ".solvency_wad"));
            string memory eStr = raw.readString(string.concat(base, ".expected_spread_wad"));
            vectors.push(Vector({solvencyWad: vm.parseUint(sStr), expectedSpreadWad: vm.parseInt(eStr)}));
        }
    }

    function test_differential_against_python_reference() public {
        uint256 maxAbsDiff = 0;
        uint256 maxAtIndex = type(uint256).max;

        for (uint256 i = 0; i < vectors.length; i++) {
            Vector memory v = vectors[i];
            int256 got = SpreadCurve.spread(v.solvencyWad);

            int256 diff = got - v.expectedSpreadWad;
            uint256 absDiff = uint256(diff < 0 ? -diff : diff);

            if (absDiff > ABS_TOL_WAD) {
                emit log_named_uint("index   ", i);
                emit log_named_uint("solvency", v.solvencyWad);
                emit log_named_int("expected", v.expectedSpreadWad);
                emit log_named_int("got     ", got);
                emit log_named_uint("|diff|  ", absDiff);
                emit log_named_uint("tol     ", ABS_TOL_WAD);
                revert("differential mismatch");
            }

            if (absDiff > maxAbsDiff) {
                maxAbsDiff = absDiff;
                maxAtIndex = i;
            }
        }

        emit log_named_uint("vectors_checked", vectors.length);
        emit log_named_uint("max_abs_diff_wei", maxAbsDiff);
        if (maxAtIndex < vectors.length) {
            emit log_named_uint("max_diff_at_solvency", vectors[maxAtIndex].solvencyWad);
        }
    }
}
