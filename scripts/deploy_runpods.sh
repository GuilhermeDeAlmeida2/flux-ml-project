#!/bin/bash

# Script de deploy para RunPods
# Automatiza o processo de build, push e deploy da aplicação FLUX ML

set -e

# Configurações
PROJECT_NAME="flux-ml-api"
REGISTRY="registry.runpods.io"
IMAGE_TAG="${REGISTRY}/${PROJECT_NAME}:$(date +%Y%m%d-%H%M%S)"
GPU_TYPE="${1:-A10G}"  # A10G ou A100
RUNPODS_API_KEY="${RUNPODS_API_KEY}"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Verificar dependências
check_dependencies() {
    log "Verificando dependências..."
    
    if ! command -v docker &> /dev/null; then
        error "Docker não está instalado"
    fi
    
    if ! command -v curl &> /dev/null; then
        error "curl não está instalado"
    fi
    
    if [ -z "$RUNPODS_API_KEY" ]; then
        error "RUNPODS_API_KEY não está definida"
    fi
    
    log "Dependências verificadas ✓"
}

# Build da imagem Docker
build_image() {
    log "Construindo imagem Docker para GPU ${GPU_TYPE}..."
    
    if [ "$GPU_TYPE" = "A100" ]; then
        DOCKERFILE="Dockerfile.A100"
    else
        DOCKERFILE="Dockerfile.A10G"
    fi
    
    if [ ! -f "$DOCKERFILE" ]; then
        error "Dockerfile não encontrado: $DOCKERFILE"
    fi
    
    docker build -f "$DOCKERFILE" -t "$IMAGE_TAG" .
    
    log "Imagem construída: $IMAGE_TAG ✓"
}

# Push da imagem para o registry
push_image() {
    log "Fazendo push da imagem para o registry..."
    
    # Login no registry do RunPods
    echo "$RUNPODS_API_KEY" | docker login "$REGISTRY" --username runpods --password-stdin
    
    docker push "$IMAGE_TAG"
    
    log "Imagem enviada para o registry ✓"
}

# Deploy no RunPods via API
deploy_runpods() {
    log "Fazendo deploy no RunPods..."
    
    # Configurações específicas por GPU
    if [ "$GPU_TYPE" = "A100" ]; then
        GPU_ID="NVIDIA A100-SXM4-40GB"
        MEMORY_GB=40
        VCPU_COUNT=8
    else
        GPU_ID="NVIDIA A10G"
        MEMORY_GB=24
        VCPU_COUNT=4
    fi
    
    # Payload JSON para criação do pod
    PAYLOAD=$(cat <<EOF
{
    "name": "${PROJECT_NAME}-${GPU_TYPE,,}",
    "imageName": "${IMAGE_TAG}",
    "gpuTypeId": "${GPU_ID}",
    "cloudType": "SECURE",
    "volumeInGb": 50,
    "containerDiskInGb": 20,
    "minMemoryInGb": ${MEMORY_GB},
    "minVcpuCount": ${VCPU_COUNT},
    "dockerArgs": "",
    "ports": "5000/http",
    "volumeMountPath": "/app/models",
    "env": [
        {
            "key": "MODEL_CACHE_DIR",
            "value": "/app/models"
        },
        {
            "key": "OUTPUT_DIR", 
            "value": "/app/outputs"
        },
        {
            "key": "ENABLE_MODEL_OFFLOAD",
            "value": "$([ "$GPU_TYPE" = "A10G" ] && echo "true" || echo "false")"
        },
        {
            "key": "GPU_MEMORY_FRACTION",
            "value": "$([ "$GPU_TYPE" = "A100" ] && echo "0.9" || echo "0.7")"
        }
    ]
}
EOF
)
    
    # Fazer requisição para criar o pod
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $RUNPODS_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "https://api.runpods.io/graphql" \
        --data-raw '{
            "query": "mutation podRentInterruptable($input: PodRentInterruptableInput) { podRentInterruptable(input: $input) { id desiredStatus } }",
            "variables": {
                "input": '"$PAYLOAD"'
            }
        }')
    
    # Verificar resposta
    if echo "$RESPONSE" | grep -q '"errors"'; then
        error "Erro no deploy: $RESPONSE"
    fi
    
    POD_ID=$(echo "$RESPONSE" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
    
    if [ -z "$POD_ID" ]; then
        error "Não foi possível obter o ID do pod"
    fi
    
    log "Pod criado com sucesso! ID: $POD_ID ✓"
    
    # Aguardar pod ficar pronto
    wait_for_pod "$POD_ID"
}

