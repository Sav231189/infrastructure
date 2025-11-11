# Headlamp - Kubernetes Web UI

Headlamp — веб-интерфейс для управления Kubernetes кластером.

## Что такое Headlamp

Headlamp — это современный веб-интерфейс для Kubernetes, который позволяет:

- Просматривать и управлять ресурсами кластера (Pods, Deployments, Services, etc.)
- Мониторить метрики и логи
- Управлять приложениями через удобный UI
- Расширять функционал через плагины

## Установка Headlamp

### Шаг 1: Добавить Helm репозиторий

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update
```

### Шаг 2: Установка Headlamp

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

helm install my-headlamp headlamp/headlamp \
  --namespace kube-system \
  --set config.pluginsDir=/headlamp-plugins
```

### Шаг 3: Настройка Ingress (для внешнего доступа)

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Создать Ingress
cat <<EOF | kubectl -n kube-system apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: headlamp
  namespace: kube-system
spec:
  ingressClassName: nginx
  rules:
  - host: headlamp.stroy-track.ru
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-headlamp
            port:
              number: 80
EOF
```

### Шаг 4: Проверка установки

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Проверить статус
kubectl -n kube-system get deployment my-headlamp
kubectl -n kube-system get pods -l app.kubernetes.io/name=headlamp

# Дождаться готовности
kubectl -n kube-system rollout status deployment/my-headlamp

# Проверить сервис
kubectl -n kube-system get svc my-headlamp
```

### Шаг 5: Получение токена для входа

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

kubectl create token my-headlamp --namespace kube-system
```

**Результат:** Скопируйте полученный токен — он понадобится для входа в Headlamp UI.

---

## Доступ к Headlamp

1. Откройте браузер и перейдите по адресу: `https://headlamp.stroy-track.ru`
2. Введите токен, полученный на Шаге 5
3. Нажмите "Sign in"

---

## Установка плагинов

Headlamp поддерживает плагины для расширения функционала. Доступные плагины:

- **Flux** — управление GitOps с Flux
- **KEDA** — автоматическое масштабирование
- **cert-manager** — управление сертификатами
- **Karpenter** — автоматическое управление нодами
- **Prometheus** — встроен по умолчанию

### Метод установки через initContainer (рекомендуется)

#### Шаг 1: Подготовка values-файла

Создайте файл `/tmp/headlamp-plugin-values.yaml` **на мастере кластера**:

```bash
cat > /tmp/headlamp-plugin-values.yaml << 'EOF'
config:
  pluginsDir: /build/plugins

initContainers:
  - name: headlamp-plugin-<PLUGIN_NAME>
    image: ghcr.io/headlamp-k8s/headlamp-plugin-<PLUGIN_NAME>:latest
    imagePullPolicy: Always
    command:
      - /bin/sh
      - -c
      - mkdir -p /build/plugins && cp -r /plugins/* /build/plugins/ && chown -R 100:101 /build
    securityContext:
      runAsNonRoot: false
      runAsUser: 0
      runAsGroup: 0
    volumeMounts:
      - mountPath: /build/plugins
        name: headlamp-plugins

volumeMounts:
  - mountPath: /build/plugins
    name: headlamp-plugins

volumes:
  - name: headlamp-plugins
    emptyDir: {}
EOF
```

**Важно:** Замените `<PLUGIN_NAME>` на имя плагина (например: `flux`, `keda`, `cert-manager`)

#### Шаг 2: Проверка доступности образа плагина

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Проверить что образ плагина доступен
kubectl run test-plugin --image=ghcr.io/headlamp-k8s/headlamp-plugin-flux:latest \
  --rm -i --restart=Never -- ls /plugins
```

#### Шаг 3: Обновление Headlamp через Helm

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Dry-run для проверки конфигурации
helm upgrade my-headlamp headlamp/headlamp \
  -n kube-system \
  --reuse-values \
  -f /tmp/headlamp-plugin-values.yaml \
  --dry-run

# Если dry-run успешен, применяем изменения
helm upgrade my-headlamp headlamp/headlamp \
  -n kube-system \
  --reuse-values \
  -f /tmp/headlamp-plugin-values.yaml
```

#### Шаг 4: Проверка установки плагина

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Проверить статус rollout
kubectl -n kube-system rollout status deployment/my-headlamp

