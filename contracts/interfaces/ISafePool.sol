// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ISafePool {
    function calcMintInput(uint256 _safeAssetAmount) external view returns (uint256 _collateralAmount, uint256 _shareAmount);

    function calcMintOutputFromCollateral(uint256 _collateralAmount) external view returns (uint256 _safeAssetAmount, uint256 _shareAmount);

    function calcMintOutputFromShare(uint256 _shareAmount) external view returns (uint256 _safeAssetAmount, uint256 _collateralAmount);

    function calcRedeemOutput(uint256 _safeAssetAmount) external view returns (uint256 _collateralAmount, uint256 _shareAmount);

    function getCollateralPrice() external view returns (uint256);

    function getSharePrice() external view returns (uint256);

    function getEffectiveCollateralRatio() external view returns (uint256);

    function getRedemptionOpenTime(address _account) external view returns (uint256);

    function unclaimed_pool_collateral() external view returns (uint256);

    function unclaimed_pool_share() external view returns (uint256);

    function treasuryMintByShares(address _receiver, uint256 _safeAssetAmount) external returns (uint256 _shareAmount);
}
