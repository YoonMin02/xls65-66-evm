export const tokenAbi = [
  'function mint(address to,uint256 amount)',
  'function approve(address spender,uint256 amount) returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
] as const;

export const vaultAbi = [
  'function deposit(uint256 requestedAssets,address receiver) returns (uint256 shares)',
  'function assetsTotal() view returns (uint256)',
  'function assetsAvailable() view returns (uint256)',
  'function lossUnrealized() view returns (uint256)',
  'function balanceOf(address account) view returns (uint256)',
  'function broker() view returns (address)',
  'function owner() view returns (address)',
] as const;

export const loanTuple = '(address borrower,uint256 principal,uint256 originationFee,uint256 serviceFee,uint256 latePaymentFee,uint256 closePaymentFee,uint32 interestRate,uint32 lateInterestRate,uint32 closeInterestRate,uint32 paymentTotal,uint32 paymentInterval,uint32 gracePeriod)';

export const brokerAbi = [
  `function approveLoanTerms(${loanTuple} terms) returns (bytes32)`,
  `function hashLoanTerms(${loanTuple} terms) view returns (bytes32)`,
  'function borrowerApprovals(bytes32 termsHash) view returns (bool)',
  `function loanSet(${loanTuple} terms) returns (uint256 loanId)`,
  'function coverDeposit(uint256 amount)',
  'function coverWithdraw(uint256 amount,address destination)',
  'function defaultLoan(uint256 loanId)',
  'function getLoan(uint256 loanId) view returns ((address borrower,uint8 status,uint32 paymentRemaining,uint32 paymentInterval,uint32 gracePeriod,uint32 interestRate,uint32 lateInterestRate,uint32 closeInterestRate,uint64 startDate,uint64 previousPaymentDueDate,uint64 nextPaymentDueDate,uint256 principalOutstanding,uint256 totalValueOutstanding,uint256 managementFeeOutstanding,uint256 periodicPayment,uint256 serviceFee,uint256 latePaymentFee,uint256 closePaymentFee,uint256 impairmentAmount))',
  'function debtTotal() view returns (uint256)',
  'function coverAvailable() view returns (uint256)',
  'function minimumCover() view returns (uint256)',
  'function effectiveCoverRateMinimum() view returns (uint256)',
  'function loanSequence() view returns (uint256)',
  'function vault() view returns (address)',
  'function owner() view returns (address)',
  'function coverRateMinimum() view returns (uint32)',
  'function coverRateLiquidation() view returns (uint32)',
] as const;

export const harnessAbi = [
  ...brokerAbi,
  'function lockedCover() view returns (uint256)',
  'function withdrawableCover() view returns (uint256)',
  'function singleLoanLimitRate() view returns (uint32)',
  'function borrowerLimitRate() view returns (uint32)',
  'function recoveryPeriod() view returns (uint64)',
  'function historyWindow() view returns (uint64)',
  'function coverRateFloor() view returns (uint32)',
  'function historySlope() view returns (uint32)',
] as const;
