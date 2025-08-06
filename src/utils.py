#!/usr/bin/env python3
"""
Módulo de utilitários para o FLUX ML API Server
Contém classes para gerenciamento de modelos, LoRA, cache, segurança e otimização.
"""

import os
import io
import json
import time
import hashlib
import logging
import base64
from typing import Optional, Dict, Any, List, Union
from pathlib import Path
import tempfile
import subprocess

import torch
import torch.nn as nn
from torch.cuda.amp import autocast
import numpy as np
from PIL import Image
import requests
from transformers import (
    CLIPTextModel, 
    CLIPTokenizer,
    T5EncoderModel,
    T5TokenizerFast
)
from diffusers import (
    FluxPipeline,
    FluxTransformer2DModel,
    FlowMatchEulerDiscreteScheduler
)
from diffusers.utils import load_image
from safetensors.torch import load_file, save_file
import redis
import psutil

logger = logging.getLogger(__name__)

class FluxModelManager:
    """Gerenciador de modelos FLUX com otimizações para GPU"""
    
    def __init__(self, cache_dir: str):
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.pipeline = None
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.dtype = torch.float16 if torch.cuda.is_available() else torch.float32
        self.model_loaded = False
        
        # Configurações de otimização
        self.enable_attention_slicing = True
        self.enable_memory_efficient_attention = True
        self.enable_cpu_offload = os.environ.get('ENABLE_CPU_OFFLOAD', 'false').lower() == 'true'
        
        logger.info(f"FluxModelManager inicializado - Device: {self.device}, Dtype: {self.dtype}")
    
    def load_base_model(self, model_id: str = "black-forest-labs/FLUX.1-dev"):
        """Carrega o modelo base FLUX"""
        try:
            logger.info(f"Carregando modelo FLUX: {model_id}")
            
            # Configurações de carregamento otimizadas
            load_kwargs = {
                "torch_dtype": self.dtype,
                "device_map": "auto" if self.enable_cpu_offload else None,
                "low_cpu_mem_usage": True,
                "cache_dir": str(self.cache_dir),
            }
            
            # Carregar pipeline
            self.pipeline = FluxPipeline.from_pretrained(
                model_id,
                **load_kwargs
            )
            
            if not self.enable_cpu_offload:
                self.pipeline = self.pipeline.to(self.device)
            
            # Aplicar otimizações
            self._apply_optimizations()
            
            self.model_loaded = True
            logger.info("Modelo FLUX carregado com sucesso")
            
            # Log de uso de memória
            if torch.cuda.is_available():
                memory_allocated = torch.cuda.memory_allocated() / 1024**3
                memory_reserved = torch.cuda.memory_reserved() / 1024**3
                logger.info(f"Memória GPU - Alocada: {memory_allocated:.2f}GB, Reservada: {memory_reserved:.2f}GB")
        
        except Exception as e:
            logger.error(f"Erro ao carregar modelo FLUX: {str(e)}")
            raise
    
    def _apply_optimizations(self):
        """Aplica otimizações de memória e performance"""
        try:
            if self.pipeline is None:
                return
            
            # Attention slicing para reduzir uso de memória
            if self.enable_attention_slicing:
                self.pipeline.enable_attention_slicing(1)
                logger.info("Attention slicing habilitado")
            
            # Memory efficient attention
            if self.enable_memory_efficient_attention and hasattr(self.pipeline, 'enable_memory_efficient_attention'):
                self.pipeline.enable_memory_efficient_attention()
                logger.info("Memory efficient attention habilitado")
            
            # Compilação do modelo para otimização (PyTorch 2.0+)
            if hasattr(torch, 'compile') and torch.cuda.is_available():
                try:
                    self.pipeline.transformer = torch.compile(
                        self.pipeline.transformer, 
                        mode="reduce-overhead"
                    )
                    logger.info("Modelo compilado com torch.compile")
                except Exception as e:
                    logger.warning(f"Falha ao compilar modelo: {str(e)}")
        
        except Exception as e:
            logger.warning(f"Erro ao aplicar otimizações: {str(e)}")
    
    def generate_image(self, prompt: str, width: int = 512, height: int = 512,
                      num_inference_steps: int = 50, guidance_scale: float = 7.5,
                      seed: Optional[int] = None) -> Image.Image:
        """Gera uma imagem usando o modelo FLUX"""
        if not self.model_loaded:
            raise RuntimeError("Modelo não foi carregado")
        
        try:
            # Configurar seed se fornecido
            if seed is not None:
                torch.manual_seed(seed)
                if torch.cuda.is_available():
                    torch.cuda.manual_seed(seed)
            
            # Gerar imagem com autocast para otimização
            with autocast(enabled=torch.cuda.is_available()):
                image = self.pipeline(
                    prompt=prompt,
                    width=width,
                    height=height,
                    num_inference_steps=num_inference_steps,
                    guidance_scale=guidance_scale,
                    generator=torch.Generator(device=self.device).manual_seed(seed) if seed else None
                ).images[0]
            
            return image
        
        except Exception as e:
            logger.error(f"Erro na geração de imagem: {str(e)}")
            raise
    
    def is_loaded(self) -> bool:
        """Verifica se o modelo está carregado"""
        return self.model_loaded and self.pipeline is not None
    
    def unload_model(self):
        """Descarrega o modelo da memória"""
        if self.pipeline is not None:
            del self.pipeline
            self.pipeline = None
            self.model_loaded = False
            
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
            
            logger.info("Modelo descarregado da memória")

