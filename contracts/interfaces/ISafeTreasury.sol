// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ISafeTreasury {
    function hasPool(address _address) external view returns (bool);

    function minting_fee() external view returns (uint256);

    function redemption_fee() external view returns (uint256);

    function reserve_share_state() external view returns (uint8);

    function collateralReserve() external view returns (address);

    function profitSharingFund() external view returns (address);

    function globalCollateralBalance() external view returns (uint256);

    function globalCollateralValue() external view returns (uint256);

    function globalShareBalance() external view returns (uint256);

    function globalShareValue() external view returns (uint256);

    function requestTransfer(address token, address receiver, uint256 amount) external;

    function reserveReceiveShares(uint256 amount) external;

    function info()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint8
        );
}
