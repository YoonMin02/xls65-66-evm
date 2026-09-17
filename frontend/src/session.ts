import {
  BrowserProvider,
  Contract,
  ContractFactory,
  JsonRpcProvider,
  Wallet,
  parseEther,
  type TransactionResponse,
} from 'ethers';
import artifacts from './artifacts.json';
import { CHAIN_ID, PUBLIC_RPC_URL, type DeploymentManifest } from './config';

export type RoleKeys = {
  owner: string;
  depositor: string;
  borrower: string;
};

export type RoleWallets = {
  owner: Wallet;
  depositor: Wallet;
  borrower: Wallet;
};

export type TxReporter = (label: string, tx: TransactionResponse) => Promise<void>;
export type ProgressReporter = (message: string) => void;

const OWNER_GAS_TARGET = parseEther('0.05');
const PARTICIPANT_GAS_TARGET = parseEther('0.003');
const USDC = 10n ** 6n;

const walletKey = (funder: string) => `xls66:auto:wallets:${funder.toLowerCase()}`;
const deploymentKey = (funder: string) => `xls66:auto:deployment:${funder.toLowerCase()}`;

export function publicProvider() {
  return new JsonRpcProvider(PUBLIC_RPC_URL, Number(CHAIN_ID), { staticNetwork: true });
}

export function loadRoleKeys(funder: string): RoleKeys | null {
  const value = localStorage.getItem(walletKey(funder));
  return value ? JSON.parse(value) as RoleKeys : null;
}

export function ensureRoleKeys(funder: string): RoleKeys {
  const existing = loadRoleKeys(funder);
  if (existing) return existing;
  const keys: RoleKeys = {
    owner: Wallet.createRandom().privateKey,
    depositor: Wallet.createRandom().privateKey,
    borrower: Wallet.createRandom().privateKey,
  };
  localStorage.setItem(walletKey(funder), JSON.stringify(keys));
  return keys;
}

export function roleWallets(funder: string, provider: JsonRpcProvider): RoleWallets {
  const keys = ensureRoleKeys(funder);
  return {
    owner: new Wallet(keys.owner, provider),
    depositor: new Wallet(keys.depositor, provider),
    borrower: new Wallet(keys.borrower, provider),
  };
}

export function loadDeployment(funder: string): DeploymentManifest | null {
  const value = localStorage.getItem(deploymentKey(funder));
  if (!value) return null;
  const deployment = JSON.parse(value) as DeploymentManifest;
  return BigInt(deployment.chainId) === CHAIN_ID ? deployment : null;
}

async function deployContract(
  factory: ContractFactory,
  label: string,
  args: readonly unknown[],
  report: TxReporter,
) {
  const contract = await factory.deploy(...args);
  const tx = contract.deploymentTransaction();
  if (!tx) throw new Error(`${label} 배포 트랜잭션을 만들지 못했습니다.`);
  await report(label, tx);
  return contract;
}

