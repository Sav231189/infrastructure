# Безопасность контейнеров

## 1. Harbor Registry - Image Scanning

### Установка Harbor

```bash
# Через Helm
helm repo add harbor https://helm.goharbor.io
helm install harbor harbor/harbor \
  --namespace harbor \
  --create-namespace \
  --set expose.type=nodePort \
  --set expose.nodePort.ports.https.nodePort=30443 \
  --set externalURL=https://harbor.stroy-track.ru \
  --set persistence.enabled=true \
  --set persistence.persistentVolumeClaim.registry.storageClass=longhorn \
  --set persistence.persistentVolumeClaim.registry.size=50Gi \
  --set trivy.enabled=true
```

### Настройка Trivy сканирования

```bash
# В Harbor UI:
# Administration → Interrogation Services → Trivy
# - Включить автоматическое сканирование
# - Scan on push: enabled
# - Prevent vulnerable images from running: enabled
# - Severity level: High, Critical
```

### Политика блокировки уязвимых образов

```yaml
# Harbor Project → Configuration → CVE Allowlist
# Заблокировать образы с Critical/High уязвимостями

# Webhook для уведомлений
apiVersion: v1
kind: ConfigMap
metadata:
  name: harbor-webhook
  namespace: harbor
data:
  webhook.yaml: |
    targets:
    - type: http
      address: https://slack.com/api/webhooks/xxx
      skip_cert_verify: false
    event_types:
    - SCANNING_FAILED
    - SCANNING_COMPLETED
```

### Signed Images (Notary)

```bash
# Включить content trust
export DOCKER_CONTENT_TRUST=1
export DOCKER_CONTENT_TRUST_SERVER=https://harbor.stroy-track.ru:4443

# Подписать образ
docker trust sign harbor.stroy-track.ru/stroy-track/gateway:v1.0.0

# Проверка подписи
docker trust inspect harbor.stroy-track.ru/stroy-track/gateway:v1.0.0
```

## 2. Kubernetes Admission Controller

### Принимать только подписанные образы

```yaml
# OPA Gatekeeper Constraint
apiVersion: templates.gatekeeper.sh/v1beta1
kind: ConstraintTemplate
metadata:
  name: k8srequirednotary
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredNotary
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequirednotary

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not startswith(container.image, "harbor.stroy-track.ru/")
          msg := sprintf("Image %v must be from Harbor registry", [container.image])
        }

---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredNotary
metadata:
  name: require-harbor-images
spec:
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment", "StatefulSet"]
    namespaces:
      - "apps"
```

## 3. Runtime Security

### Pod Security Standards

```yaml
# Enforce Restricted на production namespaces
apiVersion: v1
kind: Namespace
metadata:
  name: apps
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

### Рекомендуемый Security Context

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
spec:
  template:
    spec:
      # Pod-level security
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: gateway
          image: harbor.stroy-track.ru/stroy-track/gateway:v1.0.0

          # Container-level security
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop:
                - ALL
              # Если нужны специфичные capabilities:
              # add:
              # - NET_BIND_SERVICE  # для портов < 1024

          # Volumes для writable paths
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /app/.cache

      volumes:
        - name: tmp
          emptyDir: {}
        - name: cache
          emptyDir: {}
```

### Resource Limits

```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"
# Предотвращает:
# - OOM bombs
# - CPU exhaustion
# - Resource starvation
```

## 4. Image Build Best Practices

### Multi-stage Build

```dockerfile
# Плохо: образ с build tools в production
FROM node:18
WORKDIR /app
COPY . .
RUN npm install
CMD ["node", "index.js"]

# Хорошо: multi-stage build
# Stage 1: Build
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
RUN npm run build

# Stage 2: Production
FROM node:18-alpine
RUN apk add --no-cache dumb-init
WORKDIR /app

# Создать non-root user
RUN addgroup -g 10001 appuser && \
    adduser -D -u 10001 -G appuser appuser

# Копировать только необходимое
COPY --from=builder --chown=appuser:appuser /app/dist ./dist
COPY --from=builder --chown=appuser:appuser /app/node_modules ./node_modules
COPY --chown=appuser:appuser package*.json ./

USER appuser

# Используем dumb-init для proper signal handling
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "dist/main.js"]
```

### Минимизация слоев и размера

```dockerfile
# Плохо: много слоев
RUN apt-get update
RUN apt-get install -y package1
RUN apt-get install -y package2
RUN apt-get clean

# Хорошо: один слой
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      package1 \
      package2 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
```

### .dockerignore

