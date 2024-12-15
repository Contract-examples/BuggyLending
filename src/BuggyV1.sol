// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BuggyLendingV1 is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    address public immutable DAI;
    address public lender;
    address public borrower;

    // Fixed price: 1 ETH = 3500 DAI (for simplicity)
    uint256 public constant DAI_PRICE = 285714285714285; // 1e18/3500 (ETH per DAI)

    modifier onlyLender() {
        require(msg.sender == lender, "Only lender can call");
        _;
    }

    modifier onlyBorrower() {
        require(msg.sender == borrower, "Only borrower can call");
        _;
    }

    struct Loan {
        uint256 loanAmount; // Amount in ETH
        uint256 collateralAmount;
        uint256 startTime;
        uint256 dueDate;
        bool isActive;
        bool isBorrowed;
    }

    // Constants
    uint256 public constant LOAN_DURATION = 20 days;
    uint256 public constant LIQUIDATION_THRESHOLD = 150; // 150% collateralization ratio

    // Single loan state
    Loan public activeLoan;

    // Track lender's ETH balance
    uint256 public lenderBalance;

    event LoanCreated(uint256 amount);
    event LoanBorrowed(uint256 collateralAmount);
    event LoanRepaid(uint256 amount);
    event LoanLiquidated();
    event BorrowerUpdated(address newBorrower);
    event LenderUpdated(address newLender);

    constructor(address _dai) Ownable(msg.sender) {
        require(_dai != address(0), "Invalid DAI address");
        DAI = _dai;
    }

    function setBorrower(address _borrower) external onlyOwner {
        require(_borrower != address(0), "Invalid borrower address");
        borrower = _borrower;
        emit BorrowerUpdated(_borrower);
    }

    function setLender(address _lender) external onlyOwner {
        require(_lender != address(0), "Invalid lender address");
        lender = _lender;
        emit LenderUpdated(_lender);
    }

    function createLoan() external payable onlyLender nonReentrant {
        require(msg.value > 0, "Invalid loan amount");
        require(!activeLoan.isActive, "Loan already exists");

        activeLoan = Loan({
            loanAmount: msg.value,
            collateralAmount: 0,
            startTime: 0,
            dueDate: 0,
            isActive: true,
            isBorrowed: false
        });

        lenderBalance += msg.value;

        emit LoanCreated(msg.value);
    }

    function borrowLoan(uint256 collateralAmount) external onlyBorrower nonReentrant {
        require(activeLoan.isActive && !activeLoan.isBorrowed, "Loan not available");
        require(collateralAmount > 0, "Invalid collateral amount");

        uint256 collateralValue = collateralAmount * DAI_PRICE;
        uint256 requiredCollateral = activeLoan.loanAmount * LIQUIDATION_THRESHOLD / 100;
        collateralValue = collateralValue / 1e18;

        require(collateralValue >= requiredCollateral, "Insufficient collateral");

        IERC20(DAI).safeTransferFrom(msg.sender, address(this), collateralAmount);

        activeLoan.collateralAmount = collateralAmount;
        activeLoan.startTime = block.timestamp;
        activeLoan.dueDate = block.timestamp + LOAN_DURATION;
        activeLoan.isBorrowed = true;

        (bool success,) = payable(borrower).call{ value: activeLoan.loanAmount }("");
        require(success, "ETH transfer failed");

        emit LoanBorrowed(collateralAmount);
    }

    function canLiquidate() public view returns (bool) {
        if (!activeLoan.isActive || !activeLoan.isBorrowed) return false;

        bool isDefaulted = block.timestamp > activeLoan.dueDate;

        uint256 collateralValue = activeLoan.collateralAmount * DAI_PRICE;
        uint256 requiredCollateral = activeLoan.loanAmount * LIQUIDATION_THRESHOLD / 100;
        collateralValue = collateralValue / 1e18;

        return isDefaulted || collateralValue < requiredCollateral;
    }

    function liquidate() external onlyLender nonReentrant {
        require(canLiquidate(), "Cannot liquidate this loan");
        require(activeLoan.isActive && activeLoan.isBorrowed, "Loan not active or not borrowed");

        activeLoan.isActive = false;
        lenderBalance -= activeLoan.loanAmount;

        IERC20(DAI).safeTransfer(lender, activeLoan.collateralAmount);

        emit LoanLiquidated();
    }

    function repayLoan() external payable onlyBorrower nonReentrant {
        require(activeLoan.isActive && activeLoan.isBorrowed, "Loan not active or not borrowed");
        require(msg.value >= activeLoan.loanAmount, "Insufficient repayment amount");

        activeLoan.isActive = false;
        lenderBalance += msg.value;

        IERC20(DAI).safeTransfer(borrower, activeLoan.collateralAmount);

        emit LoanRepaid(msg.value);
    }

    function withdrawBalance() external onlyLender nonReentrant {
        uint256 amount = lenderBalance;
        require(amount > 0, "No balance to withdraw");

        // Deactivate the loan if it hasn't been borrowed yet
        if (activeLoan.isActive && !activeLoan.isBorrowed) {
            activeLoan.isActive = false;
        }

        lenderBalance = 0;

        (bool success,) = payable(lender).call{ value: amount }("");
        require(success, "ETH transfer failed");
    }

    receive() external payable { }
}
