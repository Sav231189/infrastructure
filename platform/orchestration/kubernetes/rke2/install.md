# RKE2 Kubernetes Cluster - Руководство по установке

- Версия RKE2 (должна совпадать на всех нодах!)
- ⚠️ **Server нода: МИНИМУМ 4 ГБ RAM**
- ⚠️ **Agent нода: минимум 2 ГБ RAM**
- ⚠️ Все ноды должны иметь **одинаковую версию RKE2**
- ⚠️ **Уникальное имя хоста** - обязательно

- Инициализация ноды "Master" - через установку rke2 с типом "server"
- Инициализация ноды "Worker" - через установку rke2 с типом "agent"
- Master нода может инициализировать новый кластер или добавиться к текущему в роли Master
- Agent нода может добавиться к текущему кластеру в роли Worker
- Устанавливать уникальное имя хоста через `/dev/urandom`
- При добавлении новых нод использовать реальный токен с мастера: `/var/lib/rancher/rke2/server/node-token`

- информация о сетевых портах:
  - 6443 (Kubernetes API)
  - 9345 (RKE2 supervisor API)
  - 10250 (kubelet)
  - 2379-2380 (etcd)

## Taint and Label

> Taint (node-taint)

Метка-запрет на ноде. Поды не будут сюда планироваться, пока у них нет "tolerations" (разрешения).

**Формат**: `key=value:Effect`

**Effects** (обязательное поле):

- `NoSchedule` — не пускать новые поды без toleration
- `PreferNoSchedule` — постарайся не пускать (мягко)
- `NoExecute` — не пускать и выселить уже запущенные поды без toleration

```yaml Example
# System taints (для control-plane нод)
node-taint:
  - "node-role.kubernetes.io/control-plane:NoSchedule"
  - "node-role.kubernetes.io/master=true:NoSchedule"

# Custom taints (для специализированных нод)
node-taint:
  - "workload=ceph:NoSchedule"
```

> Label (node-label)

Kubernetes-лейблы ноды (пары key=value), которые задаются при подключении ноды к кластеру.
Лейблы ноды управляют ПОДАМИ (куда ставить контейнеры) через nodeSelector или nodeAffinity.

```yaml Example
# Например для injection services на ноде
node-label:
  - "ceph=enabled"
  - "vault=enabled"
```

## Подготовка Nodes

> - Ubuntu 24.04 LTS

```bash
# stop the software firewall
systemctl disable --now ufw

# get updates, install nfs, and apply
apt update
apt install nfs-common -y
apt upgrade -y

# clean up
apt autoremove -y

# Отключить все swap
swapoff -a
## Удалить все swap файлы
sudo rm -f /swap.img /swapfile* /swap.img.* /swapfile.* /var/swap /swap
## Найти и удалить все swap файлы
sudo find / -name "*swap*" -type f 2>/dev/null | grep -E "\.(img|file)$" | xargs sudo rm -f
## Очистить fstab
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swapfile/ s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap.img/ s/^\(.*\)$/#\1/g' /etc/fstab
## Проверить результат
echo "Проверяем результат..."
swapon --show
cat /proc/swaps

# ВАЖНО: Перезагрузите после обновлений!
reboot
```

## Установка RKE2

> Установить RKE2 Master/Server на ноду

```bash
# Версия RKE2 (должна совпадать на всех нодах!)
RKE2_VERSION=v1.33.4+rke2r1

# Установка RKE2 на ноду с типом master
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${RKE2_VERSION} INSTALL_RKE2_TYPE=server sh -

# Проверить статус сервиса, чтобы убедиться что установка прошла успешно, перед запуском с конфигом
systemctl status rke2-server
```

> Установить RKE2 Worker/Agent на ноду

```bash
# Версия RKE2 (должна совпадать на всех нодах!)
RKE2_VERSION=v1.33.4+rke2r1

# Установка RKE2 на ноду с типом worker
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${RKE2_VERSION} INSTALL_RKE2_TYPE=agent sh -

# Проверить статус сервиса, чтобы убедиться что установка прошла успешно, перед запуском с конфигом
systemctl status rke2-agent
```

## Инициализация Kubernetes (RKE2)

> Конфиг для первой ноды мастера
> Создать конфига для инициализации кластера на ноде с установленным RKE2 Master/Server

