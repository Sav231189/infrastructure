# Argo CD - GitOps для Kubernetes

## Что это?

Argo CD — инструмент для автоматического развертывания приложений в Kubernetes из Git репозиториев. Вы меняете манифесты в Git → Argo CD автоматически обновляет кластер.

**GitOps принцип**: Git — единственный источник истины для состояния кластера.

---

## Шаг 1: Создать namespace

```bash
kubectl create namespace argocd
```

---

## Шаг 2: Установить Argo CD через Helm

### 1. Добавить репозиторий

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

### 2. Установить

> 📋 **Пример:** см. файл `values.yml`

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --values values.yml \
  --wait
```

### 3. Обновление (при изменении конфигурации)

```bash
helm upgrade argocd argo/argo-cd \
  --namespace argocd \
  --values values.yml
```

---

## Шаг 3: Получить пароль admin

```bash
# Argo CD автоматически создал пароль, получить его:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## Шаг 4: Доступ к UI

### Вариант 1: Port-forward (для теста)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Откройте: `https://localhost:8080`

### Вариант 2: Ingress (для продакшена)

> 📋 **Пример:** см. файл `ingress.yaml`

---

## Основные компоненты

| Компонент                    | Описание                               | Реплики |
| ---------------------------- | -------------------------------------- | ------- |
| **server**                   | Web UI + API                           | 2+ (HA) |
| **repo-server**              | Клонирование Git, рендеринг манифестов | 2+ (HA) |
| **application-controller**   | Синхронизация приложений               | 1+      |
| **dex**                      | SSO сервер                             | 1       |
| **redis**                    | Кэш и сессии                           | 1       |
| **commit-server**            | Отслеживание коммитов                  | 1       |
| **notifications-controller** | Уведомления (Slack, Email)             | 1       |

---

## Работа в UI: Добавить Git репозиторий

### Через UI

1. **Settings** → **Repositories** → **Connect Repo**
2. Указать:
   - **Type**: `git`
   - **Repository URL**: `https://github.com/your-org/your-repo`
   - **Username/Password**: если приватный репозиторий
3. **Connect**

### Через Secret (рекомендуется)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/your-org/your-repo
  password: your-token
  username: your-username
```

---

## Работа в UI: Создать Application

### Через UI

1. **New App** → **General**
2. Заполните:
   - **Application Name**: `my-app`
   - **Project**: `default`
   - **Source**:
     - Repository URL: ваш репозиторий
     - Path: `deploy/stage/my-app`
     - Revision: `main` или `HEAD`
   - **Destination**:
     - Cluster: `https://kubernetes.default.svc`
     - Namespace: `my-namespace`
   - **Sync Policy**:
     - ✅ **Automatic sync**
     - ✅ **Self-heal** (автоматически исправлять отклонения)
     - ✅ **Prune resources** (удалять ресурсы, которых нет в Git)
3. **Create**

### Через манифест

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default

  # Откуда брать манифесты
  source:
    repoURL: https://github.com/your-org/your-repo
    targetRevision: main
    path: deploy/stage/my-app

  # Куда деплоить
  destination:
    server: https://kubernetes.default.svc
    namespace: my-namespace

  # Автоматическая синхронизация
  syncPolicy:
    automated:
      prune: true # Удалять ресурсы, которых нет в Git
      selfHeal: true # Автоматически исправлять отклонения
    syncOptions:
      - CreateNamespace=true # Создавать namespace если не существует
```

---

## Структура Git репозитория

Рекомендуемая структура:

```
your-repo/
├── deploy/
│   ├── stage/
│   │   ├── my-app/
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── ingress.yaml
│   │   └── another-app/
│   └── prod/
│       └── my-app/
└── README.md
```

---

## Настройка Prometheus (опционально)

После установки Prometheus включите ServiceMonitor в `values.yml`:

```yaml
server:
  metrics:
    serviceMonitor:
      enabled: true
      namespace: "monitoring"
```

Применить изменения:

```bash
helm upgrade argocd argo/argo-cd \
  --namespace argocd \
  --values values.yml
```

---

## Настройка StorageClass (опционально)

Для использования Ceph RBD в `values.yml`:

### Redis (persistent storage)

```yaml
redis:
  existingVolumes:
    data:
      persistentVolumeClaim:
        claimName: argocd-redis-data
        storageClass: ceph-rbd
        size: 5Gi
```

### Repo Server (кэш Helm)

```yaml
repoServer:
  existingVolumes:
    helmWorkingDir:
      persistentVolumeClaim:
        claimName: argocd-repo-server-helm-cache
        storageClass: ceph-rbd
        size: 10Gi
```

> 💡 **Примечание**: По умолчанию используется emptyDir (временное хранилище). PVC нужен только для production с большими репозиториями.
