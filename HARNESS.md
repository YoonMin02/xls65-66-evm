# Harness 정책

`XLS66LoanBrokerHarness`는 `XLS66LoanBroker`의 대출·상환·default 동작을 유지하면서 집중도, Cover 회수,
minimum cover rate에 추가 제약을 적용합니다. 정책값은 생성 시 설정되며 이후 변경할 수 없습니다.

## 대출 집중도

`loanSet` 실행 전에 단일 대출과 Borrower별 누적 원금을 검사합니다.

```text
concentrationBase = max(postLoanPrincipalTotal, debtFloor)

newPrincipal <= singleLoanLimitRate × concentrationBase
borrowerExposure + newPrincipal <= borrowerLimitRate × concentrationBase
```

`debtFloor`는 초기 대출의 분모가 지나치게 작아지는 것을 방지합니다. 집중도는 미래 이자를 포함하는
`DebtTotal` 대신 실제 outstanding principal을 기준으로 계산합니다.

## Cover 회수 지연

대출이 default되면 당시 effective cover rate에 해당하는 금액을 `recoveryPeriod` 동안 출금할 수 없도록
기록합니다.

```text
lockedCover = defaultAmount × effectiveCoverRateMinimum
withdrawableCover = max(0, CoverAvailable - MinimumCover - activeLockedCover)
```

잠긴 Cover는 LoanBroker 컨트랙트에 남아 있으므로 다른 default의 First-Loss Capital로 사용할 수 있습니다.
제한되는 동작은 Owner의 `coverWithdraw`입니다.

## 이력 연동 Cover Rate

최근 `historyWindow` 동안의 대출 실행액과 default 금액으로 effective cover rate를 계산합니다.

```text
defaultRate = min(recentDefaults / recentOriginations, 100%)
linkedRate = min(coverRateFloor + historySlope × defaultRate, 100%)
effectiveCRM = max(coverRateMinimum, linkedRate)
```

같은 기간에 대출 실행 이력은 없고 default만 남아 있으면 default rate를 100%로 계산합니다. 산출된 비율은
minimum cover, 신규 대출의 Cover 검사, default waterfall에 동일하게 적용됩니다.

## Vault 바인딩

각 `XLS65Vault`는 `bindBroker`를 통해 Broker 하나에 영구 바인딩됩니다. 바인딩할 Broker는 해당 Vault를
참조하고 Vault와 동일한 Owner를 가져야 합니다. 바인딩이 완료된 뒤에는 Baseline Broker, 다른 Harness,
EOA를 추가할 수 없습니다.

## 운영상 고려사항

최근 이력과 활성 Cover lock은 배열을 순회하여 계산합니다. 기록이 지속적으로 증가하는 환경에서는 epoch
bucket, 누적 checkpoint 또는 ring buffer 방식으로 교체하여 조회와 `coverWithdraw`의 가스 사용량을
제한해야 합니다.
