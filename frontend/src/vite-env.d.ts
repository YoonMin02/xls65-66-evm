/// <reference types="vite/client" />

interface Window {
  ethereum?: import('ethers').Eip1193Provider & {
    on(event: 'accountsChanged' | 'chainChanged', listener: (...args: unknown[]) => void): void;
    removeListener(event: 'accountsChanged' | 'chainChanged', listener: (...args: unknown[]) => void): void;
  };
}
