# FLUX ML API - Guia Completo de Implementação

## Visão Geral

Este repositório contém uma implementação completa de uma API RESTful para geração de imagens e vídeos usando o modelo FLUX, otimizada para deployment em GPUs NVIDIA A10G e A100 através do RunPods. O projeto inclui integração com LoRA para fine-tuning, sistema de cache, autenticação JWT, e ferramentas completas de DevOps.

## Estrutura do Projeto

```
flux-ml-project/
├── Dockerfile.A10G              # Container otimizado para GPU A10G
├── Dockerfile.A100              # Container otimizado para GPU A100
├── k8s-deployment.yaml          # Manifesto Kubernetes completo
├── Makefile                     # Automação de tarefas
├── src/
│   ├── app.py                   # Aplicação Flask principal
│   ├── utils.py                 # Utilitários e gerenciadores
│   └── requirements.txt         # Dependências Python
├── scripts/
│   ├── deploy_runpods.sh        # Script de deploy automatizado
│   └── test_local.sh            # Testes locais com mock
├── docs/
│   ├── README.md                # Este arquivo
│   ├── architecture.md          # Documentação da arquitetura
│   ├── alternatives.md          # Análise de alternativas
│   └── cost-estimates.md        # Estimativas de custo
└── diagrams/
    └── architecture.png         # Diagrama visual da arquitetura
```

## Pré-requisitos

### Sistema Local (para desenvolvimento)
- Python 3.10 ou superior
- Docker (para build de containers)
- curl (para testes de API)
- Git

### Para Deploy em Produção
- Conta no RunPods com API key
- GPU NVIDIA A10G ou A100 disponível
- Conhecimento básico de Kubernetes (opcional)

## Instalação e Configuração

### 1. Clone e Configuração Inicial

```bash
# Clonar o repositório
git clone <seu-repositorio>
cd flux-ml-project

# Instalar dependências locais
make install

# Ou manualmente:
pip install -r src/requirements.txt
```

### 2. Configuração de Variáveis de Ambiente

Crie um arquivo `.env` na raiz do projeto:

```bash
# Configurações da aplicação
MODEL_CACHE_DIR=/app/models
OUTPUT_DIR=/app/outputs
ENABLE_MODEL_OFFLOAD=true
GPU_MEMORY_FRACTION=0.8

# Configurações Redis
REDIS_URL=redis://localhost:6379/0

# Configurações de segurança
SECRET_KEY=seu-secret-key-aqui
JWT_SECRET_KEY=seu-jwt-secret-key-aqui

# Para deploy no RunPods
RUNPODS_API_KEY=seu-runpods-api-key-aqui
```

### 3. Testes Locais

Execute os testes locais usando o mock server (não requer GPU):

```bash
# Teste completo com mock
make test-local

# Ou usando o script diretamente
./scripts/test_local.sh --mock

# Teste em porta específica
./scripts/test_local.sh --mock --port 8080
```

Os testes verificam:
- Health check da API
- Autenticação JWT
- Geração de imagens mock
- Geração de vídeos mock
- Download de resultados

## Deploy em Produção

### Opção 1: Deploy Automatizado no RunPods

```bash
# Configurar API key
export RUNPODS_API_KEY="seu-api-key-aqui"

# Deploy com GPU A10G (mais econômico)
make prod-deploy-a10g

# Ou deploy com GPU A100 (mais performático)
make prod-deploy-a100

# Ou usando o script diretamente
./scripts/deploy_runpods.sh A10G
```

O script automatiza:
- Build da imagem Docker otimizada
- Push para registry do RunPods
- Criação do pod com configurações adequadas
- Verificação de saúde do deployment
- Geração de informações de acesso

### Opção 2: Deploy Manual no Kubernetes

```bash
# Aplicar manifesto Kubernetes
make k8s-deploy

# Verificar status
make k8s-status

# Ver logs
make k8s-logs

# Remover deployment
make k8s-delete
```

