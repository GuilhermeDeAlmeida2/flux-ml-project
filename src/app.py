#!/usr/bin/env python3
"""
FLUX ML API Server
Implementação de endpoints RESTful para geração de imagens e vídeos usando FLUX
com suporte a LoRA fine-tuning e otimizações para GPUs A10G e A100.
"""

import os
import io
import json
import time
import uuid
import logging
from typing import Optional, Dict, Any, List
from pathlib import Path
import traceback

import torch
import numpy as np
from PIL import Image
from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
from flask_jwt_extended import JWTManager, create_access_token, jwt_required, get_jwt_identity
import redis
from celery import Celery

from utils import (
    FluxModelManager, 
    LoRAManager, 
    CacheManager,
    SecurityManager,
    ModelOptimizer,
    VideoGenerator
)

# Configuração de logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Inicialização da aplicação Flask
app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'flux-ml-secret-key-2024')
app.config['JWT_SECRET_KEY'] = os.environ.get('JWT_SECRET_KEY', 'jwt-secret-key-2024')
app.config['JWT_ACCESS_TOKEN_EXPIRES'] = False

# Configuração CORS para permitir acesso de qualquer origem
CORS(app, origins="*", allow_headers=["Content-Type", "Authorization"])

# Configuração JWT
jwt = JWTManager(app)

# Configuração Redis e Celery para processamento assíncrono
redis_url = os.environ.get('REDIS_URL', 'redis://localhost:6379/0')
redis_client = redis.from_url(redis_url)

celery = Celery(
    app.import_name,
    broker=redis_url,
    backend=redis_url
)

# Configurações globais
CONFIG = {
    'MODEL_CACHE_DIR': os.environ.get('MODEL_CACHE_DIR', '/app/models'),
    'OUTPUT_DIR': os.environ.get('OUTPUT_DIR', '/app/outputs'),
    'MAX_IMAGE_SIZE': int(os.environ.get('MAX_IMAGE_SIZE', '1024')),
    'MAX_VIDEO_DURATION': int(os.environ.get('MAX_VIDEO_DURATION', '30')),
    'GPU_MEMORY_FRACTION': float(os.environ.get('GPU_MEMORY_FRACTION', '0.8')),
    'ENABLE_MODEL_OFFLOAD': os.environ.get('ENABLE_MODEL_OFFLOAD', 'true').lower() == 'true',
    'RATE_LIMIT_PER_MINUTE': int(os.environ.get('RATE_LIMIT_PER_MINUTE', '10')),
}

# Inicialização dos gerenciadores
model_manager = FluxModelManager(CONFIG['MODEL_CACHE_DIR'])
lora_manager = LoRAManager()
cache_manager = CacheManager(redis_client)
security_manager = SecurityManager(redis_client)
model_optimizer = ModelOptimizer(CONFIG)
video_generator = VideoGenerator(CONFIG)

# Garantir que os diretórios existam
os.makedirs(CONFIG['MODEL_CACHE_DIR'], exist_ok=True)
os.makedirs(CONFIG['OUTPUT_DIR'], exist_ok=True)

@app.before_request
def initialize_models():
    """Inicializa os modelos na primeira requisição"""
    try:
        # Evita tentar carregar o modelo em toda requisição e durante /health
        if not model_manager.is_loaded():
            # Não inicializa durante o health check para evitar timeouts no primeiro acesso
            if request.path == '/health':
                return
            logger.info("Inicializando modelos FLUX...")
            model_manager.load_base_model()
            logger.info("Modelos inicializados com sucesso")
    except Exception as e:
        logger.error(f"Erro ao inicializar modelos: {str(e)}")

@app.route('/health', methods=['GET'])
def health_check():
    """Endpoint de verificação de saúde"""
    try:
        # Verificar status da GPU
        gpu_available = torch.cuda.is_available()
        gpu_count = torch.cuda.device_count() if gpu_available else 0
        gpu_memory = []
        
        if gpu_available:
            for i in range(gpu_count):
                memory_allocated = torch.cuda.memory_allocated(i) / 1024**3  # GB
                memory_reserved = torch.cuda.memory_reserved(i) / 1024**3   # GB
                gpu_memory.append({
                    'device': i,
                    'allocated_gb': round(memory_allocated, 2),
                    'reserved_gb': round(memory_reserved, 2)
                })
        
        # Verificar Redis
        redis_status = 'connected'
        try:
            redis_client.ping()
        except:
            redis_status = 'disconnected'
        
        return jsonify({
            'status': 'healthy',
            'timestamp': time.time(),
            'gpu_available': gpu_available,
            'gpu_count': gpu_count,
            'gpu_memory': gpu_memory,
            'redis_status': redis_status,
            'model_loaded': model_manager.is_loaded(),
            'config': {
                'max_image_size': CONFIG['MAX_IMAGE_SIZE'],
                'max_video_duration': CONFIG['MAX_VIDEO_DURATION'],
                'model_offload_enabled': CONFIG['ENABLE_MODEL_OFFLOAD']
            }
        })
    except Exception as e:
        return jsonify({
            'status': 'unhealthy',
            'error': str(e),
            'timestamp': time.time()
        }), 500

