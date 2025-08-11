#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/api_common.sh"

PROMPT=${PROMPT:-"A beautiful landscape with mountains and lakes"}
WIDTH=${WIDTH:-512}
HEIGHT=${HEIGHT:-512}
STEPS=${STEPS:-50}
GUIDANCE=${GUIDANCE:-7.5}
SEED=${SEED:-}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt) PROMPT="$2"; shift 2;;
    --width) WIDTH="$2"; shift 2;;
    --height) HEIGHT="$2"; shift 2;;
    --steps) STEPS="$2"; shift 2;;
    --guidance) GUIDANCE="$2"; shift 2;;
    --seed) SEED="$2"; shift 2;;
    *) log_error "Flag desconhecida: $1"; exit 1;;
  esac
done

log_step "Obtendo token..."
token=$(get_token)

log_step "Criando requisição de imagem..."
payload=$(jq -n \
  --arg prompt "$PROMPT" \
  --argjson width "$WIDTH" \
  --argjson height "$HEIGHT" \
  --argjson steps "$STEPS" \
  --argjson guidance "$GUIDANCE" \
  --arg seed "${SEED:-}" \
  '{prompt:$prompt,width:$width,height:$height,num_inference_steps:$steps,guidance_scale:$guidance} + ( ($seed|length>0)? {seed: ($seed|tonumber)} : {} )'
) || payload=$(python3 - <<PY
import json, os
prompt=os.environ.get('PROMPT')
width=int(os.environ.get('WIDTH'))
height=int(os.environ.get('HEIGHT'))
steps=int(os.environ.get('STEPS'))
guidance=float(os.environ.get('GUIDANCE'))
seed=os.environ.get('SEED')
data=dict(prompt=prompt,width=width,height=height,num_inference_steps=steps,guidance_scale=guidance)
if seed:
    data['seed']=int(seed)
print(json.dumps(data))
PY
)

create_resp=$(curl -sS -X POST "$API_URL/generate-image" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $token" \
  -d "$payload")

echo "$create_resp" | (command -v jq >/dev/null 2>&1 && jq || cat)

task_id=$(json_get "$create_resp" '.task_id' || echo '')
if [ -z "$task_id" ]; then
  log_error "Não foi possível obter task_id"
  exit 1
fi

log_step "Aguardando conclusão da tarefa $task_id..."
poll_task_until_done "$token" "$task_id" >/dev/null

outfile="$OUTPUT_DIR/${task_id}.png"
download_result "$token" "$task_id" "$outfile"
echo "$outfile"


