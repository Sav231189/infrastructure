# 🐳 Harbor — приватный Docker Registry с UI

## 📌 Что это такое

Harbor — это хранилище Docker-образов с веб-интерфейсом.  
Сюда CI (Drone/W...) будет пушить образы, а ArgoCD будет тянуть их при обновлении git (GitOps - подход).

## 📦 Что умеет
- Web-интерфейс для управления образами (https://harbor.stroy-track.ru)
- Авторизация: логин/пароль
- Поддержка проектов (`stage`, `prod`)
- Работа с Docker push/pull
- Можно смотреть, удалять, тегать, сканировать образы

## ⚙️ Как работает
1. NGINX с SSL/TLS проксирует запросы с `https://harbor.stroy-track.ru` на `http://localhost:8081`
2. Harbor API и Web UI работают на одном и том же порту `http://localhost:8081`

---

## 📦 Установка Harbor в docker
> ./install.md
