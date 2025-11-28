Vault (Управление секретами)

## Назначение

- Централизованное хранение секретов
- Dynamic secrets для БД
- Автоматическая ротация ключей

## Данные

- Пароли баз данных
- API ключи
- SSL сертификаты
- Токены доступа

## Установка

- При установке хук может установиться раньше vault, и блокировать PVC, требует обновить Release.

> Values

```yaml
# =====================================================================
# HashiCorp Vault — Helm values (PROD HA, Raft, ClusterIP + Ingress)
# Домен: vault.stroy-track.ru -> Ingress/NPM -> ClusterIP Service
# Namespace для релиза: vault
# =====================================================================

global:
  enabled: true
  namespace: "vault"

  # Внутренний TLS у самого Vault выключен (терминация на ingress).
  tlsDisable: true

  # (опционально) интеграция с Prometheus Operator, оставим выкл.
  serverTelemetry:
    prometheusOperator: false

# =====================================================================
# Injector (mutating webhook) — безопасный прод-режим
#  - 3 реплики + PDB + anti-affinity
#  - MWC матчится ТОЛЬКО на NS с меткой vault.hashicorp.com/agent-injection=enabled
#  - системные NS исключены
#  - в таком NS можешь ещё ДОБАВИТЬ АННОТАЦИЮ (см. ниже), и тогда инъекция будет
#    ПО УМОЛЧАНИЮ для всех Pod без под-аннотаций (NS-wide)
# =====================================================================
injector:
  enabled: true
  replicas: 3

  # КРИТИЧНО для RKE2: API Server не может достучаться до ClusterIP webhook
  # Используем hostNetwork чтобы webhook был доступен напрямую через IP ноды
  hostNetwork: true

  image:
    repository: "hashicorp/vault-k8s"
    tag: "1.7.0"
    pullPolicy: IfNotPresent

  agentImage:
    repository: "hashicorp/vault"
    tag: "1.20.4"

  # Resources для самого инжектора (webhook сервера)
  resources:
    requests:
      cpu: "100m"
      memory: "128Mi"
    limits:
      cpu: "500m"
      memory: "256Mi"

  # Базовые лимиты для сайдкара агента (подправишь при желании)
  agentDefaults:
    cpuLimit: "500m"
    cpuRequest: "100m"
    memLimit: "256Mi"
    memRequest: "128Mi"
    template: "map"

    templateConfig:
      exitOnRetryFailure: true
      staticSecretRenderInterval: ""

  # Пробы инжектора
  livenessProbe:
    initialDelaySeconds: 5
    periodSeconds: 2
    timeoutSeconds: 5
    failureThreshold: 2
  readinessProbe:
    initialDelaySeconds: 5
    periodSeconds: 2
    timeoutSeconds: 5
    failureThreshold: 2
  startupProbe:
    initialDelaySeconds: 5
    periodSeconds: 5
    timeoutSeconds: 5
    failureThreshold: 12

  authPath: "auth/kubernetes"
  logLevel: "info"
  logFormat: "standard"

  # === ВАЖНО ===
  # Жёсткая политика: если вебхук недоступен — Pod НЕ создаётся.
  # Это безопасно для приложений, но благодаря namespaceSelector ниже
  # системные NS вообще не попадают под вебхук — и кластер не "встанет".
  webhook:
    failurePolicy: Fail
    timeoutSeconds: 10
    matchPolicy: Exact

    # Вебхук матчится ТОЛЬКО на NS с меткой vault.hashicorp.com/agent-injection=enabled
    # и НЕ матчится на системные NS
    namespaceSelector:
      matchExpressions:
        - key: vault.hashicorp.com/agent-injection
          operator: In
          values: ["enabled"]
        # - key: kubernetes.io/metadata.name
        #   operator: NotIn
        #   values:
        #     [
        #       "kube-system",
        #       "rook-ceph",
        #       "longhorn-system",
        #       "cattle-system",
        #       "tigera-operator",
        #       "monitoring",
        #     ]

    # Самого себя не мутируем
    objectSelector: |
      matchExpressions:
      - key: app.kubernetes.io/name
        operator: NotIn
        values:
        - {{ template "vault.name" . }}-agent-injector

    annotations: {}

  # TLS для вебхука:
  # Вариант A (рекомендуем на старте): доверь чарту → он сам создаст self-signed и пропишет caBundle в MWC.
  certs:
    secretName: null
    caBundle: ""
    certName: tls.crt
    keyName: tls.key

  # Вариант B (cert-manager) см. отдельный файл ниже.
  # Если будешь использовать cert-manager, здесь укажи:
  # certs:
  #   secretName: vault-injector-webhook-tls
  # webhook:
  #   annotations:
  #     cert-manager.io/inject-ca-from: "vault/vault-injector-webhook-tls"

  # Разложить реплики вебхука по разным нодам
  affinity: |
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/name: {{ template "vault.name" . }}-agent-injector
              app.kubernetes.io/instance: "{{ .Release.Name }}"
              component: webhook
          topologyKey: kubernetes.io/hostname

  podDisruptionBudget:
    maxUnavailable: 1

# =====================================================================
# Vault Server — HA на Raft, 3 реплики, Ingress
# =====================================================================
server:
  enabled: true

  image:
    repository: "hashicorp/vault"
    tag: "1.20.4"
    pullPolicy: IfNotPresent

  # Обновлять Pods вручную по одному (надёжно для StatefullSet)
  updateStrategyType: "OnDelete"

  resources:
    requests: { cpu: "250m", memory: "512Mi" }
    limits: { cpu: "1000m", memory: "1Gi" }

  # Доступ извне через nginx-ingress (RKE2)
  ingress:
    enabled: true
    ingressClassName: "nginx"
    pathType: Prefix
    activeService: true
    hosts:
      - host: vault.stroy-track.ru
        paths: ["/"]
    tls: [] # TLS терминирует ingress-контроллер

  # Kubernetes auth: даём server ServiceAccount нужные RBAC
  authDelegator:
    enabled: true

  # Проба готовности: считаем готовыми и standby
  readinessProbe:
    enabled: true
    port: 8200
    path: /v1/sys/health?standbyok=true&perfstandbyok=true
    initialDelaySeconds: 10
    periodSeconds: 5
    timeoutSeconds: 3
    failureThreshold: 2

  # Liveness включишь позже, когда конфиг стабилен
  livenessProbe:
    enabled: false

  # # PVC под данные Raft (пока longhorn; позже поменяешь на ceph)
  # dataStorage:
  #   enabled: true
  #   size: 10Gi
  #   storageClass: "longhorn"
  #   accessMode: ReadWriteOnce
  #   mountPath: "/vault/data"

  # PVC Ceph
  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: "ceph-rbd"
    accessMode: ReadWriteOnce
    mountPath: "/vault/data"

  # Не удалять PVC при scale/delete
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain

  # HA: Raft (кластер из 3 реплик)
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true

        listener "tcp" {
          tls_disable     = 1
          address         = "[::]:8200"
          cluster_address = "[::]:8201"
        }

        storage "raft" {
          path = "/vault/data"
          # автодискавери по Kubernetes (подхватит пэры)
          retry_join {
            auto_join = "provider=k8s namespace=vault label_selector=\"app.kubernetes.io/name=vault,component=server\""
          }
        }

        service_registration "kubernetes" {}

# UI-сервис (ClusterIP), поднимается вместе с server
ui:
  enabled: true
  publishNotReadyAddresses: true
  activeVaultPodOnly: false
  serviceType: "ClusterIP"

# CSI-провайдер (монтировать секреты как тома) — пока выкл.
csi:
  enabled: false
```

