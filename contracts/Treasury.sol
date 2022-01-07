// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";
import "./interfaces/ITreasury.sol";

contract Treasury is ContractGuard, ITreasury, OwnableUpgradeSafe {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    uint256 private constant EXPANSION_EPOCH_PERIOD = 8 hours;
    uint256 private constant CONTRACTION_EPOCH_PERIOD = 6 hours;

    // flags
    bool public migrated = false;

    // epoch
    uint256 public startTime;
    uint256 public lastEpochTime;
    uint256 private _epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public dollar = address(0x86BC05a6f65efdaDa08528Ec66603Aef175D967f);
    address public share = address(0x352db329B707773DD3174859F1047Fb4Fd2030BC);
    address public bond = address(0x714bb9798BfAF689795d55838D0527EC749A156f);

    address public boardroom;
    address public dollarOracle;

    // price
    uint256 public dollarPriceOne;
    uint256 public dollarPriceCeiling;

    uint256 public seigniorageSaved;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDeptRatioPercent;

    uint256 public bootstrapEpochs;

    uint256 public previousEpochDollarPrice;
    uint256 public allocateSeigniorageSalary;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra SDO during dept phase

    uint256 public dollarSupplyTarget;
    address[] public dollarLockedAccounts;

    // 40% for Stakers in boardroom (THIS)
    // 10% for SDS LP providers (locked in 80w)
    // 40% for DAO fund
    // 10% to lottery
    address public daoFund;
    uint256 public daoFundSharedPercent;
    address public lpProviderBoardroom;
    uint256 public lpProviderBoardroomSharedPercent;
    address public lotteryFund;
    uint256 public lotteryFundSharedPercent;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    // ...

    /* =================== Events =================== */

    event Migration(address indexed target);
    event RedeemedBonds(address indexed from, uint256 dollarAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 dollarAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event LpProviderBoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event LotteryFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier checkCondition {
        require(!migrated, "Treasury: migrated");
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch {
        uint256 _nextEpochPoint = nextEpochPoint();
        require(now >= _nextEpochPoint, "Treasury: not opened yet");

        _;

        lastEpochTime = _nextEpochPoint;
        _epoch = _epoch.add(1);
        epochSupplyContractionLeft = (getDollarPrice() >= dollarPriceCeiling) ? 0 : IERC20(dollar).totalSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    /* ========== VIEW FUNCTIONS ========== */

    // flags
    function isMigrated() public view returns (bool) {
        return migrated;
    }

    // epoch
    function epoch() public override view returns (uint256) {
        return _epoch;
    }

    function nextEpochPoint() public override view returns (uint256) {
        return lastEpochTime.add(nextEpochLength());
    }

    function nextEpochLength() public override view returns (uint256 _length) {
        if (_epoch <= bootstrapEpochs) {
            _length = EXPANSION_EPOCH_PERIOD;
        } else {
            _length = (getDollarPrice() >= dollarPriceCeiling) ? EXPANSION_EPOCH_PERIOD : CONTRACTION_EPOCH_PERIOD;
        }
    }

    // oracle
    function getDollarPrice() public override view returns (uint256 dollarPrice) {
        try IOracle(dollarOracle).consult(dollar, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult dollar price from the oracle");
        }
    }

    function getDollarUpdatedPrice() public view returns (uint256 _dollarPrice) {
        try IOracle(dollarOracle).twap(dollar, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult dollar price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableDollarLeft() public view returns (uint256 _burnableDollarLeft) {
        uint256  _dollarPrice = getDollarPrice();
        if (_dollarPrice <= dollarPriceOne) {
            uint256 _dollarSupply = IERC20(dollar).totalSupply();
            uint256 _bondMaxSupply = _dollarSupply.mul(maxDeptRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(bond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableDollar = _maxMintableBond.mul(_dollarPrice).div(1e18);
                _burnableDollarLeft = Math.min(epochSupplyContractionLeft, _maxBurnableDollar);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256  _dollarPrice = getDollarPrice();
        if (_dollarPrice >= dollarPriceCeiling) {
            uint256 _totalDollar = IERC20(dollar).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalDollar.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _dollarPrice = getDollarPrice();
        if (_dollarPrice <= dollarPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = dollarPriceOne;
            } else {
                uint256 _bondAmount = dollarPriceOne.mul(1e18).div(_dollarPrice); // to burn 1 dollar
                uint256 _discountAmount = _bondAmount.sub(dollarPriceOne).mul(discountPercent).div(10000);
                _rate = dollarPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _dollarPrice = getDollarPrice();
        if (_dollarPrice >= dollarPriceCeiling) {
            if (premiumPercent == 0) {
                // no premium bonus
                _rate = dollarPriceOne;
            } else {
                uint256 _premiumAmount = _dollarPrice.sub(dollarPriceOne).mul(premiumPercent).div(10000);
                _rate = dollarPriceOne.add(_premiumAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getDollarLockedBalance() public view returns (uint256 _lockedBalance) {
        uint256 _length = dollarLockedAccounts.length;
        for (uint256 i = 0; i < _length; i++) {
            _lockedBalance = _lockedBalance.add(IERC20(dollar).balanceOf(dollarLockedAccounts[i]));
        }
    }

    function getDollarCirculatingSupply() public view returns (uint256) {
        return IERC20(dollar).totalSupply().sub(getDollarLockedBalance());
    }

    function getDollarExpansionRate() public view returns (uint256 _rate) {
        if (_epoch < bootstrapEpochs) {// 21 first epochs with 3.0% expansion
            _rate = maxSupplyExpansionPercent.mul(100);
        } else {
            uint256 _twap = getDollarUpdatedPrice();
            if (_twap >= dollarPriceCeiling) {
                uint256 _percentage = _twap.sub(dollarPriceOne); // 1% = 1e16
                uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                _rate = _percentage.div(1e12);
            }
        }
    }

    function getDollarExpansionAmount() external view returns (uint256) {
        uint256 _rate = getDollarExpansionRate();
        return getDollarCirculatingSupply().mul(_rate).div(1e6);
    }

    /* ========== GOVERNANCE ========== */

    function initialize(address _dollar, address _share, address _bond, address _boardroom, address _dollarOracle, uint256 _startTime) external initializer {
        OwnableUpgradeSafe.__Ownable_init();

        dollar = _dollar;
        share = _share;
        bond = _bond;
        boardroom = _boardroom;
        dollarOracle = _dollarOracle;
        startTime = _startTime;
        lastEpochTime = _startTime.sub(EXPANSION_EPOCH_PERIOD);

        dollarPriceOne = 10 ** 18;
        dollarPriceCeiling = dollarPriceOne.mul(10001).div(10000);

        maxSupplyExpansionPercent = 300; // Upto 3.0% supply for expansion
        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 5000; // At least 50% of expansion reserved for boardroom
        maxSupplyContractionPercent = 400; // Upto 4.0% supply for contraction (to burn SDO and mint SDB)
        maxDeptRatioPercent = 5000; // Upto 50% supply of SDB to purchase
        mintingFactorForPayingDebt = 10000; // 100%

        dollarSupplyTarget = 1000000 ether; // 1 million supply is the next target to reduce expansion rate

        allocateSeigniorageSalary = 1 ether; // 1 SDO salary for calling allocateSeigniorage()

        // First 21 epochs with 3.0% expansion
        bootstrapEpochs = 21;

        maxDiscountRate = 13e17; // 30% - when purchasing bond
        maxPremiumRate = 13e17; // 30% - when redeeming bond

        discountPercent = 0; // no discount
        premiumPercent = 6500; // 65% premium

        daoFund = msg.sender; // temporarily
        daoFundSharedPercent = 4000; // 40% toward DAO Fund
        lpProviderBoardroom = address(0);
        lpProviderBoardroomSharedPercent = 0; // 0% beginning and set to 10% later
        lotteryFund = msg.sender; // temporarily
        lotteryFundSharedPercent = 1000; // 10%

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(dollar).balanceOf(address(this));
    }

    function resetStartTime(uint256 _startTime) external onlyOwner {
        require(_epoch == 0, "already started");
        startTime = _startTime;
        lastEpochTime = _startTime.sub(EXPANSION_EPOCH_PERIOD);
    }

    function setBoardroom(address _boardroom) external onlyOwner {
        boardroom = _boardroom;
    }

    function setDollarOracle(address _dollarOracle) external onlyOwner {
        dollarOracle = _dollarOracle;
    }

    function setDollarPriceCeiling(uint256 _dollarPriceCeiling) external onlyOwner {
        require(_dollarPriceCeiling >= dollarPriceOne && _dollarPriceCeiling <= dollarPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        dollarPriceCeiling = _dollarPriceCeiling;
    }

    function setMaxSupplyExpansionPercent(uint256 _maxSupplyExpansionPercent) external onlyOwner {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOwner {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOwner {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDeptRatioPercent(uint256 _maxDeptRatioPercent) external onlyOwner {
        require(_maxDeptRatioPercent >= 1000 && _maxDeptRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDeptRatioPercent = _maxDeptRatioPercent;
    }

    function setExtraFunds(address _daoFund, uint256 _daoFundSharedPercent,
        address _lpProviderBoardroom, uint256 _lpProviderBoardroomSharedPercent,
        address _lotteryFund, uint256 _lotteryFundSharedPercent) external onlyOwner {
        require(_daoFund != address(0), "zero");
        require(_lotteryFund != address(0), "zero");
        require(_daoFundSharedPercent <= 6000, "out of range"); // <= 50%
        require(_lpProviderBoardroomSharedPercent <= 2000, "out of range"); // <= 20%
        require(_lotteryFundSharedPercent <= 1500, "out of range"); // <= 15%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        lpProviderBoardroom = _lpProviderBoardroom;
        lpProviderBoardroomSharedPercent = _lpProviderBoardroomSharedPercent;
        lotteryFund = _lotteryFund;
        lotteryFundSharedPercent = _lotteryFundSharedPercent;
    }

    function setAllocateSeigniorageSalary(uint256 _allocateSeigniorageSalary) external onlyOwner {
        require(_allocateSeigniorageSalary <= 10 ether, "Treasury: dont pay too much");
        allocateSeigniorageSalary = _allocateSeigniorageSalary;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOwner {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOwner {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOwner {
        require(_discountPercent <= 15000, "_discountPercent is over 150%");
        discountPercent = _discountPercent;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOwner {
        require(_premiumPercent <= 15000, "_premiumPercent is over 150%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOwner {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    function setDollarSupplyTarget(uint256 _dollarSupplyTarget) external onlyOwner {
        require(_dollarSupplyTarget > getDollarCirculatingSupply(), "too small"); // >= current circulating supply
        dollarSupplyTarget = _dollarSupplyTarget;
    }

    function setDollarLockedAccounts(address[] memory _dollarLockedAccounts) external onlyOwner {
        delete dollarLockedAccounts;
        uint256 _length = _dollarLockedAccounts.length;
        for (uint256 i = 0; i < _length; i++) {
            dollarLockedAccounts.push(_dollarLockedAccounts[i]);
        }
    }

    function migrate(address target) external onlyOwner {
        require(!migrated, "Treasury: migrated");

        // dollar
        IERC20(dollar).transfer(target, IERC20(dollar).balanceOf(address(this)));

        // bond
        Operator(bond).transferOperator(target);
        Operator(bond).transferOwnership(target);
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        migrated = true;
        emit Migration(target);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateDollarPrice() internal {
        try IOracle(dollarOracle).update() {} catch {}
    }

    function buyBonds(uint256 _dollarAmount, uint256 targetPrice) external override onlyOneBlock checkCondition {
        require(_epoch >= bootstrapEpochs, "Treasury: still in boostrap");
        require(_dollarAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 dollarPrice = getDollarPrice();
        require(dollarPrice == targetPrice, "Treasury: dollar price moved");
        require(
            dollarPrice < dollarPriceOne, // price < $1
            "Treasury: dollarPrice not eligible for bond purchase"
        );

        require(_dollarAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _dollarAmount.mul(_rate).div(1e18);
        uint256 dollarSupply = IERC20(dollar).totalSupply();
        uint256 newBondSupply = IERC20(bond).totalSupply().add(_bondAmount);
        require(newBondSupply <= dollarSupply.mul(maxDeptRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(dollar).burnFrom(msg.sender, _dollarAmount);
        IBasisAsset(bond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_dollarAmount);
        _updateDollarPrice();

        emit BoughtBonds(msg.sender, _dollarAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external override onlyOneBlock checkCondition {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 dollarPrice = getDollarPrice();
        require(dollarPrice == targetPrice, "Treasury: dollar price moved");
        require(
            dollarPrice >= dollarPriceCeiling, // price >= $1.0001
            "Treasury: dollarPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _dollarAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(dollar).balanceOf(address(this)) >= _dollarAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _dollarAmount));

        IBasisAsset(bond).burnFrom(msg.sender, _bondAmount);
        IERC20(dollar).safeTransfer(msg.sender, _dollarAmount);

        _updateDollarPrice();

        emit RedeemedBonds(msg.sender, _dollarAmount, _bondAmount);
    }

    function _sendToBoardRoom(uint256 _amount) internal {
        IBasisAsset(dollar).mint(address(this), _amount);
        uint256 _boardroomAmount = _amount;
        if (daoFundSharedPercent > 0) {
            uint256 _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(dollar).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
            _boardroomAmount = _boardroomAmount.sub(_daoFundSharedAmount);
        }
        if (lotteryFundSharedPercent > 0) {
            uint256 _lotterySharedAmount = _amount.mul(lotteryFundSharedPercent).div(10000);
            IERC20(dollar).transfer(lotteryFund, _lotterySharedAmount);
            emit LotteryFundFunded(now, _lotterySharedAmount);
            _boardroomAmount = _boardroomAmount.sub(_lotterySharedAmount);
        }
        if (lpProviderBoardroomSharedPercent > 0) {
            uint256 _lpProviderBoardroomSharedAmount = _amount.mul(lpProviderBoardroomSharedPercent).div(10000);
            IERC20(dollar).safeIncreaseAllowance(lpProviderBoardroom, _lpProviderBoardroomSharedAmount);
            IBoardroom(lpProviderBoardroom).allocateSeigniorage(_lpProviderBoardroomSharedAmount);
            emit LpProviderBoardroomFunded(now, _lpProviderBoardroomSharedAmount);
            _boardroomAmount = _boardroomAmount.sub(_lpProviderBoardroomSharedAmount);
        }
        IERC20(dollar).safeIncreaseAllowance(boardroom, _boardroomAmount);
        IBoardroom(boardroom).allocateSeigniorage(_boardroomAmount);
        emit BoardroomFunded(now, _boardroomAmount);
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch {
        _updateDollarPrice();
        previousEpochDollarPrice = getDollarPrice();
        uint256 _dollarSupply = getDollarCirculatingSupply();
        if (_dollarSupply >= dollarSupplyTarget) {
            dollarSupplyTarget = dollarSupplyTarget.mul(12500).div(10000); // +25%
            maxSupplyExpansionPercent = maxSupplyExpansionPercent.mul(9500).div(10000); // -5%
            if (maxSupplyExpansionPercent < 10) {
                maxSupplyExpansionPercent = 10; // min 0.1%
            }
        }
        if (_epoch < bootstrapEpochs) {// 21 first epochs with 3.0% expansion
            _sendToBoardRoom(_dollarSupply.mul(maxSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochDollarPrice >= dollarPriceCeiling) {
                // Expansion ($SDO Price > 1$): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(bond).totalSupply();
                uint256 _percentage = previousEpochDollarPrice.sub(dollarPriceOne);
                uint256 _savedForBond;
                uint256 _savedForBoardRoom;
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {// saved enough to pay dept, mint as usual rate
                    uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                    if (_percentage > _mse) {
                        _percentage = _mse;
                    }
                    _savedForBoardRoom = _dollarSupply.mul(_percentage).div(1e18);
                } else {// have not saved enough to pay dept, mint more
                    uint256 _mse = maxSupplyExpansionPercent.mul(15e13); // maxSupplyExpansionPercentInDebtPhase = maxSupplyExpansionPercent * 1.5
                    if (_percentage > _mse) {
                        _percentage = _mse;
                    }
                    uint256 _seigniorage = _dollarSupply.mul(_percentage).div(1e18);
                    _savedForBoardRoom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForBoardRoom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBoardRoom > 0) {
                    _sendToBoardRoom(_savedForBoardRoom);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(dollar).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
        if (allocateSeigniorageSalary > 0) {
            IBasisAsset(dollar).mint(address(msg.sender), allocateSeigniorageSalary);
        }
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOwner {
        // do not allow to drain core tokens
        require(address(_token) != address(dollar), "dollar");
        require(address(_token) != address(bond), "bond");
        require(address(_token) != address(share), "share");
        _token.safeTransfer(_to, _amount);
    }
}
