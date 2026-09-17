import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../..');
const targets = {
  token: 'out/MockUSDC.sol/MockUSDC.json',
  vault: 'out/XLS65Vault.sol/XLS65Vault.json',
  broker: 'out/XLS66LoanBroker.sol/XLS66LoanBroker.json',
  harness: 'out/XLS66LoanBrokerHarness.sol/XLS66LoanBrokerHarness.json',
};

const artifacts = Object.fromEntries(Object.entries(targets).map(([name, relative]) => {
  const source = JSON.parse(readFileSync(resolve(root, relative), 'utf8'));
  const object = source.bytecode.object;
  return [name, { abi: source.abi, bytecode: object.startsWith('0x') ? object : `0x${object}` }];
}));

writeFileSync(resolve(root, 'frontend/src/artifacts.json'), `${JSON.stringify(artifacts)}\n`);
console.log('Frontend deployment artifacts updated.');
