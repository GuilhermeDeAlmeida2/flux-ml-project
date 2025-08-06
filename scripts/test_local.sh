#!/bin/bash

# Script de testes locais para FLUX ML API
# Permite testar a aplicação sem GPU através de mocks e dry-runs

set -e

# Configurações
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$PROJECT_DIR/.venv"
MOCK_MODE="${MOCK_MODE:-true}"
PORT="${PORT:-5000}"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

info() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

# Verificar dependências
check_dependencies() {
    log "Verificando dependências do sistema..."
    
    if ! command -v python3 &> /dev/null; then
        error "Python 3 não está instalado"
    fi
    
    if ! command -v curl &> /dev/null; then
        error "curl não está instalado"
    fi
    
    if ! command -v jq &> /dev/null; then
        warn "jq não está instalado (recomendado para testes de API)"
        echo "Para instalar: sudo apt-get install jq"
    fi
    
    log "Dependências verificadas ✓"
}

# Configurar ambiente virtual
setup_venv() {
    log "Configurando ambiente virtual..."
    
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR"
        log "Ambiente virtual criado"
    fi
    
    source "$VENV_DIR/bin/activate"
    
    # Instalar dependências básicas para testes
    pip install --quiet --upgrade pip
    pip install --quiet flask flask-cors flask-jwt-extended redis requests pillow numpy
    
    # Instalar dependências mock para testes sem GPU
    if [ "$MOCK_MODE" = "true" ]; then
        pip install --quiet pytest pytest-mock responses
        log "Dependências mock instaladas"
    fi
    
    log "Ambiente virtual configurado ✓"
}

# Criar mock server
create_mock_server() {
    log "Criando mock server..."
    
    cat > "$PROJECT_DIR/mock_server.py" << 'EOF'
#!/usr/bin/env python3
"""
Mock server para testes locais sem GPU
Simula os endpoints da API FLUX ML com respostas fake
"""

import os
import json
import time
import uuid
from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
from PIL import Image
import io
import base64

app = Flask(__name__)
CORS(app, origins="*")

# Configurações mock
MOCK_GENERATION_TIME = 2  # segundos
MOCK_OUTPUT_DIR = "/tmp/flux_mock_outputs"

os.makedirs(MOCK_OUTPUT_DIR, exist_ok=True)

def create_mock_image(width=512, height=512):
    """Cria uma imagem mock colorida"""
    import random
    
    # Criar imagem com gradiente colorido
    image = Image.new('RGB', (width, height))
    pixels = []
    
    for y in range(height):
        for x in range(width):
            r = int(255 * (x / width))
            g = int(255 * (y / height))
            b = int(255 * ((x + y) / (width + height)))
            pixels.append((r, g, b))
    
    image.putdata(pixels)
    return image

@app.route('/health', methods=['GET'])
def health_check():
    """Mock health check"""
    return jsonify({
        'status': 'healthy',
        'timestamp': time.time(),
        'gpu_available': False,  # Mock sem GPU
        'gpu_count': 0,
        'gpu_memory': [],
        'redis_status': 'mocked',
        'model_loaded': True,
        'mock_mode': True,
        'config': {
            'max_image_size': 1024,
            'max_video_duration': 30,
            'model_offload_enabled': False
        }
    })

@app.route('/auth/token', methods=['POST'])
def create_token():
    """Mock token creation"""
    data = request.get_json()
    api_key = data.get('api_key', '')
    
    # Aceitar qualquer API key para testes
    if api_key:
        return jsonify({
            'access_token': 'mock_jwt_token_' + str(uuid.uuid4()),
            'user_info': {
                'user_id': 'mock_user',
                'tier': 'basic',
                'rate_limit': 100
            }
        })
    
    return jsonify({'error': 'API key inválida'}), 401

@app.route('/generate-image', methods=['POST'])
def generate_image():
    """Mock image generation"""
    data = request.get_json()
    
    if not data or 'prompt' not in data:
        return jsonify({'error': 'Prompt é obrigatório'}), 400
    
    task_id = str(uuid.uuid4())
    
    # Simular processamento
    time.sleep(MOCK_GENERATION_TIME)
    
    # Criar imagem mock
    width = data.get('width', 512)
    height = data.get('height', 512)
    image = create_mock_image(width, height)
    
    # Salvar imagem
    output_path = os.path.join(MOCK_OUTPUT_DIR, f"{task_id}.png")
    image.save(output_path)
    
    return jsonify({
        'task_id': task_id,
        'status': 'completed',
        'image_url': f'/task/{task_id}/result',
        'generation_time': MOCK_GENERATION_TIME,
        'mock': True
    })

@app.route('/generate-video', methods=['POST'])
def generate_video():
    """Mock video generation"""
    data = request.get_json()
    
    if not data or 'prompt' not in data or 'duration' not in data:
        return jsonify({'error': 'Prompt e duration são obrigatórios'}), 400
    
    task_id = str(uuid.uuid4())
    duration = float(data['duration'])
    
    # Simular processamento mais longo para vídeo
    processing_time = max(5, duration * 2)
    time.sleep(processing_time)
    
    # Criar arquivo mock (texto simulando vídeo)
    output_path = os.path.join(MOCK_OUTPUT_DIR, f"{task_id}.mp4")
    with open(output_path, 'w') as f:
        f.write(f"Mock video file for task {task_id}\n")
        f.write(f"Prompt: {data['prompt']}\n")
        f.write(f"Duration: {duration}s\n")
    
    return jsonify({
        'task_id': task_id,
        'status': 'completed',
        'video_url': f'/task/{task_id}/result',
        'generation_time': processing_time,
        'mock': True
    })

@app.route('/task/<task_id>/status', methods=['GET'])
def get_task_status(task_id):
    """Mock task status"""
    return jsonify({
        'task_id': task_id,
        'status': 'completed',
        'progress': 100,
        'mock': True
    })

@app.route('/task/<task_id>/result', methods=['GET'])
def get_task_result(task_id):
    """Mock task result"""
    # Verificar se arquivo existe
    png_path = os.path.join(MOCK_OUTPUT_DIR, f"{task_id}.png")
    mp4_path = os.path.join(MOCK_OUTPUT_DIR, f"{task_id}.mp4")
    
    if os.path.exists(png_path):
        return send_file(png_path, as_attachment=True)
    elif os.path.exists(mp4_path):
        return send_file(mp4_path, as_attachment=True)
    else:
        return jsonify({'error': 'Resultado não encontrado'}), 404

if __name__ == '__main__':
    print("🚀 Iniciando FLUX ML Mock Server...")
    print(f"📍 Servidor rodando em: http://localhost:{os.environ.get('PORT', 5000)}")
    print("🔧 Modo: MOCK (sem GPU)")
    print("📝 Endpoints disponíveis:")
    print("   GET  /health")
    print("   POST /auth/token")
    print("   POST /generate-image")
    print("   POST /generate-video")
    print("   GET  /task/<id>/status")
    print("   GET  /task/<id>/result")
    
    app.run(
        host='0.0.0.0',
        port=int(os.environ.get('PORT', 5000)),
        debug=True
    )
EOF
    
    log "Mock server criado ✓"
}