class LoRAManager:
    """Gerenciador de LoRA (Low-Rank Adaptation) para fine-tuning"""
    
    def __init__(self):
        self.current_lora = None
        self.lora_cache = {}
        
    def process_lora(self, lora_data: Union[str, bytes, dict], task_id: str) -> Optional[str]:
        """Processa dados LoRA (base64, URL ou arquivo)"""
        try:
            lora_path = None
            
            if isinstance(lora_data, str):
                if lora_data.startswith('http'):
                    # Download de URL
                    lora_path = self._download_lora(lora_data, task_id)
                elif lora_data.startswith('data:'):
                    # Base64 data URL
                    lora_path = self._decode_base64_lora(lora_data, task_id)
                else:
                    # Base64 simples
                    lora_path = self._decode_base64_lora(f"data:application/octet-stream;base64,{lora_data}", task_id)
            
            elif isinstance(lora_data, dict) and 'data' in lora_data:
                # Objeto com dados base64
                lora_path = self._decode_base64_lora(lora_data['data'], task_id)
            
            if lora_path and os.path.exists(lora_path):
                # Validar arquivo LoRA
                if self._validate_lora_file(lora_path):
                    return lora_path
                else:
                    logger.warning(f"Arquivo LoRA inválido: {lora_path}")
                    os.remove(lora_path)
            
            return None
        
        except Exception as e:
            logger.error(f"Erro ao processar LoRA: {str(e)}")
            return None
    
    def _download_lora(self, url: str, task_id: str) -> str:
        """Faz download de LoRA de uma URL"""
        try:
            response = requests.get(url, timeout=30)
            response.raise_for_status()
            
            lora_path = f"/tmp/lora_{task_id}.safetensors"
            with open(lora_path, 'wb') as f:
                f.write(response.content)
            
            return lora_path
        
        except Exception as e:
            logger.error(f"Erro ao baixar LoRA: {str(e)}")
            raise
    
    def _decode_base64_lora(self, data_url: str, task_id: str) -> str:
        """Decodifica LoRA de base64"""
        try:
            if data_url.startswith('data:'):
                # Remover header do data URL
                base64_data = data_url.split(',', 1)[1]
            else:
                base64_data = data_url
            
            lora_bytes = base64.b64decode(base64_data)
            
            lora_path = f"/tmp/lora_{task_id}.safetensors"
            with open(lora_path, 'wb') as f:
                f.write(lora_bytes)
            
            return lora_path
        
        except Exception as e:
            logger.error(f"Erro ao decodificar LoRA base64: {str(e)}")
            raise
    
    def _validate_lora_file(self, lora_path: str) -> bool:
        """Valida se o arquivo LoRA é válido"""
        try:
            # Tentar carregar como safetensors
            tensors = load_file(lora_path)
            
            # Verificar se contém tensores válidos
            if not tensors:
                return False
            
            # Verificar estrutura básica de LoRA
            lora_keys = [k for k in tensors.keys() if 'lora' in k.lower()]
            if not lora_keys:
                logger.warning("Arquivo não contém tensores LoRA válidos")
                return False
            
            return True
        
        except Exception as e:
            logger.error(f"Erro ao validar arquivo LoRA: {str(e)}")
            return False
    
    def load_lora(self, lora_path: str, adapter_name: str = "default"):
        """Carrega LoRA no pipeline"""
        try:
            if not os.path.exists(lora_path):
                raise FileNotFoundError(f"Arquivo LoRA não encontrado: {lora_path}")
            
            # Implementação específica dependeria do pipeline usado
            # Aqui é um placeholder para a integração real
            logger.info(f"LoRA carregado: {lora_path}")
            self.current_lora = lora_path
        
        except Exception as e:
            logger.error(f"Erro ao carregar LoRA: {str(e)}")
            raise
    
    def unload_lora(self):
        """Remove LoRA do pipeline"""
        if self.current_lora:
            # Implementação específica para remoção
            logger.info("LoRA removido do pipeline")
            self.current_lora = None