## Инициализация Vault

> Список Pods

```bash
kubectl -n vault get pods
```

> Инициализировать первый Pod

```bash
# Инициализировать vault-1760342381-0
kubectl -n vault exec -it <vault-1760342381-0> -c vault -- vault operator init

# Сохраните все 5 ключей и root token!
```

> Присоединить Pods к Pod

```bash
# Присоединить к первому Pod
kubectl -n vault exec -it vault-2 -c vault -- vault operator raft join http://vault-0.vault-internal:8200
```

> Распечатать Pod через

```bash
kubectl -n vault exec -it vault-2 -c vault -- vault operator unseal <Unseal-Key-1>
```

> Проверить статус Pod vault-2

```bash
# Проверить статус vault-1760342381-0
kubectl -n vault exec -it <vault-1760342381-0> -c vault -- vault status
```

> Инжекция

Включить матчинг вебхука на NS (чтоб apiserver вызывал вебхук vault-injector):

```bash
kubectl label ns my-apps vault.hashicorp.com/agent-injection=enabled --overwrite
```

Добавить аннотацию (annotation) на namespace для активации Vault injection

```bash
kubectl annotate ns my-apps vault.hashicorp.com/agent-injection="enabled" --overwrite
```

> Получить сертификаты для Vault UI

```bash
# Под Vault-сервера (любой)
POD=$(kubectl -n vault get pod -l app.kubernetes.io/name=vault,component=server -o jsonpath='{.items[0].metadata.name}')

# CA (скопируйте в UI "Kubernetes CA Certificate")
kubectl -n vault exec $POD -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# Token reviewer (скопируйте целиком в UI "Token Reviewer JWT")
kubectl -n vault exec $POD -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
# -----BEGIN CERTIFICATE-----
# MIIBeDCCAR+gAwIBAgIBADAKBggqhkjOPQQDAjAkMSIwIAYDVQQDDBlya2UyLXNl
# MIIBeDCCAR+gAwIBAgIBADAKBggqhkjOPQQDAjAkMSIwIAYDVQQDDBlya2UyLXNl
# cnZlci1jYUAxNzYwMjYzMTY5MB4XDTI1MTAxMjA5NTkyOVoXDTM1MTAxMDA5NTky
# OVowJDEiMCAGA1UEAwwZcmtlMi1zZXJ2ZXItY2FAMTc2MDI2MzE2OTBZMBMGByqG
# SM49AgEGCCqGSM49AwEHA0IABMAt04fWVWQTQINd2z/5R8sMvaHPkIunRem4CdI1
# EtNwqHWm4rbx7ywYN9dSWMmdLW+yIEaXxY2F3H6z+V4gw2WjQjBAMA4GA1UdDwEB
# /wQEAwICpDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBT5ZoaDvFPP92hFe+rX
# OwzH+pQrpDAKBggqhkjOPQQDAgNHADBEAiBvCyPReQy6YROfKYJR5YhY6B5oyn5f
# 3SFGLvre0CB83AIgNIhRNDdEHMYo0QByayiym5gGOqM1ZA4t7u0nhgnF1qY=
# -----END CERTIFICATE-----
# eyJhbGciOiJSUzI1NiIsImtpZCI6ImFCbnVIQW1tTDJKMEpFdzZxam1QQjVPZktQVTI4QzFieHhsZHBnekMxTkUifQ.eyJhdWQiOlsiaHR0cHM6Ly9rdWJlcm5ldGVzLmRlZmF1bHQuc3ZjLmNsdXN0ZXIubG9jYWwiLCJya2UyIl0sImV4cCI6MTc5MjEzODA0MSwiaWF0IjoxNzYwNjAyMDQxLCJpc3MiOiJodHRwczovL2t1YmVybmV0ZXMuZGVmYXVsdC5zdmMuY2x1c3Rlci5sb2NhbCIsImp0aSI6IjMyODIyMTY2LWE1ZDAtNGEyOC05OWI4LWRkYTUyNzQ2ZjI2MCIsImt1YmVybmV0ZXMuaW8iOnsibmFtZXNwYWNlIjoidmF1bHQiLCJub2RlIjp7Im5hbWUiOiJjb250cm9sLXdvcmtlci1tZDMzYmxscSIsInVpZCI6ImNhNzcwMTM5LWYzMjgtNDcyMC05NWYwLTRjZDQ3YTg3YWNjMCJ9LCJwb2QiOnsibmFtZSI6InZhdWx0LTE3NjAzNjM0NDAtMCIsInVpZCI6IjgxOGU0MjcwLWQ5MWMtNDZmMy1iODFhLTAwMDkwNGQ2MjI1ZSJ9LCJzZXJ2aWNlYWNjb3VudCI6eyJuYW1lIjoidmF1bHQtMTc2MDM2MzQ0MCIsInVpZCI6IjQ4ZjNjNmU2LWJiMWQtNDE0Ni1iYTk3LTk4NzMzMTY3ZGQ4MCJ9LCJ3YXJuYWZ0ZXIiOjE3NjA2MDU2NDh9LCJuYmYiOjE3NjA2MDIwNDEsInN1YiI6InN5c3RlbTpzZXJ2aWNlYWNjb3VudDp2YXVsdDp2YXVsdC0xNzYwMzYzNDQwIn0.NwtANi2AldDt9WRnIdInjW50MWbhjdOgMNjp7Xbh_h8qdCAcTI3hxdLZEtaCm4UakyLDFc3h5fSGc0O4jC1g0j1rhBqSLchcIoVwLEIknJs6qnM1GYyeTphE9-7SfKvjc4nS4lqURuBPPqoedKbEbeVY9tjYy6lfKrlzxolnRJlU1L8Kk553v2F80eSjP8o-4XmsUDuHpRQu-PmpfpswsXXkxAFON73vMdVGGjbPy1FIn19sigtZy7bVhntYl9mG3NfNemL57sVZZ5ocIkdlL-nM-zpjh4iDf3Qr6L1XOmSQIRmzewWu1jICbuQLrZkt4tF3p1fnhzN181pLHQRPxwroot@root@control:~#
```

