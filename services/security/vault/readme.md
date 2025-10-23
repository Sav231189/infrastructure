# 🔐 Vault (HashiCorp) — безопасное хранилище секретов

## 🛠️ Установка в Docker
> ./install.md

## 📌 Назначение
Vault — это безопасное хранилище всех секретов проекта:
- логины и пароли
- токены от Docker Registry
- SSH-ключи от GitHub
- пароли к базам данных
- внутренние ключи и API

## ⚙️ Как работает
1. NGINX с SSL/TLS проксирует запросы с `https://vault.stroy-track.ru` на `http://localhost:8200`
2. Vault API и Web UI работают на одном и том же порту `http://localhost:8200`
3. RBAC	После запуска можно создавать ACL политики и роли
