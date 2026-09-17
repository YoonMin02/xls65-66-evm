# XLS-65/66 Comparison UI

Baseline LoanBroker와 Harnessed LoanBroker를 같은 조건으로 실행하고 Sepolia 상태를 비교하는 React
애플리케이션입니다.

## 실행

```bash
npm ci
npm run dev
```

MetaMask를 연결하고 `MetaMask 1회 확인 후 배포`를 누르면 임시 Owner 지갑의 잔액을 0.05 Sepolia
ETH까지 채우는 거래 한 건만 확인합니다. 이후 컨트랙트 배포와 Owner·Depositor·Borrower 거래는
브라우저가 생성한 임시지갑이 자동 서명합니다.

배포 주소는 연결한 MetaMask 주소별로 브라우저 `localStorage`에 저장됩니다. 고정 주소 파일이나 소스
수정은 필요하지 않습니다. 화면의 상태는 API 키가 없는 공개 Sepolia RPC
`https://ethereum-sepolia-rpc.publicnode.com`에서 같은 블록을 기준으로 읽습니다.

임시지갑 개인키도 해당 브라우저에만 저장됩니다. 테스트넷 전용 구조이므로 실제 자산을 보내거나 운영
지갑으로 사용하면 안 됩니다.

## 배포 artifact 갱신

컨트랙트를 수정한 경우 프론트엔드에 ABI와 bytecode를 다시 반영합니다.

```bash
cd ..
forge build
cd frontend
npm run sync:artifacts
```

전체 사용 절차는 [DEPLOYMENT.md](../DEPLOYMENT.md)를 참고하십시오.
