#!/usr/bin/env bash
set -euo pipefail

RANCHER_NS="cattle-system"

# prompt_string "Текст приглашения" [дефолт]
# Если указан дефолт, выводит: "Текст [дефолт]: "
# Если дефолт не указан (или пустой), выводит: "Текст: " и требует не пустого ввода
prompt_string() {
  local prompt="$1"
  local default="${2-}"
  local ans
  if [[ -n "$default" ]]; then
    read -p "$prompt [$default]: " ans
    # если пусто — возвращаем дефолт
    echo "${ans:-$default}"
  else
    while true; do
      read -p "$prompt: " ans
      if [[ -n "$ans" ]]; then
        echo "$ans"
        return
      fi
      echo "⚠️  Поле обязательно для заполнения."
    done
  fi
}

# prompt_number "Текст приглашения" [дефолт]
# Проверяет, что введено целое число (может быть отрицательным)
# Если дефолт указан, пустой ввод отдаёт дефолт; иначе вход обязателен
prompt_number() {
  local prompt="$1"
  local default="${2-}"
  local ans
  if [[ -n "$default" ]]; then
    while true; do
      read -p "$prompt [$default]: " ans
      ans="${ans:-$default}"
      if [[ "$ans" =~ ^-?[0-9]+$ ]]; then
        echo "$ans"
        return
      fi
      echo "⚠️  Введите целое число."
    done
  else
    while true; do
      read -p "$prompt: " ans
      if [[ "$ans" =~ ^-?[0-9]+$ ]]; then
        echo "$ans"
        return
      fi
      echo "⚠️  Поле обязательно и должно быть целым числом."
    done
  fi
}

# prompt_port "Текст приглашения" [дефолт]
# Проверяет, что введено целое число в диапазоне 1–65535
# Аналогично prompt_number по обязательности
prompt_port() {
  local prompt="$1"
  local default="${2-}"
  local ans
  if [[ -n "$default" ]]; then
    while true; do
      read -p "$prompt [$default]: " ans
      ans="${ans:-$default}"
      if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans>=1 && ans<=65535 )); then
        echo "$ans"
        return
      fi
      echo "⚠️  Введите порт (1–65535)."
    done
  else
    while true; do
      read -p "$prompt: " ans
      if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans>=1 && ans<=65535 )); then
        echo "$ans"
        return
      fi
      echo "⚠️  Поле обязательно и должно быть портом (1–65535)."
    done
  fi
}

function install_rancher() {
  echo
  echo "🚀 Установка Rancher в k3s..."

  # Домeн обязательный (никакого дефолта):
  DOMAIN=$(prompt_string "Введите доменное имя для Rancher (пример: rancher.stroy-track.ru)")
  # HTTP-порт с дефолтом:
  HTTP_NODEPORT=$(prompt_port "Введите HTTP NodePort (порт для HTTP UI без TLS)" 8080)
  # HTTPS-порт с дефолтом:
  HTTPS_NODEPORT=$(prompt_port "Введите HTTPS NodePort (порт для HTTPS UI c TLS)" 30443)

  echo "Domain: $DOMAIN, HTTP: $HTTP_NODEPORT, HTTPS: $HTTPS_NODEPORT"

  kubectl create namespace "${RANCHER_NS}" --dry-run=client -o yaml | kubectl apply -f -
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
  helm repo update

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: rancher-nodeport
  namespace: ${RANCHER_NS}
spec:
  type: NodePort
  selector:
    app: rancher
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: http
      nodePort: ${HTTP_NODEPORT}
    - name: https
      protocol: TCP
      port: 443
      targetPort: https
      nodePort: ${HTTPS_NODEPORT}
EOF

  helm upgrade --install rancher rancher-latest/rancher \
    --namespace "${RANCHER_NS}" \
    --set hostname="${DOMAIN}" \
    --set ingress.enabled=false \
    --set tls=external \
    --set replicas=1 \
    --set service.type=ClusterIP \
    --timeout 5m
}

function check_install() {
  echo
  echo "🔍 Проверяем установку Rancher..."
  kubectl -n "${RANCHER_NS}" get pods
  kubectl get svc -n "${RANCHER_NS}"
}

function get_bootstrap_password() {
  echo
  echo "🔑 Bootstrap-пароль для первого входа:"
  kubectl get secret --namespace "${RANCHER_NS}" bootstrap-secret \
    -o jsonpath="{.data.bootstrapPassword}" \
    | base64 -d
  echo
}

function uninstall_rancher() {
  echo
  echo "🧹 Удаление Rancher..."
  helm uninstall rancher -n "${RANCHER_NS}" --timeout 2m || true
  kubectl delete svc rancher rancher-nodeport -n "${RANCHER_NS}" --ignore-not-found || true
  # (если нужно) убрать CRD Rancher — иначе при повторной установке могут остаться «остатки»
  # kubectl get crd -o name | grep -E 'cattle\.io|fleet\.cattle\.io|rancher\.io' | xargs -r kubectl delete || true
  echo "✅ Rancher удалён из namespace ${RANCHER_NS}."
}

# ====== главное меню ======
while true; do
  cat <<EOF

===============================
  Rancher K3s Manager
===============================
1) Установить Rancher
2) Проверка статуса pods и svc в ${RANCHER_NS}
3) Вывести bootstrap-пароль первого входа
4) Удалить Rancher
0) Выход
EOF

  read -p "Выберите действие [0-3]: " choice
  case "$choice" in
    1) install_rancher ;;
    2) check_install ;;
    3) get_bootstrap_password ;;
    4) uninstall_rancher ;;
    0) echo "👋 Выход."; exit 0 ;;
    *) echo "❌ Неверный выбор, попробуйте снова." ;;
  esac
done