# Executar testes de API
run_api_tests() {
    info "Executando testes de API..."
    
    local base_url="http://localhost:$PORT"
    local token=""
    
    # Aguardar servidor iniciar
    sleep 3
    
    # Teste 1: Health check
    info "Teste 1: Health Check"
    response=$(curl -s "$base_url/health")
    if echo "$response" | grep -q '"status":"healthy"'; then
        log "Health check: ✓ PASSOU"
    else
        error "Health check: ✗ FALHOU"
    fi
    
    # Teste 2: Autenticação
    info "Teste 2: Autenticação"
    auth_response=$(curl -s -X POST "$base_url/auth/token" \
        -H "Content-Type: application/json" \
        -d '{"api_key": "test-key"}')
    
    if echo "$auth_response" | grep -q '"access_token"'; then
        token=$(echo "$auth_response" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
        log "Autenticação: ✓ PASSOU (Token: ${token:0:20}...)"
    else
        error "Autenticação: ✗ FALHOU"
    fi
    
    # Teste 3: Geração de imagem
    info "Teste 3: Geração de Imagem"
    image_response=$(curl -s -X POST "$base_url/generate-image" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d '{"prompt": "A beautiful landscape", "width": 512, "height": 512}')
    
    if echo "$image_response" | grep -q '"task_id"'; then
        task_id=$(echo "$image_response" | grep -o '"task_id":"[^"]*"' | cut -d'"' -f4)
        log "Geração de imagem: ✓ PASSOU (Task ID: $task_id)"
        
        # Testar download do resultado
        sleep 1
        curl -s -o "/tmp/test_image.png" "$base_url/task/$task_id/result"
        if [ -f "/tmp/test_image.png" ]; then
            log "Download de imagem: ✓ PASSOU"
        else
            warn "Download de imagem: ⚠ FALHOU"
        fi
    else
        error "Geração de imagem: ✗ FALHOU"
    fi
    
    # Teste 4: Geração de vídeo
    info "Teste 4: Geração de Vídeo"
    video_response=$(curl -s -X POST "$base_url/generate-video" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d '{"prompt": "A flowing river", "duration": 5}')
    
    if echo "$video_response" | grep -q '"task_id"'; then
        task_id=$(echo "$video_response" | grep -o '"task_id":"[^"]*"' | cut -d'"' -f4)
        log "Geração de vídeo: ✓ PASSOU (Task ID: $task_id)"
        
        # Testar download do resultado
        sleep 1
        curl -s -o "/tmp/test_video.mp4" "$base_url/task/$task_id/result"
        if [ -f "/tmp/test_video.mp4" ]; then
            log "Download de vídeo: ✓ PASSOU"
        else
            warn "Download de vídeo: ⚠ FALHOU"
        fi
    else
        error "Geração de vídeo: ✗ FALHOU"
    fi
    
    info "Todos os testes de API concluídos!"
}

# Executar warm-up
run_warmup() {
    info "Executando warm-up do sistema..."
    
    # Verificar imports Python
    python3 -c "
import sys
try:
    import flask, redis, PIL
    print('✓ Imports básicos funcionando')
except ImportError as e:
    print(f'✗ Erro de import: {e}')
    sys.exit(1)
"
    
    # Testar criação de imagem mock
    python3 -c "
from PIL import Image
import tempfile
import os

# Criar imagem de teste
img = Image.new('RGB', (256, 256), color='red')
temp_path = tempfile.mktemp(suffix='.png')
img.save(temp_path)

if os.path.exists(temp_path):
    print('✓ Geração de imagem mock funcionando')
    os.remove(temp_path)
else:
    print('✗ Erro na geração de imagem mock')
"
    
    log "Warm-up concluído ✓"
}

# Iniciar servidor mock
start_mock_server() {
    log "Iniciando servidor mock na porta $PORT..."
    
    cd "$PROJECT_DIR"
    source "$VENV_DIR/bin/activate"
    
    # Matar processo anterior se existir
    pkill -f "mock_server.py" 2>/dev/null || true
    
    # Iniciar servidor em background
    FLASK_ENV=development PORT=$PORT python3 mock_server.py &
    local server_pid=$!
    
    echo $server_pid > "$PROJECT_DIR/.mock_server.pid"
    
    log "Servidor mock iniciado (PID: $server_pid)"
    log "URL: http://localhost:$PORT"
    
    return $server_pid
}

# Parar servidor mock
stop_mock_server() {
    if [ -f "$PROJECT_DIR/.mock_server.pid" ]; then
        local pid=$(cat "$PROJECT_DIR/.mock_server.pid")
        if kill -0 $pid 2>/dev/null; then
            kill $pid
            log "Servidor mock parado (PID: $pid)"
        fi
        rm -f "$PROJECT_DIR/.mock_server.pid"
    fi
    
    # Cleanup adicional
    pkill -f "mock_server.py" 2>/dev/null || true
}

# Função principal
main() {
    log "Iniciando testes locais do FLUX ML API..."
    log "Modo: $([ "$MOCK_MODE" = "true" ] && echo "MOCK (sem GPU)" || echo "REAL (com GPU)")"
    
    # Trap para cleanup
    trap stop_mock_server EXIT
    
    check_dependencies
    setup_venv
    
    if [ "$MOCK_MODE" = "true" ]; then
        create_mock_server
        start_mock_server
        run_warmup
        run_api_tests
    else
        warn "Modo real não implementado neste script"
        warn "Para testes com GPU, use o ambiente de produção"
    fi
    
    log "Testes locais concluídos com sucesso! 🎉"
}

# Verificar argumentos
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Uso: $0 [OPÇÕES]"
    echo ""
    echo "Opções:"
    echo "  --mock      Executar em modo mock (padrão)"
    echo "  --real      Executar com GPU real (requer hardware)"
    echo "  --port PORT Porta para o servidor (padrão: 5000)"
    echo "  --help      Mostrar esta ajuda"
    echo ""
    echo "Variáveis de ambiente:"
    echo "  MOCK_MODE   true/false (padrão: true)"
    echo "  PORT        Porta do servidor (padrão: 5000)"
    echo ""
    echo "Exemplos:"
    echo "  $0 --mock"
    echo "  $0 --port 8080"
    echo "  MOCK_MODE=false $0"
    exit 0
fi

# Processar argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --mock)
            MOCK_MODE=true
            shift
            ;;
        --real)
            MOCK_MODE=false
            shift
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        *)
            error "Argumento desconhecido: $1"
            ;;
    esac
done

# Executar testes
main

