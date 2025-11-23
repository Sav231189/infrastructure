# Harbor (Docker Registry)

## Что это такое?

Harbor - это приватный Docker registry (хранилище Docker образов). Это как Docker Hub, но ваш собственный.

**Зачем нужен:**

- Хранить образы ваших приложений
- Сканировать образы на уязвимости перед деплоем
- Контролировать доступ к образам (кто может скачивать/загружать)
- Автоматически удалять старые версии образов

**Архитектура Harbor:**

- **Core** - главный сервис (UI, API, аутентификация)
- **Registry** - хранилище самих образов Docker
- **PostgreSQL** - база данных (метаданные образов, пользователи)
- **Redis** - кэш для ускорения работы (временные данные, сессии)
- **Trivy** - сканер уязвимостей в образах
- **JobService** - фоновые задачи (сканирование, репликация, очистка)

## Установка

> Через Lens (UI) - Рекомендуется

1. Откройте **Lens** → ваш кластер
2. **Catalog** (левое меню) → **Helm Charts**
3. Поиск: `harbor`
4. Выберите `harbor` от `goharbor`
5. **Install**
6. **Namespace:** создайте новый `harbor`
7. Скопируйте Values (ниже) в редактор
8. **Измените:**
   - `harborAdminPassword` - придумайте сильный пароль
   - `secretKey` - 16 случайных символов
9. **Install**

> Values.yaml

- Не забудьте изменить пароли!

```yaml
# ============================================
# СЕТЬ - Как Harbor доступен извне
# ============================================
expose:
  type: ingress # Через домен, а не через IP:порт

  tls:
    enabled: false # SSL на NPM, не в K8s
    certSource: none

  ingress:
    hosts:
      core: harbor.stroy-track.ru # ← ВАШ ДОМЕН

    className: "nginx" # Тип вашего Ingress Controller

    annotations:
      # Не редиректить на HTTPS (SSL уже на NPM)
      nginx.ingress.kubernetes.io/ssl-redirect: "false"
      # Без лимита размера файлов (для больших образов)
      nginx.ingress.kubernetes.io/proxy-body-size: "0"
      # Таймауты для медленных соединений (10 минут)
      nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
      nginx.ingress.kubernetes.io/proxy-send-timeout: "600"

# ============================================
# URL
# ============================================
externalURL: https://harbor.stroy-track.ru

# ============================================
# ХРАНИЛИЩЕ - Диски (всего ~46 GB)
# ============================================
persistence:
  enabled: true
  resourcePolicy: "keep" # Сохранять данные при удалении Harbor

  persistentVolumeClaim:
    registry:
      # Docker образы - самое большое хранилище
      storageClass: "longhorn"
      size: 10Gi

    jobservice:
      # Логи фоновых задач
      jobLog:
        storageClass: "longhorn"
        size: 2Gi

    database:
      # PostgreSQL (метаданные, пользователи)
      storageClass: "longhorn"
      size: 2Gi

    redis:
      # Redis кэш (сессии, временные данные)
      storageClass: "longhorn"
      size: 2Gi

    trivy:
      # База уязвимостей
      storageClass: "longhorn"
      size: 5Gi

  imageChartStorage:
    type: filesystem # Хранить на диске (не в облаке S3/Azure)

# ============================================
# БЕЗОПАСНОСТЬ
# ============================================
# ⚠️ ОБЯЗАТЕЛЬНО СМЕНИТЕ ДО УСТАНОВКИ!
harborAdminPassword: "harborAdminPassword" # Логин: admin
secretKey: "aB3dEf7hIj9kLm0n" # Ровно 16 символов для шифрования!

# ============================================
# НАСТРОЙКИ
# ============================================
logLevel: info # debug, info, warning, error, fatal
imagePullPolicy: IfNotPresent # Когда скачивать образы компонентов

# ============================================
# КОМПОНЕНТЫ
# ============================================
core:
  replicas: 1 # Количество подов Core

registry:
  replicas: 1 # Количество подов Registry

database:
  type: internal # Встроенная PostgreSQL

redis:
  type: internal # Встроенный Redis

trivy:
  enabled: true # Включить сканер уязвимостей
```

## Первый вход

1. Откройте https://harbor.stroy-track.ru
2. **Логин:** `admin`
3. **Пароль:** тот что указали в `harborAdminPassword`
4. **СРАЗУ смените пароль!**  
   → Правый верхний угол → **Change Password**

## Настройка: Хранить только 5 последних образов

Чтобы не забивать диск старыми версиями:

> Через UI Harbor:

1. **Projects** → выберите проект (или создайте новый)
2. **Policy** (вкладка)
3. **Add Rule**:
   - **Action:** Retain
   - **Retain the most recently:** `5` images
   - **Repositories:** `**` (все репозитории)
   - **Tags:** `**` (все теги)
   - **Schedule:** Daily at `02:00` (каждую ночь в 2:00)
4. **Save**

> Что это делает:

- Каждую ночь в 2:00 запускается проверка
- Для каждого репозитория оставляет 5 последних версий
- Остальные образы удаляются автоматически
- Освобождается место на диске

> Пример:

Если у вас образ `myapp` с тегами:

- `v1.0`, `v1.1`, `v1.2`, `v1.3`, `v1.4`, `v1.5`, `v1.6`

Останутся только:

- `v1.2`, `v1.3`, `v1.4`, `v1.5`, `v1.6` (5 последних)

## Резервное копирование

### Что бэкапить:

1. **PersistentVolumes** (через Longhorn):

   - `harbor-registry` - Docker образы
   - `harbor-database` - PostgreSQL
   - `harbor-trivy` - БД уязвимостей

2. **Secrets**:

```bash
kubectl get secrets -n harbor -o yaml > harbor-secrets-backup.yaml
```

### Восстановление:

```bash
# Восстановите Secrets
kubectl apply -f harbor-secrets-backup.yaml

# PVC восстанавливаются через Longhorn UI (см. longhorn.md)
```