### Opção 3: Build e Teste Local com Docker

```bash
# Build das imagens
make build-all

# Teste das imagens localmente
make test-docker-a10g
make test-docker-a100

# Executar container localmente
docker run -p 5000:5000 -e MOCK_MODE=true flux-ml-api:a10g
```

## Uso da API

### 1. Autenticação

Primeiro, obtenha um token JWT:

```bash
curl -X POST http://seu-endpoint/auth/token \
  -H "Content-Type: application/json" \
  -d '{"api_key": "sua-api-key"}'
```

Resposta:
```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9...",
  "user_info": {
    "user_id": "user123",
    "tier": "basic",
    "rate_limit": 10
  }
}
```

### 2. Geração de Imagem

```bash
curl -X POST http://seu-endpoint/generate-image \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer SEU_TOKEN" \
  -d '{
    "prompt": "A beautiful landscape with mountains and lakes",
    "width": 512,
    "height": 512,
    "num_inference_steps": 50,
    "guidance_scale": 7.5,
    "seed": 42
  }'
```

Resposta:
```json
{
  "task_id": "uuid-da-tarefa",
  "status": "processing",
  "estimated_time": 15
}
```

### 3. Geração de Vídeo

```bash
curl -X POST http://seu-endpoint/generate-video \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer SEU_TOKEN" \
  -d '{
    "prompt": "A flowing river through a forest",
    "duration": 5.0,
    "width": 512,
    "height": 512,
    "fps": 24
  }'
```

### 4. Verificar Status e Baixar Resultado

```bash
# Verificar status
curl http://seu-endpoint/task/uuid-da-tarefa/status \
  -H "Authorization: Bearer SEU_TOKEN"

# Baixar resultado quando pronto
curl http://seu-endpoint/task/uuid-da-tarefa/result \
  -H "Authorization: Bearer SEU_TOKEN" \
  -o resultado.png
```

### 5. Usando LoRA Personalizado

```bash
curl -X POST http://seu-endpoint/generate-image \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer SEU_TOKEN" \
  -d '{
    "prompt": "A portrait in custom style",
    "lora": "data:application/octet-stream;base64,UklGRnoGAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQoGAACBhYqFbF1fdJivrJBhNjVgodDbq2EcBj+a2/LDciUFLIHO8tiJNwgZaLvt559NEAxQp+PwtmMcBjiR1/LMeSwFJHfH8N2QQAoUXrTp66hVFApGn+DyvmwhBSuBzvLZiTYIG2m98OScTgwOUarm7blmHgU7k9n1unEiBC13yO/eizEIHWq+8+OWT...",
    "width": 512,
    "height": 512
  }'
```

## Monitoramento e Debugging

### Health Check

```bash
curl http://seu-endpoint/health
```

Resposta típica:
```json
{
  "status": "healthy",
  "timestamp": 1703123456.789,
  "gpu_available": true,
  "gpu_count": 1,
  "gpu_memory": [
    {
      "device": 0,
      "allocated_gb": 2.5,
      "reserved_gb": 8.0
    }
  ],
  "redis_status": "connected",
  "model_loaded": true,
  "config": {
    "max_image_size": 1024,
    "max_video_duration": 30,
    "model_offload_enabled": true
  }
}
```

### Logs e Debugging

```bash
# Ver logs do Kubernetes
make k8s-logs

# Monitorar logs em tempo real
make monitor

# Verificar status geral
make status
```

## Otimizações de Performance

### Para GPU A10G (24GB VRAM)
- `ENABLE_MODEL_OFFLOAD=true` - Offload para CPU quando necessário
- `GPU_MEMORY_FRACTION=0.7` - Uso conservador de memória
- Batch size limitado a 1
- Attention slicing habilitado

### Para GPU A100 (40GB VRAM)
- `ENABLE_MODEL_OFFLOAD=false` - Manter tudo na GPU
- `GPU_MEMORY_FRACTION=0.9` - Uso agressivo de memória
- Batch size até 2
- Flash attention quando disponível

