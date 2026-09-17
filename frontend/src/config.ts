export const CHAIN_ID = 11_155_111n;
export const PUBLIC_RPC_URL = 'https://ethereum-sepolia-rpc.publicnode.com';

export type DeploymentAddresses = {
  token: string;
  baselineVault: string;
  baselineBroker: string;
  harnessedVault: string;
  harnessedBroker: string;
};

export type DeploymentManifest = {
  chainId: number;
  deployedAt: string;
  funder: string;
  addresses: DeploymentAddresses;
};

export const explorer = (addressOrHash: string) => `https://sepolia.etherscan.io/${
  addressOrHash.length === 66 ? 'tx' : 'address'
}/${addressOrHash}`;
