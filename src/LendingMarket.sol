// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/**
 * @title LendingMarket
 * @notice Single-collateral money market. Suppliers deposit the base asset and earn interest;
 *         borrowers post collateral and draw the base asset against it. Balances are tracked as
 *         principal and scaled by a pair of global indices that advance with accrued interest.
 *
 * @dev This contract is deployed behind a TransparentUpgradeableProxy. Live markets hold real
 *      user balances in the storage layout below.
 *
 *      Scaling: all values are 1e18-fixed-point unless stated otherwise. Collateral prices are
 *      quoted by the oracle in base-asset terms, also 1e18.
 */
contract LendingMarket {
    // -------------------------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------------------------

    uint256 internal constant FACTOR = 1e18;

    /// @dev Oldest oracle answer the market will price against. A one hour heartbeat plus slack
    ///      for a round that lands late.
    uint256 internal constant MAX_PRICE_AGE = 1 hours + 15 minutes;

    /// @dev Highest borrow rate governance can set, 100% APR expressed per second.
    uint256 internal constant MAX_BORROW_RATE = 1e18 / uint256(365 days);

    /// @dev Highest liquidation incentive governance can set, a 50% bonus.
    uint256 internal constant MAX_LIQUIDATION_INCENTIVE = 1.5e18;

    // -------------------------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------------------------

    // --- roles and wiring ---
    address public admin;
    address public pauseGuardian;
    IPriceOracle public oracle;
    IERC20 public baseToken;
    IERC20 public collateralToken;

    // --- accrual state ---
    uint256 public baseBorrowIndex;
    uint256 public baseSupplyIndex;
    uint256 public lastAccrualTime;

    // --- market totals (principal terms) ---
    uint256 public totalSupplyPrincipal;
    uint256 public totalBorrowPrincipal;
    uint256 public totalCollateral;

    // --- risk parameters ---
    uint256 public collateralFactor;
    uint256 public liquidationIncentive;
    uint256 public borrowRatePerSecond;

    // --- per-account state ---
    mapping(address => uint256) public supplyPrincipal;
    mapping(address => uint256) public borrowPrincipal;
    mapping(address => uint256) public collateralBalance;

    // --- circuit breaker ---
    bool public paused;

    bool private _initialized;

    // -------------------------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------------------------

    event Supply(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);
    event SupplyCollateral(address indexed account, uint256 amount);
    event WithdrawCollateral(address indexed account, uint256 amount);
    event Borrow(address indexed account, uint256 amount);
    event Repay(address indexed account, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed borrower, uint256 repaid, uint256 seized);
    event OracleUpdated(address indexed newOracle);
    event ParametersUpdated(uint256 collateralFactor, uint256 liquidationIncentive, uint256 borrowRate);
    event PausedSet(bool paused);

    // -------------------------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------------------------

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == pauseGuardian || msg.sender == admin, "not guardian");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    // -------------------------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------------------------

    /// @dev Locks the implementation itself. Runs in the implementation's storage only, so the
    ///      proxy still initializes through initialize().
    constructor() {
        _initialized = true;
    }

    function initialize(
        address admin_,
        address pauseGuardian_,
        address oracle_,
        address baseToken_,
        address collateralToken_,
        uint256 collateralFactor_,
        uint256 liquidationIncentive_,
        uint256 borrowRatePerSecond_
    ) external {
        require(!_initialized, "already initialized");
        _initialized = true;

        require(IPriceOracle(oracle_).decimals() == 18, "oracle decimals");
        _checkParameters(collateralFactor_, liquidationIncentive_, borrowRatePerSecond_);

        admin = admin_;
        pauseGuardian = pauseGuardian_;
        oracle = IPriceOracle(oracle_);
        baseToken = IERC20(baseToken_);
        collateralToken = IERC20(collateralToken_);

        collateralFactor = collateralFactor_;
        liquidationIncentive = liquidationIncentive_;
        borrowRatePerSecond = borrowRatePerSecond_;

        baseBorrowIndex = FACTOR;
        baseSupplyIndex = FACTOR;
        lastAccrualTime = block.timestamp;
    }

    // -------------------------------------------------------------------------------------------
    // Interest accrual
    // -------------------------------------------------------------------------------------------

    /// @notice Advances both indices to the current block timestamp.
    function accrueInterest() public {
        uint256 elapsed = block.timestamp - lastAccrualTime;
        if (elapsed == 0) return;

        uint256 interest = borrowRatePerSecond * elapsed;

        uint256 borrowsBefore = presentValueBorrow(totalBorrowPrincipal);
        uint256 suppliesBefore = presentValueSupply(totalSupplyPrincipal);

        baseBorrowIndex += (baseBorrowIndex * interest) / FACTOR;

        if (suppliesBefore > 0) {
            uint256 accruedToSuppliers = (borrowsBefore * interest) / FACTOR;
            baseSupplyIndex += (baseSupplyIndex * accruedToSuppliers) / suppliesBefore;
        }

        lastAccrualTime = block.timestamp;
    }

    // -------------------------------------------------------------------------------------------
    // Supplier actions
    // -------------------------------------------------------------------------------------------

    function supply(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        baseToken.transferFrom(msg.sender, address(this), amount);

        uint256 principal = _principalForSupply(amount);
        supplyPrincipal[msg.sender] += principal;
        totalSupplyPrincipal += principal;

        emit Supply(msg.sender, amount);
    }

    function withdraw(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        uint256 principal = _principalForSupply(amount);
        require(supplyPrincipal[msg.sender] >= principal, "insufficient balance");

        supplyPrincipal[msg.sender] -= principal;
        totalSupplyPrincipal -= principal;

        baseToken.transfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------------
    // Borrower actions
    // -------------------------------------------------------------------------------------------

    function supplyCollateral(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");

        collateralToken.transferFrom(msg.sender, address(this), amount);

        collateralBalance[msg.sender] += amount;
        totalCollateral += amount;

        emit SupplyCollateral(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        require(collateralBalance[msg.sender] >= amount, "insufficient collateral");

        collateralBalance[msg.sender] -= amount;
        totalCollateral -= amount;

        require(isHealthy(msg.sender), "would be undercollateralized");

        collateralToken.transfer(msg.sender, amount);

        emit WithdrawCollateral(msg.sender, amount);
    }

    function borrow(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        accrueInterest();

        uint256 principal = _principalForBorrow(amount);
        borrowPrincipal[msg.sender] += principal;
        totalBorrowPrincipal += principal;

        require(isHealthy(msg.sender), "would be undercollateralized");

        baseToken.transfer(msg.sender, amount);

        emit Borrow(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        require(amount > 0, "zero amount");
        accrueInterest();

        uint256 owed = borrowBalanceOf(msg.sender);
        if (amount > owed) amount = owed;

        uint256 principal = _principalForBorrow(amount);

        baseToken.transferFrom(msg.sender, address(this), amount);

        borrowPrincipal[msg.sender] -= principal;
        totalBorrowPrincipal -= principal;

        emit Repay(msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------------
    // Liquidation
    // -------------------------------------------------------------------------------------------

    /**
     * @notice Repays part of an unhealthy borrower's debt in exchange for their collateral,
     *         plus the liquidation incentive.
     * @param borrower the account being liquidated
     * @param repayAmount how much of the borrower's debt the liquidator is repaying
     */
    function liquidate(address borrower, uint256 repayAmount) external whenNotPaused {
        require(repayAmount > 0, "zero amount");
        accrueInterest();

        require(!isHealthy(borrower), "borrower is healthy");

        uint256 owed = borrowBalanceOf(borrower);
        if (repayAmount > owed) repayAmount = owed;

        // repayAmount is in base units. Convert it to collateral units at the oracle price.
        uint256 price = getPrice();
        uint256 seizeAmount = (repayAmount * liquidationIncentive) / price;
        if (seizeAmount > collateralBalance[borrower]) {
            // Not enough collateral to pay the full incentive. Seize what is there and only
            // take the repayment it covers, rounded up so the liquidator never underpays.
            seizeAmount = collateralBalance[borrower];
            repayAmount = (seizeAmount * price + liquidationIncentive - 1) / liquidationIncentive;
        }

        uint256 principal = _principalForBorrow(repayAmount);
        borrowPrincipal[borrower] -= principal;
        totalBorrowPrincipal -= principal;

        collateralBalance[borrower] -= seizeAmount;
        totalCollateral -= seizeAmount;

        baseToken.transferFrom(msg.sender, address(this), repayAmount);
        collateralToken.transfer(msg.sender, seizeAmount);

        emit Liquidate(msg.sender, borrower, repayAmount, seizeAmount);
    }

    // -------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------

    function borrowBalanceOf(address account) public view returns (uint256) {
        return presentValueBorrow(borrowPrincipal[account]);
    }

    function supplyBalanceOf(address account) public view returns (uint256) {
        return presentValueSupply(supplyPrincipal[account]);
    }

    function presentValueBorrow(uint256 principal) public view returns (uint256) {
        return (principal * baseBorrowIndex) / FACTOR;
    }

    function presentValueSupply(uint256 principal) public view returns (uint256) {
        return (principal * baseSupplyIndex) / FACTOR;
    }

    /// @notice Fraction of supplied base currently borrowed, 1e18 scaled.
    /// @dev Multiplication is applied before the division so the 1e18 scale survives; the
    ///      intermediate cannot realistically overflow at supported market sizes.
    function utilization() public view returns (uint256) {
        uint256 supplied = presentValueSupply(totalSupplyPrincipal);
        if (supplied == 0) return 0;
        return (presentValueBorrow(totalBorrowPrincipal) * FACTOR) / supplied;
    }

    /// @notice True when the account's borrowing power covers its debt.
    function isHealthy(address account) public view returns (bool) {
        uint256 debt = borrowBalanceOf(account);
        if (debt == 0) return true;

        uint256 collateralValue = (collateralBalance[account] * getPrice()) / FACTOR;
        uint256 borrowingPower = (collateralValue * collateralFactor) / FACTOR;

        return borrowingPower >= debt;
    }

    /// @notice Collateral price in base-asset terms, 1e18 scaled.
    function getPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        require(answer > 0, "bad price");
        require(block.timestamp - updatedAt <= MAX_PRICE_AGE, "stale price");
        return uint256(answer);
    }

    // -------------------------------------------------------------------------------------------
    // Internal accounting helpers
    // -------------------------------------------------------------------------------------------

    function _principalForBorrow(uint256 amount) internal view returns (uint256) {
        return (amount * FACTOR) / baseBorrowIndex;
    }

    function _principalForSupply(uint256 amount) internal view returns (uint256) {
        return (amount * FACTOR) / baseSupplyIndex;
    }

    function _checkParameters(
        uint256 collateralFactor_,
        uint256 liquidationIncentive_,
        uint256 borrowRatePerSecond_
    ) internal pure {
        require(collateralFactor_ <= FACTOR, "cf too high");
        require(liquidationIncentive_ >= FACTOR, "incentive below par");
        require(liquidationIncentive_ <= MAX_LIQUIDATION_INCENTIVE, "incentive too high");
        // At or above 1, each liquidation cuts borrowing power by at least as much as it cuts debt.
        require(collateralFactor_ * liquidationIncentive_ < FACTOR * FACTOR, "cf * incentive too high");
        require(borrowRatePerSecond_ <= MAX_BORROW_RATE, "rate too high");
    }

    // -------------------------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------------------------

    function setOracle(address newOracle) external onlyAdmin {
        require(newOracle != address(0), "zero oracle");
        require(IPriceOracle(newOracle).decimals() == 18, "oracle decimals");
        oracle = IPriceOracle(newOracle);
        emit OracleUpdated(newOracle);
    }

    function setParameters(uint256 collateralFactor_, uint256 liquidationIncentive_, uint256 borrowRatePerSecond_)
        external
        onlyAdmin
    {
        _checkParameters(collateralFactor_, liquidationIncentive_, borrowRatePerSecond_);

        accrueInterest();

        collateralFactor = collateralFactor_;
        liquidationIncentive = liquidationIncentive_;
        borrowRatePerSecond = borrowRatePerSecond_;

        emit ParametersUpdated(collateralFactor_, liquidationIncentive_, borrowRatePerSecond_);
    }

    function setPaused(bool paused_) external onlyGuardian {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        admin = newAdmin;
    }
}