> Test kubernetes vault connection

```bash
# Удалить старый
kubectl -n my-apps delete pod myapp-test

# Создать с правильным шаблоном
cat <<'EOF' | kubectl -n my-apps apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: myapp-test
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "myapp"
    vault.hashicorp.com/agent-inject-secret-app-config: "secret/data/app"
    vault.hashicorp.com/agent-inject-template-app-config: |
      {{- with secret "secret/data/app" -}}
      {{- range $k, $v := .Data.data }}
      export {{ $k | toUpper }}="{{ $v }}"
      {{- end }}
      {{- end -}}
spec:
  serviceAccountName: myapp-sa
  containers:
  - name: app
    image: busybox
    command: ['sh', '-c']
    args:
    - |
      echo "==============================================="
      echo "  Vault секреты успешно инъектированы!"
      echo "==============================================="
      cat /vault/secrets/app-config
      echo ""
      echo "✅ Секреты загружены!"
      sleep 3600
EOF

# Следить за запуском
kubectl -n my-apps get pod myapp-test -w

# Просмотреть логи
kubectl -n my-apps logs myapp-test -c app
```

## Инициализация Vault через UI

> Выбрать Create инициализацию Vault

- Указать сколько создать ключей unseal для разблокировки Vault (5 шт)
- Указать сколько ключей unseal для разблокировки Vault нужно ввести (3 шт)

