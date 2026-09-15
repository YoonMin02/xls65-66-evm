# Harness 정책

`XLS66LoanBrokerHarness`는 `XLS66LoanBroker`의 대출·상환·default 동작을 유지하면서 집중도, Cover 회수,
minimum cover rate에 추가 제약을 적용합니다. 정책값은 생성 시 설정되며 이후 변경할 수 없습니다.

## 대출 집중도

`loanSet` 실행 전에 단일 대출과 Borrower별 누적 원금을 검사합니다.

```text
concentrationBase = max(DebtTotal + newPrincipal, debtFloor)

newPrincipal <= singleLoanLimitRate × concentrationBase
borrowerExposure + newPrincipal <= borrowerLimitRate × concentrationBase
```

첫 번째 식은 발표자료의 단일 대출 한도와 같습니다. 두 번째 식에는 빈 Vault에서도 여러 차주의 대출을
순차적으로 구성할 수 있도록 동일한 `debtFloor`를 추가했습니다. `borrowerExposure`는 해당 차주의 현재
미상환 원금 합계입니다.

## Cover 회수 지연

대출이 default되면 설정된 minimum cover rate에 해당하는 금액을 `recoveryPeriod` 동안 출금할 수 없도록
기록합니다.

```text
lockedCover = defaultAmount × coverRateMinimum
withdrawableCover = max(0, CoverAvailable - MinimumCover - activeLockedCover)
```

잠긴 Cover는 LoanBroker 컨트랙트에 남아 있으므로 다른 default의 First-Loss Capital로 사용할 수 있습니다.
제한되는 동작은 Owner의 `coverWithdraw`입니다.

## 이력 연동 Cover Rate

최근 `historyWindow` 동안의 대출 실행 원금과 default 금액으로 effective cover rate를 계산합니다.

```text
DefaultRate_T = sum(DefaultAmount in T) / sum(executed principal in T)
effectiveCRM = max(coverRateMinimum, coverRateFloor + historySlope × DefaultRate_T)
```

발표자료의 식에 없는 100% 상한은 적용하지 않습니다. 기간 내 실행 원금이 0이면 디폴트율을 0으로
처리합니다. 신규 LoanBroker는 이력이 없으므로 `max(coverRateMinimum, coverRateFloor)`에서 시작하고,
이후 `LoanSet`의 minimum cover 검사와 default waterfall에는 당시의 effective CRM이 사용됩니다.

## Vault 바인딩

각 `XLS65Vault`는 `bindBroker`를 통해 Broker 하나에 영구 바인딩됩니다. 바인딩할 Broker는 해당 Vault를
참조하고 Vault와 동일한 Owner를 가져야 합니다. 바인딩이 완료된 뒤에는 Baseline Broker, 다른 Harness,
EOA를 추가할 수 없습니다.

## 운영상 고려사항

최근 이력과 활성 Cover lock은 배열을 순회하여 계산합니다. 기록이 지속적으로 증가하는 환경에서는 epoch
bucket, 누적 checkpoint 또는 ring buffer 방식으로 교체하여 조회와 `coverWithdraw`의 가스 사용량을
제한해야 합니다.