```bash
# Token для инициализации кластера
TOKEN=Bootstrap-Token

# Запросить токен в консоле и вставить в переменную TOKEN
read -p "Введите токен для инициализации кластера (по умолчанию: ${TOKEN}): " TOKEN

# Генерация имени ноды по умолчанию
NODE_NAME=$(hostname)-master-$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)

# Запросить имя ноды в консоле и вставить в переменную NODE_NAME
read -p "Введите имя ноды (по умолчанию: ${NODE_NAME}): " NODE_NAME

# Создание директории конфига, если не существует
mkdir -p /etc/rancher/rke2/

# Добавление конфига с уникальным именем и taint для мастера
cat > /etc/rancher/rke2/config.yaml <<EOFCONFIG
node-name: "${NODE_NAME}"
token: ${TOKEN}
write-kubeconfig-mode: "0600"
node-taint:
  - "node-role.kubernetes.io/control-plane:NoSchedule"
EOFCONFIG

# Проверить конфиг
cat /etc/rancher/rke2/config.yaml
```

> Запуск Master/Server с конфигом на ноде с установленным RKE2 Master/Server

```bash
echo "🚀 Запуск сервиса rke2-server... ожидание запуска (может занять 2-5 минут)..."

# Запуск и включение автостарта (--now уже запускает сервис)
systemctl enable --now rke2-server.service

echo "🔍 Проверка статуса сервиса rke2-server..."

# Проверка статуса
systemctl status rke2-server
```

> Установка символической ссылки kubectl -> cli rancher на мастер ноде

```bash
# Создать символическую ссылку kubectl на cli rancher, который устанавливается из RKE2.
ln -s /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl

# add kubectl conf with persistence
echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> ~/.bashrc
echo "export PATH=\$PATH:/usr/local/bin/:/var/lib/rancher/rke2/bin/" >> ~/.bashrc
source ~/.bashrc
```

> Проверка кластера на мастер ноде

```bash
kubectl get nodes

kubectl get pods -A

kubectl get jobs -A
```

> Проверка ресурсов нод

```bash
watch kubectl top nodes
```

> Получение kubeconfig для external подключения

```bash
# Вывести содержимое конфига
cat /etc/rancher/rke2/rke2.yaml
```

> Установка HELM (пакетный менеджер). Должен установиться по дефолту через RKE2.

```bash
curl -#L https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "✅ Helm установлен успешно:"

helm version --short
```

## Расширение кластера

> Создать конфиг для расширения Master в кластера на ноде с установленным RKE2 Master/Server

```bash
# Token для инициализации кластера
TOKEN=Bootstrap-Token

# Запросить токен в консоле и вставить в переменную TOKEN
read -p "Введите токен для добавления в кластер (по умолчанию: ${TOKEN}): " TOKEN

# Запросить IP мастера для добавления в кластер
read -p "Введите IP мастера: " MASTER_IP

# Генерация имени ноды по умолчанию
NODE_NAME=$(hostname)-master-$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)
read -p "Введите имя ноды (по умолчанию: ${NODE_NAME}): " NODE_NAME

# Создание директории конфига, если не существует
mkdir -p /etc/rancher/rke2/

# Создание конфига
cat > /etc/rancher/rke2/config.yaml <<EOFCONFIG
server: https://${MASTER_IP}:9345
token: ${TOKEN}
node-name: "${NODE_NAME}"
write-kubeconfig-mode: "0600"
node-taint:
  - "node-role.kubernetes.io/control-plane:NoSchedule"
EOFCONFIG

# Проверить конфиг
cat /etc/rancher/rke2/config.yaml
```

> Создать конфиг для расширения Worker кластера на ноде с установленным RKE2 Worker/Agent

```bash
# Token для инициализации кластера
TOKEN=Bootstrap-Token

# Запросить IP мастера для добавления в кластер
read -p "Введите IP мастера: " MASTER_IP

# Генерация имени ноды по умолчанию
NODE_NAME=$(hostname)-worker-$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)
read -p "Введите имя ноды для добавления в кластер (по умолчанию: ${NODE_NAME}): " NODE_NAME

# Создание директории конфига, если не существует
mkdir -p /etc/rancher/rke2/

# Создание конфига
cat > /etc/rancher/rke2/config.yaml <<EOFCONFIG
server: https://${MASTER_IP}:9345
token: ${TOKEN}
node-name: "${NODE_NAME}"
EOFCONFIG

# Проверить конфиг
cat /etc/rancher/rke2/config.yaml
```

