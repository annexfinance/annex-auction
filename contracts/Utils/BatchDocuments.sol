// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../seriality/Seriality.sol";

/**
 * @title Standard implementation of ERC1643 Document management
 */
contract BatchDocuments is Ownable, Seriality {
    struct Document {
        uint32 docIndex; // Store the document name indexes
        uint64 lastModified; // Timestamp at which document details was last modified
        string data; // data of the document that exist off-chain
    }

    // mapping to store the documents details in the document
    mapping(string => Document) internal _documents;
    // mapping to store the document name indexes
    mapping(string => uint32) internal _docIndexes;
    // Array use to store all the document name present in the contracts
    string[] internal _docNames;

    constructor() public Ownable() {}

    // Document Events
    event DocumentRemoved(string indexed _name, string _data);
    event DocumentUpdated(string indexed _name, string _data);

    /**
     * @notice Used to attach a new document to the contract, or update the data or hash of an existing attached document
     * @dev Can only be executed by the owner of the contract.
     * @param _name Name of the document. It should be unique always
     * @param _data Off-chain data of the document from where it is accessible to investors/advisors to read.
     */
    function _setDocument(string calldata _name, string calldata _data)
        external
        onlyOwner
    {
        require(bytes(_name).length > 0, "Zero name is not allowed");
        require(bytes(_data).length > 0, "Should not be a empty data");
        // Document storage document = _documents[_name];
        if (_documents[_name].lastModified == uint64(0)) {
            _docNames.push(_name);
            _documents[_name].docIndex = uint32(_docNames.length);
        }
        _documents[_name] = Document(
            _documents[_name].docIndex,
            uint64(block.timestamp),
            _data
        );
        emit DocumentUpdated(_name, _data);
    }

    /**
     * @notice Used to remove an existing document from the contract by giving the name of the document.
     * @dev Can only be executed by the owner of the contract.
     * @param _name Name of the document. It should be unique always
     */

    function _removeDocument(string calldata _name) external onlyOwner {
        require(
            _documents[_name].lastModified != uint64(0),
            "Document should exist"
        );
        uint32 index = _documents[_name].docIndex - 1;
        if (index != _docNames.length - 1) {
            _docNames[index] = _docNames[_docNames.length - 1];
            _documents[_docNames[index]].docIndex = index + 1;
        }
        _docNames.pop();
        emit DocumentRemoved(_name, _documents[_name].data);
        delete _documents[_name];
    }

    /**
     * @notice Used to return the details of a document with a known name (`string`).
     * @param _name Name of the document
     * @return string The data associated with the document.
     * @return uint256 the timestamp at which the document was last modified.
     */
    function getDocument(string calldata _name)
        external
        view
        returns (string memory, uint256)
    {
        return (
            _documents[_name].data,
            uint256(_documents[_name].lastModified)
        );
    }

    /**
     * @notice Used to retrieve a full list of documents attached to the smart contract.
     * @return string List of all documents names present in the contract.
     */
    function getAllDocuments() external view returns (bytes memory) {
        uint startindex = 0;
        uint endindex = _docNames.length;
        require(endindex >= startindex);

        if (endindex > (_docNames.length - 1)) {
            endindex = _docNames.length - 1;
        }

        uint offset = 64 * ((endindex - startindex) + 1);

        bytes memory buffer = new bytes(offset);
        string memory out1 = new string(32);

        for (uint i = startindex; i <= endindex; i++) {
            out1 = _docNames[i];

            stringToBytes(offset, bytes(out1), buffer);
            offset -= sizeOfString(out1);
        }
        return buffer;
    }

    /**
     * @notice Used to retrieve the total documents in the smart contract.
     * @return uint256 Count of the document names present in the contract.
     */
    function getDocumentCount() external view returns (uint256) {
        return _docNames.length;
    }

    /**
     * @notice Used to retrieve the document name from index in the smart contract.
     * @return string Name of the document name.
     */
    function getDocumentName(uint256 _index)
        external
        view
        returns (string memory)
    {
        require(_index < _docNames.length, "Index out of bounds");
        return _docNames[_index];
    }
}
