# Контроль доступа

## 1. Vault - Управление секретами

### Dynamic Secrets для баз данных

```bash
# Включить database secrets engine
vault secrets enable database

# Настроить подключение к Citus
vault write database/config/citus \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-role" \
  connection_url="postgresql://{{username}}:{{password}}@citus-coordinator:5432/stroy_track" \
  username="vault" \
  password="vault-password"

# Создать роль с TTL
vault write database/roles/app-role \
  db_name=citus \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

# Получить временные credentials
vault read database/creds/app-role
# Key                Value
# ---                -----
# lease_id           database/creds/app-role/2f6a614c
# lease_duration     1h
# password           A1a-y7CvQBWPVTNp3c6N
# username           v-root-app-role-2f6a614c
```

### Автоматическая ротация секретов

```yaml
# External Secrets Operator для синхронизации с K8s
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: apps
spec:
  provider:
    vault:
      server: "http://vault.control.svc:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "apps-role"
          serviceAccountRef:
            name: "app-sa"

---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: database-credentials
  namespace: apps
spec:
  refreshInterval: 1h # Обновлять каждый час
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: db-secret
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: database/creds/app-role
        property: username
    - secretKey: password
      remoteRef:
        key: database/creds/app-role
        property: password
```

### Шифрование данных (Transit Engine)

```bash
# Включить transit engine
vault secrets enable transit

# Создать ключ шифрования
vault write -f transit/keys/customer-data

# Зашифровать данные
vault write transit/encrypt/customer-data \
  plaintext=$(echo "sensitive data" | base64)
# Key           Value
# ---           -----
# ciphertext    vault:v1:8SDd3WHDOjf7mq69CyCqYjBXAiQQAVZRkFM13ok481zoCmHnSeDX9vyf7w==

# Расшифровать
vault write transit/decrypt/customer-data \
  ciphertext="vault:v1:8SDd3WHDOjf7mq69CyCqYjBXAiQQAVZRkFM13ok481zoCmHnSeDX9vyf7w=="
```

## 2. Kubernetes RBAC

### Least Privilege Principle

```yaml
# Service Account для apps
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: apps

---
# Role с минимальными правами
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: app-role
  namespace: apps
rules:
  # Только чтение своих pods
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
    resourceNames: ["gateway-*", "auth-*"]

  # Только чтение secrets
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    resourceNames: ["db-secret", "minio-secret"]

  # Только чтение configmaps
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]

---
# Binding
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-rolebinding
  namespace: apps
subjects:
  - kind: ServiceAccount
    name: app-sa
    namespace: apps
roleRef:
  kind: Role
  name: app-role
  apiGroup: rbac.authorization.k8s.io
```

### RBAC для админов

```yaml
# Admin Role (полный доступ к namespace)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: namespace-admin
  namespace: apps
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]

---
# Developer Role (ограниченный доступ)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer
  namespace: apps
rules:
  # Чтение всего
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]

  # Создание/обновление pods, deployments
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["create", "update", "patch"]

  # Логи pods
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get", "list"]
# НЕТ доступа к secrets!
```

### MFA для админов

```bash
# Rancher уже поддерживает MFA через:
# - Google Authenticator
# - Okta
# - Azure AD

# Включить MFA в Rancher UI:
# User Settings → Enable Two-Factor Authentication

# Для kubectl доступа использовать kubelogin с Azure AD
kubectl oidc-login setup \
  --oidc-issuer-url=https://login.microsoftonline.com/TENANT_ID/v2.0 \
  --oidc-client-id=CLIENT_ID
```

## 3. Pod Security Standards

### Enforce Restricted Policy

```yaml
# На уровне namespace
apiVersion: v1
kind: Namespace
metadata:
  name: apps
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

### Security Context в Deployments

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
  namespace: apps
spec:
  template:
    spec:
      # Запретить escalation privileges
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: gateway
          image: harbor.stroy-track.ru/gateway:v1.0.0

          # Container-level security
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 1000
            capabilities:
              drop:
                - ALL

          # Resource limits
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            limits:
              memory: "1Gi"
              cpu: "1000m"

          # Readiness/liveness probes
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 10

          readinessProbe:
            httpGet:
              path: /ready
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
```

## 4. Admission Controllers

### OPA Gatekeeper для политик

```yaml
# Установка
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/master/deploy/gatekeeper.yaml

# Constraint Template: Запретить latest тег
apiVersion: templates.gatekeeper.sh/v1beta1
kind: ConstraintTemplate
metadata:
  name: k8snolatestimages
spec:
  crd:
    spec:
      names:
        kind: K8sNoLatestImages
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8snolatestimages

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          endswith(container.image, ":latest")
          msg := sprintf("Container %v uses :latest tag", [container.name])
        }

---
# Применить политику
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sNoLatestImages
metadata:
  name: no-latest-images
spec:
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment", "StatefulSet"]
    namespaces:
      - "apps"
```

### Политика: Обязательные labels

```yaml
apiVersion: templates.gatekeeper.sh/v1beta1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
      validation:
        openAPIV3Schema:
          properties:
            labels:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels

        violation[{"msg": msg}] {
          required := input.parameters.labels[_]
          not input.review.object.metadata.labels[required]
          msg := sprintf("Missing required label: %v", [required])
        }

---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: required-labels
spec:
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment"]
  parameters:
    labels:
      - "app"
      - "version"
      - "owner"
```

## Мониторинг и аудит

```yaml
# Alert на создание privileged pod
- alert: PrivilegedPodCreated
  expr: increase(kube_pod_container_status_running{security_context_privileged="true"}[5m]) > 0
  for: 1m

# Alert на доступ к секретам
- alert: UnauthorizedSecretAccess
  expr: increase(apiserver_audit_event_total{verb="get",objectRef_resource="secrets"}[5m]) > 10
  for: 2m

# Alert на изменение RBAC
- alert: RBACChanged
  expr: increase(apiserver_audit_event_total{objectRef_resource=~"roles|rolebindings"}[5m]) > 0
  for: 1m
```

## Checklist

- [ ] Vault установлен и настроен
- [ ] Dynamic secrets для баз данных
- [ ] External Secrets Operator синхронизирует секреты
- [ ] Автоматическая ротация секретов (TTL 1-24h)
- [ ] RBAC: least privilege для всех service accounts
- [ ] MFA включен для всех админов
- [ ] Pod Security Standards: restricted
- [ ] Security Context во всех deployments
- [ ] OPA Gatekeeper с политиками
- [ ] Мониторинг доступа к секретам
- [ ] Audit log включен
- [ ] Регулярный аудит RBAC правил
