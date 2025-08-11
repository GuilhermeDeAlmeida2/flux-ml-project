#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/api_common.sh"

log_step "Health check em $API_URL/health"
curl -sS "$API_URL/health" | (command -v jq >/dev/null 2>&1 && jq || cat)


