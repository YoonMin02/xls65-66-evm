// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XLS65Vault} from "./XLS65Vault.sol";
import {XLS66LoanBroker} from "./XLS66LoanBroker.sol";

/// @notice XLS-66 broker with concentration, recovery-lock, and history-linked cover policies.
/// @dev This contract is intentionally separate from the harness-free baseline.
contract XLS66LoanBrokerHarness is XLS66LoanBroker {
    struct TimedAmount {
        uint64 timestamp;
        uint256 amount;
    }

    error ConcentrationLimitExceeded();
    error BorrowerLimitExceeded();
    error RecoveryLocked();

    // All rates use XLS-66's 1/10 bp scale (100_000 == 100%). Policies are
    // immutable so the broker cannot weaken its own guardrails after deposits.
    uint32 public immutable singleLoanLimitRate;
    uint32 public immutable borrowerLimitRate;
    uint256 public immutable debtFloor;
    uint64 public immutable recoveryPeriod;
    uint64 public immutable historyWindow;
    uint32 public immutable coverRateFloor;
    uint32 public immutable historySlope;

    uint256 public principalTotal;
    mapping(address => uint256) public borrowerExposure;
    TimedAmount[] private _originations;
    TimedAmount[] private _defaults;
    TimedAmount[] private _coverLocks;

    event RecoveryCoverLocked(uint256 indexed loanId, uint256 amount, uint256 unlockTime);

    constructor(
        XLS65Vault vault_,
        uint32 managementFeeRate_,
        uint256 debtMaximum_,
        uint32 coverRateMinimum_,
        uint32 coverRateLiquidation_,
        uint32 singleLoanLimitRate_,
        uint32 borrowerLimitRate_,
        uint256 debtFloor_,
        uint64 recoveryPeriod_,
        uint64 historyWindow_,
        uint32 coverRateFloor_,
        uint32 historySlope_
    ) XLS66LoanBroker(vault_, managementFeeRate_, debtMaximum_, coverRateMinimum_, coverRateLiquidation_) {
        if (
            singleLoanLimitRate_ == 0 || singleLoanLimitRate_ > RATE_DENOMINATOR || borrowerLimitRate_ == 0
                || borrowerLimitRate_ > RATE_DENOMINATOR || debtFloor_ == 0 || recoveryPeriod_ == 0
                || historyWindow_ == 0 || coverRateFloor_ > RATE_DENOMINATOR || historySlope_ > RATE_DENOMINATOR
        ) revert InvalidTerms();
        singleLoanLimitRate = singleLoanLimitRate_;
        borrowerLimitRate = borrowerLimitRate_;
        debtFloor = debtFloor_;
        recoveryPeriod = recoveryPeriod_;
        historyWindow = historyWindow_;
        coverRateFloor = coverRateFloor_;
        historySlope = historySlope_;
    }

    /// @notice CRM_eff = max(CRM_set, CRM_floor + lambda * DefaultRate_T).
    /// @dev DefaultRate_T = defaults in T / originated principal in T. The
    ///      presentation formula does not cap DefaultRate_T or CRM_eff at 100%.
    function effectiveCoverRateMinimum() public view override returns (uint256) {
        uint256 linkedRate = uint256(coverRateFloor) + uint256(historySlope) * defaultRate() / RATE_DENOMINATOR;
        return linkedRate > coverRateMinimum ? linkedRate : coverRateMinimum;
    }

    function defaultRate() public view returns (uint256) {
        (uint256 originated, uint256 defaulted) = historyTotals();
        return originated == 0 ? 0 : defaulted * RATE_DENOMINATOR / originated;
    }

    /// @notice max(DebtTotal + L_new, D_floor), shared by both concentration checks.
    function concentrationBase(uint256 newLoan) public view returns (uint256) {
        uint256 postLoanDebt = debtTotal + newLoan;
        return postLoanDebt > debtFloor ? postLoanDebt : debtFloor;
    }

    function loanSet(LoanTerms calldata terms) public override returns (uint256 loanId) {
        uint256 postPrincipal = principalTotal + terms.principal;
        uint256 base = concentrationBase(terms.principal);

        if (terms.principal > base * singleLoanLimitRate / RATE_DENOMINATOR) {
            revert ConcentrationLimitExceeded();
        }
        if (borrowerExposure[terms.borrower] + terms.principal > base * borrowerLimitRate / RATE_DENOMINATOR) {
            revert BorrowerLimitExceeded();
        }

        loanId = super.loanSet(terms);
        principalTotal = postPrincipal;
        borrowerExposure[terms.borrower] += terms.principal;
        _originations.push(TimedAmount({timestamp: uint64(block.timestamp), amount: terms.principal}));
    }

    function pay(uint256 loanId, uint256 maxAmount, bool fullPayment) public override {
        Loan storage loan = loans[loanId];
        address borrower = loan.borrower;
        uint256 principalBefore = loan.principalOutstanding;
        super.pay(loanId, maxAmount, fullPayment);
        uint256 principalPaid = principalBefore - loans[loanId].principalOutstanding;
        principalTotal -= principalPaid;
        borrowerExposure[borrower] -= principalPaid;
    }

    function defaultLoan(uint256 loanId) public override {
        Loan storage loan = loans[loanId];
        address borrower = loan.borrower;
        uint256 principal = loan.principalOutstanding;
        uint256 defaultAmount = loan.totalValueOutstanding - loan.managementFeeOutstanding;
        uint256 lockAmount = defaultAmount * coverRateMinimum / RATE_DENOMINATOR;

        super.defaultLoan(loanId);

        principalTotal -= principal;
        borrowerExposure[borrower] -= principal;
        _defaults.push(TimedAmount({timestamp: uint64(block.timestamp), amount: defaultAmount}));
        _coverLocks.push(TimedAmount({timestamp: uint64(block.timestamp + recoveryPeriod), amount: lockAmount}));
        emit RecoveryCoverLocked(loanId, lockAmount, block.timestamp + recoveryPeriod);
    }

    function coverWithdraw(uint256 amount, address destination) public override {
        if (amount > withdrawableCover()) revert RecoveryLocked();
        super.coverWithdraw(amount, destination);
    }

    function withdrawableCover() public view returns (uint256) {
        uint256 required = minimumCover();
        uint256 locked = lockedCover();
        if (coverAvailable <= required + locked) return 0;
        return coverAvailable - required - locked;
    }

    function lockedCover() public view returns (uint256 amount) {
        uint256 length = _coverLocks.length;
        for (uint256 i; i < length; ++i) {
            TimedAmount storage item = _coverLocks[i];
            if (item.timestamp > block.timestamp) amount += item.amount;
        }
    }

    function historyTotals() public view returns (uint256 originated, uint256 defaulted) {
        uint256 cutoff = block.timestamp > historyWindow ? block.timestamp - historyWindow : 0;
        uint256 length = _originations.length;
        for (uint256 i; i < length; ++i) {
            TimedAmount storage item = _originations[i];
            if (item.timestamp > cutoff) originated += item.amount;
        }
        length = _defaults.length;
        for (uint256 i; i < length; ++i) {
            TimedAmount storage item = _defaults[i];
            if (item.timestamp > cutoff) defaulted += item.amount;
        }
    }

    function originationsLength() external view returns (uint256) {
        return _originations.length;
    }

    function defaultsLength() external view returns (uint256) {
        return _defaults.length;
    }

    function coverLocksLength() external view returns (uint256) {
        return _coverLocks.length;
    }
}
