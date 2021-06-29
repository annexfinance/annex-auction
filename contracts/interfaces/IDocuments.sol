// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface IDocuments {
    function _removeDocument(string calldata _name) external;

    function getDocumentCount() external view returns (uint256);

    function getAllDocuments() external view returns (bytes memory);

    function _setDocument(string calldata _name, string calldata _data)
        external;

    function getDocumentName(uint256 _index)
        external
        view
        returns (string memory);

    function getDocument(string calldata _name)
        external
        view
        returns (string memory, uint256);
}
