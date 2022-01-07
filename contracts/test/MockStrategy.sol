// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/IFarmingPool.sol";

contract MockStrategy is IStrategy {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public lp;
    address public override farmingToken;
    address public farmingPool;
    address public override targetProfitToken;

    constructor(address _lp, address _farmingToken, address _farmingPool, address _targetProfitToken) public {
        lp = _lp;
        farmingToken = _farmingToken;
        farmingPool = _farmingPool;
        targetProfitToken = _targetProfitToken;
    }

    function want() external override view returns (address) {
        return lp;
    }

    function inFarmBalance() public override view returns (uint256) {
        (uint256 amount, ) = IFarmingPool(farmingPool).userInfo(0, address(this));
        return amount;
    }

    function totalBalance() external override view returns (uint256) {
        return IERC20(lp).balanceOf(address(this)).add(inFarmBalance());
    }

    function deposit(address, uint256 _amount) external override {
        IERC20(lp).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(lp).safeIncreaseAllowance(farmingPool, _amount);
        IFarmingPool(farmingPool).deposit(0, _amount);
    }

    function withdraw(address, uint256 _amount) public override {
        IFarmingPool(farmingPool).withdraw(0, _amount);
        IERC20(lp).safeTransfer(msg.sender, _amount);
    }

    function withdrawAll() external override {
        withdraw(msg.sender, inFarmBalance());
    }
}
