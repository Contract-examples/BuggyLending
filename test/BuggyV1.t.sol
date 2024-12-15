// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "src/BuggyV1.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockDAI is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(_allowances[from][msg.sender] >= amount, "Insufficient allowance");
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
}

contract BuggyV1Test is Test {
    BuggyLendingV1 public lending;
    MockDAI public dai;
    address public lender;
    address public borrower;

    function setUp() public {
        // Deploy contracts
        dai = new MockDAI();
        lending = new BuggyLendingV1(address(dai));
        
        // Setup roles
        lender = makeAddr("lender");
        borrower = makeAddr("borrower");
        
        // Set lender and borrower
        lending.setBorrower(borrower);
        lending.setLender(lender);
        
        // Mint DAI for borrower
        dai.mint(borrower, 10_000 * 1e18);
        
        // Give ETH to lender
        vm.deal(lender, 10 ether);
        
        // Approve lending contract to use DAI
        vm.prank(borrower);
        dai.approve(address(lending), type(uint256).max);
    }
    
    function testTimeLogicBug() public {
        // 1. Lender creates loan
        vm.prank(lender);
        lending.createLoan{value: 1 ether}();
        
        console2.log("DAI_PRICE:", lending.DAI_PRICE());
        
        // Calculate required collateral matching contract's calculation
        uint256 loanAmountInETH = 1 ether;
        uint256 requiredCollateralInETH = (loanAmountInETH * lending.LIQUIDATION_THRESHOLD()) / 100;
        uint256 requiredCollateralInDAI = requiredCollateralInETH * 3500;
        
        console2.log("Calculation details:");
        console2.log(" - Loan amount (ETH):", loanAmountInETH);
        console2.log(" - Required collateral (ETH):", requiredCollateralInETH);
        console2.log(" - Required collateral (DAI):", requiredCollateralInDAI);
        
        // Add some margin to ensure we have enough collateral
        uint256 collateralWithMargin = requiredCollateralInDAI * 12 / 10; // Add 20% margin
        console2.log(" - Collateral with margin (DAI):", collateralWithMargin);
        
        // Verify we have enough DAI
        require(collateralWithMargin <= dai.balanceOf(borrower), "Not enough DAI balance");
        
        // Set initial block timestamp
        vm.warp(1000);
        
        // 2. Borrower provides collateral and borrows
        vm.prank(borrower);
        lending.borrowLoan(collateralWithMargin);
        
        // 3. Check if loan can be liquidated (should not be possible)
        bool canLiquidateBeforeDefault = lending.canLiquidate();
        assertFalse(canLiquidateBeforeDefault, "Loan should not be liquidatable");
        
        // Print loan details
        (,,uint256 startTime, uint256 dueDate,,) = lending.activeLoan();
        console2.log("Loan details:");
        console2.log(" - Start time:", startTime);
        console2.log(" - Due date:", dueDate);
        console2.log(" - Current time:", block.timestamp);
        
        // 4. Warp time to trigger the time logic bug
        // Due to the bug in canLiquidate(): block.timestamp + dueDate > startTime
        // We need to set block.timestamp to a small negative value (relative to startTime)
        uint256 newTimestamp;
        unchecked {
            // Calculate a timestamp that will cause overflow when added to dueDate
            newTimestamp = type(uint256).max - dueDate + 1;
        }
        vm.warp(newTimestamp);
        
        console2.log("After time warp:");
        console2.log(" - Current time:", block.timestamp);
        console2.log(" - Start time:", startTime);
        console2.log(" - Due date:", dueDate);
        
        // Now check if the loan can be liquidated due to the time logic bug
        bool canLiquidateAfterTimeWarp = lending.canLiquidate();
        assertTrue(canLiquidateAfterTimeWarp, "Loan should be liquidatable due to time logic bug");
        
        // 5. Try to liquidate
        vm.prank(lender);
        lending.liquidate();
        
        // 6. Check loan status after liquidation
        (,,,, bool isActive,) = lending.activeLoan();
        assertFalse(isActive, "Loan should be liquidated");
        
        // Print final balances
        console2.log("Lender DAI balance after liquidation:", dai.balanceOf(lender));
    }
}
