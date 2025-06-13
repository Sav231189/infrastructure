**Создать директорию для данных**
```bash
sudo mkdir -p /opt/vault/data
sudo chown 100:100 /opt/vault/data
```

**Запусти Vault в docker**
```bash
CONFIG=$(cat <<'EOF'
{
  "storage": {
    "file": { "path": "/vault/data" }
  },
  "listener": {
    "tcp": {
      "address": "0.0.0.0:8200",
      "tls_disable": 1
    }
  },
  "ui": true
}
EOF
)

docker run -d --name vault \
  --cap-add=IPC_LOCK \
  --restart unless-stopped \
  -p 8200:8200 \
  -e VAULT_LOCAL_CONFIG="$CONFIG" \
  -v /opt/vault/data:/vault/data \
  hashicorp/vault:1.13 server
```

**Инициализация Vault**
> Первый запуск требует инициализации (`vault operator init`):
> - Зайти в поднятый контейнер с установленным Vault и запустить инициализацию, после инициализации получаешь
> - 5 Unseal Keys - default=5 или указать значение (*-key-threshold=2 -key-shares=3* - необходимо 2 из 3), нужны для "разблокировки" Vault при каждой перезагрузке сервиса (reboot vps).
> - 1 Root Token - основной root ключ (Доступ к разблокированному Vault)
```bash
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 \
  vault vault operator init -key-shares=3 -key-threshold=2
```

**Удалить Docker с Vault**
```bash
docker stop vault
docker rm -f vault 2>/dev/null
```