@app.route('/auth/token', methods=['POST'])
def create_token():
    """Cria token JWT para autenticação"""
    try:
        data = request.get_json()
        api_key = data.get('api_key')
        
        if not security_manager.validate_api_key(api_key):
            return jsonify({'error': 'API key inválida'}), 401
        
        # Criar token com informações do usuário
        user_info = security_manager.get_user_info(api_key)
        access_token = create_access_token(
            identity=user_info['user_id'],
            additional_claims={
                'tier': user_info.get('tier', 'basic'),
                'rate_limit': user_info.get('rate_limit', CONFIG['RATE_LIMIT_PER_MINUTE'])
            }
        )
        
        return jsonify({
            'access_token': access_token,
            'user_info': user_info
        })
    
    except Exception as e:
        logger.error(f"Erro ao criar token: {str(e)}")
        return jsonify({'error': 'Erro interno do servidor'}), 500

@app.route('/generate-image', methods=['POST'])
@jwt_required()
def generate_image():
    """
    Endpoint para geração de imagens usando FLUX
    
    Aceita JSON com:
    - prompt: string (obrigatório)
    - lora: arquivo LoRA opcional (base64 ou URL)
    - width: int (opcional, padrão 512)
    - height: int (opcional, padrão 512)
    - num_inference_steps: int (opcional, padrão 50)
    - guidance_scale: float (opcional, padrão 7.5)
    - seed: int (opcional, aleatório)
    """
    try:
        # Verificar rate limiting
        user_id = get_jwt_identity()
        if not security_manager.check_rate_limit(user_id, 'image'):
            return jsonify({'error': 'Rate limit excedido'}), 429
        
        # Validar entrada
        data = request.get_json()
        if not data or 'prompt' not in data:
            return jsonify({'error': 'Prompt é obrigatório'}), 400
        
        prompt = data['prompt']
        width = min(data.get('width', 512), CONFIG['MAX_IMAGE_SIZE'])
        height = min(data.get('height', 512), CONFIG['MAX_IMAGE_SIZE'])
        num_inference_steps = data.get('num_inference_steps', 50)
        guidance_scale = data.get('guidance_scale', 7.5)
        seed = data.get('seed', None)
        lora_data = data.get('lora', None)
        
        # Validações adicionais
        if len(prompt) > 1000:
            return jsonify({'error': 'Prompt muito longo (máximo 1000 caracteres)'}), 400
        
        if num_inference_steps < 1 or num_inference_steps > 100:
            return jsonify({'error': 'num_inference_steps deve estar entre 1 e 100'}), 400
        
        # Gerar ID único para a tarefa
        task_id = str(uuid.uuid4())
        
        # Verificar cache
        cache_key = cache_manager.generate_cache_key(
            prompt, width, height, num_inference_steps, guidance_scale, seed, lora_data
        )
        
        cached_result = cache_manager.get_cached_result(cache_key)
        if cached_result:
            logger.info(f"Resultado encontrado no cache para task_id: {task_id}")
            return jsonify({
                'task_id': task_id,
                'status': 'completed',
                'image_url': cached_result['image_url'],
                'cached': True,
                'generation_time': 0
            })
        
        # Processar LoRA se fornecido
        lora_path = None
        if lora_data:
            lora_path = lora_manager.process_lora(lora_data, task_id)
        
        # Iniciar geração assíncrona
        generation_task = generate_image_task.delay(
            task_id=task_id,
            prompt=prompt,
            width=width,
            height=height,
            num_inference_steps=num_inference_steps,
            guidance_scale=guidance_scale,
            seed=seed,
            lora_path=lora_path,
            cache_key=cache_key,
            user_id=user_id
        )
        
        return jsonify({
            'task_id': task_id,
            'status': 'processing',
            'estimated_time': estimate_generation_time(width, height, num_inference_steps),
            'celery_task_id': generation_task.id
        })
    
    except Exception as e:
        logger.error(f"Erro na geração de imagem: {str(e)}")
        logger.error(traceback.format_exc())
        return jsonify({'error': 'Erro interno do servidor'}), 500

