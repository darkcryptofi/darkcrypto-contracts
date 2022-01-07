// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../../interfaces/ISafeOracle.sol";

contract MockSafeOracle is ISafeOracle {
    address public token;
    uint256 public mockPrice;
    uint256 public minPrice;

    constructor(address _token, uint256 _mockPrice, uint256 _minPrice) public {
        token = _token;
        mockPrice = _mockPrice;
        minPrice = _minPrice;
    }

    function consult() external view override returns (uint256) {
        return (mockPrice > minPrice) ? mockPrice : minPrice;
    }

    function consultTrue() external view override returns (uint256) {
        return mockPrice;
    }

    function setMockPrice(uint256 _mockPrice) external {
        mockPrice = _mockPrice;
    }

    function setMinPrice(uint256 _minPrice) external {
        minPrice = _minPrice;
    }
}
