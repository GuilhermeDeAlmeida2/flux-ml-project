#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/api_common.sh"

log_step "Obtendo token JWT em $API_URL/auth/token"
token=$(get_token)
echo "$token"


