# Woodpecker CI (Kubernetes / Helm)

## Что это?

Бесплатный CI/CD (форк Drone). Автоматически собирает Docker образы при пуше в GitHub и публикует в Harbor.

**Компоненты:**

- **Server** - веб-интерфейс и API
- **Agent** - выполняет сборки (масштабируется)
- **SQLite** - встроенная база данных

---

## Шаг 1: Создать GitHub OAuth App

1. Откройте https://github.com/settings/developers
2. **New OAuth App**
3. Заполните:
   - **Application name:** `Woodpecker CI`
   - **Homepage URL:** `https://woodpecker.stroy-track.ru`
   - **Authorization callback URL:** `https://woodpecker.stroy-track.ru/authorize`
4. **Register application**
5. Скопируйте:
   - **Client ID**
   - **Client Secret** (кнопка Generate)

---

## Шаг 2: Создать Kubernetes Secret

### 1. Создайте namespace

```bash
kubectl create namespace woodpecker
```

### 2. Сгенерируйте Agent Secret

```bash
openssl rand -hex 32
```

Скопируйте результат.

### 3. Создайте Secret с данными

```bash
kubectl create secret generic woodpecker-secret \
  --from-literal=WOODPECKER_GITHUB_CLIENT='ваш-github-client-id' \
  --from-literal=WOODPECKER_GITHUB_SECRET='ваш-github-client-secret' \
  --from-literal=WOODPECKER_AGENT_SECRET='результат-из-openssl' \
  --from-literal=WOODPECKER_ADMIN='Sav231189' \
  --namespace woodpecker
```

> **Будущее:** Можно интегрировать с Vault через External Secrets Operator для автоматической синхронизации секретов.

---

## Шаг 3: Установка через Helm

### 1. Создайте файл woodpecker-values.yaml

⚠️ **Измените только домен:**

```yaml
server:
  host: "https://woodpecker.stroy-track.ru" # ← ЗАМЕНИТЬ: ваш домен
  logLevel: "info"
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
  persistence:
    enabled: true
    storageClass: "ceph-rbd"
    size: 5Gi
  env:
    WOODPECKER_GITHUB: "true"
  extraSecretNamesForEnvFrom:
    - woodpecker-secret

agent:
  replicas: 2
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 2000m
      memory: 2Gi
  extraSecretNamesForEnvFrom:
    - woodpecker-secret

ingress:
  enabled: true
  className: "nginx"
  hosts:
    - host: woodpecker.stroy-track.ru # ← (тот же домен)
      paths:
        - path: /
          pathType: Prefix
  tls: []
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"

database:
  type: sqlite
```

### 2. Установите Woodpecker

```bash
helm install woodpecker \
  oci://ghcr.io/woodpecker-ci/helm/woodpecker \
  --namespace woodpecker \
  --values woodpecker-values.yaml
```

---

## Шаг 4: Проверка через Lens

### 1. Helm Release

1. **Helm** → **Releases**
2. Namespace: `woodpecker`
3. Статус: **Deployed**

### 2. Pods

1. **Workloads** → **Pods**
2. Namespace: `woodpecker`
3. Должны быть **Running**:
   - `woodpecker-server-0` (1 шт)
   - `woodpecker-agent-xxxxx` (2 шт)

### 3. Ingress

1. **Network** → **Ingresses**
2. Namespace: `woodpecker`
3. Должен быть ingress с доменом

---

## Шаг 5: Настройка домена в NPM

1. **Proxy Hosts** → **Add Proxy Host**
2. Заполните:
   - **Domain Names:** `woodpecker.stroy-track.ru`
   - **Scheme:** `http`
   - **Forward Hostname/IP:** IP вашего Ingress (Lens: **Network** → **Services** → `ingress-nginx-controller`)
   - **Forward Port:** `80`
   - **Websockets Support:** ✅
3. Вкладка **SSL:**
   - **SSL Certificate:** Request a new Let's Encrypt Certificate
   - **Force SSL:** ✅
   - **Email:** ваш email
4. **Save**

---

## Шаг 6: Первый вход

1. Откройте `https://woodpecker.stroy-track.ru`
2. **Login with GitHub**
3. **Authorize**
4. Готово! 🎉

---

## Работа в UI: Подключение репозитория

### 1. Синхронизация

1. **Repositories** (левое меню)
2. **Reload repositories** (иконка обновления)
3. Подождите 3-5 секунд

### 2. Включение CI

1. Найдите репозиторий
2. **Enable**
3. **Settings** → **General:**
   - **Trusted:** ✅
   - **Protected:** ✅
   - **Timeout:** `3600`

---

## Работа в UI: Секреты для Harbor

1. **Repositories** → репозиторий
2. **Settings** → **Secrets**
3. **New secret** для каждого:

**DOCKER_REGISTRY:**