> Подключение к Vault UI (forwarding/domain/port) и выбрать Unseal (подключение к Vault через UI)

- Этот DNS адрес автоматически разрешается внутри Kubernetes:
  - vault-0 - имя первого пода StatefulSet
  - vault-internal - имя headless service (создается автоматически Helm chart'ом)
  - 8200 - порт Vault API

```yml
## Адрес подключения к Vault через UI
http://vault-0.vault-internal:8200
```

## 📋 Настройка Vault Injection для приложений Пошаговая инструкция

### ✅ Checklist перед использованием

- [ ] Label на namespace: `vault.hashicorp.com/agent-injection=enabled`
- [ ] ServiceAccount создан
- [ ] Политика в Vault создана с правами на нужные пути
- [ ] Роль в Vault создана и привязана к SA и namespace
- [ ] Секрет в Vault существует
- [ ] Pod использует правильный ServiceAccount
- [ ] Аннотации в Pod корректные

### Шаг 1: Включить Vault injection для namespace

```bash
# Добавить label для активации webhook
kubectl label namespace my-apps vault.hashicorp.com/agent-injection=enabled

# Проверить
kubectl get namespace my-apps --show-labels
```

**⚠️ КРИТИЧНО**: Без этого label webhook НЕ будет вызываться для подов в namespace!

### Шаг 2: Создать ServiceAccount для приложения

```bash
# Создать ServiceAccount
kubectl -n my-apps create serviceaccount myapp-sa

# Проверить
kubectl -n my-apps get serviceaccount myapp-sa
```

### Шаг 3: Настроить Vault через UI

**1. Создать политику (Policy)**

1. Vault UI → **Policies** → **Create ACL policy**
2. **Name**: `myapp`
3. **Policy**:

```hcl
# Доступ к секрету secret/data/app
path "secret/data/app" {
  capabilities = ["read"]
}

# Можно добавить другие пути
path "secret/data/myapp/*" {
  capabilities = ["read", "list"]
}
```

4. **Create policy**

**2. Создать роль Kubernetes auth**

1. Vault UI → **Access** → **Authentication Methods** → **kubernetes/**
2. Вкладка **Roles** → **Create role**
3. Заполнить:
   - **Name**: `myapp`
   - **Bound service account names**: `myapp-sa` (или `*` для всех SA в namespace)
   - **Bound service account namespaces**: `my-apps`
   - **Generated Token's Policies**: выбрать `myapp`
   - **Generated Token's Period**: `86400` (24 часа)
4. **Save**

   **3. Создать секрет**

5. Vault UI → **Secrets** → **secret/** (KV v2)
6. **Create secret**
7. **Path for this secret**: `app`
8. Добавить данные:
   ```
   Key: database_url    Value: postgres://db:5432/mydb
   Key: api_key         Value: secret-api-key-123
   Key: password        Value: s3cr3t
   ```
9. **Save**

### Шаг 4: Создать Pod с инъекцией секретов

```bash
cat <<'EOF' | kubectl -n my-apps apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: myapp
  annotations:
    # Включить Vault injection
    vault.hashicorp.com/agent-inject: "true"

    # Роль для аутентификации
    vault.hashicorp.com/role: "myapp"

    # Инъектировать секрет в /vault/secrets/config
    vault.hashicorp.com/agent-inject-secret-config: "secret/data/app"

    # Шаблон форматирования (shell exports)
    vault.hashicorp.com/agent-inject-template-config: |
      {{- with secret "secret/data/app" -}}
      {{- range $k, $v := .Data.data }}
      export {{ $k | toUpper }}="{{ $v }}"
      {{- end }}
      {{- end -}}
spec:
  serviceAccountName: myapp-sa
  containers:
  - name: app
    image: busybox
    command: ['sh', '-c']
    args:
    - |
      # Загрузить секреты из Vault
      source /vault/secrets/config

      echo "Приложение запущено с секретами из Vault!"
      echo "DATABASE_URL=$DATABASE_URL"

      # Запуск приложения
      sleep 3600
EOF
```

### Шаг 5: Проверка

```bash
# Статус пода (должен быть 2/2 Running)
kubectl -n my-apps get pod myapp

# Посмотреть логи приложения
kubectl -n my-apps logs myapp -c app

# Посмотреть секреты
kubectl -n my-apps exec myapp -c app -- cat /vault/secrets/config
```

## 📝 Шаблоны для разных форматов

**JSON формат:**

```yaml
vault.hashicorp.com/agent-inject-template-config.json: |
  {{- with secret "secret/data/app" -}}
  {
    "database_url": "{{ .Data.data.database_url }}",
    "api_key": "{{ .Data.data.api_key }}"
  }
  {{- end -}}
```

**.env формат:**

```yaml
vault.hashicorp.com/agent-inject-template-app.env: |
  {{- with secret "secret/data/app" -}}
  DATABASE_URL={{ .Data.data.database_url }}
  API_KEY={{ .Data.data.api_key }}
  {{- end -}}
```

**Raw (без шаблона):**

```yaml
vault.hashicorp.com/agent-inject-secret-config: "secret/data/app"
# Создаст файл со всеми данными в формате key=value
```
