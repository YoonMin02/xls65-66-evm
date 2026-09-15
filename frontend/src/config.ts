export const CHAIN_ID = 11_155_111n;
export const DEPLOYER = '0x81c2c42bd4a2a5f08f70e4e69e7edf790a815cdc';
export const DEPLOYMENT_MANIFEST = '/deployment.json';

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
  addresses: DeploymentAddresses;
};

export const explorer = (addressOrHash: string) => `https://sepolia.etherscan.io/${
  addressOrHash.length === 66 ? 'tx' : 'address'
}/${addressOrHash}`;
