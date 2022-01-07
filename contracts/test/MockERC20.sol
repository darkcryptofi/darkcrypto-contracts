pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";

import "../owner/Operator.sol";

contract MockERC20 is ERC20Burnable, Operator {
    mapping(address => bool) public minter;

    constructor(string memory name, string memory symbol, uint8 _decimals) public ERC20(name, symbol) {
        _setupDecimals(_decimals);
    }

    function setMinter(address _account, bool _isMinter) external onlyOperator {
        require(_account != address(0), "zero");
        minter[_account] = _isMinter;
    }

    /**
     * @notice Operator mints dino dollar to a recipient
     * @param recipient_ The address of recipient
     * @param amount_ The amount of dino dollar to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyOperator returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function faucet(uint256 amt) public returns (bool) {
        require(minter[msg.sender] || amt <= 10000 * (10 ** uint256(decimals())), "upto 10000 token");
        _mint(msg.sender, amt);
        return true;
    }

    function faucet1000coins() public returns (bool) {
        return faucet(1000 * (10 ** uint256(decimals())));
    }
}
