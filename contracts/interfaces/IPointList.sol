// SPDX-License-Identifier: MIT
pragma solidity >=0.6.8;

// ----------------------------------------------------------------------------
// White List interface
// ----------------------------------------------------------------------------

interface IPointList {
    function isInList(address account) external view returns (bool);

    function hasPoints(address account, uint256 amount)
        external
        view
        returns (bool);

    function setPoints(address[] memory accounts, uint256[] memory amounts)
        external;

    function initPointList(address accessControl) external;
}
