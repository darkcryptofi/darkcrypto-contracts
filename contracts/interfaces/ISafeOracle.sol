// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ISafeOracle {
    function consult() external view returns (uint256);

    function consultTrue() external view returns (uint256);
}