export async function deploySession(
  browserProvider: BrowserProvider,
  funder: string,
  progress: ProgressReporter,
  report: TxReporter,
): Promise<DeploymentManifest> {
  const network = await browserProvider.getNetwork();
  if (network.chainId !== CHAIN_ID) {
    await browserProvider.send('wallet_switchEthereumChain', [{ chainId: '0xaa36a7' }]);
  }

  const provider = publicProvider();
  const roles = roleWallets(funder, provider);
  const ownerBalance = await provider.getBalance(roles.owner.address);
  if (ownerBalance < OWNER_GAS_TARGET) {
    progress('MetaMask에서 임시 Owner의 가스 충전 1건을 확인하세요.');
    const signer = await browserProvider.getSigner();
    const tx = await signer.sendTransaction({
      to: roles.owner.address,
      value: OWNER_GAS_TARGET - ownerBalance,
    });
    await report('MetaMask → 임시 Owner 가스 충전', tx);
  }

  progress('임시 Owner가 비교용 컨트랙트 5개를 배포하고 있습니다.');
  const token = await deployContract(
    new ContractFactory(artifacts.token.abi, artifacts.token.bytecode, roles.owner),
    'MockUSDC 배포',
    [],
    report,
  );
  const tokenAddress = await token.getAddress();

  const baselineVault = await deployContract(
    new ContractFactory(artifacts.vault.abi, artifacts.vault.bytecode, roles.owner),
    'Baseline Vault 배포',
    [tokenAddress, 'XLS-65 Baseline USDC Vault', 'bvUSDC', 6, 0, false, true],
    report,
  );
  const baselineVaultAddress = await baselineVault.getAddress();
  const baselineBroker = await deployContract(
    new ContractFactory(artifacts.broker.abi, artifacts.broker.bytecode, roles.owner),
    'Baseline Broker 배포',
    [baselineVaultAddress, 1_000, 0, 10_000, 10_000],
    report,
  );
  const baselineBrokerAddress = await baselineBroker.getAddress();
  await report('Baseline Vault–Broker 영구 연결', await (baselineVault as Contract).bindBroker(baselineBrokerAddress));

  const harnessedVault = await deployContract(
    new ContractFactory(artifacts.vault.abi, artifacts.vault.bytecode, roles.owner),
    'Harness Vault 배포',
    [tokenAddress, 'XLS-65 Harnessed USDC Vault', 'hvUSDC', 6, 0, false, true],
    report,
  );
  const harnessedVaultAddress = await harnessedVault.getAddress();
  const harnessedBroker = await deployContract(
    new ContractFactory(artifacts.harness.abi, artifacts.harness.bytecode, roles.owner),
    'Harness Broker 배포',
    [
      harnessedVaultAddress,
      1_000,
      0,
      10_000,
      10_000,
      20_000,
      30_000,
      2_500n * USDC,
      30n * 24n * 60n * 60n,
      365n * 24n * 60n * 60n,
      10_000,
      20_000,
    ],
    report,
  );
  const harnessedBrokerAddress = await harnessedBroker.getAddress();
  await report('Harness Vault–Broker 영구 연결', await (harnessedVault as Contract).bindBroker(harnessedBrokerAddress));

  progress('예치자와 차주의 자동 거래용 가스를 준비하고 있습니다.');
  for (const [name, wallet] of [['예치자', roles.depositor], ['차주', roles.borrower]] as const) {
    const balance = await provider.getBalance(wallet.address);
    if (balance < PARTICIPANT_GAS_TARGET) {
      await report(`${name} 임시지갑 가스 충전`, await roles.owner.sendTransaction({
        to: wallet.address,
        value: PARTICIPANT_GAS_TARGET - balance,
      }));
    }
  }

  const deployment: DeploymentManifest = {
    chainId: Number(CHAIN_ID),
    deployedAt: new Date().toISOString(),
    funder,
    addresses: {
      token: tokenAddress,
      baselineVault: baselineVaultAddress,
      baselineBroker: baselineBrokerAddress,
      harnessedVault: harnessedVaultAddress,
      harnessedBroker: harnessedBrokerAddress,
    },
  };
  localStorage.setItem(deploymentKey(funder), JSON.stringify(deployment));
  progress('새 비교 환경 배포가 완료되었습니다.');
  return deployment;
}

export async function sweepRoleGas(funder: string, report: TxReporter): Promise<void> {
  const provider = publicProvider();
  const roles = roleWallets(funder, provider);
  const fee = await provider.getFeeData();
  const gasPrice = fee.maxFeePerGas ?? fee.gasPrice ?? 2n * 10n ** 9n;
  const reserve = gasPrice * 21_000n * 2n;
  for (const [name, wallet] of Object.entries(roles) as Array<[keyof RoleWallets, Wallet]>) {
    const balance = await provider.getBalance(wallet.address);
    if (balance > reserve) {
      await report(`${name} 남은 가스 회수`, await wallet.sendTransaction({
        to: funder,
        value: balance - reserve,
        gasLimit: 21_000,
      }));
    }
  }
}
