# 📦 Registry (Docker)

## 📌 Назначение

Этот Docker Registry используется для хранения всех Docker-образов, собираемых CI (Drone).

### 💡 Особенности:
- Развёрнут локально на том же сервере, где и CI
- Работает на порту `5000`, но доступен снаружи через `https://registry.yourdomain.com`
- Аутентификация через `htpasswd` (basic auth)
- Используется CI для пуша образов

---

## ⚙️ Как работает

1. Сервис Registry запускается на `http://localhost:5000`
2. Https настроить через proxy (NGINX слушает внешний `443` и проксирует на `http://localhost:5000`)
3. CI логинится в `registry.yourdomain.com` через `docker login`
4. Образы пушатся в `registry.yourdomain.com/<service>:<tag>`

---

## 🛠️ Установка Registry (Docker)

# 1. Установи зависимости
```bash
sudo apt update && sudo apt install -y docker.io apache2-utils
```

# 2. Создай пользователя и пароль (basic auth)
- ci	логин для CI
- htpasswd файл хранит пароль, который CI использует для логина, ввод пароля при генерации.
```bash
sudo mkdir -p /opt/registry/auth
htpasswd -Bc /opt/registry/auth/htpasswd ci
```

# 3. 
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

# 4. 🧪 Проверка вручную
```bash
docker login registry.yourdomain.com
docker tag ubuntu registry.yourdomain.com/ubuntu:latest
docker push registry.yourdomain.com/ubuntu:latest
```