@app.route('/generate-video', methods=['POST'])
@jwt_required()
def generate_video():
    """
    Endpoint para geração de vídeos usando FLUX
    
    Aceita JSON com:
    - prompt: string (obrigatório)
    - duration: float (obrigatório, em segundos)
    - lora: arquivo LoRA opcional
    - width: int (opcional, padrão 512)
    - height: int (opcional, padrão 512)
    - fps: int (opcional, padrão 24)
    - seed: int (opcional, aleatório)
    """
    try:
        # Verificar rate limiting
        user_id = get_jwt_identity()
        if not security_manager.check_rate_limit(user_id, 'video'):
            return jsonify({'error': 'Rate limit excedido'}), 429
        
        # Validar entrada
        data = request.get_json()
        if not data or 'prompt' not in data or 'duration' not in data:
            return jsonify({'error': 'Prompt e duration são obrigatórios'}), 400
        
        prompt = data['prompt']
        duration = min(float(data['duration']), CONFIG['MAX_VIDEO_DURATION'])
        width = min(data.get('width', 512), CONFIG['MAX_IMAGE_SIZE'])
        height = min(data.get('height', 512), CONFIG['MAX_IMAGE_SIZE'])
        fps = data.get('fps', 24)
        seed = data.get('seed', None)
        lora_data = data.get('lora', None)
        
        # Validações
        if duration <= 0 or duration > CONFIG['MAX_VIDEO_DURATION']:
            return jsonify({'error': f'Duration deve estar entre 0 e {CONFIG["MAX_VIDEO_DURATION"]} segundos'}), 400
        
        if fps < 1 or fps > 60:
            return jsonify({'error': 'FPS deve estar entre 1 e 60'}), 400
        
        # Gerar ID único para a tarefa
        task_id = str(uuid.uuid4())
        
        # Processar LoRA se fornecido
        lora_path = None
        if lora_data:
            lora_path = lora_manager.process_lora(lora_data, task_id)
        
        # Iniciar geração assíncrona
        generation_task = generate_video_task.delay(
            task_id=task_id,
            prompt=prompt,
            duration=duration,
            width=width,
            height=height,
            fps=fps,
            seed=seed,
            lora_path=lora_path,
            user_id=user_id
        )
        
        return jsonify({
            'task_id': task_id,
            'status': 'processing',
            'estimated_time': estimate_video_generation_time(duration, width, height, fps),
            'celery_task_id': generation_task.id
        })
    
    except Exception as e:
        logger.error(f"Erro na geração de vídeo: {str(e)}")
        logger.error(traceback.format_exc())
        return jsonify({'error': 'Erro interno do servidor'}), 500

@app.route('/task/<task_id>/status', methods=['GET'])
@jwt_required()
def get_task_status(task_id):
    """Verifica o status de uma tarefa"""
    try:
        user_id = get_jwt_identity()
        
        # Verificar se o usuário tem acesso a esta tarefa
        task_info = cache_manager.get_task_info(task_id)
        if not task_info or task_info.get('user_id') != user_id:
            return jsonify({'error': 'Tarefa não encontrada'}), 404
        
        return jsonify(task_info)
    
    except Exception as e:
        logger.error(f"Erro ao verificar status da tarefa: {str(e)}")
        return jsonify({'error': 'Erro interno do servidor'}), 500

@app.route('/task/<task_id>/result', methods=['GET'])
@jwt_required()
def get_task_result(task_id):
    """Obtém o resultado de uma tarefa completada"""
    try:
        user_id = get_jwt_identity()
        
        # Verificar se o usuário tem acesso a esta tarefa
        task_info = cache_manager.get_task_info(task_id)
        if not task_info or task_info.get('user_id') != user_id:
            return jsonify({'error': 'Tarefa não encontrada'}), 404
        
        if task_info['status'] != 'completed':
            return jsonify({'error': 'Tarefa ainda não foi completada'}), 400
        
        # Retornar arquivo
        file_path = task_info.get('output_path')
        if not file_path or not os.path.exists(file_path):
            return jsonify({'error': 'Arquivo de resultado não encontrado'}), 404
        
        return send_file(
            file_path,
            as_attachment=True,
            download_name=f"{task_id}.{file_path.split('.')[-1]}"
        )
    
    except Exception as e:
        logger.error(f"Erro ao obter resultado da tarefa: {str(e)}")
        return jsonify({'error': 'Erro interno do servidor'}), 500

