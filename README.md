# XLS-65/66 EVM

XLS-65 Single Asset Vault와 XLS-66 Lending Protocol의 핵심 동작을 Solidity로 구현한 프로젝트입니다.
기본 `LoanBroker`와 리스크 통제를 추가한 `Harnessed LoanBroker`를 동일한 조건에서 비교할 수 있습니다.

## 구성

| 경로 | Vault | Broker |
| --- | --- | --- |
| Baseline | `XLS65Vault` | `XLS66LoanBroker` |
| Harness | `XLS65Vault` | `XLS66LoanBrokerHarness` |

두 경로는 하나의 `MockUSDC`를 기초자산으로 사용하지만 Vault와 Broker 상태는 서로 분리됩니다. 각 Vault는
배포 시 지정된 Broker 하나에 영구적으로 바인딩되며, 이후 다른 Broker를 추가하거나 교체할 수 없습니다.

```text
Depositor → XLS65Vault → XLS66LoanBroker         → Borrower
Depositor → XLS65Vault → XLS66LoanBrokerHarness → Borrower
```

## 주요 기능

### XLS65Vault

- ERC-20 자산 예치와 Vault share 발행
- share 상환과 사용 가능한 유동성 관리
- `AssetsTotal`, `AssetsAvailable`, `LossUnrealized` 회계
- public/private Vault와 share 전송 정책
- Vault와 LoanBroker의 일회성 영구 바인딩

### XLS66LoanBroker

- Borrower의 대출 조건 승인
- 고정 기간 대출 실행과 상환
- impairment와 default 처리
- First-Loss Capital 예치, 청산, 회수
- `DebtTotal`, `CoverAvailable`, minimum cover 관리

### XLS66LoanBrokerHarness

- 단일 대출 집중도 제한
- Borrower별 누적 노출 제한
- default 이후 Cover 회수 지연
- 최근 default 이력에 연동되는 minimum cover rate

Harness 정책과 계산식은 [HARNESS.md](./HARNESS.md)에 정리되어 있습니다.

## 설치

요구 사항은 Foundry와 Node.js 20 이상입니다.

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-commit
forge install foundry-rs/forge-std --no-commit
cd frontend
npm ci
```

## 테스트

```bash
forge test
```

## 프론트엔드

```bash
cd frontend
npm run dev
```

프론트엔드는 `public/deployment.json`에서 현재 Sepolia 배포 주소를 읽습니다. Vault와 Broker의 상태는
MetaMask가 연결한 Sepolia RPC에서 같은 블록을 기준으로 조회합니다.

새로운 테스트 환경을 배포하는 방법은 [DEPLOYMENT.md](./DEPLOYMENT.md)를 참고하십시오.

## 구현 범위

이 구현은 Vault 회계, 대출, 상환, default, First-Loss Capital 등 XLS-65/66의 EVM 실행에 필요한 핵심
경로에 집중합니다. 다음 XRPL 전용 기능은 포함하지 않습니다.

- pseudo-account, owner reserve, ledger directory
- XRP, IOU, MPT별 precision 규칙
- trust line, freeze, clawback, Permissioned Domain
- XRPL transaction serialization과 Ripple Epoch
- batch transaction과 XRPL multisigning

`MockUSDC`는 누구나 mint할 수 있는 테스트 토큰입니다. 이 저장소의 컨트랙트는 감사를 받지 않았으며
실제 자산을 관리하는 용도로 사용해서는 안 됩니다.
