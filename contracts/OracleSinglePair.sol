// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "./lib/Babylonian.sol";
import "./lib/FixedPoint.sol";
import "./lib/UniswapV2OracleLibrary.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IEpoch.sol";

// fixed window oracle that recomputes the average price for the entire period once every period
// note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
contract OracleSinglePair is IEpoch {
    using FixedPoint for *;
    using SafeMath for uint144;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    address public constant dollar = address(0x86BC05a6f65efdaDa08528Ec66603Aef175D967f);
    uint144 public constant DECIMALS_MULTIPLER = 10 ** 12; // USDC Decimals = 6

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // uniswap
    address public token0;
    address public token1;
    IUniswapV2Pair public pair;

    // oracle
    uint32 public blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    // epoch
    address public treasury;
    mapping(uint256 => uint256) public epochDollarPrice;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    // ...

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event Updated(uint256 price0CumulativeLast, uint256 price1CumulativeLast);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "OracleSinglePair: caller is not the operator");
        _;
    }

    modifier notInitialized {
        require(!initialized, "OracleSinglePair: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function epoch() public override view returns (uint256) {
        return IEpoch(treasury).epoch();
    }

    function nextEpochPoint() public override view returns (uint256) {
        return IEpoch(treasury).nextEpochPoint();
    }

    function nextEpochLength() external override view returns (uint256) {
        return IEpoch(treasury).nextEpochLength();
    }

    function checkEpoch() public view returns (bool) {
        return epochDollarPrice[epoch()] == 0 || now >= nextEpochPoint();
    }

    function getPegPrice() external view returns (uint256) {
        return consult(dollar, 1e18);
    }

    function getPegPriceUpdated() external view returns (uint256) {
        return twap(dollar, 1e18);
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        IUniswapV2Pair _pair
    ) public notInitialized {
        pair = _pair;
        token0 = pair.token0();
        token1 = pair.token1();
        price0CumulativeLast = pair.price0CumulativeLast(); // fetch the current accumulated price value (1 / 0)
        price1CumulativeLast = pair.price1CumulativeLast(); // fetch the current accumulated price value (0 / 1)
        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1, blockTimestampLast) = pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, "OracleSinglePair: NO_RESERVES"); // ensure that there's liquidity in the pair

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setTreasury(address _treasury) external onlyOperator {
        treasury = _treasury;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    /** @dev Updates 1-day EMA price from Uniswap.  */
    function update() external {
        if (checkEpoch()) {
            (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
            uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

            if (timeElapsed == 0) {
                // prevent divided by zero
                return;
            }

            // overflow is desired, casting never truncates
            // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
            price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
            price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));

            price0CumulativeLast = price0Cumulative;
            price1CumulativeLast = price1Cumulative;
            blockTimestampLast = blockTimestamp;

            epochDollarPrice[epoch()] = consult(dollar, 1e18);
            emit Updated(price0Cumulative, price1Cumulative);
        }
    }

    // note this will always return 0 before update has been called successfully for the first time.
    function consult(address _token, uint256 _amountIn) public view returns (uint144 _amountOut) {
        if (_token == token0) {
            _amountOut = price0Average.mul(_amountIn).decode144();
        } else {
            require(_token == token1, "OracleSinglePair: INVALID_TOKEN");
            _amountOut = price1Average.mul(_amountIn).decode144();
        }
        if (_token == dollar) {
            _amountOut = uint144(_amountOut.mul(DECIMALS_MULTIPLER));
        }
    }

    function twap(address _token, uint256 _amountIn) public view returns (uint144 _amountOut) {
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (_token == token0) {
            _amountOut = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed)).mul(_amountIn).decode144();
        } else if (_token == token1) {
            _amountOut = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed)).mul(_amountIn).decode144();
        }
        if (_token == dollar) {
            _amountOut = uint144(_amountOut.mul(DECIMALS_MULTIPLER));
        }
    }
}
