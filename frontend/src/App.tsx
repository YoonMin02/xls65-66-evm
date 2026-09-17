import {
  BrowserProvider,
  Contract,
  JsonRpcProvider,
  formatUnits,
  parseUnits,
  type ContractTransactionResponse,
  type TransactionResponse,
} from 'ethers';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { brokerAbi, harnessAbi, tokenAbi, vaultAbi } from './abi';
import {
  CHAIN_ID,
  PUBLIC_RPC_URL,
  explorer,
  type DeploymentAddresses,
  type DeploymentManifest,
} from './config';
import {
  deploySession,
  loadDeployment,
  publicProvider,
  roleWallets,
  sweepRoleGas,
  type RoleWallets,
} from './session';

type Kind = 'baseline' | 'harness';
type StepKey = 'setup' | 'approve' | 'issue' | 'wait' | 'default' | 'recover';
type TxStatus = 'signing' | 'mining' | 'confirmed' | 'error';
type LoanView = {
  id: bigint;
  status: number;
  borrower: string;
  principal: bigint;
  dueAt: number;
  defaultAt: number;
};
type SideState = {
  assetsTotal: bigint;
  assetsAvailable: bigint;
  loss: bigint;
  shares: bigint;
  debt: bigint;
  cover: bigint;
  minimumCover: bigint;
  effectiveRate: bigint;
  locked: bigint;
  withdrawable: bigint;
  approval: boolean;
  loan: LoanView | null;
  configuredBroker: string | null;
  brokerPointsBack: boolean;
  codePresent: boolean;
};
type HarnessPolicy = {
  singleLoan: bigint;
  borrowerLimit: bigint;
  debtFloor: bigint;
  recoveryPeriod: bigint;
  historyWindow: bigint;
  coverRateMinimum: bigint;
  coverRateLiquidation: bigint;
  coverRateFloor: bigint;
  historySlope: bigint;
};
type Snapshot = { block: number; timestamp: number; readAt: number };
type TxLog = { label: string; hash?: string; status: TxStatus; block?: number };
type RoleAddresses = { owner: string; depositor: string; borrower: string };

const ZERO_SIDE: SideState = {
  assetsTotal: 0n,
  assetsAvailable: 0n,
  loss: 0n,
  shares: 0n,
  debt: 0n,
  cover: 0n,
  minimumCover: 0n,
  effectiveRate: 0n,
  locked: 0n,
  withdrawable: 0n,
  approval: false,
  loan: null,
  configuredBroker: null,
  brokerPointsBack: false,
  codePresent: false,
};
const ZERO_POLICY: HarnessPolicy = {
  singleLoan: 0n,
  borrowerLimit: 0n,
  debtFloor: 0n,
  recoveryPeriod: 0n,
  historyWindow: 0n,
  coverRateMinimum: 0n,
  coverRateLiquidation: 0n,
  coverRateFloor: 0n,
  historySlope: 0n,
};
const USDC = (value: string) => parseUnits(value, 6);
const fmt = (value: bigint, digits = 2) => Number(formatUnits(value, 6)).toLocaleString('ko-KR', { maximumFractionDigits: digits });
const percent = (value: bigint) => `${(Number(value) / 1000).toFixed(1)}%`;
const duration = (seconds: bigint) => Number(seconds) % 86_400 === 0 ? `${Number(seconds) / 86_400}일` : `${seconds.toString()}초`;
const short = (value: string) => `${value.slice(0, 6)}…${value.slice(-4)}`;
const validAddress = (value: string) => /^0x[0-9a-fA-F]{40}$/.test(value);
const statusName = ['없음', '진행 중', '손상 인식', '상환 완료', 'Default'];
const RPC_PROVIDER = publicProvider();

function loanTerms(borrower: string) {
  return [
    borrower, USDC('500'), 0n, USDC('1'), USDC('2'), USDC('1'),
    10_000, 5_000, 1_000, 12, 60, 60,
  ] as const;
}

function contractSet(provider: JsonRpcProvider, addresses: DeploymentAddresses) {
  return {
    token: new Contract(addresses.token, tokenAbi, provider),
    baseline: {
      vault: new Contract(addresses.baselineVault, vaultAbi, provider),
      broker: new Contract(addresses.baselineBroker, brokerAbi, provider),
    },
    harness: {
      vault: new Contract(addresses.harnessedVault, vaultAbi, provider),
      broker: new Contract(addresses.harnessedBroker, harnessAbi, provider),
    },
  };
}

function Source({ getter }: { getter: string }) {
  return <code className="source">{getter}()</code>;
}

