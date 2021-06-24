// SPDX-License-Identifier: MIT
pragma solidity >=0.6.8;

interface IAnnexMarket {

    function init(bytes calldata data) external payable;
    function initMarket( bytes calldata data ) external;
    function marketTemplate() external view returns (uint256);

}