# Проверить что initContainer выполнился успешно
kubectl -n kube-system get pod -l app.kubernetes.io/name=headlamp \
  -o jsonpath='{.items[0].status.initContainerStatuses[0].state}'

# Проверить что плагин скопирован
kubectl -n kube-system exec deployment/my-headlamp -- ls -la /build/plugins

# Проверить логи Headlamp
kubectl -n kube-system logs deployment/my-headlamp | grep -i plugin
```

#### Шаг 5: Проверка плагина в UI

1. Откройте Headlamp UI: `https://headlamp.stroy-track.ru`
2. Перейдите в **Settings** → **Plugins**
3. Убедитесь, что плагин появился в списке

---

## Пример: Установка плагина Flux

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# 1. Создать values-файл НА МАСТЕРЕ
cat > /tmp/flux-plugin.yaml << 'EOF'
config:
  pluginsDir: /build/plugins
initContainers:
  - name: headlamp-flux-plugin
    image: ghcr.io/headlamp-k8s/headlamp-plugin-flux:latest
    imagePullPolicy: Always
    command:
      - /bin/sh
      - -c
      - mkdir -p /build/plugins && cp -r /plugins/* /build/plugins/ && chown -R 100:101 /build
    securityContext:
      runAsNonRoot: false
      runAsUser: 0
      runAsGroup: 0
    volumeMounts:
      - mountPath: /build/plugins
        name: headlamp-plugins
volumeMounts:
  - mountPath: /build/plugins
    name: headlamp-plugins
volumes:
  - name: headlamp-plugins
    emptyDir: {}
EOF

# 2. Применить изменения
helm upgrade my-headlamp headlamp/headlamp \
  -n kube-system \
  --reuse-values \
  -f /tmp/flux-plugin.yaml

# 3. Дождаться готовности
kubectl -n kube-system rollout status deployment/my-headlamp

# 4. Проверить
kubectl -n kube-system exec deployment/my-headlamp -- ls -la /build/plugins/flux
```

---

## Где смотреть установленные плагины

### В UI Headlamp:

1. Откройте `https://headlamp.stroy-track.ru`
2. В левом меню нажмите **Settings** (шестеренка)
3. Выберите **Plugins**
4. В списке будут видны все установленные плагины с их статусом (Enabled/Disabled)

### Через kubectl:

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Список плагинов в поде
kubectl -n kube-system exec deployment/my-headlamp -- ls -la /build/plugins

# Встроенные плагины
kubectl -n kube-system exec deployment/my-headlamp -- ls -la /headlamp/static-plugins

# Проверить логи загрузки плагинов
kubectl -n kube-system logs deployment/my-headlamp | grep -i plugin
```

---

## Проверка работоспособности

### Базовая проверка:

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Статус deployment
kubectl -n kube-system get deployment my-headlamp

# Статус подов
kubectl -n kube-system get pods -l app.kubernetes.io/name=headlamp

# Логи
kubectl -n kube-system logs deployment/my-headlamp --tail=50

# Проверка сервиса
kubectl -n kube-system get svc my-headlamp

# Проверка ingress
kubectl -n kube-system get ingress headlamp
```

---

## Управление Headlamp

### Обновление Headlamp:

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

helm repo update
helm upgrade my-headlamp headlamp/headlamp -n kube-system --reuse-values
```

### Удаление Headlamp:

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

helm uninstall my-headlamp -n kube-system
kubectl delete ingress headlamp -n kube-system
```

### Получить текущие значения Helm:

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

helm get values my-headlamp -n kube-system
```

---

## Полезные ссылки

- Официальная документация: https://headlamp.dev/
- Репозиторий плагинов: https://github.com/headlamp-k8s/plugins
- Helm chart: https://github.com/kubernetes-sigs/headlamp/tree/main/charts/headlamp

---

## Текущая конфигурация

- **Namespace:** `kube-system`
- **Release name:** `my-headlamp`
- **URL:** `https://headlamp.stroy-track.ru`
- **Plugins dir:** `/build/plugins`
- **Установленные плагины:**
  - Prometheus (встроен, находится в `/headlamp/static-plugins`)
  - Flux (установлен через initContainer, находится в `/build/plugins`)
