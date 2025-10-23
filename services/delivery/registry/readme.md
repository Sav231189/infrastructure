# 📦 Registry

## 📌 Назначение

Этот Docker Registry используется для хранения всех Docker-образов, собираемых CI (Drone).

## 🛠️ Установка в Docker
> ./install.md

## 💡 Особенности:
- Развёрнут локально на том же сервере, где и CI
- Работает на порту `5000`, но доступен снаружи через `https://registry.yourdomain.com`
- Аутентификация через `htpasswd` (basic auth)
- Используется CI для пуша образов

## ⚙️ Как работает
1. Сервис Registry запускается на `http://localhost:5000`
2. Настроить https через proxy (PROXY слушает внешний `443` и проксирует на `http://localhost:5000`)
3. CI логинится в `registry.yourdomain.com` через `docker login`
4. Образы пушатся в `registry.yourdomain.com/<service>:<tag>`
