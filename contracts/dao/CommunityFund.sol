//// SPDX-License-Identifier: MIT
//
//pragma solidity 0.6.12;
//
//import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//import "@openzeppelin/contracts/math/SafeMath.sol";
//import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
//import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
//
//import "../interfaces/IUniswapV2Router.sol";
//import "../interfaces/IUniswapV2Pair.sol";
//import "../interfaces/IBPool.sol";
//import "../interfaces/IBoardroom.sol";
//import "../interfaces/IShare.sol";
//import "../interfaces/ITreasury.sol";
//import "../interfaces/IOracle.sol";
//import "../interfaces/IRewardPool.sol";
//import "../interfaces/IuniswapswapPool.sol";
//
///**
// * @dev This contract will collect vesting Shares, stake to the Boardroom and rebalance SDO, BUSD, WBNB according to DAO.
// */
//contract CommunityFund is OwnableUpgradeSafe {
//    using SafeERC20 for IERC20;
//    using SafeMath for uint256;
//
//    /* ========== STATE VARIABLES ========== */
//
//    // governance
//    address public strategist;
//
//    // flags
//    bool public initialized = false;
//    bool public publicAllowed; // set to true to allow public to call rebalance()
//
//    // price
//    uint256 public dollarPriceToSell; // to rebalance when expansion
//    uint256 public dollarPriceToBuy; // to rebalance when contraction
//
//    address public dollar = address(0x35e869B7456462b81cdB5e6e42434bD27f3F788c);
//    address public share = address(0x242E46490397ACCa94ED930F2C4EdF16250237fa);
//    address public bond = address(0xCaD2109CC2816D47a796cB7a0B57988EC7611541);
//
//    address public constant usdc = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
//    address public constant usdt = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
//
//    address public boardroom = address(0xFF0b41ad7a85430FEbBC5220fd4c7a68013F2C0d);
//    address public dollarOracle = address(0x26593B4E6a803aac7f39955bd33C6826f266D7Fc);
//    address public treasury = address(0xD3372603Db4087FF5D797F91839c0Ca6b9aF294a);
//
//    // PolyDex
//    IUniswapV2Router public uniswapRouter = IUniswapV2Router(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
//    mapping(address => mapping(address => address[])) public uniswapPaths;
//
//    address public constant lpDollarUsdt = address(0xd245BDb115707730136F0459e2aa9b0b19023724);
//    address public constant lpDollarUsdc = address(0xD65F81878517039E39c359434d8D8bD46CC4531F); // ShareRewardPool [0]
//    address public constant lpShareUsdc = address(0xD65F81878517039E39c359434d8D8bD46CC4531F);  // ShareRewardPool [1]
//    address public constant shareRewardPool = address(0xecC17b190581C60811862E5dF8c9183dA98BD08a);
//
//    // DAO parameters
//    uint256[] public expansionPercent;
//    uint256[] public contractionPercent;
//
//    /* =================== Added variables (need to keep orders for proxy to work) =================== */
//    // ...
//
//    /* ========== EVENTS ========== */
//
//    event SwapToken(address inputToken, address outputToken, uint256 amount);
//    event BoughtBonds(uint256 amount);
//    event RedeemedBonds(uint256 amount);
//    event ExecuteTransaction(address indexed target, uint256 value, string signature, bytes data);
//
//    /* ========== Modifiers =============== */
//
//    modifier onlyStrategist() {
//        require(strategist == msg.sender || owner() == msg.sender, "!strategist");
//        _;
//    }
//
//    modifier checkPublicAllow() {
//        require(publicAllowed || msg.sender == operator, "!operator nor !publicAllowed");
//        _;
//    }
//
//    /* ========== GOVERNANCE ========== */
//
//    function initialize(
//        address _dollar,
//        address _share,
//        address _bond,
//        address _boardroom,
//        address _dollarOracle,
//        address _treasury
//    ) external initializer {
//        OwnableUpgradeSafe.__Ownable_init();
//        dollar = _dollar;
//        share = _share;
//        bond = _bond;
//        boardroom = _boardroom;
//        dollarOracle = _dollarOracle;
//        treasury = _treasury;
//        dollarPriceToSell = 1500 finney; // $1.5
//        dollarPriceToBuy = 800 finney; // $0.8
//        expansionPercent = [3000, 6800, 200]; // dollar (30%), BUSD (68%), WBNB (2%) during expansion period
//        contractionPercent = [8800, 1160, 40]; // dollar (88%), BUSD (11.6%), WBNB (0.4%) during contraction period
//        publicAllowed = true;
//        strategist = msg.sender;
//    }
//
//    function setOperator(address _operator) external onlyOwner {
//        operator = _operator;
//    }
//
//    function setStrategist(address _strategist) external onlyOwner {
//        strategist = _strategist;
//    }
//
//    function setTreasury(address _treasury) external onlyOwner {
//        treasury = _treasury;
//    }
//
//    function setDollarOracle(address _dollarOracle) external onlyOwner {
//        dollarOracle = _dollarOracle;
//    }
//
//    function setPublicAllowed(bool _publicAllowed) external onlyStrategist {
//        publicAllowed = _publicAllowed;
//    }
//
//    function setExpansionPercent(uint256 _dollarPercent, uint256 _busdPercent, uint256 _usdtPercent) external onlyStrategist {
//        require(_dollarPercent.add(_busdPercent).add(_usdtPercent) == 10000, "!100%");
//        expansionPercent[0] = _dollarPercent;
//        expansionPercent[1] = _busdPercent;
//        expansionPercent[2] = _usdtPercent;
//    }
//
//    function setContractionPercent(uint256 _dollarPercent, uint256 _busdPercent, uint256 _usdtPercent) external onlyStrategist {
//        require(_dollarPercent.add(_busdPercent).add(_usdtPercent) == 10000, "!100%");
//        contractionPercent[0] = _dollarPercent;
//        contractionPercent[1] = _busdPercent;
//        contractionPercent[2] = _usdtPercent;
//    }
//
//    function setDollarPriceToSell(uint256 _dollarPriceToSell) external onlyStrategist {
//        require(_dollarPriceToSell >= 950 finney && _dollarPriceToSell <= 2000 finney, "out of range"); // [$0.95, $2.00]
//        dollarPriceToSell = _dollarPriceToSell;
//    }
//
//    function setDollarPriceToBuy(uint256 _dollarPriceToBuy) external onlyStrategist {
//        require(_dollarPriceToBuy >= 500 finney && _dollarPriceToBuy <= 1050 finney, "out of range"); // [$0.50, $1.05]
//        dollarPriceToBuy = _dollarPriceToBuy;
//    }
//
//    function setUnirouterPath(address _input, address _output, address[] memory _path) external onlyStrategist {
//        uniswapPaths[_input][_output] = _path;
//    }
//
//    function withdrawShare(uint256 _amount) external onlyStrategist {
//        IBoardroom(boardroom).withdraw(_amount);
//    }
//
//    function exitBoardroom() external onlyStrategist {
//        IBoardroom(boardroom).exit();
//    }
//
//    function grandFund(address _token, uint256 _amount, address _to) external onlyOwner {
//        IERC20(_token).transfer(_to, _amount);
//    }
//
//    /* ========== VIEW FUNCTIONS ========== */
//
//    function earned() public view returns (uint256) {
//        return IBoardroom(boardroom).earned(address(this));
//    }
//
//    function tokenBalances() public view returns (uint256 _dollarBal, uint256 _busdBal, uint256 _usdtBal, uint256 _totalBal) {
//        _dollarBal = IERC20(dollar).balanceOf(address(this));
//        _busdBal = IERC20(busd).balanceOf(address(this));
//        _usdtBal = IERC20(usdt).balanceOf(address(this));
//        _totalBal = _dollarBal.add(_busdBal).add(_usdtBal);
//    }
//
//    function tokenPercents() public view returns (uint256 _dollarPercent, uint256 _busdPercent, uint256 _usdtPercent) {
//        (uint256 _dollarBal, uint256 _busdBal, uint256 _usdtBal, uint256 _totalBal) = tokenBalances();
//        if (_totalBal > 0) {
//            _dollarPercent = _dollarBal.mul(10000).div(_totalBal);
//            _busdPercent = _busdBal.mul(10000).div(_totalBal);
//            _usdtPercent = _usdtBal.mul(10000).div(_totalBal);
//        }
//    }
//
//    function dollarLpReserves() public view returns (uint256 _dollarBusdReserve, uint256 _dollarUsdtReserve, uint256 _totalDollarReserve) {
//        address _dollar = dollar;
//        (_dollarBusdReserve, ) = _uniswapGetReserves(_dollar, busd, lpDollarBusd);
//        (_dollarUsdtReserve, ) = _uniswapGetReserves(_dollar, usdt, lpDollarUsdt);
//        _totalDollarReserve = _dollarBusdReserve.add(_dollarUsdtReserve);
//    }
//
//    function getDollarPrice() public view returns (uint256 dollarPrice) {
//        try IOracle(dollarOracle).consult(dollar, 1e18) returns (uint144 price) {
//            return uint256(price);
//        } catch {
//            revert("failed to consult price");
//        }
//    }
//
//    function getDollarUpdatedPrice() public view returns (uint256 _dollarPrice) {
//        try IOracle(dollarOracle).twap(dollar, 1e18) returns (uint144 price) {
//            return uint256(price);
//        } catch {
//            revert("failed to consult price");
//        }
//    }
//
//    /* ========== MUTATIVE FUNCTIONS ========== */
//
//    function collectShareRewards() public checkPublicAllow {
//        if (IShare(share).unclaimedTreasuryFund() > 0) {
//            IShare(share).claimRewards();
//        }
//    }
//
//    function claimAndRestake() public checkPublicAllow {
//        if (IBoardroom(boardroom).canClaimReward(address(this))) {// only restake more if at this epoch we could claim pending dollar rewards
//            if (earned() > 0) {
//                IBoardroom(boardroom).claimReward();
//            }
//            uint256 _shareBal = IERC20(share).balanceOf(address(this));
//            if (_shareBal > 0) {
//                IERC20(share).safeIncreaseAllowance(boardroom, _shareBal);
//                IBoardroom(boardroom).stake(_shareBal);
//            }
//        }
//    }
//
//    function rebalance() public checkPublicAllow {
//        (uint256 _dollarBal, uint256 _busdBal, uint256 _usdtBal, uint256 _totalBal) = tokenBalances();
//        if (_totalBal > 0) {
//            uint256 _dollarPercent = _dollarBal.mul(10000).div(_totalBal);
//            // uint256 _busdPercent = _busdBal.mul(10000).div(_totalBal);
//            // uint256 _usdtPercent = _usdtBal.mul(10000).div(_totalBal);
//            uint256 _dollarPrice = getDollarUpdatedPrice();
//            if (_dollarPrice >= dollarPriceToSell) {// expansion: sell SDO
//                if (_dollarPercent > expansionPercent[0]) {
//                    uint256 _sellingDollar = _dollarBal.mul(_dollarPercent.sub(expansionPercent[0])).div(10000);
//                    uint256 _maxDollarAmountToTrade = maxAmountToTrade[dollar];
//                    if (_sellingDollar > _maxDollarAmountToTrade) {
//                        _sellingDollar = _maxDollarAmountToTrade;
//                    }
//                    (uint256 _dollarBusdReserve, , uint256 _totalDollarReserve) = dollarLpReserves();
//                    uint256 _sellAmountToBusdPool = _sellingDollar.mul(_dollarBusdReserve).div(_totalDollarReserve);
//                    uint256 _sellAmountToUsdtPool = _sellingDollar.sub(_sellAmountToBusdPool);
//                    _swapToken(dollar, busd, _sellAmountToBusdPool);
//                    _swapToken(dollar, usdt, _sellAmountToUsdtPool);
//                }
//            } else if (_dollarPrice <= dollarPriceToBuy && (msg.sender == operator || msg.sender == strategist)) {// contraction: buy SDO
//                uint256 _buyingDollar = _dollarBal.mul(contractionPercent[0].sub(_dollarPercent)).div(10000);
//                uint256 _maxDollarAmountToTrade = maxAmountToTrade[dollar];
//                if (_buyingDollar > _maxDollarAmountToTrade) {
//                    _buyingDollar = _maxDollarAmountToTrade;
//                }
//                (uint256 _dollarBusdReserve, , uint256 _totalDollarReserve) = dollarLpReserves();
//                uint256 _buyAmountToBusdPool = _buyingDollar.mul(_dollarBusdReserve).div(_totalDollarReserve);
//                uint256 _buyAmountToUsdtPool = _buyingDollar.sub(_buyAmountToBusdPool);
//                if (_buyAmountToBusdPool > _busdBal) _buyAmountToBusdPool = _busdBal;
//                if (_buyAmountToUsdtPool > _usdtBal) _buyAmountToUsdtPool = _usdtBal;
//                _swapToken(busd, dollar, _buyAmountToBusdPool);
//                _swapToken(usdt, dollar, _buyAmountToUsdtPool);
//            }
//        }
//    }
//
//    function workForDaoFund() external checkPublicAllow {
//        collectShareRewards();
//        claimAllRewardFromSharePool();
//        claimAndRestake();
//        rebalance();
//    }
//
//    function buyBonds(uint256 _dollarAmount) external onlyStrategist {
//        uint256 _dollarPrice = ITreasury(treasury).getDollarPrice();
//        ITreasury(treasury).buyBonds(_dollarAmount, _dollarPrice);
//        emit BoughtBonds(_dollarAmount);
//    }
//
//    function redeemBonds(uint256 _bondAmount) external onlyStrategist {
//        uint256 _dollarPrice = ITreasury(treasury).getDollarPrice();
//        ITreasury(treasury).redeemBonds(_bondAmount, _dollarPrice);
//        emit RedeemedBonds(_bondAmount);
//    }
//
//    function forceSell(address _buyingToken, uint256 _dollarAmount) external onlyStrategist {
//        require(getDollarUpdatedPrice() >= dollarPriceToBuy, "price is too low to sell");
//        _swapToken(dollar, _buyingToken, _dollarAmount);
//    }
//
//    function forceBuy(address _sellingToken, uint256 _sellingAmount) external onlyStrategist {
//        require(getDollarUpdatedPrice() <= dollarPriceToSell, "price is too high to buy");
//        _swapToken(_sellingToken, dollar, _sellingAmount);
//    }
//
//    function trimNonCoreToken(address _sellingToken) public onlyStrategist {
//        require(_sellingToken != dollar &&
//            _sellingToken != bond && _sellingToken != share &&
//            _sellingToken != usdc && _sellingToken != usdt, "core");
//        uint256 _bal = IERC20(_sellingToken).balanceOf(address(this));
//        if (_bal > 0) {
//            _swapToken(_sellingToken, dollar, _bal);
//        }
//    }
//
//    function _swapToken(address _inputToken, address _outputToken, uint256 _amount) internal {
//        if (_amount == 0) return;
//        address[] memory _path = uniswapPaths[_inputToken][_outputToken];
//        if (_path.length == 0) {
//            _path = new address[](2);
//            _path[0] = _inputToken;
//            _path[1] = _outputToken;
//        }
//        IERC20(_inputToken).safeApprove(address(uniswapRouter), 0);
//        IERC20(_inputToken).safeApprove(address(uniswapRouter), _amount);
//        uniswapRouter.swapExactTokensForTokens(_amount, 1, _path, address(this), now.add(1800));
//    }
//
//    function _addLiquidity(address _tokenB, uint256 _amountADesired) internal {
//        // tokenA is always SDO
//        _addLiquidity2(dollar, _tokenB, _amountADesired, IERC20(_tokenB).balanceOf(address(this)));
//    }
//
//    function _removeLiquidity(address _lpAdd, address _tokenB, uint256 _liquidity) internal {
//        // tokenA is always SDO
//        _removeLiquidity2(_lpAdd, dollar, _tokenB, _liquidity);
//    }
//
//    function _addLiquidity2(address _tokenA, address _tokenB, uint256 _amountADesired, uint256 amountBDesired) internal {
//        IERC20(_tokenA).safeApprove(address(uniswapRouter), 0);
//        IERC20(_tokenA).safeApprove(address(uniswapRouter), type(uint256).max);
//        IERC20(_tokenB).safeApprove(address(uniswapRouter), 0);
//        IERC20(_tokenB).safeApprove(address(uniswapRouter), type(uint256).max);
//        // addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline)
//        uniswapRouter.addLiquidity(_tokenA, _tokenB, _amountADesired, amountBDesired, 0, 0, address(this), now.add(1800));
//    }
//
//    function _removeLiquidity2(address _lpAdd, address _tokenA, address _tokenB, uint256 _liquidity) internal {
//        IERC20(_lpAdd).safeApprove(address(uniswapRouter), 0);
//        IERC20(_lpAdd).safeApprove(address(uniswapRouter), _liquidity);
//        // removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline)
//        uniswapRouter.removeLiquidity(_tokenA, _tokenB, _liquidity, 1, 1, address(this), now.add(1800));
//    }
//
//    function _uniswapGetReserves(address tokenA, address tokenB, address pair) internal view returns (uint256 _reserveA, uint256 _reserveB) {
//        address _token0 = IUniswapV2Pair(pair).token0();
//        address _token1 = IUniswapV2Pair(pair).token1();
//        (uint112 _reserve0, uint112 _reserve1, ) = IUniswapV2Pair(pair).getReserves();
//        if (_token0 == tokenA) {
//            if (_token1 == tokenB) {
//                _reserveA = uint256(_reserve0);
//                _reserveB = uint256(_reserve1);
//            }
//        } else if (_token0 == tokenB) {
//            if (_token1 == tokenA) {
//                _reserveA = uint256(_reserve1);
//                _reserveB = uint256(_reserve0);
//            }
//        }
//    }
//
//    /* ========== FARMING ========== */
//
//    function depositToPool(address _pool, uint256 _pid, address _lpAdd, uint256 _lpAmount) public onlyStrategist {
//        IERC20(_lpAdd).safeIncreaseAllowance(_pool, _lpAmount);
//        IRewardPool(_pool).deposit(_pid, _lpAmount);
//    }
//
//    function depositToPoolMax(address _pool, uint256 _pid, address _lpAdd) external onlyStrategist {
//        uint256 _bal = IERC20(_lpAdd).balanceOf(address(this));
//        require(_bal > 0, "no lp");
//        depositToPool(_pool, _pid, _lpAdd, _bal);
//    }
//
//    function withdrawFromPool(address _pool, uint256 _pid, uint256 _lpAmount) public onlyStrategist {
//        IRewardPool(_pool).withdraw(_pid, _lpAmount);
//    }
//
//    function withdrawFromPoolMax(address _pool, uint256 _pid) external onlyStrategist {
//        uint256 _stakedAmount = stakeAmountFromPool(_pool, _pid);
//        withdrawFromPool(_pool, _pid, _stakedAmount);
//    }
//
//    function claimFromPool(address _pool, uint256 _pid) public {
//        IRewardPool(_pool).withdraw(_pid, 0);
//    }
//
//    function pendingFromPool(address _pool, uint256 _pid) external view returns (uint256) {
//        return IRewardPool(_pool).pendingReward(_pid, address(this));
//    }
//
//    function stakeAmountFromPool(address _pool, uint256 _pid) public view returns (uint256 _stakedAmount) {
//        (_stakedAmount,) = IRewardPool(_pool).userInfo(_pid, address(this));
//    }
//
//    /* ========== PROVIDE LP AND STAKE TO SHARE POOL ========== */
//
//    function depositToSharePool(address _tokenB, uint256 _dollarAmount) external onlyStrategist {
//        address _lpAdd = lpPairAddress[_tokenB];
//        uint256 _before = IERC20(_lpAdd).balanceOf(address(this));
//        _addLiquidity(_tokenB, _dollarAmount);
//        uint256 _after = IERC20(_lpAdd).balanceOf(address(this));
//        uint256 _lpBal = _after.sub(_before);
//        require(_lpBal > 0, "!_lpBal");
//        address _shareRewardPool = shareRewardPool;
//        uint256 _pid = shareRewardPoolId[_tokenB];
//        IERC20(_lpAdd).safeApprove(_shareRewardPool, 0);
//        IERC20(_lpAdd).safeApprove(_shareRewardPool, _lpBal);
//        IRewardPool(_shareRewardPool).deposit(_pid, _lpBal);
//    }
//
//    function withdrawFromSharePool(address _tokenB, uint256 _lpAmount) public onlyStrategist {
//        address _lpAdd = lpPairAddress[_tokenB];
//        address _shareRewardPool = shareRewardPool;
//        uint256 _pid = shareRewardPoolId[_tokenB];
//        IRewardPool(_shareRewardPool).withdraw(_pid, _lpAmount);
//        _removeLiquidity(_lpAdd, _tokenB, _lpAmount);
//    }
//
//    function exitSharePool(address _tokenB) public onlyStrategist {
//        (uint _stakedAmount,) = IRewardPool(shareRewardPool).userInfo(shareRewardPoolId[_tokenB], address(this));
//        withdrawFromSharePool(_tokenB, _stakedAmount);
//    }
//
//    function exitAllSharePool() external {
//        if (stakeAmountFromSharePool(busd) > 0) exitSharePool(busd);
//        if (stakeAmountFromSharePool(usdt) > 0) exitSharePool(usdt);
//    }
//
//    function claimRewardFromSharePool(address _tokenB) public {
//        uint256 _pid = shareRewardPoolId[_tokenB];
//        IRewardPool(shareRewardPool).withdraw(_pid, 0);
//    }
//
//    function claimAllRewardFromSharePool() public {
//        if (pendingFromSharePool(busd) > 0) claimRewardFromSharePool(busd);
//        if (pendingFromSharePool(usdt) > 0) claimRewardFromSharePool(usdt);
//    }
//
//    function pendingFromSharePool(address _tokenB) public view returns(uint256) {
//        return IRewardPool(shareRewardPool).pendingShare(shareRewardPoolId[_tokenB], address(this));
//    }
//
//    function pendingAllFromSharePool() public view returns(uint256) {
//        return pendingFromSharePool(busd).add(pendingFromSharePool(usdt));
//    }
//
//    function stakeAmountFromSharePool(address _tokenB) public view returns(uint256 _stakedAmount) {
//        (_stakedAmount, ) = IRewardPool(shareRewardPool).userInfo(shareRewardPoolId[_tokenB], address(this));
//    }
//
//    function stakeAmountAllFromSharePool() public view returns(uint256 _bnbPoolStakedAmount, uint256 _usdtPoolStakedAmount) {
//        _bnbPoolStakedAmount = stakeAmountFromSharePool(busd);
//        _usdtPoolStakedAmount = stakeAmountFromSharePool(usdt);
//    }
//
//    /* ========== EMERGENCY ========== */
//
//    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data) public onlyOwner returns (bytes memory) {
//        bytes memory callData;
//
//        if (bytes(signature).length == 0) {
//            callData = data;
//        } else {
//            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
//        }
//
//        // solium-disable-next-line security/no-call-value
//        (bool success, bytes memory returnData) = target.call{value: value}(callData);
//        require(success, string("CommunityFund::executeTransaction: Transaction execution reverted."));
//
//        emit ExecuteTransaction(target, value, signature, data);
//
//        return returnData;
//    }
//
//    receive() external payable {}
//}