> Добавить taint в конфиг (опционально example: workload=longhorn:NoSchedule)

```bash
cat >> /etc/rancher/rke2/config.yaml <<EOFCONFIG
node-taint:
  - "workload=ceph:NoSchedule"
EOFCONFIG
```

> Добавить node-labels в конфиг (опционально example: role=db)
> db для базы данных / media для медиа-сервисов / storage для хранилища

```bash
cat >> /etc/rancher/rke2/config.yaml <<EOFCONFIG
node-label:
  - "role=db"
EOFCONFIG
```

> Запуск Master/Server с конфигом на ноде с установленным RKE2 Master/Server

```bash
echo "🚀 Запуск сервиса rke2-server... ожидание запуска (может занять 2-5 минут)..."

# Запуск и включение автостарта (--now уже запускает сервис)
systemctl enable --now rke2-server.service

# Ожидание запуска
echo "🔍 Проверка статуса сервиса rke2-server..."

# Проверка статуса
systemctl status rke2-server

# Проверка готовности
# journalctl -u rke2-server -f
```

> Запуск Worker/Agent с конфигом на ноде с установленным RKE2 Worker/Agent

```bash
echo "🚀 Запуск сервиса rke2-agent... ожидание запуска (может занять 2-5 минут)..."

# Запуск и включение автостарта (--now уже запускает сервис)
systemctl enable --now rke2-agent.service

# Ожидание запуска
echo "🔍 Проверка статуса сервиса rke2-agent..."

# Проверка статуса
systemctl status rke2-agent

# Проверка готовности
# journalctl -u rke2-agent -f
```

## Очистка кластера после установки

> Удалить все Pod'ы установки

```bash
# Проверить Pod'ы установки
kubectl get pods -A

# Удалить все Pod'ы установки
kubectl get pods -n kube-system | grep helm-install-rke2 | awk '{print $1}' | xargs kubectl delete pod -n kube-system

# Проверить что остались только рабочие поды
kubectl get pods -A
```

## Удаление RKE2 (для переустановки)

⚠️ **ВНИМАНИЕ**: Эта операция полностью удалит RKE2 и все связанные данные!

```bash
# Тип ноды: worker или master
NODE_ROLE=worker

echo "⚠️  ВНИМАНИЕ: Начинается полная очистка RKE2..."
sleep 5

# Определение типа для очистки
if [ "$NODE_ROLE" = "master" ]; then
  SERVICE_NAME=rke2-server
else
  SERVICE_NAME=rke2-agent
fi

# Остановка и отключение сервиса
echo "🛑 Остановка сервиса ${SERVICE_NAME}..."
sudo systemctl stop ${SERVICE_NAME}
sudo systemctl disable ${SERVICE_NAME}
sudo /usr/local/bin/rke2-killall.sh 2>/dev/null || true
sudo /usr/local/bin/rke2-uninstall.sh 2>/dev/null || true

# Общая очистка
echo "🧹 Удаление файлов и директорий..."
sudo rm -rf /etc/rancher/rke2 /var/lib/rancher/rke2 /var/lib/kubelet
sudo rm -f /usr/local/bin/rke2 /usr/local/bin/kubectl /usr/local/bin/crictl /usr/local/bin/ctr
sudo systemctl stop containerd 2>/dev/null || true
sudo systemctl disable containerd 2>/dev/null || true
sudo rm -rf /var/lib/containerd /etc/containerd

# Дополнительная очистка в зависимости от типа
if [ "$NODE_ROLE" = "master" ]; then
  echo "🧹 Очистка master-специфичных данных..."
  sudo rm -rf /var/lib/etcd /etc/kubernetes ~/.kube
else
  echo "🧹 Очистка worker-специфичных данных..."
  sudo rm -rf /etc/rancher/node /var/lib/rancher/rke2/agent
  sudo rm -f /etc/rancher/node/password
fi

echo "✅ Очистка завершена. Система будет перезагружена через 5 секунд..."
sleep 5
sudo reboot
```
