// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../interfaces/IFarmingPool.sol";

contract MockFarmingPool is IFarmingPool {
    using SafeMath for uint256;

    address public lp;
    address public reward;
    uint256 public rewardAmount;

    mapping(address => uint256) private userBalances;

    constructor(address _lp, address _reward, uint256 _rewardAmount) public {
        lp = _lp;
        reward = _reward;
        rewardAmount = _rewardAmount;
    }

    function pendingReward(uint256, address) external override view returns (uint256) {
        return rewardAmount;
    }

    function userInfo(uint256, address _user) external override view returns (uint256 amount, uint256 rewardDebt) {
        amount = userBalances[_user];
        rewardDebt = 0;
    }

    function deposit(uint256, uint256 _amount) external override {
        userBalances[msg.sender] = userBalances[msg.sender].add(_amount);
        IERC20(lp).transferFrom(msg.sender, address(this), _amount);
    }

    function withdraw(uint256, uint256 _amount) external override {
        if (_amount == 0) {
            IERC20(reward).transfer(msg.sender, rewardAmount);
        } else {
            userBalances[msg.sender] = userBalances[msg.sender].sub(_amount);
            IERC20(lp).transfer(msg.sender, _amount);
        }
    }
}
