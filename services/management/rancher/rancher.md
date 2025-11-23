# Rancher (Управление Kubernetes)

## Назначение

- Централизованное управление K8s кластерами
- Мониторинг состояния кластеров
- Деплой приложений
- Управление workloads
- RBAC и пользователи
- Мониторинг ресурсов
- Backup и восстановление

## Import cluster

Check status импортированного кластера

```bash
# Текущие логи пода
kubectl logs -n cattle-system -l app=cattle-cluster-agent --tail=50

# Логи предыдущего краша
kubectl logs -n cattle-system -l app=cattle-cluster-agent --previous

# Детали и события пода
kubectl describe pod -n cattle-system -l app=cattle-cluster-agent

# События в namespace
kubectl get events -n cattle-system --sort-by='.lastTimestamp' | tail -20

# Логи в реальном времени (Ctrl+C для выхода)
kubectl logs -n cattle-system -l app=cattle-cluster-agent -f
```

```bash
# Полная очистка Rancher из кластера
kubectl delete namespace cattle-system --force --grace-period=0
kubectl delete validatingwebhookconfiguration -l cattle.io/creator=rancher
kubectl delete mutatingwebhookconfiguration -l cattle.io/creator=rancher
kubectl delete clusterrole,clusterrolebinding -l cattle.io/creator=rancher
kubectl delete clusterrole cattle-admin proxy-clusterrole-kubeapiserver
kubectl delete clusterrolebinding cattle-admin-binding proxy-role-binding-kubernetes-master

# Проверка (не должно быть результатов)
kubectl get all,clusterrole,clusterrolebinding,validatingwebhookconfiguration,mutatingwebhookconfiguration | grep -E "cattle|rancher"

# После очистки примените новый манифест импорта из Rancher UI
```

## Create cluster

При создании новых кластеров из Rancher установить Agent Environment Vars

```bash
CATTLE_CA_CHECKSUM: ""            # Пустое - не требует CA от Rancher
CATTLE_AGENT_STRICT_VERIFY: false # Отключает строгую проверку CA checksum
STRICT_VERIFY: false              # Дополнительная страховка
```

Подключение агента Rancher в K8s

```bash
# 1. Генерируем уникальное имя
UNIQUE_NODE_NAME="$(hostname)-$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
echo "Имя ноды: $UNIQUE_NODE_NAME"

TOKEN="jdpmmdt5s48rrhcqqf2dp6jvdvrg8gpphg2q24gcdhwbcs5kgwnbf8"

# 2. Запускаем команду ИЗ RANCHER UI, добавив аргумент --node-name
# --etcd --controlplane --worker
curl -fL https://rancher.stroy-track.ru/system-agent-install.sh | \
sudo CATTLE_CA_CHECKSUM="skip" CATTLE_AGENT_STRICT_VERIFY="false" \
sh -s - \
  --server https://rancher.stroy-track.ru \
  --label 'cattle.io/os=linux' \
  --token ${TOKEN} \
  --worker \
  --node-name "${UNIQUE_NODE_NAME}"
```

Check status

```bash
# 1. Статус rancher-system-agent
systemctl status rancher-system-agent

# 2. Логи rancher-system-agent
journalctl -u rancher-system-agent -n 100 --no-pager

# 3. Статус rke2-server (если control plane)
systemctl status rke2-server

# 4. Проверьте процессы
ps aux | grep rancher
```

Clear

```bash
# 1. Остановите все сервисы
systemctl stop rancher-system-agent
systemctl stop rke2-server
systemctl disable rke2-server

# 2. Удалите старый агент
/usr/local/bin/rancher-system-agent-uninstall.sh

# 3. Полная очистка
rm -rf /var/lib/rancher/agent
rm -rf /var/lib/rancher/rke2
rm -rf /var/lib/rancher/capr
rm -rf /etc/rancher/agent
rm -rf /etc/rancher/rke2
rm -rf /etc/rancher/node
```

Start

```bash
sudo systemctl start rancher-system-agent
```

Restart

```bash
sudo systemctl restart rancher-system-agent
```
