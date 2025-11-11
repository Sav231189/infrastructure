## 🗄️ Rook-Ceph - Распределённое хранилище для Kubernetes

> **Rook-Ceph** — это оператор для развёртывания Ceph кластера в Kubernetes. Предоставляет блочные (RBD), файловые (CephFS) и объектные (RGW) хранилища.

## 🏷️ Подготовка нод: Labels и Taints

⚠️ **ВАЖНО:** Перед установкой Ceph необходимо настроить labels и taints на storage-нодах!

### Настройка на каждой storage-ноде

```bash
# Замените NODE_NAME на имя вашей ноды (например: data-worker-1)

# 1. Добавить label для идентификации storage-ноды
kubectl label nodes NODE_NAME role=storage --overwrite

# 2. Добавить taint чтобы обычные поды не запускались на storage-нодах
kubectl taint nodes NODE_NAME workload=ceph:NoSchedule --overwrite

# 3. Проверить настройки
kubectl get node NODE_NAME --show-labels
kubectl describe node NODE_NAME | grep -A5 Taints
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
# На КАЖДОЙ ноде с расширенным разделом выполните:

# Устанавливаем переменные для имени диска
DISK_NAME="sda"
# Устанавливаем переменные для номера ноды
NODE_NUMBER=1
# Устанавливаем переменные для номера раздела
PART_NUMBER=4
# Устанавливаем переменные для имени группы томов (имя УНИКАЛЬНОЕ для каждой ноды!)
VG_NAME="ceph-vg-${NODE_NUMBER}"

# Шаг 1: Создать раздел (если ещё не создан)
# ВАЖНО: Если раздел уже есть, но создан неправильно - сначала удалите его:
# sgdisk --delete=4 /dev/sda && partprobe /dev/sda
# Затем создайте правильно:
sgdisk --new=${PART_NUMBER}:-0:0 --typecode=${PART_NUMBER}:8300 --change-name=${PART_NUMBER}:ceph-osd /dev/${DISK_NAME}
partprobe /dev/${DISK_NAME}

# Проверить результат
sudo parted -s /dev/${DISK_NAME} unit GiB print free
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
# Должно показать: sda4 ~30G part (без FSTYPE)

# Шаг 2: Создать Physical Volume
pvcreate /dev/${DISK_NAME}${PART_NUMBER}

# Шаг 3: Создать Volume Group (имя УНИКАЛЬНОЕ для каждой ноды!)
vgcreate ${VG_NAME} /dev/${DISK_NAME}${PART_NUMBER}

# Шаг 4: Создать Logical Volume на ВСЁ пространство
lvcreate -l 100%FREE -n osd-lv ceph-vg-1

# Шаг 5: Проверить доступность LVM тома
# Проверить что LVM том создан и доступен
lvdisplay /dev/${VG_NAME}/osd-lv
# Должно показать: LV Path = /dev/ceph-vg-1/osd-lv, LV Size = ~50 GiB

# Альтернативная проверка через lsblk
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
# Должно показать: ceph-vg-1/osd-lv с размером ~50G и типом lvm

# (Опционально) Проверка через ceph-volume (если установлен ceph-base)
# ceph-volume inventory /dev/${VG_NAME}/osd-lv
# Должно показать: LV Status = available
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
# Устанавливаем переменные для имени диска
DISK_NAME="sda"
# Устанавливаем переменные для номера раздела
PART_NUMBER=4

# Показать ID дисков
ls -l /dev/disk/by-id/ | grep ${DISK_NAME}${PART_NUMBER}
# Должно показать: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-part4 -> /dev/sda4
```

Теперь в конфигурации Ceph используйте путь к диску:

```yaml
nodes:
  - name: control-worker-1
    devices:
      - name: /dev/sda4 # ← ID Disk путь (scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-part4)
```

## ⚙️ Установка через Helm

> Создать namespace rook-ceph

```bash
kubectl create namespace rook-ceph
```

### 2. Добавить Helm репозиторий

```bash
helm repo add rook-release https://charts.rook.io/release
helm repo update
```

### 3. Установить Rook-Ceph Operator

```bash
helm install rook-ceph-operator rook-release/rook-ceph-operator \
  --namespace rook-ceph \
  --create-namespace \
  --values values-operator.yaml
```

> 💡 Файл конфигурации: [`values-operator.yaml`](./values-operator.yaml)

### 4. Установить Rook-Ceph Cluster

После установки оператора (подождите ~30 секунд):

```bash
helm install rook-ceph-cluster rook-release/rook-ceph-cluster \
  --namespace rook-ceph \
  --values values-cluster.yaml
```

> 💡 Файл конфигурации: [`values-cluster.yaml`](./values-cluster.yaml)

---

## 📄 Файлы конфигурации

> 💡 Файл конфигурации operator: [`values-operator.yaml`](./values-operator.yaml)

> 💡 Файл конфигурации cluster: [`values-cluster.yaml`](./values-cluster.yaml)

> 🌐 Dashboard - получить пароль

```bash
# Получить автоматически сгенерированный пароль
kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode && echo

# Логин по умолчанию: admin
```

## Настроить Ingress

Создайте Ingress для доступа к Dashboard через браузер:

```bash
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

Теперь Dashboard доступен по адресу: `https://ceph.stroy-track.local`

---

## Добавление новой ноды

1. Подготовьте диск на новой VPS (см. [Подготовка дисков](#-подготовка-дисков-на-vps))
2. Обновите файл [`values-cluster.yaml`](./values-cluster.yaml), добавив новую ноду в секцию `storage.nodes`
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