```
# .dockerignore
node_modules
npm-debug.log
.git
.gitignore
README.md
.env
.env.*
dist
coverage
.vscode
.idea
*.md
Dockerfile
.dockerignore
```

## 5. Continuous Scanning

### Woodpecker CI Pipeline

```yaml
# .woodpecker.yml
pipeline:
  build:
    image: node:18-alpine
    commands:
      - npm ci
      - npm run build
      - npm test

  docker:
    image: plugins/docker
    settings:
      registry: harbor.stroy-track.ru
      repo: harbor.stroy-track.ru/stroy-track/gateway
      tags: ${CI_COMMIT_SHA}
      username:
        from_secret: harbor_username
      password:
        from_secret: harbor_password

  # Дождаться сканирования Harbor
  wait-scan:
    image: curlimages/curl
    commands:
      - sleep 30 # Дать время на сканирование
      - |
        # Проверить результаты сканирования
        SCAN_RESULT=$(curl -u admin:password \
          https://harbor.stroy-track.ru/api/v2.0/projects/stroy-track/repositories/gateway/artifacts/${CI_COMMIT_SHA}/scan)

        CRITICAL=$(echo $SCAN_RESULT | jq '.vulnerabilities.critical')
        HIGH=$(echo $SCAN_RESULT | jq '.vulnerabilities.high')

        if [ "$CRITICAL" -gt "0" ] || [ "$HIGH" -gt "5" ]; then
          echo "Too many vulnerabilities: Critical=$CRITICAL, High=$HIGH"
          exit 1
        fi

  # Обновить Git с новым тегом
  update-manifest:
    image: alpine/git
    commands:
      - git clone https://github.com/your-org/stroy-track-deploy.git
      - cd stroy-track-deploy
      - |
        sed -i "s|image: .*gateway:.*|image: harbor.stroy-track.ru/stroy-track/gateway:${CI_COMMIT_SHA}|" \
          apps/gateway/deployment.yaml
      - git commit -am "Update gateway to ${CI_COMMIT_SHA}"
      - git push
```

## 6. Runtime Monitoring с Falco

### Установка Falco

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco-system \
  --create-namespace \
  --set falco.grpc.enabled=true \
  --set falco.grpcOutput.enabled=true
```

### Custom Rules для StoryTrack

```yaml
# /etc/falco/rules.d/stroy-track.yaml
- rule: Unauthorized Process in Container
  desc: Detect unauthorized process execution
  condition: >
    spawned_process and 
    container and
    k8s.ns.name = "apps" and
    not proc.name in (node, npm, sh, bash)
  output: >
    Unauthorized process in container
    (user=%user.name process=%proc.name container=%container.name)
  priority: WARNING

- rule: Write to Non-Tmp Directory
  desc: Detect writes outside /tmp or /app/.cache
  condition: >
    open_write and
    container and
    k8s.ns.name = "apps" and
    not fd.name startswith /tmp and
    not fd.name startswith /app/.cache
  output: >
    Write to read-only filesystem
    (file=%fd.name container=%container.name)
  priority: ERROR

- rule: Container Drift Detection
  desc: Detect new executable created in container
  condition: >
    spawned_process and
    container and
    proc.is_exe_from_memfd = true
  output: >
    Container drift detected - executable created at runtime
    (process=%proc.name container=%container.name)
  priority: CRITICAL
```

## Monitoring и Alerts

```yaml
# Prometheus alerts
- alert: VulnerableImageDeployed
  expr: harbor_project_vulnerabilities{severity="Critical"} > 0
  for: 1m

- alert: UnauthorizedImageRegistry
  expr: increase(kube_pod_container_status_running{image!~"harbor.stroy-track.ru/.*"}[5m]) > 0
  for: 1m

- alert: FalcoRuntimeViolation
  expr: increase(falco_events{priority="ERROR"}[5m]) > 0
  for: 1m

- alert: ContainerRunningAsRoot
  expr: kube_pod_container_status_running{security_context_run_as_user="0"} > 0
  for: 5m
```

## Checklist

- [ ] Harbor установлен с Trivy scanning
- [ ] Автоматическое сканирование on push
- [ ] Блокировка Critical/High уязвимостей
- [ ] Signed images (Notary)
- [ ] Только образы из Harbor в production
- [ ] Pod Security Standards: restricted
- [ ] Security Context во всех deployments
- [ ] Resource limits установлены
- [ ] Multi-stage builds используются
- [ ] Non-root user в контейнерах
- [ ] Read-only root filesystem
- [ ] Falco установлен с custom rules
- [ ] CI/CD проверяет уязвимости перед deploy