class CacheManager:
    """Gerenciador de cache usando Redis"""
    
    def __init__(self, redis_client: redis.Redis):
        self.redis = redis_client
        self.cache_ttl = 3600 * 24  # 24 horas
        self.task_ttl = 3600 * 2    # 2 horas
    
    def generate_cache_key(self, prompt: str, width: int, height: int, 
                          steps: int, guidance: float, seed: Optional[int],
                          lora_data: Optional[Any] = None) -> str:
        """Gera chave de cache baseada nos parâmetros"""
        cache_data = {
            'prompt': prompt,
            'width': width,
            'height': height,
            'steps': steps,
            'guidance': guidance,
            'seed': seed,
            'lora': hashlib.md5(str(lora_data).encode()).hexdigest() if lora_data else None
        }
        
        cache_string = json.dumps(cache_data, sort_keys=True)
        return f"flux_cache:{hashlib.sha256(cache_string.encode()).hexdigest()}"
    
    def get_cached_result(self, cache_key: str) -> Optional[Dict]:
        """Obtém resultado do cache"""
        try:
            cached_data = self.redis.get(cache_key)
            if cached_data:
                return json.loads(cached_data)
            return None
        except Exception as e:
            logger.error(f"Erro ao obter cache: {str(e)}")
            return None
    
    def cache_result(self, cache_key: str, result_data: Dict):
        """Armazena resultado no cache"""
        try:
            self.redis.setex(
                cache_key,
                self.cache_ttl,
                json.dumps(result_data)
            )
        except Exception as e:
            logger.error(f"Erro ao armazenar cache: {str(e)}")
    
    def update_task_status(self, task_id: str, status: str, **kwargs):
        """Atualiza status de uma tarefa"""
        try:
            task_data = {
                'task_id': task_id,
                'status': status,
                'updated_at': time.time(),
                **kwargs
            }
            
            self.redis.setex(
                f"task:{task_id}",
                self.task_ttl,
                json.dumps(task_data)
            )
        except Exception as e:
            logger.error(f"Erro ao atualizar status da tarefa: {str(e)}")
    
    def get_task_info(self, task_id: str) -> Optional[Dict]:
        """Obtém informações de uma tarefa"""
        try:
            task_data = self.redis.get(f"task:{task_id}")
            if task_data:
                return json.loads(task_data)
            return None
        except Exception as e:
            logger.error(f"Erro ao obter info da tarefa: {str(e)}")
            return None

