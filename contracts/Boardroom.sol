// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "./utils/ContractGuard.sol";
import "./utils/ShareWrapper.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/ITreasury.sol";

contract Boardroom is ShareWrapper, ContractGuard, OwnableUpgradeSafe {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Boardseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct BoardSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    // flags
    bool public initialized = false;

    IERC20 public dollar;
    address public treasury;

    mapping(address => Boardseat) public directors;
    BoardSnapshot[] public boardHistory;

    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;

    address public daoFund;
    bool public earlyWithdrawAllowed;
    uint256 public earlyWithdrawFeeRate;
    uint256 public lateClaimRewardFeeRate;
    uint256 public lateClaimRewardFreeEpochs;
    mapping(address => mapping(address => bool)) public isApproved;

    uint256 public depositMaximumRate;
    mapping(address => bool) public isAllowedContract;
    bool public stakeAllowed;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    // ...

    /* ========== EVENTS ========== */

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier onlyTreasury() {
        require(treasury == msg.sender, "Boardroom: caller is not the treasury");
        _;
    }

    modifier onlyApproved(address _account) {
        require(isApproved[_account][msg.sender], "Boardroom: caller is not approved");
        _;
    }

    modifier isStakeAllowed() {
        require(stakeAllowed, "staking is disable");
        _;
    }

    modifier notContract() {
        if (!isAllowedContract[msg.sender]) {
            uint256 size;
            address addr = msg.sender;
            assembly {
                size := extcodesize(addr)
            }
            require(size == 0, "contract not allowed");
            require(tx.origin == msg.sender, "contract not allowed");
        }
        _;
    }

    modifier directorExists {
        require(balanceOf(msg.sender) > 0, "Boardroom: The director does not exist");
        _;
    }

    modifier updateReward(address director) {
        if (director != address(0)) {
            Boardseat memory seat = directors[director];
            seat.rewardEarned = earned(director);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            directors[director] = seat;
        }
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(IERC20 _dollar, IERC20 _share, address _treasury) external initializer {
        OwnableUpgradeSafe.__Ownable_init();

        dollar = _dollar;
        share = _share;
        treasury = _treasury;

        BoardSnapshot memory genesisSnapshot = BoardSnapshot({time : block.number, rewardReceived : 0, rewardPerShare : 0});
        boardHistory.push(genesisSnapshot);

        withdrawLockupEpochs = 6; // Lock for 6 epochs (36-48h) before release withdraw
        rewardLockupEpochs = 3; // Lock for 3 epochs (18-24h) before release claimReward

        daoFund = msg.sender; // Temporarily

        earlyWithdrawAllowed = true;
        earlyWithdrawFeeRate = 500; // fee 5% for every earlier epoch

        lateClaimRewardFreeEpochs = 9; // upto 9 epochs since last action (withdraw/stake/claim) before tax for reward
        lateClaimRewardFeeRate = 1500; // fee 10% for late claim reward

        depositMaximumRate = 200; // Each wallet can deposit a maximum of 2% SDS total supply, at the time of deposit
        stakeAllowed = true;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOwner {
        require(_withdrawLockupEpochs >= _rewardLockupEpochs && _withdrawLockupEpochs <= 56, "_withdrawLockupEpochs: out of range"); // <= 2 weeks
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
    }

    function setDaoFund(address _daoFund) external onlyOwner {
        require(_daoFund != address(0), "zero");
        daoFund = _daoFund;
    }

    function setEarlyWithdrawAllowed(bool _earlyWithdrawAllowed) external onlyOwner {
        earlyWithdrawAllowed = _earlyWithdrawAllowed;
    }

    function setEarlyWithdrawFeeRate(uint256 _earlyWithdrawFeeRate) external onlyOwner {
        earlyWithdrawFeeRate = _earlyWithdrawFeeRate;
    }

    function setLateClaimRewardFreeEpochs(uint256 _lateClaimRewardFreeEpochs) external onlyOwner {
        lateClaimRewardFreeEpochs = _lateClaimRewardFreeEpochs;
    }

    function setLateClaimRewardFeeRate(uint256 _lateClaimRewardFeeRate) external onlyOwner {
        lateClaimRewardFeeRate = _lateClaimRewardFeeRate;
    }

    function setDepositMaximumRate(uint256 _depositMaximumRate) external onlyOwner {
        require(_depositMaximumRate <= 10000, "out of range"); // <= 100%
        depositMaximumRate = _depositMaximumRate;
    }

    function setStakeAllowed(bool _stakeAllowed) external onlyOwner {
        stakeAllowed = _stakeAllowed;
    }

    function setContractAllowedStatus(address _contract, bool _isAllowed) external onlyOwner {
        isAllowedContract[_contract] = _isAllowed;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256) {
        return boardHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (BoardSnapshot memory) {
        return boardHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address director) public view returns (uint256) {
        return directors[director].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address director) internal view returns (BoardSnapshot memory) {
        return boardHistory[getLastSnapshotIndexOf(director)];
    }

    function canWithdraw(address director) external view returns (bool) {
        return isAllowedContract[director] || directors[director].epochTimerStart.add(withdrawLockupEpochs) <= ITreasury(treasury).epoch();
    }

    function canClaimReward(address director) public view returns (bool) {
        return isAllowedContract[director] || directors[director].epochTimerStart.add(rewardLockupEpochs) <= ITreasury(treasury).epoch();
    }

    function epoch() public view returns (uint256) {
        return ITreasury(treasury).epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return ITreasury(treasury).nextEpochPoint();
    }

    function getDollarPrice() external view returns (uint256) {
        return ITreasury(treasury).getDollarPrice();
    }

    function getMaximumDepositAmount(address director) public view returns (uint256) {
        uint256 _shareSupply = share.totalSupply();
        if (director == daoFund || isAllowedContract[director]) return _shareSupply;
        uint256 _maxAmount = _shareSupply.mul(depositMaximumRate).div(10000);
        uint256 _deposited = balanceOf(director);
        return (_deposited >= _maxAmount) ? 0 : _maxAmount.sub(_deposited);
    }

    // =========== Director getters

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address director) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(director).rewardPerShare;

        return balanceOf(director).mul(latestRPS.sub(storedRPS)).div(1e18).add(directors[director].rewardEarned);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function approveStakeFor(address _account) external {
        isApproved[msg.sender][_account] = true;
    }

    function unapproveStakeFor(address _account) external {
        isApproved[msg.sender][_account] = false;
    }

    function stake(uint256 _amount) public override isStakeAllowed notContract onlyOneBlock updateReward(msg.sender) {
        require(_amount > 0, "Boardroom: Cannot stake 0");
        require(_amount <= getMaximumDepositAmount(msg.sender), "Exceeds deposit maximum");
        if (canClaimReward(msg.sender)) {
            claimReward();
        }
        super.stake(_amount);
        directors[msg.sender].epochTimerStart = epoch(); // reset timer
        emit Staked(msg.sender, _amount);
    }

    function stakeFor(address _account, uint256 _amount) public isStakeAllowed notContract onlyOneBlock onlyApproved(_account) updateReward(_account) {
        require(_amount > 0, "Boardroom: Cannot stake 0");
        require(_amount <= getMaximumDepositAmount(_account), "Exceeds deposit maximum");
        super._stakeFor(_account, _amount);
        directors[_account].epochTimerStart = epoch(); // reset timer
        emit Staked(_account, _amount);
    }

    function withdraw(uint256 _amount) public notContract onlyOneBlock directorExists updateReward(msg.sender) {
        require(_amount > 0, "Boardroom: Cannot withdraw 0");
        uint256 _epochTimerStart = directors[msg.sender].epochTimerStart;
        uint256 _epoch = epoch();
        uint256 _sentAmount = _amount;
        uint256 _fee = 0;
        if (!isAllowedContract[msg.sender] && _epochTimerStart.add(withdrawLockupEpochs) > _epoch) {
            require(earlyWithdrawAllowed, "Boardroom: still in withdraw lockup");
            uint256 _pendingEpochs = _epochTimerStart.add(withdrawLockupEpochs).sub(_epoch);
            _fee = _amount.mul(_pendingEpochs).mul(earlyWithdrawFeeRate).div(10000);
            if (_fee > _amount) {
                _fee = _amount;
                _sentAmount = 0;
            } else {
                _sentAmount = _sentAmount.sub(_fee);
            }
            share.safeTransfer(daoFund, _fee);
            _claimReward(msg.sender, false); // sacrifice rewards
        } else {
            claimReward();
        }
        super.withdraw(_amount, _sentAmount);
        emit Withdrawn(msg.sender, _amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
    }

    function claimReward() public {
        require(canClaimReward(msg.sender), "Boardroom: still in reward lockup");
        _claimReward(msg.sender, true);
    }

    function _claimReward(address _account, bool _tokenTransferred) internal notContract updateReward(_account) {
        uint256 _reward = directors[_account].rewardEarned;
        if (_reward > 0) {
            directors[_account].rewardEarned = 0;
            uint256 _epoch = epoch();
            if (_tokenTransferred) {
                if (directors[_account].epochTimerStart.add(lateClaimRewardFreeEpochs) < _epoch) {
                    uint256 _fee = _reward.mul(lateClaimRewardFeeRate).div(10000);
                    _reward = _reward.sub(_fee);
                    IBasisAsset(address(dollar)).burn(_fee);
                }
                dollar.safeTransfer(_account, _reward);
            } else {
                IBasisAsset(address(dollar)).burn(_reward);
            }
            emit RewardPaid(_account, _reward);
            directors[_account].epochTimerStart = epoch(); // reset timer
        }
    }

    function allocateSeigniorage(uint256 amount) external onlyOneBlock onlyTreasury {
        require(amount > 0, "Boardroom: Cannot allocate 0");
        require(totalSupply() > 0, "Boardroom: Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        BoardSnapshot memory newSnapshot = BoardSnapshot({
            time: block.number,
            rewardReceived: amount,
            rewardPerShare: nextRPS
        });
        boardHistory.push(newSnapshot);

        dollar.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(msg.sender, amount);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOwner {
        // do not allow to drain core tokens
        require(address(_token) != address(dollar), "dollar");
        require(address(_token) != address(share), "share");
        _token.safeTransfer(_to, _amount);
    }
}
