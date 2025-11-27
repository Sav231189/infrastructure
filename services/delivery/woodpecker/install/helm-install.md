# Woodpecker CI (Kubernetes / Helm)

## Что это?

Бесплатный CI/CD (форк Drone). Автоматически собирает Docker образы при пуше в GitHub и публикует в Harbor.

**Компоненты:**

- **Server** - веб-интерфейс и API
- **Agent** - выполняет сборки (масштабируется)
- **SQLite** - встроенная база данных

**Секреты:**

- ✅ **Хранятся** в Kubernetes Secret
- ✅ **Передаются** через переменные окружения

---

## Шаг 1: Создать GitHub OAuth App

1. Откройте https://github.com/settings/developers
2. **New OAuth App**
3. Заполните:
   - **Application name:** `Woodpecker CI` (или любое)
   - **Homepage URL:** `https://woodpecker.stroy-track.ru` ⚠️ **ВАЖНО!**
   - **Authorization callback URL:** `https://woodpecker.stroy-track.ru/authorize`
4. **Register application**
5. Перейдите в **Permissions & events** → установите:
   - **Account permissions** → **Email addresses:** Read ✅
   - **Repository permissions** → **Contents:** Read & Write ✅
   - **Repository permissions** → **Metadata:** Read & Write ✅
   - **Repository permissions** → **Commit statuses:** Read & Write ✅
6. Скопируйте **Client ID** и сгенерируйте **Client Secret**

> ⚠️ **КРИТИЧНО:** Homepage URL должен совпадать с WOODPECKER_HOST!

---

## Шаг 2: Создать namespace и Secret

### 1. Создайте namespace

```bash
kubectl create namespace woodpecker
```

### 2. Создайте Secret с GitHub данными

**Вариант A: Через kubectl**

```bash
kubectl create secret generic woodpecker-secret \
  --from-literal=WOODPECKER_GITHUB='true' \
  --from-literal=WOODPECKER_GITHUB_CLIENT='YOUR_CLIENT_ID' \
  --from-literal=WOODPECKER_GITHUB_SECRET='YOUR_CLIENT_SECRET' \
  --from-literal=WOODPECKER_HOST='https://example.com' \
  --from-literal=WOODPECKER_ADMIN='YOUR_GITHUB_USERNAME' \
  --namespace woodpecker
```

**Вариант B: Через Lens (UI)**

Lens → **Config** → **Secrets** → **Create**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: woodpecker-secret
  namespace: woodpecker
type: Opaque
stringData:
  WOODPECKER_GITHUB: "true"
  WOODPECKER_GITHUB_CLIENT: "YOUR_CLIENT_ID"
  WOODPECKER_GITHUB_SECRET: "YOUR_CLIENT_SECRET"
  WOODPECKER_HOST: "https://example.com"
  WOODPECKER_ADMIN: "YOUR_GITHUB_USERNAME"
```

---

## Шаг 3: Установка через Helm

### 1. Создайте конфигурацию на сервере с kubectl

```bash
nano /tmp/woodpecker-values.yaml
```

> 📋 **Пример:** см. файл `woodpecker-values.yaml` в этой папке

### 2. Установите Woodpecker

```bash
helm install woodpecker \
  oci://ghcr.io/woodpecker-ci/helm/woodpecker \
  --namespace woodpecker \
  --values /tmp/woodpecker-values.yaml
```

### 3. Обновление (при изменении конфигурации)

```bash
helm upgrade woodpecker \
  oci://ghcr.io/woodpecker-ci/helm/woodpecker \
  --namespace woodpecker \
  --values /tmp/woodpecker-values.yaml
```

---

## Шаг 4: Установка Ingress

> ⚠️ **Важно:** Ingress устанавливается отдельно от Helm chart для гибкости управления

### 1. Создайте файл конфигурации Ingress

```bash
nano /tmp/woodpecker-ingress.yaml
```

> 📋 **Пример:** см. файл `woodpecker-ingress.yaml` в этой папке

### 2. Замените домен в конфигурации

Откройте файл и найдите строку:

```yaml
- host: example.com
```

Замените `example.com` на ваш реальный домен, например: `woodpecker.stroy-track.ru`

### 3. Установите Ingress через kubectl

```bash
kubectl apply -f /tmp/woodpecker-ingress.yaml -n woodpecker
```

**Вывод:**

```
ingress.networking.k8s.io/woodpecker-ingress created
```

---

## Шаг 5: Настройка Nginx Proxy Manager

> ⚠️ Если Ingress настроен внутри кластера, настройте внешний доступ через NPM

1. **Proxy Hosts** → **Add Proxy Host**
2. Заполните:
   - **Domain:** `example.com`
   - **Scheme:** `http`
   - **Forward Hostname/IP:** IP Ingress Controller
   - **Forward Port:** `80`
   - **Websockets Support:** ✅
3. **SSL** → Request Let's Encrypt Certificate

---

## Шаг 6: Первый вход

1. Откройте `https://example.com`
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
- **Value:** `example.com`
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
      repo: harbor.example.com/stroytrack/${CI_REPO_NAME}
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

## Удаление Woodpecker

```bash
# Удалить Helm release
helm uninstall woodpecker -n woodpecker

# Удалить данные (PVC)
kubectl delete pvc --all -n woodpecker

# Удалить Secret
kubectl delete secret woodpecker-secret -n woodpecker

# Удалить namespace
kubectl delete namespace woodpecker
```

---

## Интеграция с Vault (опционально, будущее)

> Для централизованного управления секретами через HashiCorp Vault

Используйте **External Secrets Operator** для автоматической синхронизации секретов из Vault в Kubernetes Secret.

**Преимущества:**

- Централизованное хранилище секретов
- Автоматическая ротация
- Аудит доступа

**Документация:** https://external-secrets.io/

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
