// SPDX-License-Identifier: MIT
pragma solidity >=0.6.8;

import "./SafeCast.sol";
import "./IdToAddressBiMap.sol";
import "../interfaces/IERC20.sol";
import "./IterableOrderedOrderSet.sol";

library AnnexAuction {
    using IdToAddressBiMap for IdToAddressBiMap.Data;

    bytes4 private constant SIG_SYMBOL = 0x95d89b41; // symbol()

    function sendOutTokens(IERC20 token) internal view returns (string memory) {
        (bool success, bytes memory data) =
            address(token).staticcall(abi.encodeWithSelector(SIG_SYMBOL));
        return success && data.length > 0 ? abi.decode(data, (string)) : "???";
    }
}
