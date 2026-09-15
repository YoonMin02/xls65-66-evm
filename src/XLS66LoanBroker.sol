// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {XLS65Vault} from "./XLS65Vault.sol";

/// @notice Harness-free EVM baseline for the economic state transitions in XLS-66.
/// @dev Rates use XLS-66's 1/10 basis-point units: 100_000 = 100%.
contract XLS66LoanBroker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant RATE_DENOMINATOR = 100_000;
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    enum LoanStatus {
        None,
        Active,
        Impaired,
        Repaid,
        Defaulted
    }

    struct LoanTerms {
        address borrower;
        uint256 principal;
        uint256 originationFee;
        uint256 serviceFee;
        uint256 latePaymentFee;
        uint256 closePaymentFee;
        uint32 interestRate;
        uint32 lateInterestRate;
        uint32 closeInterestRate;
        uint32 paymentTotal;
        uint32 paymentInterval;
        uint32 gracePeriod;
    }

    struct Loan {
        address borrower;
        LoanStatus status;
        uint32 paymentRemaining;
        uint32 paymentInterval;
        uint32 gracePeriod;
        uint32 interestRate;
        uint32 lateInterestRate;
        uint32 closeInterestRate;
        uint64 startDate;
        uint64 previousPaymentDueDate;
        uint64 nextPaymentDueDate;
        uint256 principalOutstanding;
        uint256 totalValueOutstanding;
        uint256 managementFeeOutstanding;
        uint256 periodicPayment;
        uint256 serviceFee;
        uint256 latePaymentFee;
        uint256 closePaymentFee;
        uint256 impairmentAmount;
    }

    error Unauthorized();
    error InvalidTerms();
    error InvalidState();
    error LoanNotApproved();
    error DebtLimitExceeded();
    error CoverInsufficient();
    error TooSoon();
    error PaymentLate();
    error InsufficientPayment();

    XLS65Vault public immutable vault;
    IERC20 public immutable asset;
    address public immutable owner;
    uint32 public immutable managementFeeRate;
    uint32 public immutable coverRateMinimum;
    uint32 public immutable coverRateLiquidation;

    bytes public data;
    uint256 public debtTotal;
    uint256 public debtMaximum;
    uint256 public coverAvailable;
    uint256 public loanSequence = 1;
    uint256 public activeLoanCount;

    mapping(uint256 => Loan) public loans;
    mapping(bytes32 => bool) public borrowerApprovals;

    event LoanTermsApproved(address indexed borrower, bytes32 indexed termsHash);
    event LoanSet(uint256 indexed loanId, address indexed borrower, uint256 principal, uint256 debtAdded);
    event LoanPaid(uint256 indexed loanId, uint256 principal, uint256 netInterest, uint256 fees, bool fullPayment);
    event LoanManaged(uint256 indexed loanId, LoanStatus status, uint256 amount, uint256 covered);
    event CoverDeposited(uint256 amount, uint256 coverAvailable);
    event CoverWithdrawn(address indexed destination, uint256 amount, uint256 coverAvailable);
    event BrokerSet(uint256 debtMaximum, bytes data);

    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(
        XLS65Vault vault_,
        uint32 managementFeeRate_,
        uint256 debtMaximum_,
        uint32 coverRateMinimum_,
        uint32 coverRateLiquidation_
    ) {
        if (
            address(vault_) == address(0) || managementFeeRate_ > 10_000 || coverRateMinimum_ > RATE_DENOMINATOR
                || coverRateLiquidation_ > RATE_DENOMINATOR
        ) revert InvalidTerms();
        vault = vault_;
        asset = vault_.asset();
        owner = msg.sender;
        managementFeeRate = managementFeeRate_;
        debtMaximum = debtMaximum_;
        coverRateMinimum = coverRateMinimum_;
        coverRateLiquidation = coverRateLiquidation_;
    }

    function setBroker(uint256 newDebtMaximum, bytes calldata newData) public virtual onlyOwner {
        if (newData.length > 256 || (newDebtMaximum != 0 && newDebtMaximum < debtTotal)) revert InvalidTerms();
        debtMaximum = newDebtMaximum;
        data = newData;
        emit BrokerSet(newDebtMaximum, newData);
    }

    function minimumCover() public view virtual returns (uint256) {
        return _requiredCover(debtTotal);
    }

    function effectiveCoverRateMinimum() public view virtual returns (uint256) {
        return coverRateMinimum;
    }

    function coverDeposit(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert InvalidTerms();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        coverAvailable += amount;
        emit CoverDeposited(amount, coverAvailable);
    }

    function coverWithdraw(uint256 amount, address destination) public virtual onlyOwner nonReentrant {
        if (amount == 0 || destination == address(0)) revert InvalidTerms();
        if (amount > coverAvailable || coverAvailable - amount < minimumCover()) revert CoverInsufficient();
        coverAvailable -= amount;
        asset.safeTransfer(destination, amount);
        emit CoverWithdrawn(destination, amount, coverAvailable);
    }

    /// @notice Borrower-side consent replacing XRPL's embedded counterparty signature.
    function approveLoanTerms(LoanTerms calldata terms) external returns (bytes32 termsHash) {
        if (msg.sender != terms.borrower) revert Unauthorized();
        termsHash = hashLoanTerms(terms);
        borrowerApprovals[termsHash] = true;
        emit LoanTermsApproved(msg.sender, termsHash);
    }

    function hashLoanTerms(LoanTerms calldata terms) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, terms));
    }

    /// @notice XLS-66 LoanSet analogue. Virtual so a later harness can add policy checks.
    function loanSet(LoanTerms calldata terms) public virtual onlyOwner nonReentrant returns (uint256 loanId) {
        _validateTerms(terms);
        bytes32 termsHash = hashLoanTerms(terms);
        if (!borrowerApprovals[termsHash]) revert LoanNotApproved();
        delete borrowerApprovals[termsHash];

        uint256 periodicRate =
            uint256(terms.interestRate) * WAD * terms.paymentInterval / RATE_DENOMINATOR / SECONDS_PER_YEAR;
        uint256 periodicPayment = _amortizedPayment(terms.principal, periodicRate, terms.paymentTotal);
        uint256 grossTotal = periodicPayment * terms.paymentTotal;
        if (grossTotal < terms.principal) revert InvalidTerms();
        uint256 grossInterest = grossTotal - terms.principal;
        uint256 managementFee = grossInterest * managementFeeRate / RATE_DENOMINATOR;
        uint256 netDebt = grossTotal - managementFee;

        if (debtMaximum != 0 && debtTotal + netDebt > debtMaximum) revert DebtLimitExceeded();
        uint256 resultingDebt = debtTotal + netDebt;
        if (coverAvailable < _requiredCover(resultingDebt)) revert CoverInsufficient();

        loanId = loanSequence++;
        Loan storage loan = loans[loanId];
        loan.borrower = terms.borrower;
        loan.status = LoanStatus.Active;
        loan.paymentRemaining = terms.paymentTotal;
        loan.paymentInterval = terms.paymentInterval;
        loan.gracePeriod = terms.gracePeriod;
        loan.interestRate = terms.interestRate;
        loan.lateInterestRate = terms.lateInterestRate;
        loan.closeInterestRate = terms.closeInterestRate;
        loan.startDate = uint64(block.timestamp);
        loan.nextPaymentDueDate = uint64(block.timestamp + terms.paymentInterval);
        loan.principalOutstanding = terms.principal;
        loan.totalValueOutstanding = grossTotal;
        loan.managementFeeOutstanding = managementFee;
        loan.periodicPayment = periodicPayment;
        loan.serviceFee = terms.serviceFee;
        loan.latePaymentFee = terms.latePaymentFee;
        loan.closePaymentFee = terms.closePaymentFee;

        debtTotal = resultingDebt;
        activeLoanCount++;
        vault.protocolLoan(terms.principal, netDebt - terms.principal, terms.borrower, owner, terms.originationFee);
        emit LoanSet(loanId, terms.borrower, terms.principal, netDebt);
    }

    function pay(uint256 loanId, uint256 maxAmount, bool fullPayment) public virtual nonReentrant {
        Loan storage loan = loans[loanId];
        if (msg.sender != loan.borrower) revert Unauthorized();
        if (loan.status != LoanStatus.Active && loan.status != LoanStatus.Impaired) revert InvalidState();

        bool late = block.timestamp > loan.nextPaymentDueDate;
        if (late && !fullPayment) revert PaymentLate();

        if (loan.status == LoanStatus.Impaired) {
            vault.setLoanImpairment(loan.impairmentAmount, 0);
            loan.impairmentAmount = 0;
            loan.status = LoanStatus.Active;
        }

        uint256 principalPaid;
        uint256 grossInterest;
        uint256 scheduledManagementFee;
        uint256 fees;

        if (fullPayment) {
            uint256 elapsed = block.timestamp - _max(loan.previousPaymentDueDate, loan.startDate);
            grossInterest =
                loan.principalOutstanding * loan.interestRate * elapsed / RATE_DENOMINATOR / SECONDS_PER_YEAR;
            uint256 closeInterest = loan.principalOutstanding * loan.closeInterestRate / RATE_DENOMINATOR;
            grossInterest += closeInterest;
            scheduledManagementFee = grossInterest * managementFeeRate / RATE_DENOMINATOR;
            principalPaid = loan.principalOutstanding;
            fees = scheduledManagementFee + loan.closePaymentFee;
        } else {
            grossInterest = loan.principalOutstanding * loan.interestRate * loan.paymentInterval / RATE_DENOMINATOR
                / SECONDS_PER_YEAR;
            if (grossInterest > loan.periodicPayment) revert InvalidState();
            principalPaid =
                loan.paymentRemaining == 1 ? loan.principalOutstanding : loan.periodicPayment - grossInterest;
            if (principalPaid > loan.principalOutstanding) principalPaid = loan.principalOutstanding;
            scheduledManagementFee = grossInterest * managementFeeRate / RATE_DENOMINATOR;
            fees = scheduledManagementFee + loan.serviceFee;
        }

        uint256 netInterest = grossInterest - scheduledManagementFee;
        uint256 due = principalPaid + netInterest + fees;
        if (maxAmount < due) revert InsufficientPayment();

        uint256 oldNetOutstanding = loan.totalValueOutstanding - loan.managementFeeOutstanding;
        uint256 totalToVault = principalPaid + netInterest;
        uint256 valueIncrease;
        uint256 valueDecrease;
        if (fullPayment) {
            if (totalToVault >= oldNetOutstanding) valueIncrease = totalToVault - oldNetOutstanding;
            else valueDecrease = oldNetOutstanding - totalToVault;
        }
        vault.protocolRepayFrom(msg.sender, totalToVault, valueIncrease, valueDecrease);
        _routeFees(msg.sender, fees);

        uint256 debtReduction;
        if (fullPayment) {
            debtReduction = oldNetOutstanding;
            loan.principalOutstanding = 0;
            loan.totalValueOutstanding = 0;
            loan.managementFeeOutstanding = 0;
            loan.paymentRemaining = 0;
            loan.nextPaymentDueDate = 0;
            loan.status = LoanStatus.Repaid;
            activeLoanCount--;
        } else {
            uint256 grossScheduled = principalPaid + grossInterest;
            debtReduction = principalPaid + netInterest;
            loan.principalOutstanding -= principalPaid;
            loan.totalValueOutstanding =
                loan.totalValueOutstanding > grossScheduled ? loan.totalValueOutstanding - grossScheduled : 0;
            loan.managementFeeOutstanding = loan.managementFeeOutstanding > scheduledManagementFee
                ? loan.managementFeeOutstanding - scheduledManagementFee
                : 0;
            loan.paymentRemaining--;
            loan.previousPaymentDueDate = loan.nextPaymentDueDate;
            if (loan.paymentRemaining == 0 || loan.principalOutstanding == 0) {
                // Clear any final integer rounding dust from the recognized debt.
                debtReduction = oldNetOutstanding;
                loan.totalValueOutstanding = 0;
                loan.managementFeeOutstanding = 0;
                loan.principalOutstanding = 0;
                loan.nextPaymentDueDate = 0;
                loan.status = LoanStatus.Repaid;
                activeLoanCount--;
            } else {
                loan.nextPaymentDueDate += loan.paymentInterval;
            }
        }
        debtTotal = debtReduction >= debtTotal ? 0 : debtTotal - debtReduction;
        emit LoanPaid(loanId, principalPaid, netInterest, fees, fullPayment);
    }

    function impair(uint256 loanId) external onlyOwner {
        Loan storage loan = loans[loanId];
        if (loan.status != LoanStatus.Active) revert InvalidState();
        // XLS-66.2: equality is not late.
        if (block.timestamp <= loan.nextPaymentDueDate) revert TooSoon();
        uint256 amount = loan.totalValueOutstanding - loan.managementFeeOutstanding;
        vault.setLoanImpairment(0, amount);
        loan.impairmentAmount = amount;
        loan.status = LoanStatus.Impaired;
        emit LoanManaged(loanId, LoanStatus.Impaired, amount, 0);
    }

    function unimpair(uint256 loanId) external onlyOwner {
        Loan storage loan = loans[loanId];
        if (loan.status != LoanStatus.Impaired) revert InvalidState();
        vault.setLoanImpairment(loan.impairmentAmount, 0);
        loan.impairmentAmount = 0;
        loan.status = LoanStatus.Active;
        emit LoanManaged(loanId, LoanStatus.Active, 0, 0);
    }

    function defaultLoan(uint256 loanId) public virtual onlyOwner nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.status != LoanStatus.Active && loan.status != LoanStatus.Impaired) revert InvalidState();
        // XLS-66.2: the grace boundary is exclusive.
        if (block.timestamp <= uint256(loan.nextPaymentDueDate) + loan.gracePeriod) revert TooSoon();

        uint256 defaultAmount = loan.totalValueOutstanding - loan.managementFeeOutstanding;
        uint256 covered = minimumCover() * coverRateLiquidation / RATE_DENOMINATOR;
        if (covered > defaultAmount) covered = defaultAmount;
        if (covered > coverAvailable) covered = coverAvailable;

        if (covered != 0) asset.forceApprove(address(vault), covered);
        vault.protocolDefault(defaultAmount, covered, loan.impairmentAmount);
        coverAvailable -= covered;
        debtTotal = defaultAmount >= debtTotal ? 0 : debtTotal - defaultAmount;
        loan.principalOutstanding = 0;
        loan.totalValueOutstanding = 0;
        loan.managementFeeOutstanding = 0;
        loan.paymentRemaining = 0;
        loan.nextPaymentDueDate = 0;
        loan.impairmentAmount = 0;
        loan.status = LoanStatus.Defaulted;
        activeLoanCount--;
        emit LoanManaged(loanId, LoanStatus.Defaulted, defaultAmount, covered);
    }

    function _routeFees(address payer, uint256 fees) internal {
        if (fees == 0) return;
        if (coverAvailable >= minimumCover()) {
            asset.safeTransferFrom(payer, owner, fees);
        } else {
            asset.safeTransferFrom(payer, address(this), fees);
            coverAvailable += fees;
        }
    }

    function _validateTerms(LoanTerms calldata terms) internal pure {
        if (
            terms.borrower == address(0) || terms.principal == 0 || terms.originationFee > terms.principal
                || terms.interestRate > RATE_DENOMINATOR || terms.lateInterestRate > RATE_DENOMINATOR
                || terms.closeInterestRate > RATE_DENOMINATOR || terms.paymentTotal == 0 || terms.paymentInterval < 60
                || terms.gracePeriod < 60 || terms.gracePeriod > terms.paymentInterval
        ) revert InvalidTerms();
    }

    function _requiredCover(uint256 debt) internal view returns (uint256) {
        return debt * effectiveCoverRateMinimum() / RATE_DENOMINATOR;
    }

    function _amortizedPayment(uint256 principal, uint256 periodicRate, uint256 payments)
        internal
        pure
        returns (uint256)
    {
        if (periodicRate == 0) return _ceilDiv(principal, payments);
        uint256 raised = _rpow(WAD + periodicRate, payments);
        uint256 factor = periodicRate * raised / (raised - WAD);
        return _ceilDiv(principal * factor, WAD);
    }

    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        z = n % 2 == 0 ? WAD : x;
        for (n /= 2; n != 0; n /= 2) {
            x = x * x / WAD;
            if (n % 2 != 0) z = z * x / WAD;
        }
    }

    function _ceilDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
