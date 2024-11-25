// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "src/interfaces/IHumanResources.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@zksync/contracts/l1-contracts/contracts/bridge/interfaces/IWETH9.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract HumanResources is IHumanResources, ReentrancyGuard {
    // Constants and immutable variables
    address private immutable _hrManager;
    uint256 private activeEmployeeCount;
    uint256 private constant SECONDS_PER_WEEK = 7 * 24 * 60 * 60;

    // External contract addresses
    address public immutable WETH_ADDRESS;
    address public immutable USDC_ADDRESS;
    address public immutable SWAP_ROUTER_ADDRESS;
    address public immutable CHAINLINK_ORACLE_ADDRESS;

    // External contract instances
    IERC20 public immutable USDC;
    IWETH9 public immutable WETH;
    ISwapRouter public immutable swapRouter;
    AggregatorV3Interface public immutable priceFeed;

    struct Employee {
        uint256 weeklyUsdSalary; // In USD with 18 decimals
        uint256 employedSince;
        uint256 terminatedAt;
        bool isActive;
        bool isEth;
        uint256 unclaimedSalary; // In USD with 18 decimals
    }

    mapping(address => Employee) private employees;

    constructor(
        address constructor_hrManager,
        address _wethAddress,
        address _usdcAddress,
        address _swapRouterAddress,
        address _chainlinkOracleAddress
    ) {
        _hrManager = constructor_hrManager;
        WETH_ADDRESS = _wethAddress;
        USDC_ADDRESS = _usdcAddress;
        SWAP_ROUTER_ADDRESS = _swapRouterAddress;
        CHAINLINK_ORACLE_ADDRESS = _chainlinkOracleAddress;
        WETH = IWETH9(WETH_ADDRESS);
        USDC = IERC20(USDC_ADDRESS);
        swapRouter = ISwapRouter(SWAP_ROUTER_ADDRESS);
        priceFeed = AggregatorV3Interface(_chainlinkOracleAddress);
    }

    // 1. HRManager and Unauthorized User Handling
    modifier onlyHRManager() {
        if (msg.sender != _hrManager) {
            revert NotAuthorized();
        }
        _;
    }

    modifier onlyEmployee() {
        if (employees[msg.sender].employedSince == 0) {
            revert NotAuthorized();
        }
        _;
    }

    // for the interface in IHumanResources
    function hrManager() external view override returns (address) {
        return _hrManager;
    }

    // 2.1 HR Manager Functions (registerEmployee)
    function registerEmployee(address employee, uint256 weeklyUsdSalary) external override onlyHRManager {
        Employee storage emp = employees[employee];

        if (emp.isActive) {
            revert EmployeeAlreadyRegistered();
        }

        // Retain any unclaimed salary if the employee is being re-registered
        uint256 retainedUnclaimedSalary = emp.unclaimedSalary;

        employees[employee] = Employee({
            weeklyUsdSalary: weeklyUsdSalary,
            employedSince: block.timestamp,
            terminatedAt: 0,
            isActive: true,
            isEth: emp.isEth ? emp.isEth : false, // Default to USDC unless previously set to ETH
            unclaimedSalary: retainedUnclaimedSalary // Retain previously unclaimed salary
        });

        activeEmployeeCount++;
        emit EmployeeRegistered(employee, weeklyUsdSalary);
    }

    // 2.2 HR Manager Functions (terminateEmployee)
    function terminateEmployee(address employee) external override onlyHRManager {
        if (!employees[employee].isActive) {
            revert EmployeeNotRegistered();
        }
        Employee storage emp = employees[employee];
        emp.isActive = false;
        emp.terminatedAt = block.timestamp;
        emp.unclaimedSalary = salaryAvailableInUSD(employee);
        emp.employedSince = block.timestamp; // Prevent further accrual
        activeEmployeeCount--;
        emit EmployeeTerminated(employee);
    }

    // 3.1 Accrual Logic (salaryAvailableInUSD) in 18 decimals
    function salaryAvailableInUSD(address employee) internal view returns (uint256) {
        // Calculate duration
        Employee memory emp = employees[employee];
        uint256 endTime = emp.isActive ? block.timestamp : emp.terminatedAt;
        // Linear accumulation
        uint256 elapsedTime = endTime - emp.employedSince;
        uint256 accruedSalary = (emp.weeklyUsdSalary * elapsedTime) / SECONDS_PER_WEEK;
        return emp.unclaimedSalary + accruedSalary; // Amount in USD with 18 decimals
    }

    // 3.2 Employee Functions (withdrawSalary)
    // If salaryAvailableInUSD > 0 but the converted usdcAmount is 0 (due to low salary),
    // do not reset unclaimedSalary. This ensures fairness for employees with low weekly salaries
    // or short employment periods, allowing their salary to accumulate for future withdrawals.

    event NoSalaryTransferred(address indexed employee, string reason);

    function withdrawSalary() public override onlyEmployee nonReentrant {
        Employee storage emp = employees[msg.sender];
        uint256 amountInUSD = salaryAvailableInUSD(msg.sender);
        require(amountInUSD > 0, "No salary available");

        if (emp.isEth) {
            uint256 ethAmount = swapUSDCForETH(amountInUSD);
            if (ethAmount > 0) {
                // Reset salary accrual before external interactions
                emp.unclaimedSalary = 0;
                emp.employedSince = block.timestamp;

                // Transfer ETH to employee
                (bool success,) = msg.sender.call{value: ethAmount}("");
                require(success, "ETH transfer failed");
                emit SalaryWithdrawn(msg.sender, true, ethAmount);
            } else {
                // Do not reset accruals; salary continues to accumulate
                emit NoSalaryTransferred(msg.sender, "No ETH transferred due to insufficient amount");
            }
        } else {
            uint256 usdcAmount = amountInUSD / 1e12; // Convert USD (18 decimals) to USDC (6 decimals)
            if (usdcAmount > 0) {
                // Reset salary accrual before external interactions
                emp.unclaimedSalary = 0;
                emp.employedSince = block.timestamp;

                // Transfer USDC to employee
                require(USDC.transfer(msg.sender, usdcAmount), "USDC transfer failed");
                emit SalaryWithdrawn(msg.sender, false, usdcAmount);
            } else {
                // Do not reset accruals; salary continues to accumulate
                emit NoSalaryTransferred(msg.sender, "No USDC transferred due to insufficient amount");
            }
        }
    }

    // 3.3 Switching Preferred Currency
    modifier onlyActiveEmployee() {
        if (employees[msg.sender].employedSince == 0 || !employees[msg.sender].isActive) {
            revert NotAuthorized();
        }
        _;
    }

    // Apply the new modifier to switchCurrency
    function switchCurrency() external override onlyActiveEmployee {
        Employee storage emp = employees[msg.sender];

        // Automatically withdraw pending salary
        uint256 amountInUSD = salaryAvailableInUSD(msg.sender);

        if (amountInUSD > 0) {
            withdrawSalary(); // Direct internal call
        }

        emp.isEth = !emp.isEth;
        emit CurrencySwitched(msg.sender, emp.isEth);
    }

    // 4 Swap function considering the scaling problem, AMM price manipulation, and slippage prevention.
    function swapUSDCForETH(uint256 amountInUSD) internal returns (uint256 ethAmount) {
        uint256 usdcAmount = amountInUSD / 1e12; // Convert USD (18 decimals) to USDC (6 decimals)
        require(USDC.balanceOf(address(this)) >= usdcAmount, "Insufficient USDC balance");

        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price data");

        uint8 priceDecimals = priceFeed.decimals();
        uint256 ethPriceInUSD18 = uint256(price) * (10 ** (18 - priceDecimals));
        uint256 expectedEthAmount = (amountInUSD * 1e18) / ethPriceInUSD18;
        uint256 amountOutMinimum = (expectedEthAmount * 98) / 100;

        require(USDC.approve(address(swapRouter), usdcAmount), "USDC approval failed");

        uint256 deadline = block.timestamp + 10 minutes; // Deadline is 10 minutes from now
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: USDC_ADDRESS,
            tokenOut: WETH_ADDRESS,
            fee: 3000, // Pool fee (0.3%)
            recipient: address(this),
            deadline: deadline,
            amountIn: usdcAmount,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = swapRouter.exactInputSingle(params);

        WETH.withdraw(amountOut);

        return amountOut;
    }

    // 5.1 View Function salaryAvailable
    function salaryAvailable(address employee) public view override returns (uint256) {
        Employee memory emp = employees[employee];
        if (emp.employedSince == 0) return 0; // Employee does not exist
        uint256 amountInUSD = salaryAvailableInUSD(employee);

        if (emp.isEth) {
            // Get the latest ETH/USD price from Chainlink
            (, int256 price,,,) = priceFeed.latestRoundData();
            require(price > 0, "Invalid price data");
            uint8 priceDecimals = priceFeed.decimals();
            // Calculate ETH price in USD with 18 decimals
            uint256 ethPriceInUSD18 = uint256(price) * (10 ** (18 - priceDecimals));
            // Calculate ETH amount
            uint256 ethAmount = (amountInUSD * 1e18) / ethPriceInUSD18;
            return ethAmount;
        } else {
            // Convert USD (18 decimals) to USDC (6 decimals)
            uint256 usdcAmount = amountInUSD / 1e12; // Assume 1 USD = 1 USDC
            return usdcAmount; // May be zero if amountInUSD is too small
        }
    }

    // 5.2 View Function hrManager
    function getHRManager() external view returns (address) {
        return _hrManager;
    }

    // 5.3 View Function getActiveEmployeeCount
    function getActiveEmployeeCount() external view override returns (uint256) {
        return activeEmployeeCount;
    }

    // 5.4 View Function getEmployeeInfo
    function getEmployeeInfo(address employee) external view override returns (uint256, uint256, uint256) {
        Employee memory emp = employees[employee];
        if (emp.employedSince == 0) {
            return (0, 0, 0); // Employee does not exist
        }
        return (emp.weeklyUsdSalary, emp.employedSince, emp.terminatedAt);
    }

    // Fallback function to receive ETH
    receive() external payable {}
}
