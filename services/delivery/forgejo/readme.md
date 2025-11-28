# Forgejo - Git Hosting Service

## Установка

### 1. Создать namespace

```bash
kubectl create namespace git
```

### 2. Добавить Secret для credentials

```bash
kubectl create secret generic forgejo-credentials \
  --namespace git \
  --from-literal=username=CHANGEME \
  --from-literal=password=CHANGEME
```

> Важно: Secret должен быть в том же namespace, что и Forgejo

### 2. Установить Forgejo через Helm

```bash
helm repo add forgejo https://codeberg.org/forgejo-contrib/helm-charts
helm repo update

helm install forgejo forgejo/forgejo \
  --namespace git \
  --values values.yml
```

### 3. Обновить значения в values.yml и перезапустить deployment

```bash
helm upgrade forgejo forgejo/forgejo \
  --namespace git \
  --values values.yml
```

## Настройка SSH

- Добавить ConfigMap для SSH проброса через nginx-ingress и перезапустить контроллер nginx-ingress
- ConfigMap - ./forgejo-ssh-tcp-configmap.yaml

> Важно: В ConfigMap должен быть указан namespace, в котором установлен ingress-nginx-controller

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tcp-services
  namespace: kube-system
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
data:
  "22": "git/forgejo-ssh:22"
EOF
```
