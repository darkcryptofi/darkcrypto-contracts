// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ISafeTreasuryPolicy {
    function minting_fee() external view returns (uint256);

    function redemption_fee() external view returns (uint256);

    function reserve_share_state() external view returns (uint8);
}