class SecurityManager:
    """Gerenciador de segurança e autenticação"""
    
    def __init__(self, redis_client: redis.Redis):
        self.redis = redis_client
        self.rate_limit_window = 60  # 1 minuto
        
        # API Keys de exemplo (em produção, usar banco de dados)
        self.valid_api_keys = {
            "flux-api-key-demo": {
                "user_id": "demo_user",
                "tier": "basic",
                "rate_limit": 10
            },
            "flux-api-key-premium": {
                "user_id": "premium_user", 
                "tier": "premium",
                "rate_limit": 100
            }
        }
    
    def validate_api_key(self, api_key: str) -> bool:
        """Valida uma API key"""
        return api_key in self.valid_api_keys
    
    def get_user_info(self, api_key: str) -> Dict:
        """Obtém informações do usuário pela API key"""
        return self.valid_api_keys.get(api_key, {})
    
    def check_rate_limit(self, user_id: str, endpoint_type: str) -> bool:
        """Verifica rate limiting"""
        try:
            key = f"rate_limit:{user_id}:{endpoint_type}"
            current_count = self.redis.get(key)
            
            if current_count is None:
                # Primeira requisição na janela
                self.redis.setex(key, self.rate_limit_window, 1)
                return True
            
            current_count = int(current_count)
            user_info = next((info for info in self.valid_api_keys.values() 
                            if info['user_id'] == user_id), {})
            rate_limit = user_info.get('rate_limit', 10)
            
            if current_count >= rate_limit:
                return False
            
            # Incrementar contador
            self.redis.incr(key)
            return True
        
        except Exception as e:
            logger.error(f"Erro no rate limiting: {str(e)}")
            return True  # Permitir em caso de erro

class ModelOptimizer:
    """Otimizador de modelos para diferentes tipos de GPU"""
    
    def __init__(self, config: Dict):
        self.config = config
        self.gpu_info = self._get_gpu_info()
    
    def _get_gpu_info(self) -> Dict:
        """Obtém informações da GPU"""
        if not torch.cuda.is_available():
            return {"type": "cpu", "memory_gb": 0}
        
        gpu_name = torch.cuda.get_device_name(0)
        memory_gb = torch.cuda.get_device_properties(0).total_memory / 1024**3
        
        # Detectar tipo de GPU
        gpu_type = "unknown"
        if "A100" in gpu_name:
            gpu_type = "a100"
        elif "A10G" in gpu_name:
            gpu_type = "a10g"
        elif "V100" in gpu_name:
            gpu_type = "v100"
        elif "T4" in gpu_name:
            gpu_type = "t4"
        
        return {
            "type": gpu_type,
            "name": gpu_name,
            "memory_gb": memory_gb
        }
    
    def get_optimal_settings(self) -> Dict:
        """Retorna configurações otimais baseadas na GPU"""
        settings = {
            "batch_size": 1,
            "enable_attention_slicing": True,
            "enable_cpu_offload": False,
            "precision": "fp16",
            "max_memory_fraction": 0.8
        }
        
        gpu_type = self.gpu_info["type"]
        memory_gb = self.gpu_info["memory_gb"]
        
        if gpu_type == "a100":
            # A100 tem muita memória, pode usar configurações mais agressivas
            settings.update({
                "batch_size": 2,
                "enable_attention_slicing": False,
                "max_memory_fraction": 0.9,
                "enable_flash_attention": True
            })
        
        elif gpu_type == "a10g":
            # A10G tem memória limitada, usar otimizações
            settings.update({
                "batch_size": 1,
                "enable_attention_slicing": True,
                "enable_cpu_offload": memory_gb < 20,
                "max_memory_fraction": 0.7
            })
        
        elif gpu_type == "t4":
            # T4 tem pouca memória, máximas otimizações
            settings.update({
                "batch_size": 1,
                "enable_attention_slicing": True,
                "enable_cpu_offload": True,
                "precision": "fp16",
                "max_memory_fraction": 0.6
            })
        
        return settings

