**🛠️ Установка Helm**
```bash
#!/usr/bin/env bash
set -euo pipefail

function install_helm() {
  # Проверим, установлен ли helm
  if command -v helm &>/dev/null; then
    local existing
    existing=$(helm version --short)
    echo "⚠️  Helm уже установлен (${existing})."
    read -rp "Переставить Helm заново? [y/N]: " yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
      echo "ℹ️  Пропускаем установку."
      return
    fi
    echo "🗑  Удаляем существующий бинарник $(command -v helm)..."
    rm -f "$(command -v helm)"
  fi

  echo "🚀 Скачиваем и устанавливаем Helm 3..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

  echo
  echo "✅ Helm установлен успешно:"
  helm version --short
}

function version_helm() {
  echo
  echo "📦 Текущая версия Helm:"
  if helm version &>/dev/null; then
    helm version --short
  else
    echo "⚠️ Helm не найден."
  fi
  echo
}

# ====== главное меню ======
while true; do
  cat <<EOF

===============================
        Helm Manager
===============================
1) Установить или переустановить Helm
2) Показать версию Helm
0) Выход
EOF

  read -rp "Выберите действие [0-2]: " choice
  case "$choice" in
    1) install_helm ;;
    2) version_helm ;;
    0) echo "👋 Выход."; exit 0 ;;
    *) echo "❌ Неверный выбор, попробуйте снова." ;;
  esac
done

```
