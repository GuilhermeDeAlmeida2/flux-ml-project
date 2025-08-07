import os
from pyngrok import ngrok
# Autentique o ngrok com seu token (obtenha em ngrok.com/dashboard/your-authtoken)
# Substitua 'YOUR_NGROK_AUTH_TOKEN' pelo seu token real
NGROK_AUTH_TOKEN = "30wCj6taoJMY9HhmConywWiHpHe_5tdMsyKroLchrvFCbxQq9"
if NGROK_AUTH_TOKEN == "YOUR_NGROK_AUTH_TOKEN":
    print("ATENÇÃO: Por favor, substitua 'YOUR_NGROK_AUTH_TOKEN' pelo seu token real do ngrok.")
    print("Você pode obter um token gratuito em: https://ngrok.com/signup")
else:
    ngrok.set_auth_token(NGROK_AUTH_TOKEN)
# Defina as variáveis de ambiente para o Flask e o modelo
os.environ["FLASK_APP"] = "src/app.py"
os.environ["MODEL_CACHE_DIR"] = "/content/flux-ml-project/models"
os.environ["OUTPUT_DIR"] = "/content/flux-ml-project/outputs"
os.environ["ENABLE_MODEL_OFFLOAD"] = "true" # Recomendado para Colab gratuito
os.environ["REDIS_URL"] = "redis://localhost:6379/0" # Redis será iniciado localmente
# Crie os diretórios de cache e output
!mkdir -p /content/flux-ml-project/models
!mkdir -p /content/flux-ml-project/outputs
# Inicie o servidor Redis em background
!apt-get update && apt-get install -y redis-server
!service redis-server start
# Inicie o túnel ngrok e o servidor Gunicorn em background
# O Gunicorn será executado na porta 5000
public_url = ngrok.connect(5000)
print(f"* Flask app rodando em: {public_url}")
# Inicie o Gunicorn em background. Use 'nohup' para que continue rodando
# mesmo se a célula do Colab for interrompida (mas a sessão ainda estiver ativa)
get_ipython().system_raw(
'gunicorn --bind 0.0.0.0:5000 --workers 1 --timeout 120 src.app:app &'
)
print("Servidor Gunicorn iniciado em background. Aguarde alguns segundos para inicialização...")