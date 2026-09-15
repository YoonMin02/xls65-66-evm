# Sepolia 배포 및 프론트엔드 연결

새로운 테스트를 처음부터 실행하려면 Baseline과 Harness의 Vault/Broker 쌍을 새로 배포해야 합니다.
기존 컨트랙트의 상태는 Sepolia에 계속 남으며 초기화되지 않습니다.

## 1. 환경 설정

프로젝트 루트에서 `.env.example`을 복사해 `.env`를 준비합니다.

```bash
cp .env.example .env
```

`.env`의 `SEPOLIA_RPC_URL`에 Sepolia RPC URL을 설정합니다. 배포 계정은 Foundry keystore를 사용합니다.

```bash
cast wallet import sepolia-deployer --interactive
```

배포 계정에는 가스비로 사용할 Sepolia ETH가 필요합니다. `.env`와 keystore 비밀번호는 저장소에
커밋하지 않습니다.

## 2. 배포와 주소 갱신

다음 명령은 컨트랙트 배포와 프론트엔드 deployment manifest 갱신을 연속으로 실행합니다.

```bash
./script/deploy-and-sync.sh
```

실행 중 `Enter keystore password:`가 표시되면 로컬 keystore 비밀번호를 입력합니다.

배포 순서는 다음과 같습니다.

1. `MockUSDC`
2. Baseline `XLS65Vault`
3. `XLS66LoanBroker`
4. Baseline Vault와 Broker 영구 바인딩
5. Harness `XLS65Vault`
6. `XLS66LoanBrokerHarness`
7. Harness Vault와 Broker 영구 바인딩

Foundry 결과는 로컬 `broadcast/DeploySepolia.s.sol/11155111/run-latest.json`에 저장됩니다. 이 디렉터리는
Git에서 제외됩니다.

## 3. 주소가 기록되는 위치

프론트엔드 소스에는 컨트랙트 주소가 하드코딩되어 있지 않습니다. 배포가 끝나면
`frontend/scripts/sync-deployment.mjs`가 최신 Foundry 결과를 읽어 다음 파일을 갱신합니다.

```text
frontend/public/deployment.json
```

manifest에는 `token`, `baselineVault`, `baselineBroker`, `harnessedVault`, `harnessedBroker` 주소가
기록됩니다.

수동으로 Foundry 배포를 실행했다면 아래 명령으로 주소만 다시 동기화할 수 있습니다.

```bash
cd frontend
npm run sync:deployment
```

`config.ts`를 직접 수정할 필요는 없습니다.

## 4. 프론트엔드 실행

```bash
cd frontend
npm run dev
```

브라우저에서 `http://127.0.0.1:5173`을 열고 MetaMask를 Sepolia로 전환합니다. 개발 서버가 이미 실행
중이라면 manifest 갱신 후 브라우저를 새로고침합니다.

화면에서 다음 상태를 확인한 후 테스트를 시작합니다.

- Sepolia chain ID `11155111`
- Baseline Vault와 Baseline Broker의 영구 바인딩
- Harness Vault와 Harnessed Broker의 영구 바인딩
- 두 Vault의 `AssetsTotal = 0`
- 두 Broker의 `CoverAvailable = 0`
- 두 Broker의 `loanSequence = 1`

## 5. 선택 설정

| 환경 변수 | 기본값 | 의미 |
| --- | ---: | --- |
| `HARNESS_DEBT_FLOOR` | `1000000000000` | 집중도 계산의 초기 기준액, MockUSDC 6 decimals |
| `HARNESS_RECOVERY_PERIOD` | `2592000` | Cover 회수 지연, 30일 |
| `HARNESS_HISTORY_WINDOW` | `31536000` | default 이력 기간, 365일 |

값을 변경하려면 배포 전에 `.env`에 설정합니다. 이미 배포된 Harness의 정책값은 변경되지 않습니다.