class VideoGenerator:
    """Gerador de vídeos usando FLUX"""
    
    def __init__(self, config: Dict):
        self.config = config
        self.temp_dir = Path("/tmp/flux_video")
        self.temp_dir.mkdir(exist_ok=True)
    
    def generate_video(self, prompt: str, duration: float, width: int, height: int,
                      fps: int, seed: Optional[int], output_path: str) -> str:
        """Gera vídeo usando múltiplos frames"""
        try:
            # Calcular número de frames
            total_frames = int(duration * fps)
            
            # Gerar frames individuais
            frames = []
            for i in range(total_frames):
                # Variar ligeiramente o prompt para cada frame
                frame_prompt = f"{prompt}, frame {i+1} of {total_frames}"
                
                # Usar seed diferente para cada frame se fornecido
                frame_seed = seed + i if seed else None
                
                # Aqui seria a geração real do frame
                # Por simplicidade, usando placeholder
                frame = self._generate_frame(frame_prompt, width, height, frame_seed)
                frames.append(frame)
            
            # Combinar frames em vídeo
            video_path = self._frames_to_video(frames, fps, output_path)
            
            return video_path
        
        except Exception as e:
            logger.error(f"Erro na geração de vídeo: {str(e)}")
            raise
    
    def _generate_frame(self, prompt: str, width: int, height: int, seed: Optional[int]) -> str:
        """Gera um frame individual (placeholder)"""
        # Em uma implementação real, usaria o FluxModelManager
        # Por agora, criar uma imagem placeholder
        frame_path = self.temp_dir / f"frame_{time.time()}_{seed or 0}.png"
        
        # Criar imagem placeholder
        image = Image.new('RGB', (width, height), color='black')
        image.save(frame_path)
        
        return str(frame_path)
    
    def _frames_to_video(self, frame_paths: List[str], fps: int, output_path: str) -> str:
        """Combina frames em vídeo usando ffmpeg"""
        try:
            # Criar arquivo de lista de frames
            frame_list_path = self.temp_dir / "frame_list.txt"
            with open(frame_list_path, 'w') as f:
                for frame_path in frame_paths:
                    f.write(f"file '{frame_path}'\n")
            
            # Comando ffmpeg
            cmd = [
                'ffmpeg', '-y',
                '-f', 'concat',
                '-safe', '0',
                '-i', str(frame_list_path),
                '-vf', f'fps={fps}',
                '-c:v', 'libx264',
                '-pix_fmt', 'yuv420p',
                output_path
            ]
            
            # Executar ffmpeg
            result = subprocess.run(cmd, capture_output=True, text=True)
            
            if result.returncode != 0:
                raise RuntimeError(f"Erro no ffmpeg: {result.stderr}")
            
            # Limpar arquivos temporários
            for frame_path in frame_paths:
                try:
                    os.remove(frame_path)
                except:
                    pass
            
            try:
                os.remove(frame_list_path)
            except:
                pass
            
            return output_path
        
        except Exception as e:
            logger.error(f"Erro ao criar vídeo: {str(e)}")
            raise

def get_system_info() -> Dict:
    """Obtém informações do sistema"""
    info = {
        "cpu_count": psutil.cpu_count(),
        "memory_gb": psutil.virtual_memory().total / 1024**3,
        "disk_usage": psutil.disk_usage('/').percent,
        "gpu_available": torch.cuda.is_available()
    }
    
    if torch.cuda.is_available():
        info.update({
            "gpu_count": torch.cuda.device_count(),
            "gpu_name": torch.cuda.get_device_name(0),
            "gpu_memory_gb": torch.cuda.get_device_properties(0).total_memory / 1024**3
        })
    
    return info

