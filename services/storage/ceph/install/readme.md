## 🗄️ Rook-Ceph - Распределённое хранилище для Kubernetes

> **Rook-Ceph** — это оператор для развёртывания Ceph кластера в Kubernetes. Предоставляет блочные (RBD), файловые (CephFS) и объектные (RGW) хранилища.

## 🏷️ Подготовка нод: Labels и Taints

⚠️ **ВАЖНО:** Перед установкой Ceph необходимо настроить labels и taints на storage-нодах!

### Настройка на каждой storage-ноде

```bash
# Запросить имя ноды с возможностью использовать значение по умолчанию
DEFAULT_NODE_NAME=$(hostname)
read -p "Введите NODE_NAME [по умолчанию: ${DEFAULT_NODE_NAME}]: " NODE_NAME
NODE_NAME=${NODE_NAME:-$DEFAULT_NODE_NAME}
echo "NODE_NAME: ${NODE_NAME}"

# 1. Добавить label для идентификации storage-ноды
kubectl label nodes ${NODE_NAME} role=ceph --overwrite

# 2. Добавить taint чтобы обычные поды не запускались на storage-нодах
# kubectl taint nodes ${NODE_NAME} workload=storage:NoSchedule --overwrite

# 3. Проверить настройки
kubectl get node ${NODE_NAME} --show-labels
kubectl describe node ${NODE_NAME} | grep -A5 Taints
```

**Ожидаемый результат:**

- **Label:** `role=storage` ✅
- **Taint:** `workload=ceph:NoSchedule` ✅

**Примечания:**

- Label `role=storage` используется для идентификации storage-нод
- Taint `NoSchedule` означает: поды без соответствующей toleration **НЕ БУДУТ** запускаться на этой ноде
- Это защищает storage-ноды от случайного размещения обычных подов

## 🔧 Подготовка дисков на VPS

### Проверка свободного места

Проверьте структуру диска и неразмеченное пространство:

```bash
# Показать разделы и свободное место
sudo parted -s /dev/sda unit GiB print free

# Показать дерево дисков
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
```

### Варианты подготовки разделов

#### 1. LVM loop mount

```bash
# Создаём файл 10GB (используем свободные 17GB)
# fallocate быстро выделяет место без записи нулей
fallocate -l 10G /ceph-disk.img

# Проверяем
ls -lh /ceph-disk.img
```

```bash
# Создаём loop device из файла
losetup -f /ceph-disk.img

# Узнаём какой loop device назначен
losetup -a | grep ceph-disk

# Должно показать что-то типа: /dev/loop0: []:12345 (/ceph-disk.img)
```

```bash
# Создаём LVM (замените loop0 на ваш номер)
pvcreate /dev/loop0
vgcreate ceph-vg-1 /dev/loop0
lvcreate -l 100%FREE -n osd-lv ceph-vg-1

# Шаг 5: Проверить доступность
# Проверь текущее состояние
losetup -a
# Должно показать: /dev/loop0: ... (/ceph-disk.img)

ceph-volume inventory /dev/ceph-vg-1/osd-lv
# Должно показать: LV Status = available
```

Автозапуск loop device при перезагрузке

```bash
cat > /etc/systemd/system/ceph-loop.service <<'EOF'
[Unit]
Description=Setup loop device for Ceph
DefaultDependencies=no
After=local-fs.target
Before=lvm2-activation-early.service

[Service]
Type=oneshot
ExecStart=/sbin/losetup /dev/loop0 /ceph-disk.img
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
EOF

# Активируем
systemctl daemon-reload
systemctl enable ceph-loop.service
systemctl start ceph-loop.service
```

В конфигурации Ceph используйте LVM путь:

```yaml
nodes:
  - name: control-worker-1
    devices:
      - name: /dev/ceph-vg-1/osd-lv # ← LVM путь
```

#### 2. LVM root mount (расширенный не размеченный раздел)

