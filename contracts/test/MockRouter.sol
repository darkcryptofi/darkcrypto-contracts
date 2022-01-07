// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockRouter {
    uint256 ratio;

    constructor(uint256 _ratio) public {
        ratio = _ratio;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external {
        require(now <= deadline, ">deadline");
        uint256 amountOut = amountIn * ratio / 1e18;
        require(amountOut >= amountOutMin, "slippage");
        address _input = path[0];
        address _output = path[path.length - 1];
        IERC20(_input).transferFrom(msg.sender, address(this), amountIn);
        IERC20(_output).transfer(to, amountOut);
    }

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts) {
        amounts = new uint[](1);
        amounts[0] = amountIn * ratio / 1e18;
    }
}
