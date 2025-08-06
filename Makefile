# Makefile para FLUX ML API Project
# Automatiza tarefas comuns de desenvolvimento, teste e deploy

.PHONY: help install test test-local build-a10g build-a100 deploy-a10g deploy-a100 clean docs

# Configurações
PROJECT_NAME := flux-ml-api
PYTHON := python3
PIP := pip3
DOCKER := docker
KUBECTL := kubectl

# Cores para output
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m

help: ## Mostra esta ajuda
	@echo "$(GREEN)FLUX ML API - Makefile$(NC)"
	@echo ""
	@echo "$(YELLOW)Comandos disponíveis:$(NC)"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(GREEN)%-15s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install: ## Instala dependências locais
	@echo "$(GREEN)Instalando dependências...$(NC)"
	$(PIP) install -r src/requirements.txt
	@echo "$(GREEN)Dependências instaladas ✓$(NC)"

test-local: ## Executa testes locais com mock
	@echo "$(GREEN)Executando testes locais...$(NC)"
	./scripts/test_local.sh --mock
	@echo "$(GREEN)Testes concluídos ✓$(NC)"

test-local-port: ## Executa testes locais em porta específica (make test-local-port PORT=8080)
	@echo "$(GREEN)Executando testes locais na porta $(PORT)...$(NC)"
	./scripts/test_local.sh --mock --port $(PORT)

warmup: ## Executa warm-up do sistema
	@echo "$(GREEN)Executando warm-up...$(NC)"
	$(PYTHON) -c "from src.utils import get_system_info; print('Sistema:', get_system_info())" || echo "Warm-up básico OK"
	@echo "$(GREEN)Warm-up concluído ✓$(NC)"

build-a10g: ## Constrói imagem Docker para A10G
	@echo "$(GREEN)Construindo imagem Docker para A10G...$(NC)"
	$(DOCKER) build -f Dockerfile.A10G -t $(PROJECT_NAME):a10g .
	@echo "$(GREEN)Imagem A10G construída ✓$(NC)"

build-a100: ## Constrói imagem Docker para A100
	@echo "$(GREEN)Construindo imagem Docker para A100...$(NC)"
	$(DOCKER) build -f Dockerfile.A100 -t $(PROJECT_NAME):a100 .
	@echo "$(GREEN)Imagem A100 construída ✓$(NC)"

build-all: build-a10g build-a100 ## Constrói todas as imagens Docker

test-docker-a10g: build-a10g ## Testa imagem Docker A10G localmente
	@echo "$(GREEN)Testando imagem Docker A10G...$(NC)"
	$(DOCKER) run --rm -p 5000:5000 -e MOCK_MODE=true $(PROJECT_NAME):a10g &
	sleep 5
	curl -f http://localhost:5000/health || (echo "$(RED)Teste falhou$(NC)" && exit 1)
	$(DOCKER) stop $$($(DOCKER) ps -q --filter ancestor=$(PROJECT_NAME):a10g) 2>/dev/null || true
	@echo "$(GREEN)Teste Docker A10G passou ✓$(NC)"

test-docker-a100: build-a100 ## Testa imagem Docker A100 localmente
	@echo "$(GREEN)Testando imagem Docker A100...$(NC)"
	$(DOCKER) run --rm -p 5001:5000 -e MOCK_MODE=true $(PROJECT_NAME):a100 &
	sleep 5
	curl -f http://localhost:5001/health || (echo "$(RED)Teste falhou$(NC)" && exit 1)
	$(DOCKER) stop $$($(DOCKER) ps -q --filter ancestor=$(PROJECT_NAME):a100) 2>/dev/null || true
	@echo "$(GREEN)Teste Docker A100 passou ✓$(NC)"

deploy-a10g: ## Deploy no RunPods com GPU A10G
	@echo "$(GREEN)Fazendo deploy no RunPods (A10G)...$(NC)"
	@if [ -z "$(RUNPODS_API_KEY)" ]; then \
		echo "$(RED)RUNPODS_API_KEY não definida$(NC)"; \
		exit 1; \
	fi
	./scripts/deploy_runpods.sh A10G
	@echo "$(GREEN)Deploy A10G concluído ✓$(NC)"

deploy-a100: ## Deploy no RunPods com GPU A100
	@echo "$(GREEN)Fazendo deploy no RunPods (A100)...$(NC)"
	@if [ -z "$(RUNPODS_API_KEY)" ]; then \
		echo "$(RED)RUNPODS_API_KEY não definida$(NC)"; \
		exit 1; \
	fi
	./scripts/deploy_runpods.sh A100
	@echo "$(GREEN)Deploy A100 concluído ✓$(NC)"

k8s-deploy: ## Deploy no Kubernetes
	@echo "$(GREEN)Fazendo deploy no Kubernetes...$(NC)"
	$(KUBECTL) apply -f k8s-deployment.yaml
	@echo "$(GREEN)Deploy Kubernetes concluído ✓$(NC)"

k8s-status: ## Verifica status do deploy Kubernetes
	@echo "$(GREEN)Status do Kubernetes:$(NC)"
	$(KUBECTL) get pods -l app=flux-ml-api
	$(KUBECTL) get services flux-ml-service

