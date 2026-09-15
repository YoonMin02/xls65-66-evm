# XLS-65/66 Comparison UI

Baseline LoanBroker와 Harnessed LoanBroker의 Sepolia 상태를 한 화면에서 비교하는 React 애플리케이션입니다.

## 실행

```bash
npm ci
npm run dev
```

화면의 수치와 단계 완료 여부는 `deployment.json`에 기록된 컨트랙트를 같은 Sepolia 블록에서 조회하여
계산합니다. 거래가 채굴되면 receipt 블록을 표시하고 컨트랙트 상태를 다시 읽습니다.

## 배포 주소

현재 주소는 `public/deployment.json`에서 런타임에 읽습니다. 새 Foundry 배포 결과를 반영하려면:

```bash
npm run sync:deployment
```

전체 배포 절차는 상위 디렉터리의 [DEPLOYMENT.md](../DEPLOYMENT.md)를 참고하십시오.
