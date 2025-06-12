**Install (interactive) AWX on K3s**:
```bash
#!/usr/bin/env bash
set -euo pipefail

# ==== Проверка root-доступа ====
if [[ $EUID -ne 0 ]]; then
  echo "❌ Этот скрипт должен быть запущен от имени root."
  exit 1
fi

# ==== Конфигурация ====
AWX_NAMESPACE="awx"
SECRET_NAME="awx-admin-password"
AWX_CR_FILE="awx-cr.yaml"
NODE_PORT="30080"
HELM_RELEASE="awx-operator"
HELM_REPO_NAME="awx-operator"
HELM_REPO_URL="https://ansible-community.github.io/awx-operator-helm/"
KUBECONFIG_FILE="/etc/rancher/k3s/k3s.yaml"
export KUBECONFIG=${KUBECONFIG:-$KUBECONFIG_FILE}
TIMEOUT="10m"

# ==== Проверка зависимостей ====
function check_deps() {
  for cmd in kubectl helm openssl fallocate free df; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "❌ Требуется установить: $cmd"
      exit 1
    fi
  done
}

# ==== Проверка ресурсов ====
function check_resources() {
  echo "🔍 Проверка ресурсов..."
  local free_space_gb=$(df -BG / | awk 'NR==2 {gsub("G", "", $4); print $4}')
  local mem_total=$(free -m | awk '/^Mem:/ {print $2}')
  local mem_free=$(free -m | awk '/^Mem:/ {print $7}')
  local swap_total=$(free -m | awk '/^Swap:/ {print $2}')
  local swap_used=$(free -m | awk '/^Swap:/ {print $3}')

  echo "📊 RAM: ${mem_total} MB total, ${mem_free} MB free"
  echo "💽 Disk: ${free_space_gb} GB available"
  echo "🔄 Swap: ${swap_total} MB total, ${swap_used} MB used"

  if (( free_space_gb < 3 )); then
    echo "⚠️ Недостаточно места на / (<3GB). Освободите диск."
    exit 1
  fi

  if (( mem_free < 1500 )); then
    echo "⚠️ Недостаточно свободной памяти (<1.5GB). Добавим swap."
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
}

function ensure_namespace() {
  kubectl create ns "$AWX_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

function ensure_helm_repo() {
  helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" 2>/dev/null || true
  helm repo update
}

function ensure_local_path_provisioner() {
  echo "🔍 Проверка local-path-provisioner..."

  if ! kubectl get ns local-path-storage &>/dev/null || \
    ! kubectl get pods -n local-path-storage 2>/dev/null | grep -q 'local-path-provisioner.*Running'; then
    echo "📦 Устанавливаем local-path-provisioner..."
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

    echo "⏳ Ожидание запуска local-path-provisioner..."
    kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=60s || {
      echo "❌ Не удалось запустить local-path-provisioner."
      exit 1
    }
  else
    echo "✅ local-path-provisioner уже установлен."
  fi
}

function wait_for_pods() {
  echo "⏳ Ожидание готовности pod’ов в namespace $AWX_NAMESPACE..."
  kubectl wait pod -n "$AWX_NAMESPACE" --for=condition=Ready --all --timeout=$TIMEOUT || true
}

function install_awx() {
  echo -e "\n🚀 Установка AWX Operator и AWX..."
  read -rp "Введите домен для AWX (например ansible.stroy-track.ru): " domain
  read -rp "Логин администратора [admin]: " admin_user
  admin_user=${admin_user:-admin}
  read -rp "Введите NodePort [30080]: " node_port
  node_port=${node_port:-30080}

  NODE_PORT="$node_port" # переопределяем глобальную переменную

  ensure_namespace
  ensure_helm_repo
  ensure_local_path_provisioner
  helm upgrade --install "$HELM_RELEASE" "$HELM_REPO_NAME/awx-operator" -n "$AWX_NAMESPACE"

  admin_pass=$(openssl rand -base64 16)
  kubectl create secret generic "$SECRET_NAME" \
    --from-literal=password="$admin_pass" -n "$AWX_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  cat > "$AWX_CR_FILE" <<EOF
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
  namespace: $AWX_NAMESPACE
spec:
  service_type: NodePort
  ingress_type: none
  hostname: $domain
  replicas: 1
  admin_user: $admin_user
  admin_password_secret: $SECRET_NAME
  projects_persistence: true
  projects_storage_size: 1Gi
  projects_storage_class: local-path
  projects_storage_access_mode: ReadWriteOnce
EOF

  echo "🔧 Применяем CR..."
  kubectl apply -f "$AWX_CR_FILE"

  echo "⏳ Ожидание появления awx-service..."
  for i in {1..60}; do
    if kubectl get svc awx-service -n "$AWX_NAMESPACE" &>/dev/null; then
      echo "✅ Сервис найден. Патчим порт $NODE_PORT..."
      kubectl patch svc awx-service -n "$AWX_NAMESPACE" --type='json' -p \
        "[{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${NODE_PORT}}]"
      break
    fi
    echo -n "."; sleep 5
  done

  if ! kubectl get svc awx-service -n "$AWX_NAMESPACE" &>/dev/null; then
    echo -e "\n⚠️  Сервис awx-service не появился. Порт не пропатчен."
  fi

  wait_for_pods
  add_demo_playbook

  echo -e "\n✅ AWX установлен!"
  echo "🌐 URL: http://${domain}:${NODE_PORT}"
  echo "👤 Логин: $admin_user"
  echo "🔑 Пароль: $admin_pass"
}

function get_bootstrap_password() {
  echo -e "\n🔑 Bootstrap-пароль:"
  kubectl get secret "$SECRET_NAME" -n "$AWX_NAMESPACE" -o jsonpath="{.data.password}" | base64 -d
  echo
}

function check_status() {
  echo -e "\n🔍 Статус в namespace $AWX_NAMESPACE:"
  kubectl get pods,svc -n "$AWX_NAMESPACE" || true
}

function uninstall_awx() {
  echo -e "\n🧹 Удаление AWX и Operator..."
  kubectl delete -f "$AWX_CR_FILE" --ignore-not-found
  kubectl delete secret "$SECRET_NAME" -n "$AWX_NAMESPACE" --ignore-not-found
  kubectl delete pvc --all -n "$AWX_NAMESPACE" --ignore-not-found
  helm uninstall "$HELM_RELEASE" -n "$AWX_NAMESPACE" --timeout 2m || true
  kubectl delete namespace "$AWX_NAMESPACE" --ignore-not-found
  echo "✅ Удалено."
}

function connect_to_awx() {
  kubectl exec -n "$AWX_NAMESPACE" awx-task -- /bin/bash
  # kubectl exec -n awx -it awx-task-65644cc448-bsm6w -- bash
  # cd /var/lib/awx/projects
  # ls -l
}

# ===== Меню =====
while true; do
  clear
  echo "==============================="
  echo "      🛠️  AWX Manager"
  echo "==============================="
  echo "1) 🚀 Установить AWX"
  echo "2) 🔍 Проверить статус"
  echo "3) 🔑 Получить bootstrap-пароль"
  echo "4) 🧹 Удалить AWX и Operator"
  echo "5) 📦 Открыть shell в AWX"
  echo "0) ❌ Выход"
  echo "==============================="
  read -rp "Выберите действие [0-5]: " choice
  case "$choice" in
    1) check_deps; check_resources; install_awx ;;
    2) check_status ;;
    3) get_bootstrap_password ;;
    4) uninstall_awx ;;
    5) connect_to_awx ;;
    0) echo "👋 До встречи!"; exit 0 ;;
    *) echo "❌ Неверный выбор."; sleep 1 ;;
  esac
  echo -e "\nНажмите Enter для продолжения..."
  read -r
done
```