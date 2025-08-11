#!/usr/bin/env bash

set -euo pipefail

# Configurações padrão (podem ser sobrescritas via env ou flags dos scripts)
API_URL=${API_URL:-http://localhost:5000}
API_KEY=${API_KEY:-flux-api-key-demo}
OUTPUT_DIR=${OUTPUT_DIR:-outputs}
POLL_INTERVAL=${POLL_INTERVAL:-5}
POLL_TIMEOUT=${POLL_TIMEOUT:-600}

mkdir -p "$OUTPUT_DIR"

_color_green='\033[0;32m'
_color_yellow='\033[1;33m'
_color_red='\033[0;31m'
_color_blue='\033[0;34m'
_color_reset='\033[0m'

log_info()  { echo -e "${_color_green}[INFO]${_color_reset} $*"; }
log_warn()  { echo -e "${_color_yellow}[WARN]${_color_reset} $*"; }
log_error() { echo -e "${_color_red}[ERROR]${_color_reset} $*" 1>&2; }
log_step()  { echo -e "${_color_blue}[STEP]${_color_reset} $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log_error "Dependência ausente: $1";
    exit 1;
  }
}

# Extrai valor de JSON. Tenta jq; fallback em Python (presente no macOS)
json_get() {
  local json="$1" path="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -er "$path"
  else
    python3 - "$path" << 'PY'
import sys, json
path = sys.argv[1]
doc = json.load(sys.stdin)
def walk(obj, tokens):
    cur = obj
    for t in tokens:
        if t == '.':
            continue
        if isinstance(cur, dict):
            cur = cur.get(t)
        elif isinstance(cur, list):
            try:
                cur = cur[int(t)]
            except Exception:
                cur = None
        else:
            cur = None
        if cur is None:
            return None
    return cur
tokens = [t for t in path.strip().split('.') if t]
val = walk(doc, tokens)
if val is None:
    sys.exit(1)
if isinstance(val, (dict, list)):
    print(json.dumps(val))
else:
    print(val)
PY
  fi
}

get_token() {
  need_cmd curl
  local payload
  payload=$(printf '{"api_key": "%s"}' "$API_KEY")
  local resp
  resp=$(curl -sS -X POST "$API_URL/auth/token" \
    -H "Content-Type: application/json" \
    -d "$payload")
  if echo "$resp" | grep -q 'access_token'; then
    json_get "$resp" '.access_token' || {
      log_error "Falha ao extrair token do JSON"; echo ""; return 1;
    }
  else
    log_error "Falha na autenticação. Resposta: $resp"
    echo ""
    return 1
  fi
}

poll_task_until_done() {
  # Args: token task_id
  need_cmd curl
  local token="$1" task_id="$2" start_ts now_ts elapsed status
  start_ts=$(date +%s)
  while true; do
    now_ts=$(date +%s) || true
    elapsed=$(( now_ts - start_ts ))
    if [ "$elapsed" -ge "$POLL_TIMEOUT" ]; then
      log_error "Timeout ao aguardar tarefa $task_id (>${POLL_TIMEOUT}s)"
      return 124
    fi
    local resp
    resp=$(curl -sS -H "Authorization: Bearer $token" "$API_URL/task/$task_id/status") || resp='{}'
    status=$(json_get "$resp" '.status' || echo '')
    if [ "$status" = "completed" ]; then
      log_info "Tarefa $task_id concluída"
      echo "$resp"
      return 0
    elif [ "$status" = "failed" ]; then
      log_error "Tarefa $task_id falhou: $resp"
      return 2
    else
      log_step "Aguardando tarefa ($task_id) - status: ${status:-desconhecido} ..."
      sleep "$POLL_INTERVAL"
    fi
  done
}

download_result() {
  # Args: token task_id output_file
  need_cmd curl
  local token="$1" task_id="$2" outfile="$3"
  curl -sS -H "Authorization: Bearer $token" -o "$outfile" "$API_URL/task/$task_id/result"
  if [ -s "$outfile" ]; then
    log_info "Resultado salvo em: $outfile"
  else
    log_error "Falha ao baixar resultado para $task_id"
    return 1
  fi
}