k8s-logs: ## Mostra logs do Kubernetes
	@echo "$(GREEN)Logs do Kubernetes:$(NC)"
	$(KUBECTL) logs -l app=flux-ml-api --tail=50

k8s-delete: ## Remove deploy do Kubernetes
	@echo "$(YELLOW)Removendo deploy do Kubernetes...$(NC)"
	$(KUBECTL) delete -f k8s-deployment.yaml
	@echo "$(GREEN)Deploy removido ✓$(NC)"

docs: ## Gera documentação
	@echo "$(GREEN)Gerando documentação...$(NC)"
	@echo "Documentação disponível em:"
	@echo "  - docs/README.md (instruções principais)"
	@echo "  - docs/architecture.md (arquitetura do sistema)"
	@echo "  - docs/alternatives.md (análise de alternativas)"
	@echo "  - docs/cost-estimates.md (estimativas de custo)"
	@echo "$(GREEN)Documentação atualizada ✓$(NC)"

lint: ## Executa linting do código
	@echo "$(GREEN)Executando linting...$(NC)"
	$(PYTHON) -m flake8 src/ --max-line-length=110 || echo "$(YELLOW)Flake8 não instalado$(NC)"
	$(PYTHON) -m black src/ --check || echo "$(YELLOW)Black não instalado$(NC)"
	@echo "$(GREEN)Linting concluído ✓$(NC)"

format: ## Formata o código
	@echo "$(GREEN)Formatando código...$(NC)"
	$(PYTHON) -m black src/ || echo "$(YELLOW)Black não instalado$(NC)"
	@echo "$(GREEN)Formatação concluída ✓$(NC)"

clean: ## Limpa arquivos temporários
	@echo "$(GREEN)Limpando arquivos temporários...$(NC)"
	find . -type f -name "*.pyc" -delete
	find . -type d -name "__pycache__" -delete
	find . -type f -name "*.log" -delete
	rm -rf .pytest_cache/
	rm -rf build/
	rm -rf dist/
	rm -rf *.egg-info/
	rm -f .mock_server.pid
	rm -rf /tmp/flux_mock_outputs/
	$(DOCKER) system prune -f 2>/dev/null || true
	@echo "$(GREEN)Limpeza concluída ✓$(NC)"

dev-setup: install ## Configuração completa para desenvolvimento
	@echo "$(GREEN)Configurando ambiente de desenvolvimento...$(NC)"
	$(PIP) install pytest pytest-mock black flake8 requests
	@echo "$(GREEN)Ambiente de desenvolvimento configurado ✓$(NC)"

benchmark: ## Executa benchmark de performance
	@echo "$(GREEN)Executando benchmark...$(NC)"
	@echo "$(YELLOW)Benchmark não implementado - use ferramentas de produção$(NC)"

security-check: ## Verifica segurança do código
	@echo "$(GREEN)Verificando segurança...$(NC)"
	$(PIP) install bandit || echo "$(YELLOW)Bandit não instalado$(NC)"
	$(PYTHON) -m bandit -r src/ || echo "$(YELLOW)Verificação de segurança não disponível$(NC)"
	@echo "$(GREEN)Verificação de segurança concluída ✓$(NC)"

all: clean dev-setup test-local build-all docs ## Executa pipeline completo

# Comandos de desenvolvimento rápido
dev: test-local ## Alias para test-local
quick-test: warmup test-local ## Teste rápido com warm-up
quick-build: build-a10g ## Build rápido (apenas A10G)

# Comandos de produção
prod-deploy-a10g: build-a10g deploy-a10g ## Pipeline completo para A10G
prod-deploy-a100: build-a100 deploy-a100 ## Pipeline completo para A100

# Informações do sistema
info: ## Mostra informações do sistema
	@echo "$(GREEN)Informações do Sistema:$(NC)"
	@echo "Python: $$($(PYTHON) --version)"
	@echo "Docker: $$($(DOCKER) --version 2>/dev/null || echo 'Não instalado')"
	@echo "Kubectl: $$($(KUBECTL) version --client --short 2>/dev/null || echo 'Não instalado')"
	@echo "GPU: $$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'Não disponível')"
	@echo "Projeto: $(PROJECT_NAME)"
	@echo "Diretório: $$(pwd)"

# Comandos de monitoramento
monitor: ## Monitora logs em tempo real (requer deploy ativo)
	@echo "$(GREEN)Monitorando logs...$(NC)"
	@echo "$(YELLOW)Pressione Ctrl+C para parar$(NC)"
	tail -f *.log 2>/dev/null || echo "Nenhum log encontrado"

status: ## Mostra status geral do projeto
	@echo "$(GREEN)Status do Projeto FLUX ML API:$(NC)"
	@echo "Arquivos principais:"
	@ls -la src/app.py src/utils.py src/requirements.txt 2>/dev/null || echo "  Arquivos não encontrados"
	@echo "Dockerfiles:"
	@ls -la Dockerfile.A10G Dockerfile.A100 2>/dev/null || echo "  Dockerfiles não encontrados"
	@echo "Scripts:"
	@ls -la scripts/ 2>/dev/null || echo "  Scripts não encontrados"
	@echo "Documentação:"
	@ls -la docs/ 2>/dev/null || echo "  Documentação não encontrada"

