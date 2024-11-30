# COMP70017 Principles of Distributed Ledgers

---

**by Chujia Song (cs824)**

This is the coursework project for COMP70017: Principles of Distributed Ledgers.

For your convenience in testing, you can refer to the results of the [GitHub Actions](https://github.com/Polumm/COMP70017-Principles-of-Distributed-Ledgers/actions) automated tests, which include `HumanResourcesTests.t.sol` provided by the professors and the self-implemented `HumanResources.t.sol` (keep the repository private until after the coursework deadline). I have configured the environment variables (e.g., `.env`, GitHub Actions secrets, and variables) and included all existing test units, which should produce results consistent with those you run locally.

## 1 Installation and Testing Guide

### 1.1 **System Requirements**

Ensure your system meets the following prerequisites:
- **Node.js and npm**: Required for managing project dependencies.
- **Forge**: A smart contract development tool.

### 1.2 **Steps to Install and Test**

1. **Clone the Repository and Navigate to the Project Directory**  
   Run the following commands in your terminal:
   ```bash
   git clone git@github.com:Polumm/COMP70017-Principles-of-Distributed-Ledgers.git
   cd COMP70017-Principles-of-Distributed-Ledgers
   ```

2. **Install Dependencies**  
   Install the required dependencies using `npm`:
   ```bash
   npm install
   ```

3. **Build the Project**  
   Build the project using `forge` to compile the Solidity smart contracts:
   ```bash
   forge build
   ```

4. **Run Tests**  
   Execute the test suite to verify the functionality of the project:
   ```bash
   forge test
   ```

---

## 2 **Implementation of `IHumanResources`**

### 2.1 **HR Manager Functions**
Both functions are restricted to authorized HR Manager addresses through the `onlyHRManager` modifier, ensuring proper control and security.
1. **`registerEmployee(address employee, uint256 weeklyUsdSalary)`**  
   - Registers a new employee with a specified weekly salary.  
   - **Process**: Validates the employee is not already registered, initializes their record, and emits the `EmployeeRegistered` event.  
   - **Access**: Restricted to the HR Manager.
   - **Implementation Highlights:**
		- **Employee State Check:** Ensures the employee is not already actively registered. If the employee exists but was terminated, the `unclaimedSalary` is preserved.
		- **Default Currency Preference:** If an employee was previously registered with a preference for ETH, this preference is retained. Otherwise, the currency defaults to USDC.
		- **Data Initialization:** Updates or initializes the `Employee` struct with the provided weekly salary, current timestamp (`block.timestamp`) as `employedSince`, and sets `isActive` to `true`.
		- **Event Emission:** Emits the `EmployeeRegistered` event to track the action.
2. **`terminateEmployee(address employee)`**  
   - Marks an employee as inactive, stops salary accrual, and calculates unclaimed salary.  
   - **Process**: Updates the employee's status and emits the `EmployeeTerminated` event.  
   - **Access**: Restricted to the HR Manager.
   - **Implementation Highlights:**
	    - **Employee State Check:** Ensures the employee is actively registered before proceeding with termination.
	    - **Salary Preservation:** Calculates the unclaimed salary using the `salaryAvailableInUSD(employee)` function and updates the `unclaimedSalary` field.
	    - **Prevent Accrual:** Stops further salary accumulation by setting both `employedSince` and `terminatedAt` to the current timestamp (`block.timestamp`).
	    - **Currency Preference:** The employee's `isEth` is reset to USDC (the default) when an employee is re-registered.
	    - **Event Emission:** Emits the `EmployeeTerminated` event to record the termination.

### 2.2 **Employee Functions**
1. **`withdrawSalary()`**  
   - Allows employees to withdraw their accumulated salary in their preferred currency (USDC or ETH).  
   - **Process**:  
     - Calculates available salary.  
     - If ETH is preferred, converts USDC to ETH using Uniswap before transferring.  
     - Resets salary accruals after successful withdrawal.
   - **Implementation Highlights:**
		1. **Salary Calculation and Validation:**  
		    The available salary is calculated using `salaryAvailableInUSD(msg.sender)`. A `require` statement ensures that the amount is greater than zero.
		 2. **Currency Preference Handling:**
		    - **ETH:** If the employee prefers ETH, the contract swaps the available USDC-equivalent amount to ETH using `swapUSDCForETH`.
		    - **USDC:** If the employee prefers USDC, the amount is converted to USDC (adjusted to 6 decimals) and transferred directly.
		3. **Precision Handling and Fairness:**  
		    If the calculated ETH or USDC amount is too small to transfer (e.g., due to low weekly salaries or short employment periods), the `NoSalaryTransferred` event is emitted, and `unclaimedSalary` is not reset. This ensures fair salary accumulation for future withdrawals.
		4.  **State Update and Reentrancy Protection:**
		    - The internal state (`emp.unclaimedSalary` and `emp.employedSince`) is updated before any external call (e.g., ETH or USDC transfer) to mitigate reentrancy risks.
		    - The `nonReentrant` modifier ensures further protection against reentrancy attacks.
2. **`switchCurrency()`**  
   - Lets employees toggle their preferred salary currency between USDC and ETH.  
   - **Process**:  
	 - Automatically withdraws any accrued salary before switching.  
	 - Emits the `CurrencySwitched` event.
   - **Implementation Highlights:**  
		1. **Authorization Check:**  
		    The `onlyActiveEmployee` modifier ensures that only currently employed and active employees can switch their currency preference, preventing terminated employees from making changes.
		2. **Automatic Salary Withdrawal:**  
		    Before toggling the currency, any accrued salary is automatically withdrawn to ensure a clean transition and avoid inconsistencies.
		3. **Currency Toggle:**  
		    The employee's currency preference (`isEth`) is toggled, and the `CurrencySwitched` event is emitted to reflect the change.
		4. **Event Emission:**  
		    The `SalaryWithdrawn` event is emitted during the automatic withdrawal, followed by the `CurrencySwitched` event.

### 2.3 **View Functions**
1. **`salaryAvailable(address employee)`**  
   - Returns the salary available for withdrawal in the employee's preferred currency.  
   - **Process**: Uses Chainlink oracle to convert USD-based salary to ETH if necessary.
   - **Implementation Highlights:**  
		- **Employee Existence Check:**  
		    If the employee is not registered (`employedSince == 0`), the function returns `0`, ensuring graceful handling of non-existent employees without reverting.
		- **Currency Conversion Logic:**
		    - **USDC:**  
		        Converts the salary from USD (18 decimals) to USDC (6 decimals) by dividing the amount by `1e12`. This ensures the returned amount aligns with USDC's standard precision.
		    - **ETH:**  
		        Converts the salary from USD to ETH using the latest price from Chainlink’s `AggregatorV3Interface`.
		        - The price feed’s decimals are retrieved using `priceFeed.decimals()` to adjust the ETH/USD conversion to 18 decimals.
		        - The resulting ETH amount is scaled to 18 decimals, ensuring consistent precision.
		- **Error Handling for Invalid Price Data:**  
		    Validates that the price feed returns a positive price before proceeding with calculations to prevent invalid or corrupted data from causing errors.
2. **`hrManager()`**  
   - Returns the HR Manager's address.
3. **`getActiveEmployeeCount()`**  
   - Returns the total number of active employees.
4. **`getEmployeeInfo(address employee)`**  
   - Provides an employee's details, including salary, start date, and termination date (if applicable). If the employee does not exist (`employedSince == 0`), the function returns `(0, 0, 0)`. This avoids unnecessary reverts and ensures consistent output for invalid queries.

### 2.4 **Integration of AMM and Oracle**

1. **AMM (Uniswap)**  
   - Used to swap USDC for ETH when employees choose ETH as their payout currency.  
   - **Key Steps**:  
     - Uses Uniswap V3's `ISwapRouter` to perform swaps.  
     - Sets a minimum output to prevent slippage (2% tolerance).  
     - Converts WETH to ETH before transferring to employees.  
   - **Implementation Highlights:**  
		- **Slippage Protection:**
		    - Calculates the `expectedEthAmount` based on the live ETH/USD price.
		    - Sets the `amountOutMinimum` to 98% of the expected amount, reverting the transaction if the swap output falls below this threshold.
		- **Front-Running Mitigation:**
		    - Includes a `deadline` parameter, set to 10 minutes from the current timestamp, ensuring the swap must be executed promptly.
		- **Swap Execution:**
		    - Executes the swap using Uniswap V3’s `ISwapRouter.exactInputSingle` with specified parameters, including the input token (USDC), output token (WETH), and slippage-protected `amountOutMinimum`.
		    - Converts the resulting WETH to ETH for employee payouts using `withdraw()`.
2. **Oracle (Chainlink)**  
   - Provides the live ETH/USD price for salary conversions.  
   - **Key Features**:  
     - Ensures accuracy by verifying the price is non-zero.  
     - Scales the ETH/USD price to 18 decimals for precise calculations.
   - **Implementation Highlights:**  
      - **ETH Price Retrieval and Scaling:**
		- Retrieves the latest ETH/USD price from Chainlink’s `AggregatorV3Interface`.
		- Scales the ETH price to 18 decimals using the price feed’s `priceFeed.decimals()` for precise calculations.