- **Name:** `DOCKER_REGISTRY`
- **Value:** `harbor.stroy-track.ru`
- **Events:** ✅ все
- **Save**

**DOCKER_USERNAME:**

- **Name:** `DOCKER_USERNAME`
- **Value:** `admin`
- **Events:** ✅ все
- **Save**

**DOCKER_PASSWORD:**

- **Name:** `DOCKER_PASSWORD`
- **Value:** ваш пароль от Harbor
- **Events:** ✅ все
- **Save**

---

## Работа в UI: Пайплайн

### 1. Создайте .woodpecker.yml

В корне репозитория:

```yaml
when:
  branch:
    - stage
    - prod

steps:
  build-docker:
    image: plugins/docker
    settings:
      registry:
        from_secret: DOCKER_REGISTRY
      username:
        from_secret: DOCKER_USERNAME
      password:
        from_secret: DOCKER_PASSWORD
      repo: harbor.stroy-track.ru/stroytrack/${CI_REPO_NAME}
      tags:
        - ${CI_COMMIT_BRANCH}-${CI_COMMIT_SHA:0:8}
        - ${CI_COMMIT_BRANCH}-latest
      dockerfile: Dockerfile
```

### 2. Пуш в Git

```bash
git add .woodpecker.yml
git commit -m "Add Woodpecker CI"
git push origin stage
```

### 3. Просмотр в UI

1. **Repositories** → репозиторий
2. **Pipelines** → видите сборку
3. Кликните → логи в реальном времени

**Статусы:**

- 🟡 Pending
- 🔵 Running
- 🟢 Success
- 🔴 Failure

---

## Обновление конфигурации

### Изменить Secret

```bash
kubectl edit secret woodpecker-secret -n woodpecker
```

Или через Lens:

1. **Config** → **Secrets** → `woodpecker-secret`
2. **Edit** → измените Base64 значения
3. **Save**

После изменения Secret перезапустите поды:

```bash
kubectl rollout restart statefulset woodpecker-server -n woodpecker
kubectl rollout restart deployment woodpecker-agent -n woodpecker
```

### Изменить values.yaml

```bash
helm upgrade woodpecker \
  oci://ghcr.io/woodpecker-ci/helm/woodpecker \
  --namespace woodpecker \
  --values woodpecker-values.yaml
```

---

## Масштабирование

### Увеличить агентов

Измените в `woodpecker-values.yaml`:

```yaml
agent:
  replicas: 5
```

Обновите:

```bash
helm upgrade woodpecker \
  oci://ghcr.io/woodpecker-ci/helm/woodpecker \
  --namespace woodpecker \
  --values woodpecker-values.yaml
```

Проверка в Lens:

- **Workloads** → **Pods** → 5 агентов

---

## Удаление

```bash
# Удалить Helm release
helm uninstall woodpecker -n woodpecker

# Удалить PVC (данные)
kubectl delete pvc -n woodpecker --all

# Удалить Secret
kubectl delete secret woodpecker-secret -n woodpecker

# Удалить namespace
kubectl delete namespace woodpecker
```

---

## Интеграция с Vault (будущее)

### Через External Secrets Operator

1. Установите External Secrets Operator в кластер
2. Создайте SecretStore для Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: woodpecker
spec:
  provider:
    vault:
      server: "https://vault.stroy-track.ru"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "woodpecker"
```

3. Создайте ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: woodpecker-secret
  namespace: woodpecker
spec:
  refreshInterval: 15s
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: woodpecker-secret
    creationPolicy: Owner
  data:
    - secretKey: WOODPECKER_GITHUB_CLIENT
      remoteRef:
        key: woodpecker
        property: github_client
    - secretKey: WOODPECKER_GITHUB_SECRET
      remoteRef:
        key: woodpecker
        property: github_secret
    - secretKey: WOODPECKER_AGENT_SECRET
      remoteRef:
        key: woodpecker
        property: agent_secret
    - secretKey: WOODPECKER_ADMIN
      remoteRef:
        key: woodpecker
        property: admin
```

Секреты будут автоматически синхронизироваться из Vault.

---

## Полезные функции UI

### Badge для README

1. **Repositories** → репозиторий
2. **Settings** → **Badge**
3. Скопируйте Markdown
4. Вставьте в `README.md`

### Cron (периодические сборки)

1. **Repositories** → репозиторий
2. **Settings** → **Cron**
3. **New cron job:**
   - **Name:** `nightly-build`
   - **Branch:** `stage`
   - **Schedule:** `0 2 * * *`
4. **Save**

### Ручной запуск

1. **Repositories** → репозиторий
2. **Trigger pipeline** (иконка play)
3. Выберите **Branch**
4. **Trigger**

### Мониторинг агентов

1. **Admin Settings** (шестеренка)
2. **Agents**
3. Видите:
   - Status: Online/Offline
   - Platform: linux
   - Capacity: задачи
