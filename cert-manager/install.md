**🛠️ Установка cert-manager в kubernetes** 
```bash
# Создать namespace для cert-manager
kubectl create namespace cert-manager
# Добавить репозиторий Jetstack
helm repo add jetstack https://charts.jetstack.io
helm repo update
# kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.crds.yaml
# Установить cert-manager через Helm
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true
```