# Arquitetura do Sistema FLUX ML API

## Visão Geral

Este documento descreve a arquitetura do sistema FLUX ML API, uma solução robusta e escalável para a geração de imagens e vídeos utilizando modelos de Machine Learning, com foco em otimização para GPUs NVIDIA A10G e A100. O sistema é projetado para ser implantado em ambientes de nuvem, como o RunPods, e oferece endpoints RESTful para integração facilitada com outras aplicações.

## Fluxo de Execução

O fluxo de execução de uma requisição, desde o recebimento até a entrega do resultado, segue os seguintes passos:

1.  **Recebimento da Requisição**: As requisições HTTP (POST para `/generate-image` ou `/generate-video`) são recebidas pelo servidor Flask/Gunicorn. Antes do processamento, a requisição passa por uma camada de segurança que verifica a autenticação via JWT e aplica políticas de rate-limiting para evitar abusos.

2.  **Validação e Pré-processamento**: Após a autenticação, os dados da requisição (prompt, parâmetros de imagem/vídeo, dados LoRA opcionais) são validados. Um `task_id` único é gerado para cada requisição. O sistema verifica então se a requisição pode ser atendida a partir do cache Redis. Se um resultado em cache for encontrado, ele é retornado imediatamente, reduzindo a latência e o uso de recursos de GPU.

3.  **Processamento Assíncrono (Celery/Redis)**: Se a requisição não estiver em cache, ela é encaminhada para uma fila de tarefas assíncronas gerenciada pelo Celery, que utiliza o Redis como broker e backend. Isso garante que as operações de geração de imagem/vídeo, que são intensivas em GPU e podem levar tempo, não bloqueiem o servidor principal da API. O cliente recebe um `task_id` e um `celery_task_id` para acompanhar o progresso.

4.  **Gerenciamento de Modelos e LoRA**: Dentro da tarefa Celery, o `FluxModelManager` é responsável por carregar e gerenciar o modelo base FLUX. Ele aplica otimizações específicas para o hardware de GPU disponível (A10G ou A100), como `attention slicing`, `memory efficient attention` e `CPU offload` (para GPUs com menos memória). Se dados LoRA forem fornecidos, o `LoRAManager` os processa (baixando de URL ou decodificando de base64) e os aplica ao modelo para fine-tuning dinâmico.

5.  **Geração de Conteúdo**: O modelo FLUX é então invocado para gerar a imagem ou o vídeo. Para vídeos, o `VideoGenerator` orquestra a geração de múltiplos frames individuais e os compila em um arquivo de vídeo final usando `ffmpeg`.

6.  **Armazenamento de Resultados**: As imagens geradas (PNG) e os vídeos (MP4) são salvos em um volume persistente (`/app/outputs`) no sistema de arquivos do Pod. O `task_id` é usado como parte do nome do arquivo para facilitar a recuperação.

7.  **Atualização de Status e Cache**: O status da tarefa é atualizado no Redis (`CacheManager`) em tempo real (processando, completado, falha), juntamente com o caminho do arquivo de saída e o tempo de geração. Se a tarefa for concluída com sucesso, o resultado também é armazenado no cache Redis para futuras requisições idênticas.

8.  **Recuperação de Resultados**: O cliente pode consultar o status da tarefa através do endpoint `/task/<task_id>/status`. Uma vez que a tarefa é `completed`, o cliente pode baixar o resultado final (imagem ou vídeo) através do endpoint `/task/<task_id>/result`, que serve o arquivo diretamente do volume de saída.

## Diagrama de Arquitetura (ASCII Art)

