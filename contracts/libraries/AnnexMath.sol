// SPDX-License-Identifier: MIT
pragma solidity >=0.6.8;

/// @notice A library for performing overflow-/underflow-safe math,
/// updated with awesomeness from of DappHub (https://github.com/dapphub/ds-math).
library AnnexMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256 c) {
        require((c = a + b) >= b, "AnnexMath: Add Overflow");
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256 c) {
        require((c = a - b) <= a, "AnnexMath: Underflow");
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
        require(b == 0 || (c = a * b) / b == a, "AnnexMath: Mul Overflow");
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256 c) {
        require(b > 0, "AnnexMath: Div zero");
        c = a / b;
    }

    function to128(uint256 a) internal pure returns (uint128 c) {
        require(a <= uint128(-1), "AnnexMath: uint128 Overflow");
        c = uint128(a);
    }

    function to64(uint256 a) internal pure returns (uint64 c) {
        require(a <= uint64(-1), "AnnexMath: uint64 Overflow");
        c = uint64(a);
    }

    function to32(uint256 a) internal pure returns (uint32 c) {
        require(a <= uint32(-1), "AnnexMath: uint32 Overflow");
        c = uint32(a);
    }

    function to16(uint256 a) internal pure returns (uint16 c) {
        require(a <= uint16(-1), "AnnexMath: uint16 Overflow");
        c = uint16(a);
    }

}

/// @notice A library for performing overflow-/underflow-safe addition and subtraction on uint128.
library AnnexMath128 {
    function add(uint128 a, uint128 b) internal pure returns (uint128 c) {
        require((c = a + b) >= b, "AnnexMath: Add Overflow");
    }

    function sub(uint128 a, uint128 b) internal pure returns (uint128 c) {
        require((c = a - b) <= a, "AnnexMath: Underflow");
    }
}

/// @notice A library for performing overflow-/underflow-safe addition and subtraction on uint64.
library AnnexMath64 {
    function add(uint64 a, uint64 b) internal pure returns (uint64 c) {
        require((c = a + b) >= b, "AnnexMath: Add Overflow");
    }

    function sub(uint64 a, uint64 b) internal pure returns (uint64 c) {
        require((c = a - b) <= a, "AnnexMath: Underflow");
    }
}

/// @notice A library for performing overflow-/underflow-safe addition and subtraction on uint32.
library AnnexMath32 {
    function add(uint32 a, uint32 b) internal pure returns (uint32 c) {
        require((c = a + b) >= b, "AnnexMath: Add Overflow");
    }

    function sub(uint32 a, uint32 b) internal pure returns (uint32 c) {
        require((c = a - b) <= a, "AnnexMath: Underflow");
    }
}

/// @notice A library for performing overflow-/underflow-safe addition and subtraction on uint32.
library AnnexMath16 {
    function add(uint16 a, uint16 b) internal pure returns (uint16 c) {
        require((c = a + b) >= b, "AnnexMath: Add Overflow");
    }

    function sub(uint16 a, uint16 b) internal pure returns (uint16 c) {
        require((c = a - b) <= a, "AnnexMath: Underflow");
    }
}
