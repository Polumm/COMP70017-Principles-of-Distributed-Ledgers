// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/HumanResources.sol";
import "src/interfaces/IHumanResources.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@zksync/contracts/l1-contracts/contracts/bridge/interfaces/IWETH9.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract HumanResourcesTest is Test {
    IHumanResources hr; // Use the IHumanResources interface
    address hrManagerAddress; // HR manager's address
    address employee = address(0x789); // Mock employee address
    address employee2 = address(0x456); // Mock second employee address
    address nonEmployee = address(0xabc); // Mock non-employee address

    IERC20 usdc;
    IWETH9 weth;
    ISwapRouter swapRouter;
    AggregatorV3Interface priceFeed;

    // Constants for addresses on Optimism
    address constant USDC_ADDRESS = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // USDC on Optimism
    address constant WETH_ADDRESS = 0x4200000000000000000000000000000000000006; // WETH on Optimism
    address constant SWAP_ROUTER_ADDRESS = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // Uniswap V3 Swap Router
    address constant CHAINLINK_ORACLE_ADDRESS = 0x13e3Ee699D1909E989722E753853AE30b17e08c5; // ETH/USD Price Feed
    uint256 forkId;

    // Events from the IHumanResources interface
    event EmployeeRegistered(address indexed employee, uint256 weeklyUsdSalary);
    event EmployeeTerminated(address indexed employee);
    event SalaryWithdrawn(address indexed employee, bool isEth, uint256 amount);
    event CurrencySwitched(address indexed employee, bool isEth);

    function setUp() public {
        // Create and select a fork of Optimism Mainnet
        string memory forkUrl = "https://mainnet.optimism.io";
        forkId = vm.createFork(forkUrl);
        vm.selectFork(forkId);

        hrManagerAddress = address(this); // Set HR manager's address to this contract
        // Initialize external contract instances with the specified addresses
        usdc = IERC20(USDC_ADDRESS);
        weth = IWETH9(WETH_ADDRESS);
        swapRouter = ISwapRouter(SWAP_ROUTER_ADDRESS);
        priceFeed = AggregatorV3Interface(CHAINLINK_ORACLE_ADDRESS);

        // Deploy the HumanResources contract
        hr = IHumanResources(
            address(
                new HumanResources(
                    hrManagerAddress, WETH_ADDRESS, USDC_ADDRESS, SWAP_ROUTER_ADDRESS, CHAINLINK_ORACLE_ADDRESS
                )
            )
        );

        // Provide USDC balance to the HR contract
        deal(USDC_ADDRESS, address(hr), 1_000_000 * 1e6); // 1 million USDC with 6 decimals
    }

    // Test that the HR manager address is set correctly
    function testHRManagerAddress() public view {
        assertEq(hr.hrManager(), hrManagerAddress, "HR manager address should match");
    }

    function testOracleIntegration() public view {
        // Fetch latest data from the price feed
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        // Log all fetched data
        console.log("Round ID:", roundId);
        console.log("Oracle Price (raw):", uint256(price));
        console.log("Started At (timestamp):", startedAt);
        console.log("Updated At (timestamp):", updatedAt);
        console.log("Answered In Round ID:", answeredInRound);

        // Log current timestamp
        uint256 currentTimestamp = block.timestamp;
        console.log("Current Timestamp (block.timestamp):", currentTimestamp);

        // Validate price is positive
        require(price > 0, "Invalid price data");

        // Fetch and log the decimals used by the oracle
        uint8 decimals = priceFeed.decimals();
        console.log("Oracle Decimals:", decimals);

        // Validate scaling logic: convert to 18-decimal precision
        uint256 scaledPrice = uint256(price) * (10 ** (18 - decimals));
        console.log("Scaled Price (ETH/USD 18 decimals):", scaledPrice);

        // Assert scaled price is in a reasonable range (e.g., $100 to $10,000 in 18 decimals)
        require(scaledPrice > 100e18 && scaledPrice < 10000e18, "Price out of expected range");
    }

    function testSwapTriggeredViaWithdrawSalary() public {
        uint256 weeklySalary = 1_000 * 1e18; // Weekly salary in USD (18 decimals)
        uint256 amountInUSD = (weeklySalary * 2 days) / 7 days; // Accrued salary for 2 days

        // Simulate USDC funding for the HR contract
        deal(address(usdc), address(hr), amountInUSD / 1e12); // Convert to USDC (6 decimals)

        console.log("HR Contract USDC Balance Before Withdrawal:", usdc.balanceOf(address(hr)));

        // Register the employee
        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Switch to ETH preference
        vm.prank(employee);
        hr.switchCurrency();

        // Simulate time progression
        vm.warp(block.timestamp + 2 days);

        // Perform withdrawal (triggers swapUSDCForETH internally)
        vm.prank(employee);
        hr.withdrawSalary();

        // Check balances
        uint256 ethBalanceAfter = address(employee).balance;
        console.log("Employee ETH Balance After Withdrawal:", ethBalanceAfter);

        require(ethBalanceAfter > 0, "ETH withdrawal failed");
    }

    // Test registering an employee
    function testRegisterEmployee() public {
        uint256 weeklySalary = 1_000 * 1e18; // 1,000 USD with 18 decimals

        // Expect the EmployeeRegistered event
        vm.expectEmit(true, true, true, true);
        emit EmployeeRegistered(employee, weeklySalary);

        // Register employee with HR manager privileges
        vm.prank(hrManagerAddress); // Set msg.sender to hrManagerAddress
        hr.registerEmployee(employee, weeklySalary);

        (uint256 weeklyUsdSalary, uint256 employedSince, uint256 terminatedAt) = hr.getEmployeeInfo(employee);

        assertEq(weeklyUsdSalary, weeklySalary, "Weekly salary should match");
        assertGt(employedSince, 0, "Employed since timestamp should be set");
        assertEq(terminatedAt, 0, "Terminated at timestamp should be zero");
    }

    // Test that only the HR manager can register an employee
    function testOnlyHRManagerCanRegisterEmployee() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        vm.prank(employee);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.registerEmployee(employee2, weeklySalary);
    }

    // Test that registering an employee twice fails
    function testRegisterEmployeeTwiceFails() public {
        uint256 weeklySalary = 1_000 * 1e18;
        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);
        // Attempt to register the same employee again should fail
        vm.prank(hrManagerAddress);
        vm.expectRevert(IHumanResources.EmployeeAlreadyRegistered.selector);
        hr.registerEmployee(employee, weeklySalary);
    }

    // Test terminating an employee
    function testTerminateEmployee() public {
        uint256 weeklySalary = 1_000 * 1e18;
        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Expect the EmployeeTerminated event
        vm.expectEmit(true, true, true, true);
        emit EmployeeTerminated(employee);
        vm.prank(hrManagerAddress);
        hr.terminateEmployee(employee);

        (,, uint256 terminatedAt) = hr.getEmployeeInfo(employee);
        assertGt(terminatedAt, 0, "Terminated at timestamp should be set");
    }

    // Test that only the HR manager can terminate an employee
    function testOnlyHRManagerCanTerminateEmployee() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        vm.prank(employee);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.terminateEmployee(employee);
    }

    // Test that terminating an unregistered employee (InvalidAddress) raises EmployeeNotRegistered error
    function testTerminateUnregisteredEmployee() public {
        address unregisteredEmployee = nonEmployee; // A mock unregistered employee address
        vm.expectRevert(IHumanResources.EmployeeNotRegistered.selector);
        vm.prank(hrManagerAddress);
        hr.terminateEmployee(unregisteredEmployee);
    }

    // Test that HR Manager can rehire the same employee who once terminated his/her job
    function testRehireEmployeeMultipleTimes() public {
        uint256 weeklySalary = 1_000 * 1e18;

        // Step 1: HR Manager registers the employee for the first time
        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Simulate termination and rehire twice
        for (uint256 i = 0; i < 2; i++) {
            // Step 2: HR Manager terminates the employee
            vm.prank(hrManagerAddress);
            hr.terminateEmployee(employee);

            // Simulate time passing to test accumulation reset
            vm.warp(block.timestamp + 7 days);

            // Step 3: HR Manager rehires the same employee with an updated salary
            uint256 newWeeklySalary = (weeklySalary + (i + 1) * 500 * 1e18);
            vm.prank(hrManagerAddress);
            hr.registerEmployee(employee, newWeeklySalary);

            // Verify the updated state after rehire
            (uint256 rehiredSalary, uint256 rehiredSince, uint256 rehiredTerminatedAt) = hr.getEmployeeInfo(employee);

            // Check if the rehired salary is updated correctly
            assertEq(rehiredSalary, newWeeklySalary, "Weekly salary should match after rehire");

            // Verify that terminatedAt is reset to 0 after rehire
            assertEq(rehiredTerminatedAt, 0, "Terminated at should be reset after rehire");

            // Verify that employedSince is updated after rehire
            assertGt(rehiredSince, block.timestamp - 7 days, "Employed since should be updated after rehire");
        }
    }

    // Test salary accrual stops after termination
    function testSalaryStopsAccruingAfterTermination() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Move time forward by 3 days
        vm.warp(block.timestamp + 3 days);

        // Terminate the employee
        vm.prank(hrManagerAddress);
        hr.terminateEmployee(employee);

        // Move time forward by another 2 days
        vm.warp(block.timestamp + 2 days);

        // Salary should only accrue up to termination
        uint256 expectedAccruedUSD = (weeklySalary * 3 days) / 7 days;
        uint256 expectedUSDC = expectedAccruedUSD / 1e12;

        uint256 accruedSalary = hr.salaryAvailable(employee);

        assertEq(accruedSalary, expectedUSDC, "Salary should not accrue after termination");
    }

    // Test withdrawing salary in USDC
    function testWithdrawSalaryInUSDC() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Move time forward by 1 day
        vm.warp(block.timestamp + 1 days);

        // Expect the SalaryWithdrawn event
        uint256 expectedUSDC = ((weeklySalary * 1 days) / 7 days) / 1e12;

        vm.expectEmit(true, true, true, true);
        emit SalaryWithdrawn(employee, false, expectedUSDC);

        // Simulate employee calling
        vm.prank(employee);
        hr.withdrawSalary();

        // Validate that salary has been reset after withdrawal
        uint256 remainingSalary = hr.salaryAvailable(employee);
        assertEq(remainingSalary, 0, "Salary should be reset after withdrawal");

        // Validate that the employee received USDC
        uint256 employeeUSDCBalance = usdc.balanceOf(employee);
        assertEq(employeeUSDCBalance, expectedUSDC, "Employee should receive correct amount of USDC");
    }

    function testLowSalaryAccumulation() public {
        uint256 weeklySalary = 1e16; // $0.01 per week (18 decimals)
        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Simulate time passage
        vm.warp(block.timestamp + 1 days);

        // Withdraw salary
        vm.prank(employee);
        hr.withdrawSalary();

        // Validate the USDC transferred
        uint256 employeeUSDCBalance = usdc.balanceOf(employee);
        uint256 expectedUSDC = ((weeklySalary * 1 days) / 7 days) / 1e12;
        console.log("expectedUSDC USDC, 6 decimal): ", expectedUSDC);
        console.log("employeeUSDCBalance USDC, 6 decimal): ", expectedUSDC);
        assertEq(employeeUSDCBalance, expectedUSDC, "USDC should match the calculated amount");

        // Validate salary is reset after withdrawal
        uint256 availableSalary = hr.salaryAvailable(employee);
        console.log("availableSalary(USDC, 6 decimal): ", availableSalary);
        assertEq(availableSalary, 0, "Salary should be reset after withdrawal");
    }

    function testLowSalaryUnclaimedPreserved() public {
        uint256 weeklySalary = 1e10; // $0.00001 per week (18 decimals, extremely low salary)
        console.log("Step 1: Register the employee with extremely low weekly salary.");
        console.log("Weekly Salary (USD, 18 decimals):", weeklySalary);

        // Register the employee
        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        console.log("Step 2: Simulate time progression of 1 day.");
        // Simulate time passage
        vm.warp(block.timestamp + 1 days);

        console.log("Step 3: Attempt to withdraw salary.");
        // Withdraw salary
        vm.prank(employee);
        hr.withdrawSalary();

        console.log("Step 4: Validate no USDC was transferred due to low salary.");
        uint256 employeeUSDCBalance = usdc.balanceOf(employee);
        console.log("Employee USDC Balance After Withdrawal (6 decimals):", employeeUSDCBalance);
        assertEq(employeeUSDCBalance, 0, "No USDC should be transferred for extremely low salary");

        console.log("Step 5: Terminate the employee.");
        vm.prank(hrManagerAddress);
        hr.terminateEmployee(employee);

        console.log("Step 6: Rehire the employee with a higher weekly salary.");
        uint256 newWeeklySalary = 1e18; // $1 per week
        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, newWeeklySalary);

        console.log("Step 7: Simulate time progression of 22 day after rehire.");
        vm.warp(block.timestamp + 22 days);

        console.log("Step 8: Withdraw salary after rehire.");
        vm.prank(employee);
        hr.withdrawSalary();

        console.log("Step 9: Validate USDC transferred includes unclaimed and newly accrued salary.");
        uint256 expectedUSDC = ((weeklySalary * 1 days) / 7 days) / 1e12 + ((newWeeklySalary * 22 days) / 7 days) / 1e12;
        employeeUSDCBalance = usdc.balanceOf(employee);
        console.log("Employee USDC Balance After Withdrawal (6 decimals):", employeeUSDCBalance);
        console.log("Expected USDC (6 decimals):", expectedUSDC);
        assertEq(employeeUSDCBalance, expectedUSDC, "USDC should include both unclaimed and new accrued salary");

        console.log("Test completed successfully.");
    }

    // Test switching currency preference to ETH
    function testSwitchCurrencyToETH() public {
        uint256 weeklySalary = 1_000 * 1e18;

        // Register the employee
        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Simulate time passage to accrue salary
        vm.warp(block.timestamp + 1 days);

        // Expect the SalaryWithdrawn and CurrencySwitched events
        vm.expectEmit(true, true, true, true);
        emit SalaryWithdrawn(employee, false, ((weeklySalary * 1 days) / 7 days) / 1e12);

        vm.expectEmit(true, true, true, true);
        emit CurrencySwitched(employee, true);

        // Switch to ETH preference
        vm.prank(employee);
        hr.switchCurrency();

        // Salary should have been withdrawn automatically
        uint256 remainingSalary = hr.salaryAvailable(employee);
        assertEq(remainingSalary, 0, "Salary should be reset upon switching currency");

        // Since the salary was withdrawn in USDC before switching, check USDC balance
        uint256 employeeUSDCBalance = usdc.balanceOf(employee);
        uint256 expectedUSDC = ((weeklySalary * 1 days) / 7 days) / 1e12;
        assertEq(employeeUSDCBalance, expectedUSDC, "Employee should receive correct amount of USDC upon switching");
    }

    // Test withdrawing salary in ETH after switching currency
    function testWithdrawSalaryInETH() public {
        uint256 weeklySalary = 1_000 * 1e18; // Weekly salary in USD with 18 decimals

        console.log("Step 1: Register the employee");
        console.log("Weekly Salary (USD, 18 decimals):", weeklySalary / 1e18, "USD");
        // Register the employee
        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        console.log("Step 2: Switch to ETH preference");
        // Switch to ETH preference
        vm.prank(employee);
        hr.switchCurrency();

        console.log("Step 3: Simulate 1 day of salary accrual");
        // Simulate time passage to accrue salary
        vm.warp(block.timestamp + 1 days);

        console.log("Step 4: Calculate expected ETH amount");
        // Calculate expected ETH amount
        uint256 amountInUSD = (weeklySalary * 1 days) / 7 days;
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price data from oracle");
        uint8 priceDecimals = priceFeed.decimals();
        uint256 ethPriceInUSD18 = uint256(price) * (10 ** (18 - priceDecimals));
        uint256 expectedEthAmount = (amountInUSD * 1e18) / ethPriceInUSD18;

        console.log("Accrued Salary (USD, 18 decimals):", amountInUSD / 1e18, "USD");
        console.log("Oracle ETH/USD Price:", uint256(price) / 1e8, "USD");
        console.log("Calculated ETH Amount (18 decimals):", expectedEthAmount / 1e18, "ETH");

        // Validate available salary before withdrawal
        uint256 availableSalary = hr.salaryAvailable(employee);
        console.log("Available Salary Before Withdrawal (ETH):", availableSalary / 1e18, "ETH");
        assertGt(availableSalary, 0, "Available salary should be greater than 0");

        console.log("Step 5: Expect the SalaryWithdrawn event in ETH");
        // Expect the SalaryWithdrawn event in ETH
        vm.expectEmit(true, true, true, false); // Ignore the amount in the event check
        emit SalaryWithdrawn(employee, true, expectedEthAmount); // Amount is approximate, so we ignore it

        console.log("Step 6: Withdraw salary");
        // Withdraw salary
        vm.prank(employee);
        hr.withdrawSalary();

        console.log("Step 7: Validate that salary has been reset");
        // Validate that salary has been reset after withdrawal
        uint256 remainingSalary = hr.salaryAvailable(employee);
        console.log("Remaining Salary After Withdrawal (USD):", remainingSalary / 1e18, "USD");
        assertEq(remainingSalary, 0, "Salary should be reset after withdrawal");

        console.log("Step 8: Validate ETH received by the employee");
        // Validate that the employee received ETH
        uint256 employeeETHBalance = employee.balance;
        console.log("Employee ETH Balance After Withdrawal:", employeeETHBalance / 1e18, "ETH");
        assertGt(employeeETHBalance, 0, "Employee should receive ETH");
    }

    // Test that non-employee cannot withdraw salary
    function testNonEmployeeCannotWithdraw() public {
        vm.prank(nonEmployee);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.withdrawSalary();
    }

    // Test that only employees can switch currency
    function testNonEmployeeCannotSwitchCurrency() public {
        vm.prank(nonEmployee);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.switchCurrency();
    }

    // Test getting the active employee count
    function testGetActiveEmployeeCount() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee2, weeklySalary);

        uint256 activeCount = hr.getActiveEmployeeCount();
        assertEq(activeCount, 2, "There should be 2 active employees");

        vm.prank(hrManagerAddress);
        hr.terminateEmployee(employee);

        activeCount = hr.getActiveEmployeeCount();
        assertEq(activeCount, 1, "There should be 1 active employee after termination");
    }

    // Test that terminated employee can withdraw remaining salary
    function testTerminatedEmployeeCanWithdrawRemainingSalary() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Move time forward by 3 days
        vm.warp(block.timestamp + 3 days);

        // Terminate employee
        vm.prank(hrManagerAddress);
        hr.terminateEmployee(employee);

        // Expect the SalaryWithdrawn event
        uint256 expectedUSDC = ((weeklySalary * 3 days) / 7 days) / 1e12;

        vm.expectEmit(true, true, true, true);
        emit SalaryWithdrawn(employee, false, expectedUSDC);

        // Simulate employee calling
        vm.prank(employee);
        hr.withdrawSalary();

        // Validate that salary has been reset after withdrawal
        uint256 remainingSalary = hr.salaryAvailable(employee);
        assertEq(remainingSalary, 0, "Salary should be reset after withdrawal");

        // Validate that the employee received USDC
        uint256 employeeUSDCBalance = usdc.balanceOf(employee);
        assertEq(employeeUSDCBalance, expectedUSDC, "Employee should receive correct amount of USDC");
    }

    // Test that employee cannot withdraw salary twice without accruing new salary
    function testCannotWithdrawSalaryTwice() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Move time forward by 1 day
        vm.warp(block.timestamp + 1 days);

        // Expect the SalaryWithdrawn event
        uint256 expectedUSDC = ((weeklySalary * 1 days) / 7 days) / 1e12;

        vm.expectEmit(true, true, true, true);
        emit SalaryWithdrawn(employee, false, expectedUSDC);

        // Simulate employee calling
        vm.prank(employee);
        hr.withdrawSalary();

        // Attempt to withdraw salary again, should have no available salary
        vm.prank(employee);
        vm.expectRevert("No salary available");
        hr.withdrawSalary();
    }

    // Test that the HR manager cannot withdraw salary
    function testHRManagerCannotWithdrawSalary() public {
        vm.prank(hrManagerAddress);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.withdrawSalary();
    }

    // Test that the HR manager cannot switch currency
    function testHRManagerCannotSwitchCurrency() public {
        vm.prank(hrManagerAddress);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.switchCurrency();
    }

    // Test that only employees can view their salary
    function testNonEmployeeSalaryAvailable() public view {
        uint256 salary = hr.salaryAvailable(nonEmployee);
        assertEq(salary, 0, "Non-employee salary should be zero");
    }

    // Test getting employee info for non-existent employee
    function testGetEmployeeInfoNonExistent() public view {
        (uint256 weeklyUsdSalary, uint256 employedSince, uint256 terminatedAt) = hr.getEmployeeInfo(nonEmployee);
        assertEq(weeklyUsdSalary, 0, "Weekly salary should be zero for non-existent employee");
        assertEq(employedSince, 0, "Employed since should be zero for non-existent employee");
        assertEq(terminatedAt, 0, "Terminated at should be zero for non-existent employee");
    }

    function testCannotSwitchCurrencyImmediately() public {
        uint256 weeklySalary = 1_000 * 1e18; // 1,000 USD with 18 decimals
        console.log("Initial Weekly Salary (USD):", weeklySalary);

        // Register the employee
        console.log("Registering employee...");
        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Simulate time progression to accrue some salary
        uint256 accrueTime = 1 days; // Simulate 1 day of salary accrual
        console.log("Simulating time progression of 1 day...");
        vm.warp(block.timestamp + accrueTime);

        // Switch to ETH preference
        console.log("Switching currency preference to ETH...");
        vm.prank(employee);
        hr.switchCurrency();

        // Attempt to switch back immediately
        console.log("Attempting to switch back to USDC immediately...");
        vm.prank(employee);

        // Only expect the CurrencySwitched event since no salary has accrued
        vm.expectEmit(true, true, true, true);
        emit CurrencySwitched(employee, false); // Expect the currency to switch back to USDC

        hr.switchCurrency();

        console.log("Test completed.");
    }

    // Test that salary accrues correctly over multiple periods
    function testSalaryAccrualOverMultiplePeriods() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Move time forward by 1 day
        vm.warp(block.timestamp + 1 days);

        vm.prank(employee);
        hr.withdrawSalary();

        uint256 employeeUSDCBalance = usdc.balanceOf(employee);
        uint256 expectedUSDC = ((weeklySalary * 1 days) / 7 days) / 1e12;
        assertEq(employeeUSDCBalance, expectedUSDC, "Employee should receive correct amount of USDC");

        // Move time forward by 2 days
        vm.warp(block.timestamp + 2 days);

        vm.prank(employee);
        hr.withdrawSalary();

        uint256 additionalUSDC = ((weeklySalary * 2 days) / 7 days) / 1e12;
        uint256 totalUSDC = usdc.balanceOf(employee);
        assertEq(totalUSDC, expectedUSDC + additionalUSDC, "Employee should receive correct cumulative USDC");
    }

    // Test that employee cannot register another employee
    function testEmployeeCannotRegisterAnotherEmployee() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        vm.prank(employee);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.registerEmployee(employee2, weeklySalary);
    }

    // Test that terminated employee cannot switch currency
    function testTerminatedEmployeeCannotSwitchCurrency() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Terminate employee
        vm.prank(hrManagerAddress);
        hr.terminateEmployee(employee);

        vm.prank(employee);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.switchCurrency();
    }

    // Test that terminated employee can still withdraw salary
    function testTerminatedEmployeeCanWithdrawSalary() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Move time forward by 3 days
        vm.warp(block.timestamp + 3 days);

        // Terminate employee
        vm.prank(hrManagerAddress);
        hr.terminateEmployee(employee);

        // Employee withdraws salary
        vm.prank(employee);
        hr.withdrawSalary();

        uint256 employeeUSDCBalance = usdc.balanceOf(employee);
        uint256 expectedUSDC = ((weeklySalary * 3 days) / 7 days) / 1e12;
        assertEq(employeeUSDCBalance, expectedUSDC, "Employee should receive correct amount of USDC");
    }

    function testSalaryAccrualFractionalDays() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Move time forward by 1.5 days
        vm.warp(block.timestamp + 1 days + 12 hours);

        uint256 expectedUSD = ((weeklySalary * (1 days + 12 hours)) / 7 days) / 1e12;
        uint256 accruedSalary = hr.salaryAvailable(employee);

        assertEq(accruedSalary, expectedUSD, "Accrued salary should match expected amount for fractional days");
    }

    function testSalaryAccrualMinimalTime() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Move time forward by 1 second
        vm.warp(block.timestamp + 1);

        uint256 expectedUSD = ((weeklySalary * 1) / 7 days) / 1e12;
        uint256 accruedSalary = hr.salaryAvailable(employee);

        assertEq(accruedSalary, expectedUSD, "Accrued salary should match expected amount for minimal time");
    }

    function testAccrualAfterWithdrawal() public {
        uint256 weeklySalary = 1_000 * 1e18;

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, weeklySalary);

        // Move time forward by 2 days
        vm.warp(block.timestamp + 2 days);

        vm.prank(employee);
        hr.withdrawSalary();

        // Move time forward by another 3 days
        vm.warp(block.timestamp + 3 days);

        uint256 expectedUSD = ((weeklySalary * 3 days) / 7 days) / 1e12;
        uint256 accruedSalary = hr.salaryAvailable(employee);

        assertEq(accruedSalary, expectedUSD, "Salary should accrue correctly after withdrawal");
    }

    function testNoOverflowOrNegativeAccrual() public {
        uint256 largeSalary = type(uint256).max / 7 days; // Large weekly salary to test overflow

        vm.prank(hrManagerAddress);
        hr.registerEmployee(employee, largeSalary);

        // Simulate large time progression
        vm.warp(block.timestamp + 7 days);

        uint256 accruedSalary = hr.salaryAvailable(employee);

        assertTrue(accruedSalary > 0, "Accrued salary should be positive");
        assertTrue(accruedSalary <= largeSalary, "Accrued salary should not overflow");
    }

    // function testAccrualResetAfterRehire() public {
    //     uint256 weeklySalary = 1_000 * 1e18;

    //     vm.prank(hrManagerAddress);
    //     hr.registerEmployee(employee, weeklySalary);

    //     // Move time forward by 2 days
    //     vm.warp(block.timestamp + 2 days);

    //     vm.prank(hrManagerAddress);
    //     hr.terminateEmployee(employee);

    //     // Rehire employee after 3 days
    //     vm.warp(block.timestamp + 3 days);
    //     vm.prank(hrManagerAddress);
    //     hr.registerEmployee(employee, weeklySalary);

    //     // Move time forward by 1 day
    //     vm.warp(block.timestamp + 1 days);

    //     uint256 expectedUSD = ((weeklySalary * 1 days) / 7 days) / 1e12;
    //     uint256 accruedSalary = hr.salaryAvailable(employee);

    //     assertEq(accruedSalary, expectedUSD, "Accrued salary should reset and match expected after rehire");
    // }
}
