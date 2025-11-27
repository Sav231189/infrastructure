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

### 4. Установка через Resource Manager

```bash
helm template woodpecker \
  oci://ghcr.io/woodpecker-ci/helm/woodpecker \
  --namespace woodpecker \
  --values /tmp/woodpecker-values.yaml
```

> Template:

```yaml
---
# Source: woodpecker/charts/agent/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: woodpecker-agent
  labels:
    helm.sh/chart: agent-2.0.1
    app.kubernetes.io/name: agent
    app.kubernetes.io/instance: woodpecker
    app.kubernetes.io/version: "3.12.0"
    app.kubernetes.io/managed-by: Helm
---
# Source: woodpecker/charts/server/templates/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: woodpecker-default-agent-secret
  namespace: woodpecker
type: Opaque
data:
  WOODPECKER_AGENT_SECRET: UGFwMHdDMjNpajdFb09YSjFMVFRVckJ6NXFlMEdJUEZUa093YVhpUHNTcGtmRnMyYzhxVVNoSjJHdWRHMDV3Sg==
---
# Source: woodpecker/charts/agent/templates/role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: woodpecker-agent
  namespace: woodpecker
  labels:
    helm.sh/chart: agent-2.0.1
    app.kubernetes.io/name: agent
    app.kubernetes.io/instance: woodpecker
    app.kubernetes.io/version: "3.12.0"
    app.kubernetes.io/managed-by: Helm
rules:
  - apiGroups: [""] # '' indicates core apiGroup (don't remove)
    resources: ["persistentvolumeclaims", "services", "secrets"]
    verbs: ["create", "delete"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["watch", "create", "delete", "get", "list"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
---
# Source: woodpecker/charts/agent/templates/rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: woodpecker-agent
  namespace: woodpecker
  labels:
    helm.sh/chart: agent-2.0.1
    app.kubernetes.io/name: agent
    app.kubernetes.io/instance: woodpecker
    app.kubernetes.io/version: "3.12.0"
    app.kubernetes.io/managed-by: Helm
subjects:
  - kind: ServiceAccount
    name: woodpecker-agent
    namespace: woodpecker
roleRef:
  kind: Role
  name: woodpecker-agent
  apiGroup: rbac.authorization.k8s.io
---
# Source: woodpecker/charts/server/templates/service-headless.yaml
apiVersion: v1
kind: Service
metadata:
  name: woodpecker-server-headless
  labels:
    helm.sh/chart: server-3.0.1
    app.kubernetes.io/name: server
    app.kubernetes.io/instance: woodpecker
    app.kubernetes.io/version: "3.12.0"
    app.kubernetes.io/managed-by: Helm
spec:
  clusterIP: None
  ports:
    - protocol: TCP
      name: http
      port: 80
      targetPort: http
    - protocol: TCP
      name: grpc
      port: 9000
      targetPort: grpc
  selector:
    app.kubernetes.io/name: server
    app.kubernetes.io/instance: woodpecker
---
# Source: woodpecker/charts/server/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: woodpecker-server
  labels:
    helm.sh/chart: server-3.0.1
    app.kubernetes.io/name: server
    app.kubernetes.io/instance: woodpecker
    app.kubernetes.io/version: "3.12.0"
    app.kubernetes.io/managed-by: Helm
spec:
  type: ClusterIP
  ports:
    - protocol: TCP
      name: http
      port: 80
      targetPort: http
    - protocol: TCP
      name: grpc
      port: 9000
      targetPort: grpc

  selector:
    app.kubernetes.io/name: server
    app.kubernetes.io/instance: woodpecker
---
# Source: woodpecker/charts/agent/templates/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: woodpecker-agent
  labels:
    helm.sh/chart: agent-2.0.1
    app.kubernetes.io/name: agent
    app.kubernetes.io/instance: woodpecker
    app.kubernetes.io/version: "3.12.0"
    app.kubernetes.io/managed-by: Helm
spec:
  serviceName: woodpecker-agent
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: agent
      app.kubernetes.io/instance: woodpecker
  template:
    metadata:
      labels:
        app.kubernetes.io/name: agent
        app.kubernetes.io/instance: woodpecker
    spec:
      serviceAccountName: woodpecker-agent
      securityContext:
        fsGroup: 1000
      initContainers:
      containers:
        - name: agent
          securityContext:
            runAsGroup: 1000
            runAsUser: 1000
          image: "docker.io/woodpeckerci/woodpecker-agent:v3.12.0"
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 3000
              protocol: TCP
          resources:
            limits:
              cpu: 2000m
              memory: 2Gi
            requests:
              cpu: 200m
              memory: 256Mi
          volumeMounts:
            - name: agent-config
              mountPath: /etc/woodpecker
          env:
            - name: WOODPECKER_BACKEND
              value: "kubernetes"
            - name: WOODPECKER_BACKEND_K8S_NAMESPACE
              value: "woodpecker"
            - name: WOODPECKER_BACKEND_K8S_NAMESPACE_PER_ORGANIZATION
              value: "false"
            - name: WOODPECKER_BACKEND_K8S_POD_ANNOTATIONS
              value: ""
            - name: WOODPECKER_BACKEND_K8S_POD_LABELS
              value: ""
            - name: WOODPECKER_BACKEND_K8S_STORAGE_CLASS
              value: ""
            - name: WOODPECKER_BACKEND_K8S_STORAGE_RWX
              value: "true"
            - name: WOODPECKER_BACKEND_K8S_VOLUME_SIZE
              value: "10G"
            - name: WOODPECKER_CONNECT_RETRY_COUNT
              value: "1"
            - name: WOODPECKER_SERVER
              value: "woodpecker-server:9000"
          envFrom:
            - secretRef:
                name: woodpecker-default-agent-secret
  volumeClaimTemplates:
    - apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: agent-config
        namespace:
        annotations:
      spec:
        accessModes:
          - "ReadWriteOnce"
        resources:
          requests:
            storage: 1Gi
---
# Source: woodpecker/charts/server/templates/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: woodpecker-server
  labels:
    helm.sh/chart: server-3.0.1
    app.kubernetes.io/name: server
    app.kubernetes.io/instance: woodpecker
    app.kubernetes.io/version: "3.12.0"
    app.kubernetes.io/managed-by: Helm
spec:
  serviceName: woodpecker-server-headless
  revisionHistoryLimit: 5
  replicas: 1
  updateStrategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app.kubernetes.io/name: server
      app.kubernetes.io/instance: woodpecker
  template:
    metadata:
      labels:
        app.kubernetes.io/name: server
        app.kubernetes.io/instance: woodpecker
    spec:
      serviceAccountName: default
      securityContext:
        fsGroup: 1000
      initContainers:
      containers:
        - name: server
          securityContext:
            runAsGroup: 1000
            runAsUser: 1000
          image: "docker.io/woodpeckerci/woodpecker-server:v3.12.0"
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8000
              protocol: TCP
            - name: grpc
              containerPort: 9000
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8000
            timeoutSeconds: 10
            periodSeconds: 10
            successThreshold: 1
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8000
            timeoutSeconds: 10
            periodSeconds: 10
            successThreshold: 1
            failureThreshold: 3
          resources:
            limits:
              cpu: 500m
              memory: 512Mi
            requests:
              cpu: 100m
              memory: 128Mi
          volumeMounts:
            - name: data
              mountPath: /var/lib/woodpecker
          env:
            - name: WOODPECKER_ADMIN
              value: "woodpecker,admin"
            - name: WOODPECKER_HOST
              value: "https://xxxxxxx"
            - name: WOODPECKER_LOG_LEVEL
              value: "info"
          envFrom:
            - secretRef:
                name: woodpecker-default-agent-secret
            - secretRef:
                name: woodpecker-secret
  volumeClaimTemplates:
    - apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
---
# Source: woodpecker/charts/server/templates/ingress-http.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: woodpecker-server
  labels:
    helm.sh/chart: server-3.0.1
    app.kubernetes.io/name: server
    app.kubernetes.io/instance: woodpecker
    app.kubernetes.io/version: "3.12.0"
    app.kubernetes.io/managed-by: Helm
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: 100m
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
    - host: "woodpecker.stroy-track.ru"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: woodpecker-server
                port:
                  name: http
```

---

## Шаг 4: Проверка установки

### Через Lens

1. **Helm** → **Releases** → Namespace: `woodpecker` → Статус: **Deployed** ✅
2. **Workloads** → **Pods** → Все **Running** ✅
3. **Network** → **Ingresses** → Домен настроен ✅

### Через kubectl

```bash
# Проверить поды
kubectl get pods -n woodpecker

# Проверить логи (если есть проблемы)
kubectl logs woodpecker-server-0 -n woodpecker --tail=20
kubectl logs woodpecker-agent-0 -n woodpecker --tail=20
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
