#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/api_common.sh"

PROMPT=${PROMPT:-"A flowing river through a forest"}
DURATION=${DURATION:-5}
WIDTH=${WIDTH:-512}
HEIGHT=${HEIGHT:-512}
FPS=${FPS:-24}
SEED=${SEED:-}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt) PROMPT="$2"; shift 2;;
    --duration) DURATION="$2"; shift 2;;
    --width) WIDTH="$2"; shift 2;;
    --height) HEIGHT="$2"; shift 2;;
    --fps) FPS="$2"; shift 2;;
    --seed) SEED="$2"; shift 2;;
    *) log_error "Flag desconhecida: $1"; exit 1;;
  esac
done

token=$(get_token)

log_step "Solicitando geração de vídeo..."
payload=$(jq -n \
  --arg prompt "$PROMPT" \
  --argjson duration "$DURATION" \
  --argjson width "$WIDTH" \
  --argjson height "$HEIGHT" \
  --argjson fps "$FPS" \
  --arg seed "${SEED:-}" \
  '{prompt:$prompt,duration:$duration,width:$width,height:$height,fps:$fps} + ( ($seed|length>0)? {seed: ($seed|tonumber)} : {} )'
) || payload=$(python3 - <<PY
import json, os
prompt=os.environ.get('PROMPT')
duration=float(os.environ.get('DURATION'))
width=int(os.environ.get('WIDTH'))
height=int(os.environ.get('HEIGHT'))
fps=int(os.environ.get('FPS'))
seed=os.environ.get('SEED')
data=dict(prompt=prompt,duration=duration,width=width,height=height,fps=fps)
if seed:
    data['seed']=int(seed)
print(json.dumps(data))
PY
)

resp=$(curl -sS -X POST "$API_URL/generate-video" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $token" \
  -d "$payload")

echo "$resp" | (command -v jq >/dev/null 2>&1 && jq || cat)

status=$(json_get "$resp" '.status' || echo '')
task_id=$(json_get "$resp" '.task_id' || echo '')

if [ -z "$task_id" ]; then
  log_error "Resposta sem task_id"
  exit 1
fi

if [ "$status" = "completed" ]; then
  log_info "Vídeo concluído imediatamente"
else
  log_step "Iniciando polling da tarefa $task_id"
  poll_task_until_done "$token" "$task_id" >/dev/null
fi

outfile="$OUTPUT_DIR/${task_id}.mp4"
download_result "$token" "$task_id" "$outfile"
echo "$outfile"


