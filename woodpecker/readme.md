# 🚀 CI Woodpecker - Fork Drone без платной лицензии.

## 📌 Назначение

CI автоматически собирает и публикует Docker-образы микросервисов при изменениях в ветках:

- `stage` — тестовое окружение
- `prod` — прод окружение

## 🔄 Общий процесс:

1. Разработчик пушит код в ветку `stage` или `prod`
2. Woodpecker запускает пайплайн
3. Определяется имя сервиса из переменной `SERVICE`
4. Читается версия из `apps/<service>/VERSION`
5. Собирается Docker-образ: `<service>:<branch>-<version>-<commit>`
6. Публикуется в Image Registry: `registry.local/<service>:tag`
7. Обновляется image tag в Git (`deploy/<branch>/<service>/values.yaml`)
8. Коммит и пуш обратно в GitHub (в ветку `deploy/stage` или `deploy/prod`) для CD

## ⚙️ Как работает
1. NGINX с SSL/TLS проксирует запросы с `https://woodpecker.yourdomain.com` на `http://localhost:80`
2. Woodpecker API и Web UI работают на одном и том же порту `http://localhost:80`
