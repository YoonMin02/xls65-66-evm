// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {XLS65Vault} from "../src/XLS65Vault.sol";
import {XLS66LoanBroker} from "../src/XLS66LoanBroker.sol";
import {XLS66LoanBrokerHarness} from "../src/XLS66LoanBrokerHarness.sol";

/// @notice Deploys isolated baseline and harnessed XLS-65/66 environments.
contract DeploySepolia is Script {
    uint256 private constant USDC = 1e6;
    uint256 private constant SEPOLIA_CHAIN_ID = 11_155_111;

    error WrongChain(uint256 actualChainId);

    function run() external {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 debtFloor = vm.envOr("HARNESS_DEBT_FLOOR", uint256(1_000_000 * USDC));
        uint64 recoveryPeriod = uint64(vm.envOr("HARNESS_RECOVERY_PERIOD", uint256(30 days)));
        uint64 historyWindow = uint64(vm.envOr("HARNESS_HISTORY_WINDOW", uint256(365 days)));

        vm.startBroadcast();

        MockUSDC mockUSDC = new MockUSDC();

        XLS65Vault baselineVault = new XLS65Vault(mockUSDC, "XLS-65 Baseline USDC Vault", "bvUSDC", 6, 0, false, true);
        XLS66LoanBroker baselineBroker = new XLS66LoanBroker(
            baselineVault,
            1_000, // 1% management fee
            0, // unlimited debt maximum
            10_000, // 10% minimum cover rate
            10_000 // 10% liquidation rate
        );
        baselineVault.bindBroker(address(baselineBroker));

        XLS65Vault harnessedVault = new XLS65Vault(mockUSDC, "XLS-65 Harnessed USDC Vault", "hvUSDC", 6, 0, false, true);
        XLS66LoanBrokerHarness harnessedBroker = new XLS66LoanBrokerHarness(
            harnessedVault,
            1_000, // 1% management fee
            0, // unlimited debt maximum
            10_000, // broker-set CRM: 10%
            10_000, // liquidation rate: 10%
            20_000, // single loan limit: 20%
            30_000, // borrower aggregate limit: 30%
            debtFloor,
            recoveryPeriod,
            historyWindow,
            10_000, // history-linked CRM floor: 10%
            20_000 // 100% default rate adds 20 percentage points
        );
        harnessedVault.bindBroker(address(harnessedBroker));

        vm.stopBroadcast();

        console2.log("chainId", block.chainid);
        console2.log("MockUSDC", address(mockUSDC));
        console2.log("BaselineVault", address(baselineVault));
        console2.log("BaselineBroker", address(baselineBroker));
        console2.log("HarnessedVault", address(harnessedVault));
        console2.log("HarnessedBroker", address(harnessedBroker));
    }
}
