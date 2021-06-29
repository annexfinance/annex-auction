// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

///////////////////////////////////////////////////////////////////////////////////////////////////////////
// Contract does not have test coverage, as it was nearly copied from:
// https://github.com/gnosis/solidity-data-structures/blob/master/contracts/libraries/IdToAddressBiMap.sol
// The only change is uint16 -> uint64
///////////////////////////////////////////////////////////////////////////////////////////////////////////

/** 
    INVALID_ID: Must have ID to get Address
    INVALID_ADDRESS: Must have Address to get ID
    ERROR_ZERO : Cannot insert zero address
    ERROR_64 : Cannot insert max uint64
**/

library IdToAddressBiMap {
    struct Data {
        mapping(uint64 => address) idToAddress;
        mapping(address => uint64) addressToId;
    }

    function hasId(Data storage self, uint64 id) internal view returns (bool) {
        return self.idToAddress[id + 1] != address(0);
    }

    function hasAddress(Data storage self, address addr)
        internal
        view
        returns (bool)
    {
        return self.addressToId[addr] != 0;
    }

    function getAddressAt(Data storage self, uint64 id)
        internal
        view
        returns (address)
    {
        require(hasId(self, id), "INVALID_ID");
        return self.idToAddress[id + 1];
    }

    function getId(Data storage self, address addr)
        internal
        view
        returns (uint64)
    {
        require(hasAddress(self, addr), "INVALID_ADDRESS");
        return self.addressToId[addr] - 1;
    }

    function insert(
        Data storage self,
        uint64 id,
        address addr
    ) internal returns (bool) {
        require(addr != address(0), "ERROR_ZERO");
        require(id != uint64(-1), "ERROR_64");
        // Ensure bijectivity of the mappings
        if (
            self.addressToId[addr] != 0 ||
            self.idToAddress[id + 1] != address(0)
        ) {
            return false;
        }
        self.idToAddress[id + 1] = addr;
        self.addressToId[addr] = id + 1;
        return true;
    }
}
