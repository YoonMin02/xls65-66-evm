// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {XLS65Vault} from "../src/XLS65Vault.sol";
import {XLS66LoanBroker} from "../src/XLS66LoanBroker.sol";
import {XLS66LoanBrokerHarness} from "../src/XLS66LoanBrokerHarness.sol";

contract XLS66HarnessTest is Test {
    uint256 private constant USDC = 1e6;

    MockUSDC private token;
    XLS65Vault private vault;
    XLS66LoanBrokerHarness private broker;
    address private lender = address(0xA11CE);
    address private borrower = address(0xB0B);

    function setUp() public {
        token = new MockUSDC();
        vault = new XLS65Vault(token, "Harnessed XLS-65 Vault", "hvUSDC", 6, 0, false, true);
        broker = new XLS66LoanBrokerHarness(
            vault,
            1_000, // 1% management fee
            0,
            10_000, // broker-set CRM: 10%
            10_000, // liquidation rate: 10%
            20_000, // one loan <= 20% of concentration base
            30_000, // one borrower <= 30% of concentration base
            5_000 * USDC, // bootstrap debt floor
            30 days,
            365 days,
            10_000, // history-linked CRM floor: 10%
            20_000 // a 100% default rate adds 20 percentage points
        );
        vault.bindBroker(address(broker));

        token.mint(lender, 5_000 * USDC);
        vm.startPrank(lender);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(5_000 * USDC, lender);
        vm.stopPrank();

        token.mint(address(this), 2_000 * USDC);
        token.approve(address(broker), type(uint256).max);
        broker.coverDeposit(1_000 * USDC);
    }

    function testSingleLoanConcentrationLimit() public {
        XLS66LoanBroker.LoanTerms memory terms = _terms(borrower, 1_001 * USDC);
        vm.prank(borrower);
        broker.approveLoanTerms(terms);

        vm.expectRevert(XLS66LoanBrokerHarness.ConcentrationLimitExceeded.selector);
        broker.loanSet(terms);
    }

    function testBorrowerAggregateLimit() public {
        _createLoan(borrower, 900 * USDC);

        XLS66LoanBroker.LoanTerms memory terms = _terms(borrower, 700 * USDC);
        vm.prank(borrower);
        broker.approveLoanTerms(terms);
        vm.expectRevert(XLS66LoanBrokerHarness.BorrowerLimitExceeded.selector);
        broker.loanSet(terms);
    }

    function testDifferentBorrowersCanUseRemainingCapacity() public {
        address secondBorrower = address(0xCAFE);
        _createLoan(borrower, 900 * USDC);
        uint256 secondId = _createLoan(secondBorrower, 700 * USDC);

        assertEq(broker.principalTotal(), 1_600 * USDC);
        assertEq(broker.borrowerExposure(borrower), 900 * USDC);
        assertEq(broker.borrowerExposure(secondBorrower), 700 * USDC);
        assertEq(uint256(broker.getLoan(secondId).status), uint256(XLS66LoanBroker.LoanStatus.Active));
    }

    function testRecoveryTimelockBlocksImmediateFullWithdrawal() public {
        uint256 id = _createLoan(borrower, 500 * USDC);
        XLS66LoanBroker.Loan memory loan = broker.getLoan(id);
        vm.warp(uint256(loan.nextPaymentDueDate) + loan.gracePeriod + 1);
        broker.defaultLoan(id);

        uint256 remainingCover = broker.coverAvailable();
        uint256 withdrawable = broker.withdrawableCover();
        assertGt(broker.lockedCover(), 0, "default-related cover must be locked");
        assertLt(withdrawable, remainingCover, "not all cover is immediately recoverable");

        vm.expectRevert(XLS66LoanBrokerHarness.RecoveryLocked.selector);
        broker.coverWithdraw(remainingCover, address(this));

        if (withdrawable != 0) broker.coverWithdraw(withdrawable, address(this));
        vm.warp(block.timestamp + broker.recoveryPeriod());
        uint256 afterUnlock = broker.withdrawableCover();
        assertEq(afterUnlock, broker.coverAvailable(), "all remaining cover unlocks when debt is zero");
        broker.coverWithdraw(afterUnlock, address(this));
    }

    function testDefaultHistoryRaisesEffectiveCoverRateForNextLoan() public {
        uint256 rateBefore = broker.effectiveCoverRateMinimum();
        uint256 id = _createLoan(borrower, 500 * USDC);
        XLS66LoanBroker.Loan memory loan = broker.getLoan(id);
        vm.warp(uint256(loan.nextPaymentDueDate) + loan.gracePeriod + 1);
        broker.defaultLoan(id);

        uint256 rateAfter = broker.effectiveCoverRateMinimum();
        assertEq(rateBefore, 10_000, "new broker starts at floor");
        assertEq(rateAfter, 30_000, "100% rolling default rate adds 20 percentage points");

        address secondBorrower = address(0xCAFE);
        _createLoan(secondBorrower, 500 * USDC);
        uint256 currentRate = broker.effectiveCoverRateMinimum();
        assertGt(currentRate, rateBefore, "default history still raises the next loan's cover rate");
        assertLt(currentRate, rateAfter, "new origination updates the rolling default-rate denominator");
        assertEq(broker.minimumCover(), broker.debtTotal() * currentRate / broker.RATE_DENOMINATOR());
    }

    function testPrincipalExposureFallsWhenLoanIsRepaid() public {
        uint256 id = _createLoan(borrower, 500 * USDC);
        token.mint(borrower, 20 * USDC);
        vm.startPrank(borrower);
        token.approve(address(vault), type(uint256).max);
        token.approve(address(broker), type(uint256).max);
        broker.pay(id, 520 * USDC, true);
        vm.stopPrank();

        assertEq(broker.principalTotal(), 0);
        assertEq(broker.borrowerExposure(borrower), 0);
    }

    function _createLoan(address loanBorrower, uint256 principal) internal returns (uint256) {
        XLS66LoanBroker.LoanTerms memory terms = _terms(loanBorrower, principal);
        vm.prank(loanBorrower);
        broker.approveLoanTerms(terms);
        return broker.loanSet(terms);
    }

    function _terms(address loanBorrower, uint256 principal) internal pure returns (XLS66LoanBroker.LoanTerms memory) {
        return XLS66LoanBroker.LoanTerms({
            borrower: loanBorrower,
            principal: principal,
            originationFee: 0,
            serviceFee: 1 * USDC,
            latePaymentFee: 2 * USDC,
            closePaymentFee: 1 * USDC,
            interestRate: 10_000,
            lateInterestRate: 5_000,
            closeInterestRate: 1_000,
            paymentTotal: 12,
            paymentInterval: 30 days,
            gracePeriod: 7 days
        });
    }
}