function Metric({ label, value, getter, tone }: { label: string; value: string; getter: string; tone?: 'good' | 'warn' }) {
  return <div className={`metric ${tone || ''}`}><span>{label}<Source getter={getter} /></span><strong>{value}</strong></div>;
}

function Binding({ state, expected }: { state: SideState; expected: string }) {
  const bound = state.configuredBroker?.toLowerCase() === expected.toLowerCase() && state.brokerPointsBack;
  return <div className={`binding ${bound ? 'verified' : 'unverified'}`}>
    <span className="dot" />
    <div><b>{bound ? '영구 Broker 연결 확인' : state.configuredBroker === null ? '구버전 Vault · 바인딩 증명 없음' : 'Broker 연결 불일치'}</b>
      <small>{state.configuredBroker ? `${short(state.configuredBroker)} · 양방향 주소 대조` : '새 컨트랙트 배포 후 검증 가능'}</small></div>
  </div>;
}

function ProtocolCard({ kind, state, policy, expectedBroker }: { kind: Kind; state: SideState; policy: HarnessPolicy; expectedBroker: string }) {
  const harnessed = kind === 'harness';
  return <article className={`protocol ${harnessed ? 'guarded' : 'baseline'}`}>
    <header>
      <div><span className="eyebrow">{harnessed ? 'PROPOSED CONTROL LAYER' : 'XLS-65 / XLS-66'}</span>
        <h2>{harnessed ? 'Harnessed lending' : 'Baseline lending'}</h2></div>
      <span className={`badge ${harnessed ? 'safe' : 'plain'}`}>{harnessed ? '3 controls on' : 'spec only'}</span>
    </header>
    <Binding state={state} expected={expectedBroker} />
    <div className="flow">
      <div><b>Depositor</b><small>MockUSDC</small></div><i>→</i>
      <div><b>XLS-65 Vault</b><small>share 발행</small></div><i>→</i>
      <div><b>{harnessed ? 'Harnessed LoanBroker' : 'LoanBroker'}</b><small>FLC + 신용심사</small></div><i>→</i>
      <div><b>Borrower</b><small>무담보 대출</small></div>
    </div>
    {harnessed && <div className="controls">
      <span>{percent(policy.singleLoan)} 단일대출</span>
      <span>{percent(policy.borrowerLimit)} 차주한도</span>
      <span>D_floor ${fmt(policy.debtFloor, 0)}</span>
      <span>{duration(policy.recoveryPeriod)} 회수지연</span>
      <span>CRM {percent(policy.coverRateMinimum)} · CRL {percent(policy.coverRateLiquidation)}</span>
      <span>이력 CRM: {percent(policy.coverRateFloor)} + {percent(policy.historySlope)} × DefaultRate</span>
    </div>}
    <div className="metrics">
      <Metric label="Vault total" getter="assetsTotal" value={`$${fmt(state.assetsTotal)}`} />
      <Metric label="Available" getter="assetsAvailable" value={`$${fmt(state.assetsAvailable)}`} />
      <Metric label="Debt total" getter="debtTotal" value={`$${fmt(state.debt)}`} />
      <Metric label="Cover" getter="coverAvailable" value={`$${fmt(state.cover)}`} />
      <Metric label="Required cover" getter="minimumCover" value={`$${fmt(state.minimumCover)}`} />
      <Metric label="Effective CRM" getter="effectiveCoverRateMinimum" value={percent(state.effectiveRate)} tone={harnessed && state.effectiveRate > 10_000n ? 'good' : undefined} />
      <Metric label="Recovery locked" getter={harnessed ? 'lockedCover' : 'N/A'} value={`$${fmt(state.locked)}`} tone={harnessed && state.locked > 0n ? 'good' : undefined} />
      <Metric label="Withdrawable" getter={harnessed ? 'withdrawableCover' : 'cover-required'} value={`$${fmt(state.withdrawable)}`} tone={!harnessed && state.withdrawable > 0n ? 'warn' : undefined} />
    </div>
    <p className="reading">{state.loan
      ? `Loan #${state.loan.id}: ${statusName[state.loan.status] || state.loan.status} · 원금 $${fmt(state.loan.principal)}`
      : '이 Broker에서 조회된 대출이 없습니다.'}</p>
  </article>;
}

type StageStatus = 'waiting' | 'ready' | 'done' | 'blocked';
function Pill({ status }: { status: StageStatus }) {
  const text = { waiting: '대기', ready: '실행 가능', done: '체인 확인', blocked: '차단됨' }[status];
  return <span className={`stage-pill ${status}`}><i />{text}</span>;
}

