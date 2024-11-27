# COMP70017 Principles of Distributed Ledgers

---

## Installation and Testing Guide

### **System Requirements**

Ensure your system meets the following prerequisites:
- **Node.js and npm**: Required for managing project dependencies.
- **Forge**: A smart contract development tool.

### **Steps to Install and Test**

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

## **Implementation of `IHumanResources`**

#### **HR Manager Functions**
1. **`registerEmployee(address employee, uint256 weeklyUsdSalary)`**  
   - Registers a new employee with a specified weekly salary.  
   - **Process**: Validates the employee is not already registered, initializes their record, and emits the `EmployeeRegistered` event.  
   - **Access**: Restricted to the HR Manager.

2. **`terminateEmployee(address employee)`**  
   - Marks an employee as inactive, stops salary accrual, and calculates unclaimed salary.  
   - **Process**: Updates the employee's status and emits the `EmployeeTerminated` event.  
   - **Access**: Restricted to the HR Manager.

#### **Employee Functions**
1. **`withdrawSalary()`**  
   - Allows employees to withdraw their accumulated salary in their preferred currency (USDC or ETH).  
   - **Process**:  
     - Calculates available salary.  
     - If ETH is preferred, converts USDC to ETH using Uniswap before transferring.  
     - Resets salary accruals after successful withdrawal.  

2. **`switchCurrency()`**  
   - Lets employees toggle their preferred salary currency between USDC and ETH.  
   - **Process**:  
     - Automatically withdraws any accrued salary before switching.  
     - Emits the `CurrencySwitched` event.

#### **View Functions**
1. **`salaryAvailable(address employee)`**  
   - Returns the salary available for withdrawal in the employee's preferred currency.  
   - **Process**: Uses Chainlink oracle to convert USD-based salary to ETH if necessary.

2. **`hrManager()`**  
   - Returns the HR Manager's address.

3. **`getActiveEmployeeCount()`**  
   - Returns the total number of active employees.

4. **`getEmployeeInfo(address employee)`**  
   - Provides an employee's details, including salary, start date, and termination date (if applicable).

### **Integration of AMM and Oracle**

1. **AMM (Uniswap)**  
   - Used to swap USDC for ETH when employees choose ETH as their payout currency.  
   - **Key Steps**:  
     - Uses Uniswap V3's `ISwapRouter` to perform swaps.  
     - Sets a minimum output to prevent slippage (2% tolerance).  
     - Converts WETH to ETH before transferring to employees.  

2. **Oracle (Chainlink)**  
   - Provides the live ETH/USD price for salary conversions.  
   - **Key Features**:  
     - Ensures accuracy by verifying the price is non-zero.  
     - Scales the ETH/USD price to 18 decimals for precise calculations.

