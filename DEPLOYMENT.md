# 브라우저 Sepolia 배포

프론트엔드는 고정된 컨트랙트 주소를 사용하지 않습니다. 사용자가 비교를 시작할 때 Baseline과 Harness의
Vault/Broker 쌍을 브라우저에서 새로 배포하고, 결과 주소를 해당 브라우저에 자동으로 저장합니다.

## 역할과 서명

| 계정 | 역할 | 확인 방식 |
| --- | --- | --- |
| 연결한 MetaMask | 임시 Owner의 Sepolia 가스 후원 | 최초 한 건만 직접 확인 |
| 임시 Owner A | 컨트랙트 배포, Vault 관리, 심사, Cover | 브라우저 자동 서명 |
| 임시 Depositor B | 두 Vault에 동일 금액 예치 | 브라우저 자동 서명 |
| 임시 Borrower C | 두 대출 조건 승인 | 브라우저 자동 서명 |

역할 지갑은 연결한 MetaMask 주소마다 한 번 생성됩니다. 개인키와 배포 주소는 서버나 저장소로 전송하지
않고 브라우저 `localStorage`에만 저장합니다. 브라우저 저장소에 접근 가능한 사용자는 이 키도 볼 수
있으므로 테스트넷 데모 전용으로 사용하고 실제 자산은 보내지 마십시오.

## 실행

```bash
cd frontend
npm ci
npm run dev
```

브라우저에서 `http://127.0.0.1:5173`을 연 뒤 다음 순서로 진행합니다.

1. `지갑 연결`을 눌러 MetaMask를 Sepolia에 연결합니다.
2. `MetaMask 1회 확인 후 배포`를 누릅니다.
3. MetaMask에서 임시 Owner A의 잔액을 0.05 Sepolia ETH까지 채우는 거래 한 건을 확인합니다.
4. 다음 컨트랙트 배포와 역할 지갑 가스 분배가 자동으로 끝날 때까지 기다립니다.
5. 화면의 1단계부터 실행 버튼을 차례대로 누릅니다. 이후에는 MetaMask 확인이 없습니다.

배포 후 Concentration limit, Recovery timelock, History-linked cover rate 중 하나를 선택합니다. 각
시나리오는 대출 금액과 Cover 조건을 해당 정책의 차이가 드러나도록 구성하며, Harness에서 정책으로
거절되는 거래도 실제 Sepolia 실패 거래로 기록합니다. 한 환경은 한 시나리오에만 사용합니다.

브라우저가 자동으로 배포하는 순서는 다음과 같습니다.

1. `MockUSDC`
2. Baseline `XLS65Vault`와 `XLS66LoanBroker`, 두 컨트랙트의 영구 바인딩
3. Harness `XLS65Vault`와 `XLS66LoanBrokerHarness`, 두 컨트랙트의 영구 바인딩
4. Depositor B와 Borrower C의 자동 거래용 가스 분배

배포가 완료되면 `token`, `baselineVault`, `baselineBroker`, `harnessedVault`,
`harnessedBroker` 주소가 연결한 MetaMask 주소를 키로 하여 저장됩니다. `deployment.json`이나
`config.ts`를 직접 수정할 필요가 없습니다.

브라우저 데모의 Harness는 단일 대출 20%, 동일 차주 누적 30%, `D_floor` 2,500 MockUSDC, Cover 회수
지연 30일, 이력 구간 365일로 배포됩니다. 설정 CRM과 이력 CRM floor는 10%, 이력 계수는 20%입니다.
이 값들은 배포된 Broker의 immutable 설정이며 화면에서도 컨트랙트 getter로 다시 읽습니다.

상태 조회와 역할 지갑의 거래 전송에는 API 키가 없는 공개 RPC
`https://ethereum-sepolia-rpc.publicnode.com`을 사용합니다. MetaMask에 설정된 RPC 주소나 개인 API
키는 프론트엔드 번들에 포함되지 않습니다.

## 다시 실행하거나 가스 회수하기

`새 환경 배포`를 누르면 새 컨트랙트 세트를 배포하고 현재 브라우저의 주소 매핑을 새 주소로 교체합니다.
기존 컨트랙트와 상태는 Sepolia에 남아 있지만 화면에서는 새 환경을 사용합니다. 임시 역할 지갑은 그대로
재사용하므로 남은 가스도 다음 배포에 사용됩니다.

데모를 마친 뒤 `가스 회수`를 누르면 역할 지갑에 남은 Sepolia ETH 중 이후 전송에 필요한 소량을 제외한
잔액을 연결한 MetaMask 주소로 돌려보냅니다.

## 컨트랙트 변경 후 artifact 갱신

Solidity 컨트랙트를 수정했다면 ABI와 배포 bytecode를 프론트엔드에 다시 생성합니다.

```bash
forge build
cd frontend
npm run sync:artifacts
```

생성되는 `frontend/src/artifacts.json`은 공개 정보인 ABI와 bytecode만 포함하며 저장소에 커밋합니다.