function stageStatus(key: StepKey, side: SideState, chainTime: number, harnessed: boolean): StageStatus {
  if (key === 'setup') return side.assetsTotal > 0n && side.cover > 0n ? 'done' : 'ready';
  if (key === 'approve') return side.approval ? 'done' : 'ready';
  if (key === 'issue') return side.loan ? 'done' : side.approval ? 'ready' : 'waiting';
  if (key === 'wait') return side.loan && chainTime > side.loan.defaultAt ? 'done' : 'waiting';
  if (key === 'default') return side.loan?.status === 4 ? 'done' : side.loan && chainTime > side.loan.defaultAt ? 'ready' : 'waiting';
  if (side.loan?.status !== 4) return 'waiting';
  if (harnessed && side.locked > 0n && side.withdrawable === 0n) return 'blocked';
  return side.cover === 0n ? 'done' : 'ready';
}

function stageEvidence(key: StepKey, side: SideState, chainTime: number, harnessed: boolean) {
  if (key === 'setup') return `Vault ${fmt(side.assetsTotal)} · Cover ${fmt(side.cover)}`;
  if (key === 'approve') return side.approval ? 'borrowerApprovals = true' : 'borrowerApprovals = false';
  if (key === 'issue') return side.loan ? `Loan #${side.loan.id} · ${statusName[side.loan.status]}` : 'Loan 없음';
  if (key === 'wait') {
    if (!side.loan) return '대출 실행 전';
    const left = Math.max(0, side.loan.defaultAt - chainTime);
    return left ? `${left}초 후 default 가능` : '유예기간 경과';
  }
  if (key === 'default') return side.loan?.status === 4 ? `Debt ${fmt(side.debt)} · Cover ${fmt(side.cover)}` : 'default 미처리';
  return harnessed
    ? `Locked ${fmt(side.locked)} · 회수가능 ${fmt(side.withdrawable)}`
    : `Locked 없음 · 회수가능 ${fmt(side.withdrawable)}`;
}

