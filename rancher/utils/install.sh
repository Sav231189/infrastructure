#!/usr/bin/env bash
set -euo pipefail

DOCKER_IMAGE=rancher/rancher:latest
DATA_DIR=/opt/rancher               # куда монтировать хранилище Rancher
# ставим запас в 5 MiB (максимально допустимый размер сообщения в gRPC-канале между Rancher-серверами и их агентами (agent → server, server → agent)
# По умолчанию = 1 048 576 байт ≈ 1 MiB, многие CRD/Fleet-объекты могут быть больше)
GRPC_MAX_RECV=$((5 * 1024 * 1024))

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
  echo "🚀 Установка Rancher в Docker"

  # Домeн обязательный (никакого дефолта):
  SERVER_URL=$(prompt_string "Введите доменное имя для Rancher (пример: https://rancher.stroy-track.ru)")
  # HTTP-порт с дефолтом:
  HOST_PORT=$(prompt_port "Введите HOST_PORT (порт для HTTP)" 80)
  # HTTPS-порт с дефолтом:
  CONTAINER_PORT=$(prompt_port "Введите CONTAINER_PORT (на каком порту внутри контейнера Rancher «слушает» HTTP)" 80)

  echo "Domain: $SERVER_URL, HTTP: $HOST_PORT, HTTPS: $CONTAINER_PORT"

  read -s -p "🔑 Введите bootstrap-пароль (первый вход для логина admin): " BOOTSTRAP_PASSWORD

  echo "⏳ Запускаем контейнер Rancher..."
  sudo docker run -d \
    --privileged \
    --restart=unless-stopped \
    -p ${HOST_PORT}:${CONTAINER_PORT} \
    -p 443:443 \
    --name rancher \
    -v /opt/rancher/ssl/fullchain.pem:/etc/rancher/ssl/cert.pem \
    -v /opt/rancher/ssl/privkey.pem:/etc/rancher/ssl/key.pem \
    -v /opt/rancher/ssl/chain.pem:/etc/rancher/ssl/cacerts.pem \
    -v ${DATA_DIR}:/var/lib/rancher \
    -e CATTLE_BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD}" \
    -e CATTLE_SERVER_URL="${SERVER_URL}" \
    -e CATTLE_GRPC_MAX_RECEIVE_MESSAGE_SIZE=${GRPC_MAX_RECV} \
    ${DOCKER_IMAGE} 
  echo "✅ Rancher запущен на порту ${HOST_PORT}, grpc-recv=${GRPC_MAX_RECV} bytes"
}

    # -v /opt/rancher/ssl/fullchain.pem:/etc/rancher/ssl/cert.pem \
    # -v /opt/rancher/ssl/privkey.pem:/etc/rancher/ssl/key.pem \
    # -v /opt/rancher/ssl/chain.pem:/etc/rancher/ssl/cacerts.pem \

function view_logs() {
  echo
  echo "📝 Логи Rancher (Ctrl-C для выхода):"
  sudo docker logs -f rancher
}

function remove_rancher() {
  echo
  echo "⚠️  Удаляем контейнер и данные Rancher..."
  sudo docker stop rancher    2>/dev/null || true
  sudo docker rm -f rancher   2>/dev/null || true
  sudo rm -rf ${DATA_DIR}     2>/dev/null || true
  echo "✅ Rancher и данные в ${DATA_DIR} удалены"
}

# ====== главное меню ======
while true; do
  cat <<EOF

===============================
  Rancher Docker Manager
===============================
1) Установить Rancher
2) Просмотреть логи Rancher
3) Удалить Rancher (контейнер + данные)
0) Выход
EOF

  read -p "Выберите действие [0-3]: " choice
  case "$choice" in
    1) install_rancher ;;
    2) view_logs ;;
    3) remove_rancher ;;
    0) echo "👋 Выход."; exit 0 ;;
    *) echo "❌ Неверный выбор, попробуйте снова." ;;
  esac
done