```bash
# Шаг 0: Проверить свободное место и узнать номер свободного раздела
parted -s /dev/sda unit GiB print free
# Должно показать:
# 3    1.75GiB  30.0GiB  28.2GiB
#      30.0GiB  100GiB   70.0GiB  Free Space
# Следующий номер раздела будет: 4

# Запросить номер раздела для создания
DEFAULT_PARTITION=4
read -p "Введите номер раздела для Ceph [по умолчанию: ${DEFAULT_PARTITION}]: " PARTITION_NUM
PARTITION_NUM=${PARTITION_NUM:-$DEFAULT_PARTITION}
echo "Используется номер раздела: ${PARTITION_NUM}"

# Шаг 1: Исправить GPT таблицу (если есть предупреждение)
echo "Исправление GPT таблицы..."
sgdisk --move-second-header /dev/sda
partprobe /dev/sda

# Шаг 2: Удалить раздел если он уже создан неправильно
if [ -e /dev/sda${PARTITION_NUM} ]; then
  echo "Удаление существующего раздела sda${PARTITION_NUM}..."
  sgdisk --delete=${PARTITION_NUM} /dev/sda
  partprobe /dev/sda
  sleep 2
fi

# Шаг 3: Создать раздел правильно
echo "Создание раздела sda${PARTITION_NUM}..."
sgdisk --new=${PARTITION_NUM}:0:-0 --typecode=${PARTITION_NUM}:8300 --change-name=${PARTITION_NUM}:ceph-osd /dev/sda
partprobe /dev/sda
sleep 2

# Шаг 4: Проверить результат создания раздела
echo "=== Проверка созданного раздела sda${PARTITION_NUM} ==="
parted -s /dev/sda unit GiB print free
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
# Должно показать: sda${PARTITION_NUM} с размером свободного места (например, ~70G) без FSTYPE

# Шаг 5: Создать Physical Volume
pvcreate /dev/sda${PARTITION_NUM}
pvdisplay /dev/sda${PARTITION_NUM}

# Шаг 6: Запросить имя Volume Group (уникальное для каждой ноды!)
DEFAULT_VG_NAME="ceph-vg-1"
read -p "Введите имя Volume Group [по умолчанию: ${DEFAULT_VG_NAME}]: " VG_NAME
VG_NAME=${VG_NAME:-$DEFAULT_VG_NAME}
echo "Используется VG: ${VG_NAME}"
echo "Для других нод используйте: ceph-vg-2, ceph-vg-3 и т.д."

# Шаг 7: Создать Volume Group
vgcreate ${VG_NAME} /dev/sda${PARTITION_NUM}
vgdisplay ${VG_NAME}

# Шаг 8: Создать Logical Volume на ВСЁ пространство
lvcreate -l 100%FREE -n osd-lv ${VG_NAME}

# Шаг 9: Проверить доступность LVM тома
echo "=== Проверка созданного LVM тома ==="
lvdisplay /dev/${VG_NAME}/osd-lv
# Должно показать: LV Path = /dev/${VG_NAME}/osd-lv, LV Size = размер свободного места

# Проверка через lsblk
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
# Должно показать: ${VG_NAME}/osd-lv с размером свободного места и типом lvm

# (Опционально) Проверка через ceph-volume (если установлен ceph-base)
# ceph-volume inventory /dev/${VG_NAME}/osd-lv
# Должно показать: LV Status = available

echo "✅ Готово! LVM том создан: /dev/${VG_NAME}/osd-lv"
```

В конфигурации Ceph используйте LVM путь:

```yaml
nodes:
  - name: control-worker-1
    devices:
      - name: /dev/ceph-vg-1/osd-lv # ← LVM путь
```

#### 3. Disk ID

```bash
# Показать разделы и ID дисков (например, sda4)
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT

# Запросить ID диска для создания
DEFAULT_DISK_ID="sda4"
read -p "Введите ID диска для Ceph [по умолчанию: ${DEFAULT_DISK_ID}]: " DISK_ID
DISK_ID=${DISK_ID:-$DEFAULT_DISK_ID}
echo "Используется ID диска: ${DISK_ID}"

# Показать ID дисков
ls -l /dev/disk/by-id/ | grep ${DISK_ID}
```

Теперь в конфигурации Ceph используйте путь к диску:

```yaml
nodes:
  - name: control-worker-1
    devices:
      - name: /dev/sda4 # ← ID Disk путь (scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-part4)
```

## ⚙️ Установка через Helm (Lens UI)

> values-operator.yaml (для rook-ceph)


> values-cluster.yaml (для rook-ceph-cluster)


> 🌐 Dashboard - получить пароль

```bash
# Получить автоматически сгенерированный пароль
kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode && echo

# Логин по умолчанию: admin
```

## Настроить Ingress

Создайте Ingress для доступа к Dashboard через браузер:

> ingress.yaml

```bash (ingress.yaml)
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ceph-dashboard
  namespace: rook-ceph
  annotations:
    # Т.к. backend уже использует HTTPS (ssl: true в конфиге), нужно проксировать на HTTPS
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    # Разрешаем самоподписанный сертификат от Ceph
    nginx.ingress.kubernetes.io/proxy-ssl-verify: "false"
    # Включаем SSL редирект
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    # Cert-manager для автоматического Let's Encrypt (если установлен)
    # cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  rules:
    - host: ceph.stroy-track.ru
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: rook-ceph-mgr-dashboard
                port:
                  number: 8443
EOF
```

Теперь Dashboard доступен по адресу: `https://ceph.stroy-track.ru` -> ingress https://ip:433

---

## Добавление новой ноды

1. Подготовьте диск на новой VPS (см. [Подготовка дисков](#-подготовка-дисков-на-vps))
2. Обновите rook-ceph-cluster `values-cluster.yaml`, добавив новую ноду в секцию `storage.nodes`
3. Примените изменения:

```bash
helm upgrade rook-ceph-cluster rook-release/rook-ceph-cluster \
  --namespace rook-ceph \
  --values values-cluster.yaml \
  --reuse-values
```

4. Проверьте что OSD запустился:

```bash
kubectl get pods -n rook-ceph | grep osd
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd tree
```
