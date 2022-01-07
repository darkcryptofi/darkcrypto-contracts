// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IStrategy {
    function want() external view returns (address);

    function farmingToken() external view returns (address);

    function targetProfitToken() external view returns (address);

    function inFarmBalance() external view returns (uint256);

    function totalBalance() external view returns (uint256);

    function deposit(address _account, uint256 _amount) external;

    function withdraw(address _account, uint256 _amount) external;

    function withdrawAll() external;
}
