import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const broadcastPath = resolve('../broadcast/DeploySepolia.s.sol/11155111/run-latest.json');
const outputPath = resolve('public/deployment.json');
const run = JSON.parse(readFileSync(broadcastPath, 'utf8'));

const created = run.transactions.filter((transaction) => transaction.transactionType === 'CREATE');
const named = (contractName, occurrence = 0) => {
  const matches = created.filter((transaction) => transaction.contractName === contractName);
  const address = matches[occurrence]?.contractAddress;
  if (!address) throw new Error(`Missing ${contractName} deployment #${occurrence + 1}`);
  return address;
};

const manifest = {
  chainId: Number(run.chain),
  deployedAt: new Date(Number(run.timestamp)).toISOString(),
  addresses: {
    token: named('MockUSDC'),
    baselineVault: named('XLS65Vault', 0),
    baselineBroker: named('XLS66LoanBroker'),
    harnessedVault: named('XLS65Vault', 1),
    harnessedBroker: named('XLS66LoanBrokerHarness'),
  },
};

if (manifest.chainId !== 11_155_111) throw new Error(`Unexpected chain ID ${manifest.chainId}`);
writeFileSync(outputPath, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`Updated ${outputPath}`);
console.log(JSON.stringify(manifest.addresses, null, 2));
