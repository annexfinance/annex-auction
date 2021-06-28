// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IDocuments{ 
    function getDocument(string calldata _name) external view returns (string memory, uint256);
    function getAllDocuments() external view returns (string[] memory);
    function getDocumentCount() external view returns (uint256);
    function getDocumentName(uint256 _index) external view returns (string memory);
}