## Установи зависимости
```bash
sudo apt update && sudo apt install -y docker.io apache2-utils
```

## Создай пользователя и пароль (basic auth)
- ci	логин для CI
- htpasswd файл хранит пароль, который CI использует для логина, ввод пароля при генерации.
```bash
sudo mkdir -p /opt/registry/auth
htpasswd -Bc /opt/registry/auth/htpasswd ci
```

## Запусти registry
```bash
docker run -d \
  --name registry \
  --restart=always \
  -p 5000:5000 \
  -v /opt/registry/data:/var/lib/registry \
  -v /opt/registry/auth:/auth \
  -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  registry:2
```

## 🧪 Проверка вручную
```bash
docker login registry.yourdomain.com
docker tag ubuntu registry.yourdomain.com/ubuntu:latest
docker push registry.yourdomain.com/ubuntu:latest
```