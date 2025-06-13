**🛠️ Установка k3s**
```bash
#!/usr/bin/env bash
set -euo pipefail

# Скрипт для установки, проверки и удаления k3s (Kubernetes lightweight)
# Работает на Debian/Ubuntu и подобных дистрибутивах

# Проверяем запуск от root
if [[ $EUID -ne 0 ]]; then
  echo "❌ Этот скрипт должен быть запущен от имени root."
  exit 1
fi

# Пути к бинарям и скриптам k3s (можно переопределить через переменные среды)
K3S_BINARY=${K3S_BINARY:-/usr/local/bin/k3s}
K3S_UNINSTALL=${K3S_UNINSTALL:-/usr/local/bin/k3s-uninstall.sh}

is_k3s_installed() {
  local bin="${K3S_BINARY:-/usr/local/bin/k3s}"
  # 1) Есть ли бинарь k3s в PATH или по явному пути?
  if command -v k3s >/dev/null 2>&1 || [[ -x "$bin" ]]; then
    # 2) Пробуем через systemctl: установлен и запущен ли сервис k3s?
    if systemctl is-active --quiet k3s; then
      return 0
    fi
    # 3) Либо проверяем, что он хотя бы установлен (файл .service на месте)
    if systemctl list-unit-files --type=service | grep -q '^k3s\.service'; then
      return 0
    fi
  fi
  return 1
}

# Выводит статус установки k3s
print_k3s_status() {
  if is_k3s_installed; then
    echo "✅ k3s установлен и сервис активен"
  else
    echo "ℹ️  k3s не установлен"
  fi
}

# Настройка PS1 и переменной KUBECONFIG в ~/.bashrc
setup_bashrc() {
  local bashrc="$HOME/.bashrc"
  touch "$bashrc"

  # Добавляем кастомный PS1, если его нет
  if ! grep -q '^PS1=' "$bashrc"; then
    cat <<'EOF' >> "$bashrc"
PS1="\[\e]0;\u@\h: \w\a\]${debian_chroot:+(\$debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "
EOF
  fi

  # Добавляем экспорт KUBECONFIG
  if ! grep -q 'export KUBECONFIG=' "$bashrc"; then
    echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> "$bashrc"
  fi

  # Обновляем текущую сессию
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
}

# Устанавливает k3s (первичный сервер)
install_k3s() {
  if is_k3s_installed; then
    echo "ℹ️  k3s уже установлен. Пропускаем установку."
    return 0
  fi

  echo "⏳ Установка k3s..."
  if ! curl -sfL https://get.k3s.io \
      | INSTALL_K3S_EXEC="--service-node-port-range=80-32767" \
          sh -s - server --cluster-init; then
    echo "❌ Не удалось установить k3s."
    return 1
  fi

  setup_bashrc

  echo -n "⏳ Ожидание запуска сервиса k3s"
  for i in {1..10}; do
    if systemctl is-active --quiet k3s; then
      echo
      break
    fi
    echo -n "."
    sleep 3
  done

  if ! systemctl is-active --quiet k3s; then
    echo "❌ Сервис k3s не запустился. Проверьте логи: journalctl -u k3s"
    return 1
  fi

  echo "✅ k3s успешно установлен"
  kubectl get nodes
}

# Проверяет статус кластера
check_k3s() {
  if is_k3s_installed; then
    echo "ℹ️  Состояние нод:";
    kubectl get nodes
  else
    echo "ℹ️  k3s не установлен"
  fi
}

# Удаляет k3s полностью, включая конфигурацию и записи в .bashrc
remove_k3s() {
  if ! is_k3s_installed; then
    echo "ℹ️  k3s не установлен. Нечего удалять."
    return 0
  fi

  read -rp "⚠️  Удалить k3s полностью? [y/N]: " answer
  case "$answer" in
    [yY]|[yY][eE][sS])
      echo "⏳ Останавливаем службу k3s..."
      systemctl stop k3s || true
      systemctl disable k3s || true

      if [[ -x "$K3S_UNINSTALL" ]]; then
        echo "⏳ Запускаем сценарий удаления k3s..."
        "$K3S_UNINSTALL"
      else
        echo "❌ Сценарий удаления не найден: $K3S_UNINSTALL"
        echo "Удаление вручную: удалите файлы в /etc/rancher/k3s и бинарник k3s."
      fi

      # Удаляем добавленные строки из .bashrc
      sed -i '/KUBECONFIG/d' "$HOME/.bashrc"
      sed -i '/PS1=/d' "$HOME/.bashrc"

      echo "✅ k3s удален"
      ;;
    *)
      echo "❌ Операция отменена"
      ;;
  esac
}

# Главное меню
while true; do
  echo
  echo "======= Управление k3s ======="
  print_k3s_status
  echo "1) Установить k3s"
  echo "2) Проверить k3s"
  echo "3) Удалить k3s"
  echo "0) Выход"
  read -rp "Выберите действие: " choice

  case "$choice" in
    1) install_k3s ;;  
    2) check_k3s  ;;  
    3) remove_k3s ;;  
    0) echo "👋 До скорого!"; exit 0 ;;  
    *) echo "❌ Неверный выбор, попробуйте снова." ;;  
  esac

done
```