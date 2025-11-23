# ArgoCD (GitOps Deployment)

## Что это?

ArgoCD это инструмент для автоматического развертывания приложений в Kubernetes прямо из Git. Вы меняете код в Git → ArgoCD автоматически обновляет кластер.

## Зачем нужен?

- **GitOps**: Git как единственный источник истины
- **Автоматизация**: нет ручного деплоя
- **История**: все изменения в Git истории
- **Откат**: легко вернуться к предыдущей версии
- **Синхронизация**: кластер всегда соответствует Git

## Как работает?

> Git Repository → ArgoCD → Kubernetes Cluster

1. Вы коммитите изменения в Git (манифесты K8s)
2. ArgoCD замечает изменения
3. ArgoCD применяет изменения в кластер
4. Кластер синхронизирован с Git

## Установка

### 1. Установка через Rancher

```bash
# В Rancher перейти в Apps & Marketplace
# Найти ArgoCD
# Установить в namespace: argocd
```

### 2. Установка через kubectl

```bash
# Создать namespace
kubectl create namespace argocd

# Установить ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Получить пароль admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### 3. Доступ к UI

```bash
# Port-forward для доступа
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Открыть в браузере
https://localhost:8080

# Логин: admin
# Пароль: из команды выше
```

## Конфигурация

### Добавить Git репозиторий

```yaml
# repository.yaml
apiVersion: v1
kind: Secret
metadata:
  name: stroy-track-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/your-org/stroy-track
  password: <your-token>
  username: <your-username>
```

### Создать Application

```yaml
# application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gateway-stage
  namespace: argocd
spec:
  project: default

  # Где взять манифесты
  source:
    repoURL: https://github.com/your-org/stroy-track
    targetRevision: HEAD
    path: deploy/stage/gateway

  # Куда деплоить
  destination:
    server: https://kubernetes.default.svc
    namespace: stage

  # Автоматическая синхронизация
  syncPolicy:
    automated:
      prune: true # Удалять ресурсы, которых нет в Git
      selfHeal: true # Автоматически исправлять отклонения
    syncOptions:
      - CreateNamespace=true
```

## Использование

### CLI команды

```bash
# Установить ArgoCD CLI
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# Логин
argocd login localhost:8080

# Список приложений
argocd app list

# Синхронизировать приложение
argocd app sync gateway-stage

# Статус приложения
argocd app get gateway-stage

# Откатить к предыдущей версии
argocd app rollback gateway-stage
```

### Структура Git репозитория

```
deploy/
├── stage/
│   ├── gateway/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   ├── frontend/
│   └── auth/
└── prod/
    ├── gateway/
    └── frontend/
```

## Workflow

### 1. Разработка

```bash
# Внести изменения в код
git checkout -b feature/new-endpoint

# Обновить версию образа в манифесте
# deploy/stage/gateway/deployment.yaml
# image: harbor.stroy-track.ru/gateway:v1.2.0

git commit -m "Update gateway to v1.2.0"
git push origin feature/new-endpoint
```

### 2. Деплой

```bash
# После мержа в main
# ArgoCD автоматически:
# 1. Обнаружит изменения в Git
# 2. Сравнит с текущим состоянием кластера
# 3. Применит изменения
# 4. Покажет статус синхронизации
```

## Мониторинг

### Web UI

- **Приложения**: все развернутые приложения
- **Синхронизация**: статус (Synced/OutOfSync)
- **Здоровье**: статус pods (Healthy/Degraded)
- **История**: все изменения и rollback

### Метрики

```bash
# Prometheus metrics
GET /metrics

# Основные метрики:
# - argocd_app_info
# - argocd_app_sync_total
# - argocd_app_k8s_request_total
```

## Примеры для StoryTrack

### Gateway (Stage)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gateway-stage
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/stroy-track
    path: deploy/stage/gateway
    targetRevision: develop
  destination:
    server: https://stage-cluster.internal
    namespace: apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Frontend (Stage)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: frontend-stage
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/stroy-track
    path: deploy/stage/frontend
    targetRevision: develop
  destination:
    server: https://stage-cluster.internal
    namespace: apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Полезные ссылки

- Документация: https://argo-cd.readthedocs.io
- GitHub: https://github.com/argoproj/argo-cd
- Best Practices: https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/