# Aguardar pod ficar pronto
wait_for_pod() {
    local pod_id="$1"
    log "Aguardando pod ficar pronto..."
    
    for i in {1..30}; do
        STATUS=$(curl -s -X POST \
            -H "Authorization: Bearer $RUNPODS_API_KEY" \
            -H "Content-Type: application/json" \
            --data-raw '{
                "query": "query pod($input: PodFilter) { pod(input: $input) { desiredStatus runtime { uptimeInSeconds } } }",
                "variables": {
                    "input": { "podId": "'"$pod_id"'" }
                }
            }' \
            "https://api.runpods.io/graphql" | \
            grep -o '"desiredStatus":"[^"]*"' | cut -d'"' -f4)
        
        if [ "$STATUS" = "RUNNING" ]; then
            log "Pod está rodando! ✓"
            get_pod_info "$pod_id"
            return 0
        fi
        
        log "Status atual: $STATUS (tentativa $i/30)"
        sleep 10
    done
    
    warn "Pod não ficou pronto no tempo esperado"
}

# Obter informações do pod
get_pod_info() {
    local pod_id="$1"
    
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $RUNPODS_API_KEY" \
        -H "Content-Type: application/json" \
        --data-raw '{
            "query": "query pod($input: PodFilter) { pod(input: $input) { id name desiredStatus runtime { uptimeInSeconds ports { ip externalPort internalPort type } } } }",
            "variables": {
                "input": { "podId": "'"$pod_id"'" }
            }
        }' \
        "https://api.runpods.io/graphql")
    
    # Extrair informações
    POD_NAME=$(echo "$RESPONSE" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    EXTERNAL_IP=$(echo "$RESPONSE" | grep -o '"ip":"[^"]*"' | cut -d'"' -f4)
    EXTERNAL_PORT=$(echo "$RESPONSE" | grep -o '"externalPort":[0-9]*' | cut -d':' -f2)
    
    log "=== INFORMAÇÕES DO DEPLOY ==="
    log "Pod ID: $pod_id"
    log "Pod Name: $POD_NAME"
    log "URL da API: http://$EXTERNAL_IP:$EXTERNAL_PORT"
    log "Health Check: http://$EXTERNAL_IP:$EXTERNAL_PORT/health"
    log "============================"
    
    # Salvar informações em arquivo
    cat > deployment_info.json <<EOF
{
    "pod_id": "$pod_id",
    "pod_name": "$POD_NAME",
    "api_url": "http://$EXTERNAL_IP:$EXTERNAL_PORT",
    "health_url": "http://$EXTERNAL_IP:$EXTERNAL_PORT/health",
    "image_tag": "$IMAGE_TAG",
    "gpu_type": "$GPU_TYPE",
    "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    
    log "Informações salvas em deployment_info.json"
}

# Função principal
main() {
    log "Iniciando deploy do FLUX ML API para RunPods..."
    log "GPU Type: $GPU_TYPE"
    
    check_dependencies
    build_image
    push_image
    deploy_runpods
    
    log "Deploy concluído com sucesso! 🚀"
}

# Verificar argumentos
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Uso: $0 [GPU_TYPE]"
    echo ""
    echo "GPU_TYPE: A10G ou A100 (padrão: A10G)"
    echo ""
    echo "Variáveis de ambiente necessárias:"
    echo "  RUNPODS_API_KEY: Chave da API do RunPods"
    echo ""
    echo "Exemplos:"
    echo "  $0 A10G"
    echo "  $0 A100"
    exit 0
fi

# Validar GPU type
if [ "$GPU_TYPE" != "A10G" ] && [ "$GPU_TYPE" != "A100" ]; then
    error "GPU_TYPE deve ser A10G ou A100"
fi

# Executar deploy
main

