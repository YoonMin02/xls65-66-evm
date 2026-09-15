// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {XLS65Vault} from "../src/XLS65Vault.sol";
import {XLS66LoanBroker} from "../src/XLS66LoanBroker.sol";

contract XLS6566Test is Test {
    uint256 private constant USDC = 1e6;

    MockUSDC private token;
    XLS65Vault private vault;
    XLS66LoanBroker private broker;
    address private lender = address(0xA11CE);
    address private borrower = address(0xB0B);

    function setUp() public {
        token = new MockUSDC();
        vault = new XLS65Vault(token, "XLS-65 USDC Vault", "vUSDC", 6, 0, false, true);
        broker = new XLS66LoanBroker(vault, 1_000, 0, 10_000, 10_000); // 1%, 10%, 10%
        vault.bindBroker(address(broker));

        token.mint(lender, 2_000 * USDC);
        vm.prank(lender);
        token.approve(address(vault), type(uint256).max);
        vm.prank(lender);
        vault.deposit(1_000 * USDC, lender);

        token.mint(address(this), 500 * USDC);
        token.approve(address(broker), type(uint256).max);
        broker.coverDeposit(200 * USDC);
    }

    function testVaultDepositAndRedeem() public {
        assertEq(vault.assetsTotal(), 1_000 * USDC, "assets total");
        assertEq(vault.assetsAvailable(), 1_000 * USDC, "assets available");
        assertEq(vault.balanceOf(lender), 1_000 * USDC, "initial 1:1 shares");

        vm.prank(lender);
        uint256 assets = vault.redeem(100 * USDC, lender);
        assertEq(assets, 100 * USDC, "redeem value");
        assertEq(vault.assetsTotal(), 900 * USDC, "total after redeem");
    }

    function testVaultBrokerBindingIsPermanent() public {
        XLS66LoanBroker replacement = new XLS66LoanBroker(vault, 1_000, 0, 10_000, 10_000);
        vm.expectRevert(XLS65Vault.BrokerAlreadyBound.selector);
        vault.bindBroker(address(replacement));
        assertEq(vault.broker(), address(broker), "original broker remains bound");
    }

    function testOwnerCannotActAsBroker() public {
        vm.expectRevert(XLS65Vault.Unauthorized.selector);
        vault.protocolLoan(1 * USDC, 0, address(this), address(this), 0);
    }

    function testLoanRequiresBorrowerConsent() public {
        XLS66LoanBroker.LoanTerms memory terms = _terms(500 * USDC);
        vm.expectRevert(XLS66LoanBroker.LoanNotApproved.selector);
        broker.loanSet(terms);
    }

    function testLoanSetMovesLiquidityAndRecognizesInterest() public {
        uint256 id = _createLoan(500 * USDC);
        XLS66LoanBroker.Loan memory loan = broker.getLoan(id);
        assertEq(uint256(loan.status), uint256(XLS66LoanBroker.LoanStatus.Active), "active");
        assertEq(token.balanceOf(borrower), 500 * USDC, "borrower funded");
        assertEq(vault.assetsAvailable(), 500 * USDC, "available reduced");
        assertTrue(vault.assetsTotal() > 1_000 * USDC, "net interest recognized");
        assertEq(broker.debtTotal(), loan.totalValueOutstanding - loan.managementFeeOutstanding, "debt");
    }

    function testRegularPaymentReturnsAssetsToVault() public {
        uint256 id = _createLoan(500 * USDC);
        XLS66LoanBroker.Loan memory beforeLoan = broker.getLoan(id);
        uint256 availableBefore = vault.assetsAvailable();
        token.mint(borrower, 100 * USDC);
        vm.prank(borrower);
        token.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        token.approve(address(broker), type(uint256).max);

        vm.prank(borrower);
        broker.pay(id, 100 * USDC, false);

        XLS66LoanBroker.Loan memory afterLoan = broker.getLoan(id);
        assertEq(afterLoan.paymentRemaining, beforeLoan.paymentRemaining - 1, "one installment");
        assertTrue(vault.assetsAvailable() > availableBefore, "liquidity returned");
        assertTrue(broker.debtTotal() < beforeLoan.totalValueOutstanding, "debt reduced");
    }

    function testEarlyFullPaymentRemovesUnearnedInterest() public {
        uint256 id = _createLoan(500 * USDC);
        token.mint(borrower, 20 * USDC);
        vm.prank(borrower);
        token.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        token.approve(address(broker), type(uint256).max);

        vm.prank(borrower);
        broker.pay(id, 520 * USDC, true);

        XLS66LoanBroker.Loan memory loan = broker.getLoan(id);
        assertEq(uint256(loan.status), uint256(XLS66LoanBroker.LoanStatus.Repaid), "repaid");
        assertEq(broker.debtTotal(), 0, "recognized debt removed");
        assertEq(vault.assetsTotal(), vault.assetsAvailable(), "no unavailable value remains");
    }

    function testImpairmentDiscountsNonSoleHolderRedemption() public {
        address secondLender = address(0xCAFE);
        token.mint(secondLender, 100 * USDC);
        vm.prank(secondLender);
        token.approve(address(vault), type(uint256).max);
        vm.prank(secondLender);
        vault.deposit(100 * USDC, secondLender);

        uint256 id = _createLoan(500 * USDC);
        XLS66LoanBroker.Loan memory loan = broker.getLoan(id);
        vm.warp(uint256(loan.nextPaymentDueDate) + 1);
        broker.impair(id);

        uint256 undiscounted = 10 * USDC * vault.assetsTotal() / vault.totalSupply();
        uint256 discounted = vault.convertToAssets(10 * USDC);
        assertTrue(discounted < undiscounted, "paper loss discounts shares");
    }

    function testDefaultUsesCappedFirstLossAndBaselineAllowsImmediateRecovery() public {
        uint256 id = _createLoan(500 * USDC);
        XLS66LoanBroker.Loan memory loan = broker.getLoan(id);
        uint256 defaultAmount = loan.totalValueOutstanding - loan.managementFeeOutstanding;
        uint256 minCoverBefore = broker.minimumCover();
        uint256 expectedCovered = minCoverBefore * broker.coverRateLiquidation() / broker.RATE_DENOMINATOR();
        uint256 coverBefore = broker.coverAvailable();
        uint256 totalBefore = vault.assetsTotal();

        vm.warp(uint256(loan.nextPaymentDueDate) + loan.gracePeriod + 1);
        broker.defaultLoan(id);

        assertEq(broker.debtTotal(), 0, "debt cleared");
        assertEq(broker.coverAvailable(), coverBefore - expectedCovered, "only capped cover used");
        assertEq(vault.assetsTotal(), totalBefore - (defaultAmount - expectedCovered), "depositors take residual");

        // This intentionally proves the unharnessed XLS-66 behavior discussed in the draft:
        // DebtTotal is now zero, so all remaining cover is immediately withdrawable.
        uint256 recoverable = broker.coverAvailable();
        broker.coverWithdraw(recoverable, address(this));
        assertEq(broker.coverAvailable(), 0, "immediate post-default recovery");
    }

    function testCoverCannotFallBelowMinimumWhileDebtExists() public {
        _createLoan(500 * USDC);
        uint256 tooMuch = broker.coverAvailable() - broker.minimumCover() + 1;
        vm.expectRevert(XLS66LoanBroker.CoverInsufficient.selector);
        broker.coverWithdraw(tooMuch, address(this));
    }

    function _createLoan(uint256 principal) internal returns (uint256) {
        XLS66LoanBroker.LoanTerms memory terms = _terms(principal);
        vm.prank(borrower);
        broker.approveLoanTerms(terms);
        return broker.loanSet(terms);
    }

    function _terms(uint256 principal) internal view returns (XLS66LoanBroker.LoanTerms memory) {
        return XLS66LoanBroker.LoanTerms({
            borrower: borrower,
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