# Tarefas Celery
@celery.task(bind=True)
def generate_image_task(self, task_id, prompt, width, height, num_inference_steps, 
                       guidance_scale, seed, lora_path, cache_key, user_id):
    """Tarefa assíncrona para geração de imagem"""
    try:
        # Atualizar status
        cache_manager.update_task_status(task_id, 'processing', user_id=user_id)
        
        start_time = time.time()
        
        # Garantir que o modelo esteja carregado ao executar dentro do worker
        if not model_manager.is_loaded():
            model_manager.load_base_model()
        
        # Carregar LoRA se necessário
        if lora_path:
            lora_manager.load_lora(lora_path)
        
        # Gerar imagem
        image = model_manager.generate_image(
            prompt=prompt,
            width=width,
            height=height,
            num_inference_steps=num_inference_steps,
            guidance_scale=guidance_scale,
            seed=seed
        )
        
        # Salvar resultado
        output_path = os.path.join(CONFIG['OUTPUT_DIR'], f"{task_id}.png")
        image.save(output_path)
        
        generation_time = time.time() - start_time
        
        # Atualizar cache
        result_data = {
            'image_url': f"/task/{task_id}/result",
            'generation_time': generation_time
        }
        cache_manager.cache_result(cache_key, result_data)
        
        # Atualizar status final
        cache_manager.update_task_status(
            task_id, 'completed', 
            output_path=output_path,
            generation_time=generation_time,
            user_id=user_id
        )
        
        return result_data
    
    except Exception as e:
        logger.error(f"Erro na tarefa de geração de imagem {task_id}: {str(e)}")
        cache_manager.update_task_status(task_id, 'failed', error=str(e), user_id=user_id)
        raise

@celery.task(bind=True)
def generate_video_task(self, task_id, prompt, duration, width, height, fps, seed, lora_path, user_id):
    """Tarefa assíncrona para geração de vídeo"""
    try:
        # Atualizar status
        cache_manager.update_task_status(task_id, 'processing', user_id=user_id)
        
        start_time = time.time()
        
        # Garantir que o modelo esteja carregado ao executar dentro do worker (se vier a usar o modelo)
        if not model_manager.is_loaded():
            try:
                model_manager.load_base_model()
            except Exception:
                # VideoGenerator atual não depende do modelo; continuar mesmo se falhar
                logger.warning("Falha ao carregar modelo no worker de vídeo. Prosseguindo com gerador de frames.")
        
        # Carregar LoRA se necessário
        if lora_path:
            lora_manager.load_lora(lora_path)
        
        # Gerar vídeo
        video_path = video_generator.generate_video(
            prompt=prompt,
            duration=duration,
            width=width,
            height=height,
            fps=fps,
            seed=seed,
            output_path=os.path.join(CONFIG['OUTPUT_DIR'], f"{task_id}.mp4")
        )
        
        generation_time = time.time() - start_time
        
        # Atualizar status final
        cache_manager.update_task_status(
            task_id, 'completed',
            output_path=video_path,
            generation_time=generation_time,
            user_id=user_id
        )
        
        return {
            'video_url': f"/task/{task_id}/result",
            'generation_time': generation_time
        }
    
    except Exception as e:
        logger.error(f"Erro na tarefa de geração de vídeo {task_id}: {str(e)}")
        cache_manager.update_task_status(task_id, 'failed', error=str(e), user_id=user_id)
        raise

def estimate_generation_time(width, height, num_steps):
    """Estima tempo de geração baseado nos parâmetros"""
    base_time = 10  # segundos base
    pixel_factor = (width * height) / (512 * 512)
    step_factor = num_steps / 50
    return int(base_time * pixel_factor * step_factor)

def estimate_video_generation_time(duration, width, height, fps):
    """Estima tempo de geração de vídeo"""
    frames = int(duration * fps)
    time_per_frame = estimate_generation_time(width, height, 20) / 4  # Assumindo otimização
    return int(frames * time_per_frame)

if __name__ == '__main__':
    # Configuração para desenvolvimento
    port = int(os.environ.get('PORT', 5000))
    debug = os.environ.get('FLASK_DEBUG', 'false').lower() == 'true'
    
    app.run(
        host='0.0.0.0',
        port=port,
        debug=debug,
        threaded=True
    )