### Cache e Performance
- Redis cache para resultados repetidos
- Volume persistente para modelos (evita re-download)
- Processamento assíncrono com Celery
- Auto-scaling baseado em demanda

## Estimativas de Custo

### GPU A10G ($0.79-1.10/hora)
- **100 imagens (512x512):** $0.18 - $0.37
- **1 minuto de vídeo:** $2.40 - $4.95

### GPU A100 ($2.89-3.18/hora)
- **100 imagens (512x512):** $0.32 - $0.53
- **1 minuto de vídeo:** $4.35 - $7.95

Veja `docs/cost-estimates.md` para análise detalhada.

## Alternativas e Comparações

O projeto foi comparado com:
- Stable Diffusion + ComfyUI
- Midjourney API
- DALL-E 3
- InvokeAI

Veja `docs/alternatives.md` para análise completa.

## Plataformas Gratuitas para Testes

- **Google Colab:** Tesla T4 gratuito, 12h/sessão
- **Kaggle Kernels:** Tesla T4, 30h/semana
- **AWS Free Tier:** Créditos promocionais
- **Hugging Face:** 30k tokens/mês

## Troubleshooting

### Problemas Comuns

**1. Erro de memória GPU:**
```bash
# Reduzir uso de memória
export GPU_MEMORY_FRACTION=0.6
export ENABLE_MODEL_OFFLOAD=true
```

**2. Timeout na geração:**
```bash
# Aumentar timeout do Gunicorn
gunicorn --timeout 300 app:app
```

**3. Modelo não carrega:**
```bash
# Verificar cache e re-download
rm -rf /app/models/*
# Reiniciar aplicação
```

**4. Redis não conecta:**
```bash
# Verificar configuração
export REDIS_URL=redis://seu-redis-host:6379/0
```

### Logs de Debug

```bash
# Habilitar logs detalhados
export FLASK_DEBUG=true
export LOG_LEVEL=DEBUG
```

## Desenvolvimento e Contribuição

### Setup de Desenvolvimento

```bash
# Configurar ambiente completo
make dev-setup

# Executar testes
make test-local

# Verificar código
make lint

# Formatar código
make format

# Limpeza
make clean
```

### Estrutura de Commits

- `feat:` Nova funcionalidade
- `fix:` Correção de bug
- `docs:` Documentação
- `style:` Formatação
- `refactor:` Refatoração
- `test:` Testes
- `chore:` Manutenção

## Segurança

### Boas Práticas Implementadas

- Autenticação JWT obrigatória
- Rate limiting por usuário
- Validação rigorosa de inputs
- CORS configurado adequadamente
- Secrets gerenciados via variáveis de ambiente
- Logs de auditoria

### Configurações de Produção

```bash
# Usar secrets seguros
export SECRET_KEY=$(openssl rand -hex 32)
export JWT_SECRET_KEY=$(openssl rand -hex 32)

# Configurar HTTPS
# (via Ingress/Load Balancer)

# Limitar rate limiting
export RATE_LIMIT_PER_MINUTE=10
```

## Suporte e Documentação

- **Arquitetura:** `docs/architecture.md`
- **Alternativas:** `docs/alternatives.md`
- **Custos:** `docs/cost-estimates.md`
- **Issues:** Use o sistema de issues do repositório
- **Discussões:** Use o fórum de discussões

## Licença

Este projeto está licenciado sob a MIT License. Veja o arquivo LICENSE para detalhes.

## Changelog

### v1.0.0 (2024-01-XX)
- Implementação inicial da API FLUX
- Suporte para GPUs A10G e A100
- Integração com LoRA
- Sistema de cache Redis
- Deploy automatizado no RunPods
- Documentação completa

---

**Desenvolvido por:** Manus AI  
**Última atualização:** Janeiro 2024