```text
+------------------+
|   Cliente (User) |
+--------+---------+
         |
         | HTTP/HTTPS (API Key/JWT)
         v
+------------------+
|   Load Balancer  |
|     (Ingress)    |
+--------+---------+
         |
         | HTTP/HTTPS
         v
+----------------------------------------------------------------------------------+
|                                 Kubernetes Cluster                               |
|                                                                                  |
|  +----------------------------------------------------------------------------+  |
|  |                                  API Gateway                               |  |
|  |                                                                            |  |
|  |  +----------------------------------------------------------------------+  |  |
|  |  |                           Flask/Gunicorn Pods                        |  |  |
|  |  |                                                                      |  |  |
|  |  |  +------------------+  +------------------+  +------------------+  |  |  |
|  |  |  |    app.py        |  |    utils.py      |  |   requirements.txt |  |  |
|  |  |  | (API Endpoints)  |  | (Model Mgmt, LoRA) |  |                  |  |  |
|  |  |  +--------+---------+  +--------+---------+  +------------------+  |  |  |
|  |  |           |                      |                                   |  |  |
|  |  |           |                      |                                   |  |  |
|  |  |           | (Task Submission)    | (Model Loading/Optimization)      |  |  |
|  |  |           v                      v                                   |  |  |
|  |  |  +----------------------------------------------------------------------+  |  |
|  |  |  |                         Celery Worker Pods                         |  |  |
|  |  |  |                                                                      |  |  |
|  |  |  |  +------------------+  +------------------+  +------------------+  |  |  |
|  |  |  |  |   GPU (A10G/A100)  |  |   FLUX Model     |  |   LoRA Adapters  |  |  |
|  |  |  |  | (Inference Engine) |  | (Base Model)     |  |                  |  |  |
|  |  |  |  +--------+---------+  +--------+---------+  +------------------+  |  |  |
|  |  |  |           |                      |                                   |  |  |
|  |  |  |           | (Image/Video Gen)    | (Model/LoRA Data)                 |  |  |
|  |  |  |           v                      v                                   |  |  |
|  |  |  +----------------------------------------------------------------------+  |  |
|  |  +----------------------------------------------------------------------------+  |
|  |                                                                                  |
|  +----------------------------------------------------------------------------+  |
|                                                                                  |
|  +------------------+  +------------------+  +------------------+              |
|  |   Redis Service  |  | Persistent Volume|  | Persistent Volume|              |
|  | (Cache, Task Queue)|  | (Model Cache)    |  | (Output Storage) |              |
|  +------------------+  +------------------+  +------------------+              |
+----------------------------------------------------------------------------------+
```

## Componentes Principais

-   **Flask/Gunicorn**: Servidor web principal que expõe os endpoints da API. Gunicorn é usado para servir a aplicação Flask de forma performática e escalável.
-   **Celery**: Sistema de fila de tarefas distribuídas que permite o processamento assíncrono de operações intensivas em GPU, como a geração de imagens e vídeos.
-   **Redis**: Utilizado como broker para o Celery (gerenciando a fila de tarefas) e como backend para armazenar os resultados das tarefas e o cache de requisições. Também é usado para rate-limiting e gerenciamento de sessões JWT.
-   **FluxModelManager**: Classe Python responsável por carregar o modelo base FLUX, aplicar otimizações de memória e performance (e.g., `attention slicing`, `CPU offload`, `torch.compile`) e executar a inferência para geração de imagens.
-   **LoRAManager**: Gerencia o carregamento e aplicação de adaptadores LoRA (Low-Rank Adaptation) para fine-tuning dinâmico do modelo base, permitindo personalização sem a necessidade de retreinar o modelo completo.
-   **CacheManager**: Implementa a lógica de cache de resultados no Redis, reduzindo a carga na GPU para requisições repetidas.
-   **SecurityManager**: Lida com a autenticação via API Key/JWT e o controle de rate-limiting por usuário.
-   **ModelOptimizer**: Detecta o tipo de GPU (A10G, A100, etc.) e fornece configurações ótimas para o carregamento e execução do modelo, balanceando performance e uso de memória.
-   **VideoGenerator**: Orquestra a geração de vídeos, dividindo a tarefa em múltiplos frames e utilizando `ffmpeg` para compilar os frames em um arquivo de vídeo final.
-   **Volumes Persistentes**: Utilizados para armazenar o cache de modelos (evitando downloads repetidos) e os resultados gerados (imagens e vídeos), garantindo persistência dos dados mesmo após o reinício dos Pods.
-   **Kubernetes (RunPods)**: Orquestrador de contêineres que gerencia o deploy, escalabilidade e resiliência dos Pods da aplicação, incluindo alocação de GPUs, health checks e readiness probes.
-   **Ingress**: Componente do Kubernetes que gerencia o roteamento externo para os serviços dentro do cluster, configurando TLS/HTTPS e roteamento de tráfego.

## Otimizações e Estratégias

-   **Offloading de Modelo**: Para GPUs com memória limitada (como A10G), partes do modelo podem ser movidas para a CPU quando não estão em uso (`enable_cpu_offload`), liberando memória valiosa da GPU. A estratégia "balanced" tenta manter o máximo possível na GPU enquanto gerencia o offload de camadas menos críticas.
-   **Model Sharding**: Embora não explicitamente implementado como sharding distribuído neste exemplo, o conceito de carregar partes do modelo ou otimizar o uso de memória (e.g., `attention slicing`) visa reduzir a pegada de memória da GPU.
-   **Caching Local**: O uso de volumes persistentes para `/app/models` permite que os modelos sejam baixados apenas uma vez e persistam entre reinicializações do Pod, acelerando o warm-up.
-   **Autenticação e Rate-Limiting**: Proteção da API contra acesso não autorizado e uso excessivo, garantindo a estabilidade do serviço.
-   **Monitoramento**: Health checks e readiness probes no Kubernetes garantem que apenas Pods saudáveis e prontos para servir requisições recebam tráfego.

Esta arquitetura visa fornecer uma solução eficiente e escalável para a geração de conteúdo multimídia, aproveitando ao máximo os recursos de hardware e software disponíveis.

