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
1. NGINX с SSL/TLS проксирует запросы с `https://woodpecker.stroy-track.ru` на `http://localhost:80`
2. Woodpecker API и Web UI работают на одном и том же порту `http://localhost:80`

---

## 🛠️ Установка CI (Woodpecker)

### 1. Установи Docker и Docker Compose (если не установлено)
```bash
### 1 — Установить Docker Engine + Buildx + Compose v2
sudo apt-get update -qq

# убрать устаревший binary‑compose (без ошибок, если его нет)
sudo apt-get remove -y docker-compose || true

# установить / обновить движок и плагины
sudo apt-get install -y -qq \
  docker.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

### 2. Необходим https domain
NGINX с SSL/TLS проксирует запросы с `https://woodpecker.stroy-track.ru` на `http://localhost:80`

### 2. Создай OAuth app в GitHub
https://github.com/settings/developers\
- указать: Application name* (например, "Woodpecker CI")
- указать: Homepage URL* (например, "https://woodpecker.stroy-track.ru")
- указать: Authorization callback URL* (например, "https://woodpecker.stroy-track.ru/authorize")
- создаём OAuth секреты: <github-client-id> и <github-client-secret>

### 3. Переходим в директорию opt/woodpecker/
```bash
sudo mkdir -p /opt/woodpecker && cd /opt/woodpecker
```

### 4. Сгенерировать конфиг .env и docker-compose.yml в директории opt/woodpecker/
- заполнить переменные в скрипте: 
    - <github-client-id> // id github OAuth app
    - <github-client-secret> // secret github OAuth app
    - <woodpecker.stroy-track.ru> // Host
    - <github-admin-login> // Admin (Root)
```bash
bash -c '
read -p "<GitHub client‑id>: "      GID
read -p "<GitHub client‑secret>: "  GSECRET
read -p "<Woodpecker host (https://woodpecker.stroy-track.ru)>: " HOST
read -p "<GitHub admin login (Sav231189)>: "    GLOGIN

# ---------- создаём каталог и .env --------------------------------------
sudo mkdir -p /opt/woodpecker && cd /opt/woodpecker
cat > .env <<EOF
WOODPECKER_GITHUB_CLIENT=$GID
WOODPECKER_GITHUB_SECRET=$GSECRET
WOODPECKER_AGENT_SECRET=$(openssl rand -hex 16)
WOODPECKER_HOST=$HOST
WOODPECKER_ADMIN=$GLOGIN
EOF

# ---------- docker‑compose.yml ------------------------------------------
cat > docker-compose.yml <<'COMPOSE'
services:
  server:
    image: woodpeckerci/woodpecker-server:v3.5.2
    restart: unless-stopped
    ports: [ "8082:8000" ]
    env_file: .env
    environment:
      WOODPECKER_GITHUB: "true"
      WOODPECKER_LOG_LEVEL: debug
    volumes:
      - woodpecker-data:/var/lib/woodpecker
      - /var/run/docker.sock:/var/run/docker.sock

  agent:
    image: woodpeckerci/woodpecker-agent:v3.5.2
    restart: unless-stopped
    depends_on: [ server ]
    env_file: .env
    environment:
      WOODPECKER_SERVER: server:9000
      WOODPECKER_LOG_LEVEL: debug
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  woodpecker-data:
COMPOSE
'
```

### 6. Запуск 
```bash
cd /opt/woodpecker && docker compose up -d      # поднять CI
```

### 5. Открой браузер:
https://woodpecker.stroy-track.ru

### 6. Удалить
```bash
cd /opt/woodpecker 2>/dev/null || true
docker compose down --volumes --remove-orphans
docker volume rm $(docker volume ls -q | grep woodpecker-data) 2>/dev/null || true
cd /
rm -rf /opt/woodpecker
```

## 📎 Пример генерации шаблона .woodpecker.yml
```bash
cat > .woodpecker.yml <<'EOF'
kind: pipeline
name: build-and-push
type: docker

trigger:
  branch:
    - stage
    - prod

# Переменные окружения, доступные всем шагам
env:
  SERVICE: ${CI_REPO_NAME}                 # можно переопределить секретом SERVICE
  VERSION: $(cat apps/${SERVICE}/VERSION)

steps:
  # 1️⃣ Сборка и публикация образа в Harbor
  build:
    image: plugins/docker
    settings:
      repo: registry.local/${SERVICE}
      tags: ${CI_COMMIT_BRANCH}-${VERSION}-${CI_COMMIT_SHA:0:8}
      username: ${DOCKER_USERNAME}
      password: ${DOCKER_PASSWORD}
      dockerfile: apps/${SERVICE}/Dockerfile

  # 2️⃣ Обновление Helm‑values в ветке deploy/*
  update-values:
    image: alpine/git
    secrets: [ GIT_SSH_KEY ]               # приватный ключ для push
    commands:
      - git config user.email "ci-bot@example.com"
      - git config user.name  "ci-bot"
      - git checkout deploy/${CI_COMMIT_BRANCH}
      - yq -i '.image.tag = "'${CI_COMMIT_BRANCH}-${VERSION}-${CI_COMMIT_SHA:0:8}'"' deploy/${CI_COMMIT_BRANCH}/${SERVICE}/values.yaml
      - git commit -am "ci: update image tag for ${SERVICE}"
      - git push origin HEAD
EOF
```