export default function App() {
  const [deployment, setDeployment] = useState<DeploymentManifest | null>(null);
  const [walletProvider, setWalletProvider] = useState<BrowserProvider>();
  const [account, setAccount] = useState('');
  const [roles, setRoles] = useState<RoleAddresses | null>(null);
  const [baseline, setBaseline] = useState<SideState>(ZERO_SIDE);
  const [harness, setHarness] = useState<SideState>(ZERO_SIDE);
  const [policy, setPolicy] = useState<HarnessPolicy>(ZERO_POLICY);
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [busy, setBusy] = useState<StepKey | null>(null);
  const [deploying, setDeploying] = useState(false);
  const [deployStatus, setDeployStatus] = useState('');
  const [logs, setLogs] = useState<TxLog[]>([]);
  const [error, setError] = useState('');

  const contracts = useMemo(() => deployment ? contractSet(RPC_PROVIDER, deployment.addresses) : null, [deployment]);

  const refresh = useCallback(async () => {
    if (!contracts || !deployment || !roles) return;
    setRefreshing(true);
    try {
      const blockNumber = await RPC_PROVIDER.getBlockNumber();
      const block = await RPC_PROVIDER.getBlock(blockNumber);
      const at = { blockTag: blockNumber };

      const readSide = async (kind: Kind): Promise<SideState> => {
        const side = contracts[kind];
        const harnessed = kind === 'harness';
        const [assetsTotal, assetsAvailable, loss, debt, cover, minimumCover, effectiveRate, sequence, brokerVault, code] = await Promise.all([
          side.vault.assetsTotal(at), side.vault.assetsAvailable(at), side.vault.lossUnrealized(at),
          side.broker.debtTotal(at), side.broker.coverAvailable(at), side.broker.minimumCover(at),
          side.broker.effectiveCoverRateMinimum(at), side.broker.loanSequence(at),
          side.broker.vault(at), RPC_PROVIDER.getCode(await side.broker.getAddress(), blockNumber),
        ]);
        const shares = await side.vault.balanceOf(roles.depositor, at);
        const locked = harnessed ? await side.broker.lockedCover(at) : 0n;
        const withdrawable = harnessed
          ? await side.broker.withdrawableCover(at)
          : cover > minimumCover ? cover - minimumCover : 0n;

        let configuredBroker: string | null = null;
        try { configuredBroker = await side.vault.broker(at); } catch { configuredBroker = null; }

        let approval = false;
        if (validAddress(roles.borrower)) {
          const hash = await side.broker.hashLoanTerms(loanTerms(roles.borrower), at);
          approval = await side.broker.borrowerApprovals(hash, at);
        }

        const latest = sequence > 1n ? sequence - 1n : 0n;
        const loanId = latest;
        let loan: LoanView | null = null;
        if (loanId > 0n) {
          const raw = await side.broker.getLoan(loanId, at);
          if (Number(raw.status) !== 0) loan = {
            id: loanId,
            status: Number(raw.status),
            borrower: raw.borrower,
            principal: raw.principalOutstanding,
            dueAt: Number(raw.nextPaymentDueDate),
            defaultAt: Number(raw.nextPaymentDueDate) + Number(raw.gracePeriod) + 1,
          };
        }
        return {
          assetsTotal, assetsAvailable, loss, shares, debt, cover, minimumCover, effectiveRate,
          locked, withdrawable, approval, loan, configuredBroker,
          brokerPointsBack: brokerVault.toLowerCase() === (kind === 'baseline' ? deployment.addresses.baselineVault : deployment.addresses.harnessedVault).toLowerCase(),
          codePresent: code !== '0x',
        };
      };

      const [baseState, harnessState, policyState] = await Promise.all([
        readSide('baseline'),
        readSide('harness'),
        Promise.all([
          contracts.harness.broker.singleLoanLimitRate(at),
          contracts.harness.broker.borrowerLimitRate(at),
          contracts.harness.broker.debtFloor(at),
          contracts.harness.broker.recoveryPeriod(at),
          contracts.harness.broker.historyWindow(at),
          contracts.harness.broker.coverRateMinimum(at),
          contracts.harness.broker.coverRateLiquidation(at),
          contracts.harness.broker.coverRateFloor(at),
          contracts.harness.broker.historySlope(at),
        ]),
      ]);
      setBaseline(baseState);
      setHarness(harnessState);
      setPolicy({
        singleLoan: policyState[0],
        borrowerLimit: policyState[1],
        debtFloor: policyState[2],
        recoveryPeriod: policyState[3],
        historyWindow: policyState[4],
        coverRateMinimum: policyState[5],
        coverRateLiquidation: policyState[6],
        coverRateFloor: policyState[7],
        historySlope: policyState[8],
      });
      setSnapshot({ block: blockNumber, timestamp: Number(block?.timestamp || 0), readAt: Date.now() });
      setError('');
    } catch (e) {
      setError(`온체인 조회 실패: ${e instanceof Error ? e.message.slice(0, 300) : String(e)}`);
    } finally { setRefreshing(false); }
  }, [contracts, deployment, roles]);

  useEffect(() => {
    if (!window.ethereum) return;
    const next = new BrowserProvider(window.ethereum);
    setWalletProvider(next);
    void next.send('eth_accounts', []).then((accounts: string[]) => setAccount(accounts[0] || ''));
    const onAccounts = (...args: unknown[]) => setAccount(((args[0] as string[] | undefined)?.[0]) || '');
    const onChain = () => window.location.reload();
    window.ethereum.on('accountsChanged', onAccounts);
    window.ethereum.on('chainChanged', onChain);
    return () => {
      window.ethereum?.removeListener('accountsChanged', onAccounts);
      window.ethereum?.removeListener('chainChanged', onChain);
    };
  }, []);

  useEffect(() => {
    if (!account) {
      setDeployment(null);
      setRoles(null);
      return;
    }
    const wallets = roleWallets(account, RPC_PROVIDER);
    setRoles({ owner: wallets.owner.address, depositor: wallets.depositor.address, borrower: wallets.borrower.address });
    setDeployment(loadDeployment(account));
  }, [account]);

  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    if (!deployment) return;
    const id = window.setInterval(() => void refresh(), 15_000);
    return () => window.clearInterval(id);
  }, [deployment, refresh]);

  async function connect(forceChooser = false) {
    if (!window.ethereum) { setError('MetaMask가 필요합니다.'); return; }
    try {
      if (forceChooser) await window.ethereum.request({ method: 'wallet_requestPermissions', params: [{ eth_accounts: {} }] });
      const next = new BrowserProvider(window.ethereum);
      await next.send('eth_requestAccounts', []);
      if ((await next.getNetwork()).chainId !== CHAIN_ID) await next.send('wallet_switchEthereumChain', [{ chainId: '0xaa36a7' }]);
      setWalletProvider(next);
      setAccount(await (await next.getSigner()).getAddress());
    } catch (e) { setError(e instanceof Error ? e.message.slice(0, 300) : String(e)); }
  }

  async function recordTransaction(label: string, tx: TransactionResponse) {
    setLogs(old => [{ label, hash: tx.hash, status: 'mining' }, ...old]);
    try {
      const receipt = await tx.wait();
      setLogs(old => old.map(x => x.hash === tx.hash ? { ...x, status: 'confirmed', block: receipt?.blockNumber } : x));
    } catch (error) {
      setLogs(old => old.map(x => x.hash === tx.hash ? { ...x, status: 'error' } : x));
      throw error;
    }
  }

  async function transact(label: string, action: () => Promise<ContractTransactionResponse>) {
    const key = `${label}-${Date.now()}`;
    setLogs(old => [{ label: key, status: 'signing' }, ...old]);
    try {
      const tx = await action();
      setLogs(old => old.filter(x => x.label !== key));
      await recordTransaction(label, tx);
      await refresh();
    } catch (e) {
      setLogs(old => old.map(x => x.label === key || x.status === 'signing' ? { ...x, label, status: 'error' } : x));
      throw e;
    }
  }

  async function createEnvironment() {
    if (!walletProvider || !account) {
      setError('먼저 MetaMask를 연결하세요.');
      return;
    }
    setDeploying(true);
    setError('');
    setDeployStatus('임시 역할 지갑을 준비하고 있습니다.');
    try {
      const next = await deploySession(walletProvider, account, setDeployStatus, recordTransaction);
      setBaseline(ZERO_SIDE);
      setHarness(ZERO_SIDE);
      setPolicy(ZERO_POLICY);
      setSnapshot(null);
      setDeployment(next);
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      setError(message.toLowerCase().includes('user rejected') ? 'MetaMask에서 가스 충전을 취소했습니다.' : message.slice(0, 500));
    } finally {
      setDeploying(false);
    }
  }

  async function sweepGas() {
    if (!account) return;
    setDeploying(true);
    setError('');
    try {
      await sweepRoleGas(account, recordTransaction);
      setDeployStatus('임시 역할 지갑의 남은 ETH를 연결 지갑으로 회수했습니다.');
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 500) : String(e));
    } finally {
      setDeploying(false);
    }
  }

  async function run(step: StepKey) {
    if (!contracts || !roles || !account) return;
    setBusy(step); setError('');
    try {
      const wallets: RoleWallets = roleWallets(account, RPC_PROVIDER);
      const ownerToken = contracts.token.connect(wallets.owner) as Contract;
      const depositorToken = contracts.token.connect(wallets.depositor) as Contract;
      const depositorBv = contracts.baseline.vault.connect(wallets.depositor) as Contract;
      const depositorHv = contracts.harness.vault.connect(wallets.depositor) as Contract;
      const ownerBb = contracts.baseline.broker.connect(wallets.owner) as Contract;
      const ownerHb = contracts.harness.broker.connect(wallets.owner) as Contract;
      const borrowerBb = contracts.baseline.broker.connect(wallets.borrower) as Contract;
      const borrowerHb = contracts.harness.broker.connect(wallets.borrower) as Contract;

      if (step === 'setup') {
        await transact('예치자 B에게 2,000 MockUSDC 지급', () => ownerToken.mint(roles.depositor, USDC('2000')));
        await transact('Owner A에게 400 MockUSDC 지급', () => ownerToken.mint(roles.owner, USDC('400')));
        for (const [name, vault] of [['Baseline', depositorBv], ['Harness', depositorHv]] as const) {
          await transact(`${name} Vault 사용 승인`, async () => depositorToken.approve(await vault.getAddress(), USDC('1000')));
          await transact(`${name} Vault에 B의 1,000 예치`, () => vault.deposit(USDC('1000'), roles.depositor));
        }
        for (const [name, broker] of [['Baseline', ownerBb], ['Harness', ownerHb]] as const) {
          await transact(`${name} Broker 사용 승인`, async () => ownerToken.approve(await broker.getAddress(), USDC('200')));
          await transact(`${name} Broker에 Cover 200 예치`, () => broker.coverDeposit(USDC('200')));
        }
      }
      if (step === 'approve') {
        if (!baseline.approval) await transact('Baseline 대출조건 승인', () => borrowerBb.approveLoanTerms(loanTerms(roles.borrower)));
        if (!harness.approval) await transact('Harness 대출조건 승인', () => borrowerHb.approveLoanTerms(loanTerms(roles.borrower)));
      }
      if (step === 'issue') {
        if (!baseline.loan) {
          await transact('Baseline Loan 실행', () => ownerBb.loanSet(loanTerms(roles.borrower)));
        }
        if (!harness.loan) {
          await transact('Harness Loan 실행', () => ownerHb.loanSet(loanTerms(roles.borrower)));
        }
      }
      if (step === 'default') {
        if (baseline.loan?.status !== 4) await transact('Baseline Loan default', () => ownerBb.defaultLoan(baseline.loan?.id));
        if (harness.loan?.status !== 4) await transact('Harness Loan default', () => ownerHb.defaultLoan(harness.loan?.id));
      }
      if (step === 'recover') {
        if (baseline.withdrawable > 0n) await transact('Baseline 회수 가능 Cover 전액 출금', () => ownerBb.coverWithdraw(baseline.withdrawable, roles.owner));
        if (harness.withdrawable > 0n) await transact('Harness가 허용한 Cover만 출금', () => ownerHb.coverWithdraw(harness.withdrawable, roles.owner));
      }
      await refresh();
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      setError(message.toLowerCase().includes('user rejected') ? 'MetaMask에서 거래를 취소했습니다.' : message.slice(0, 360));
    } finally { setBusy(null); }
  }

  const chainTime = snapshot?.timestamp || Math.floor(Date.now() / 1000);
  const stages: { key: StepKey; n: string; title: string; role: string; tx: string; explanation: string }[] = [
    { key: 'setup', n: '01', title: '유동성과 공탁금 준비', role: '예치자 B · Owner A', tx: '자동 서명 10회', explanation: 'B가 각 Vault에 1,000을 예치하고 A가 각 Broker에 Cover 200을 넣습니다.' },
    { key: 'approve', n: '02', title: '대출 조건 동의', role: '차주 C', tx: '자동 서명 2회', explanation: 'C의 임시지갑이 양쪽의 동일한 500 대출 조건에 온체인으로 동의합니다.' },
    { key: 'issue', n: '03', title: '동일한 대출 실행', role: 'Owner A', tx: '자동 서명 2회', explanation: 'A의 임시지갑이 두 Vault에서 각각 500을 C에게 보내고 Debt를 생성합니다.' },
    { key: 'wait', n: '04', title: '만기와 유예기간 경과', role: '체인 시간', tx: '서명 없음', explanation: '다음 납부기한과 grace period가 지나야 default가 가능합니다.' },
    { key: 'default', n: '05', title: '양쪽 Default 처리', role: 'Owner A', tx: '자동 서명 2회', explanation: '동일한 부실을 처리하고 Cover와 B의 Vault 손실 변화를 체인에서 읽습니다.' },
    { key: 'recover', n: '06', title: 'A의 Cover 회수 비교', role: 'Owner A', tx: '자동 서명 최대 2회', explanation: 'Baseline은 남은 Cover를 회수하지만 Harness는 default 관련 금액을 잠급니다.' },
  ];
  const actionEnabled = (key: StepKey) => {
    if (busy || deploying || !deployment || !roles) return false;
    if (key === 'setup') return !(baseline.assetsTotal > 0n || harness.assetsTotal > 0n);
    if (key === 'approve') return !(baseline.approval && harness.approval);
    if (key === 'issue') return baseline.approval && harness.approval && !(baseline.loan && harness.loan);
    if (key === 'default') return !!baseline.loan && !!harness.loan && chainTime > baseline.loan.defaultAt && chainTime > harness.loan.defaultAt && !(baseline.loan.status === 4 && harness.loan.status === 4);
    if (key === 'recover') return baseline.withdrawable > 0n || harness.withdrawable > 0n;
    return false;
  };

  if (!deployment) return <main className="manifest-loading">
    <nav>
      <div className="brand"><span>⅙</span><div><b>SIXTH SENSE</b><small>XLS-65/66 · SEPOLIA</small></div></div>
      <div className="wallet"><span className={account ? 'online' : ''} />{account ? short(account) : '지갑 미연결'}
        <button onClick={() => void connect(Boolean(account))}>{account ? '계정 전환' : '지갑 연결'}</button></div>
    </nav>
    <section className="hero">
      <div><span className="kicker">XRPL LENDING STANDARD · EVM IMPLEMENTATION</span><h1>XLS-65/66 EVM 포팅</h1>
        <p className="hero-subtitle">기존 대출 구조 vs 예치자 보호 Harness</p>
        <p className="hero-description">MetaMask는 임시 Owner의 잔액을 0.05 Sepolia ETH까지 채우는 한 건만 확인합니다. 이후 컨트랙트 배포와 역할별 거래는 브라우저가 생성한 테스트 지갑이 자동 서명합니다.</p></div>
    </section>
    <section className="scenario environment-setup">
      <header><div><span className="eyebrow">PER-BROWSER SEPOLIA ENVIRONMENT</span><h2>새 비교 환경 만들기</h2>
        <p>공개 RPC를 사용하며 API 키나 서버 비밀값을 브라우저에 넣지 않습니다.</p></div></header>
      {roles && <div className="rolebox">
        <label>자동 생성 역할 지갑</label>
        <div><small>Owner A · 관리자/심사/공탁</small><b>{roles.owner}</b><small>브라우저 자동 서명</small></div>
        <div><small>Depositor B / Borrower C</small><b>{short(roles.depositor)} · {short(roles.borrower)}</b><small>브라우저 자동 서명</small></div>
      </div>}
      <p className="reading">RPC · {PUBLIC_RPC_URL}<br />역할 개인키와 배포 주소는 이 브라우저의 localStorage에만 저장됩니다. 실제 자산을 보내지 마세요.</p>
      <button onClick={() => account ? void createEnvironment() : void connect()} disabled={deploying}>
        {deploying ? '배포 중…' : account ? 'MetaMask 1회 확인 후 배포' : '먼저 지갑 연결'}
      </button>
      {deployStatus && <p className="reading">{deployStatus}</p>}
      {error && <div className="error">{error}</div>}
    </section>
    <section className="log"><header><div><span className="eyebrow">TRANSACTION RECEIPTS</span><h3>배포 거래</h3></div></header>
      {logs.length === 0 ? <p>아직 전송한 거래가 없습니다.</p> : logs.map((log, i) => <div key={`${log.hash || log.label}-${i}`}>
        <span className={log.status}>{log.status === 'mining' ? '채굴 중' : log.status === 'confirmed' ? '반영 완료' : log.status === 'error' ? '실패' : '자동 서명'}</span>
        <b>{log.label}</b>{log.block && <small>block #{log.block.toLocaleString()}</small>}
        {log.hash && <a href={explorer(log.hash)} target="_blank">{short(log.hash)} ↗</a>}</div>)}
    </section>
  </main>;

  const addresses = deployment.addresses;

  return <main>
    <nav>
      <div className="brand"><span>⅙</span><div><b>SIXTH SENSE</b><small>XLS-65/66 · SEPOLIA</small></div></div>
      <div className="wallet"><span className={account ? 'online' : ''} />{account ? short(account) : '지갑 미연결'}
        <button onClick={() => void createEnvironment()} disabled={deploying}>{deploying ? '배포 중…' : '새 환경 배포'}</button>
        <button onClick={() => void sweepGas()} disabled={deploying}>가스 회수</button>
        <button onClick={() => void connect(Boolean(account))}>{account ? '계정 전환' : '지갑 연결'}</button></div>
    </nav>

    <section className="hero">
      <div><span className="kicker">XRPL LENDING STANDARD · EVM IMPLEMENTATION</span><h1>XLS-65/66 EVM 포팅</h1>
        <p className="hero-subtitle">기존 대출 구조 vs 예치자 보호 Harness</p>
        <p className="hero-description">기존 XLS-66과 보완된 LoanBroker를 동일 조건으로 실행하고, 예치자 B를 보호하는 차이가 실제 Sepolia 상태에 어떻게 남는지 단계별로 확인합니다.</p></div>
    </section>

    <section className={`chain-proof ${snapshot ? 'live' : ''}`}>
      <div className="proof-title"><span className="pulse" /><div><b>{snapshot ? 'Sepolia에서 직접 읽은 데이터' : '온체인 연결 대기 중'}</b>
        <small>{snapshot ? `공개 RPC eth_call · block #${snapshot.block.toLocaleString()} · ${new Date(snapshot.readAt).toLocaleTimeString('ko-KR')}` : '브라우저 세션의 배포 컨트랙트 getter를 조회합니다.'}</small></div></div>
      <div className="proof-contracts">
        <a href={explorer(addresses.baselineVault)} target="_blank">Baseline Vault {short(addresses.baselineVault)} ↗</a>
        <a href={explorer(addresses.harnessedVault)} target="_blank">Harness Vault {short(addresses.harnessedVault)} ↗</a>
      </div>
      <button onClick={() => void refresh()} disabled={refreshing}>{refreshing ? '읽는 중…' : '지금 다시 읽기'}</button>
    </section>

    <section className="difference">
      <span>현재 체인에서 확인되는 핵심 차이</span>
      <strong>{harness.locked > 0n
        ? baseline.cover === 0n
          ? `Baseline은 남은 Cover를 이미 전부 회수했지만, Harness에는 A의 Cover ${fmt(harness.locked)}가 잠겨 있습니다.`
          : `Harness는 A의 Cover ${fmt(harness.locked)}를 잠갔고, Baseline은 ${fmt(baseline.withdrawable)}를 지금 회수할 수 있습니다.`
        : baseline.debt > 0n || harness.debt > 0n
          ? `현재 CRM은 Baseline ${percent(baseline.effectiveRate)}, Harness ${percent(harness.effectiveRate)}입니다.`
          : '시나리오를 실행하면 두 경로의 Debt, 손실, Cover 회수 가능액을 같은 블록에서 비교합니다.'}</strong>
    </section>

    <section className="comparison">
      <ProtocolCard kind="baseline" state={baseline} policy={policy} expectedBroker={addresses.baselineBroker} />
      <div className="versus">VS</div>
      <ProtocolCard kind="harness" state={harness} policy={policy} expectedBroker={addresses.harnessedBroker} />
    </section>

    <section className="scenario">
      <header><div><span className="eyebrow">CHAIN-DERIVED WALKTHROUGH</span><h2>단계별 실행과 온체인 판정</h2>
        <p>초록색 ‘체인 확인’은 버튼 클릭 여부가 아니라 현재 컨트랙트 상태로 판정합니다.</p></div></header>
      <div className="rolebox"><label>브라우저 자동 서명 역할</label>
        <div><small>Owner A · 관리자/심사/공탁</small><b>{roles?.owner || '—'}</b><small>Depositor B · {roles ? short(roles.depositor) : '—'}</small></div>
        <div><small>Borrower C · 대출 조건 승인</small><b>{roles?.borrower || '—'}</b><small>MetaMask 추가 확인 없음</small></div>
      </div>

      <div className="stage-table">
        <div className="stage-header"><span>단계 / 의미</span><span>기존 XLS-66</span><span>Harness 적용</span><span>실행</span></div>
        {stages.map(stage => {
          const baseStatus = stageStatus(stage.key, baseline, chainTime, false);
          const harnessStatus = stageStatus(stage.key, harness, chainTime, true);
          return <div className="stage-row" key={stage.key}>
            <div className="stage-info"><span>{stage.n}</span><div><b>{stage.title}</b><small>{stage.role} · {stage.tx}</small><p>{stage.explanation}</p></div></div>
            <div className="stage-side"><Pill status={baseStatus} /><b>{stageEvidence(stage.key, baseline, chainTime, false)}</b></div>
            <div className="stage-side harness-side"><Pill status={harnessStatus} /><b>{stageEvidence(stage.key, harness, chainTime, true)}</b></div>
            <div className="stage-action">{stage.key === 'wait' ? <span>자동 판정</span> : <button disabled={!actionEnabled(stage.key)} onClick={() => void run(stage.key)}>{busy === stage.key ? '처리 중…' : '실행'}</button>}</div>
          </div>;
        })}
      </div>
      {error && <div className="error">{error}</div>}
    </section>

    <section className="explain-grid">
      <div><span>01</span><b>분리된 역할</b><p>A는 Vault Owner·심사자·Cover 제공자이고, B는 독립 예치자, C는 독립 차주입니다. 각 임시지갑이 실제 거래를 자동 서명합니다.</p></div>
      <div><span>02</span><b>기존 구조의 한계</b><p>Default 후 Debt가 0이 되면 Required Cover도 0이 되어 A가 남은 Cover를 즉시 회수할 수 있습니다.</p></div>
      <div><span>03</span><b>Harness의 보완</b><p>대출 집중도를 제한하고, 부실 이력으로 CRM을 높이며, default 관련 Cover를 일정 기간 잠급니다.</p></div>
    </section>

    <section className="log"><header><div><span className="eyebrow">TRANSACTION RECEIPTS</span><h3>거래와 반영 블록</h3></div></header>
      {logs.length === 0 ? <p>이 브라우저 세션에서 전송한 거래가 없습니다.</p> : logs.map((log, i) => <div key={`${log.hash || log.label}-${i}`}>
        <span className={log.status}>{log.status === 'signing' ? '자동 서명' : log.status === 'mining' ? '채굴 중' : log.status === 'confirmed' ? '반영 완료' : '실패'}</span>
        <b>{log.label}</b>{log.block && <small>block #{log.block.toLocaleString()}</small>}
        {log.hash && <a href={explorer(log.hash)} target="_blank">{short(log.hash)} ↗</a>}</div>)}
    </section>
    <footer><span>Experimental · Not audited · Sepolia only · public RPC</span><code>Token {short(addresses.token)}</code></footer>
  </main>;
}
