#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOUNDRY_ACCOUNT_NAME="${FOUNDRY_ACCOUNT_NAME:-sepolia-deployer}"

cd "$PROJECT_DIR"
set -a
source .env
set +a

forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --account "$FOUNDRY_ACCOUNT_NAME" \
  --broadcast \
  --slow \
  -vv

cd frontend
npm run sync:deployment

echo "Deployment manifest updated. Reload the frontend."
