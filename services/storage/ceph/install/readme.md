## 🗄️ Rook-Ceph - Распределённое хранилище для Kubernetes

> **Rook-Ceph** — это оператор для развёртывания Ceph кластера в Kubernetes. Предоставляет блочные (RBD), файловые (CephFS) и объектные (RGW) хранилища.

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

# Шаг 1: Создать раздел (если ещё не создан)
sgdisk --new=4:0:0 --typecode=4:8300 --change-name=4:ceph-osd /dev/sda
partprobe /dev/sda

# Шаг 2: Создать Physical Volume
pvcreate /dev/sda4

# Шаг 3: Создать Volume Group (имя УНИКАЛЬНОЕ для каждой ноды!)
vgcreate ceph-vg-1 /dev/sda4  # на первой ноде
# vgcreate ceph-vg-2 /dev/sda4  # на второй ноде
# vgcreate ceph-vg-3 /dev/sda4  # на третьей ноде

# Шаг 4: Создать Logical Volume на ВСЁ пространство
lvcreate -l 100%FREE -n osd-lv ceph-vg-1

# Шаг 5: Проверить доступность
# Проверь текущее состояние
losetup -a
# Должно показать: /dev/loop0: ... (/ceph-disk.img)

ceph-volume inventory /dev/ceph-vg-1/osd-lv
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
# Показать ID дисков
ls -l /dev/disk/by-id/ | grep sda4


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

```yaml
# === Rook-Ceph Operator (control plane) ===
image:
  repository: docker.io/rook/ceph
  tag: v1.18.4
  pullPolicy: IfNotPresent

# CRD создаём оператором (при первом деплое оставить true)
crds:
  enabled: true

# Ресурсы самого оператора (ему много не нужно)
resources:
  requests:
    cpu: 200m
    memory: 128Mi
  limits:
    memory: 512Mi

# Где оператор работает: по умолчанию — в любом узле.
# currentNamespaceOnly=false позволяет оператору видеть CR из своего неймспейса (rook-ceph) и управлять ими.
currentNamespaceOnly: false

# Общий уровень логов оператора
logLevel: INFO

# RBAC включён
rbacEnable: true

# === CSI (Container Storage Interface) - интеграция Ceph с Kubernetes ===
# CSI драйверы позволяют создавать PVC (Persistent Volume Claims) в K8s
csi:
  # rookUseCsiOperator - использовать встроенный CSI оператор (рекомендуется)
  rookUseCsiOperator: true

  # === Типы хранилищ (включить/выключить по необходимости) ===
  #
  # ℹ️ Здесь только 2 драйвера - это ПРАВИЛЬНО!
  # Object Storage (S3) НЕ требует CSI драйвера, т.к. работает через HTTP API
  # Настройка Object Storage в values-cluster.yaml (секция cephObjectStores)

  # RBD (Block Storage) - ОБЯЗАТЕЛЬНО для большинства
  # Использование: БД, stateful приложения, PVC с режимом ReadWriteOnce (RWO)
  # Монтируется как блочное устройство в под
  enableRbdDriver: true

  # CephFS (File System) - ОПЦИОНАЛЬНО
  # Использование: Shared storage, ReadWriteMany (RWX), несколько подов пишут одновременно
  # Монтируется как файловая система в поды
  # Выключить если не нужен: enableCephfsDriver: false
  enableCephfsDriver: false

  # Общий переключатель CSI (всегда должен быть "false" чтобы CSI работал)
  disableCsiDriver: "false"

  # ========================================================================
  # PROVISIONER - управляющий компонент (создает/удаляет RBD образы)
  # ========================================================================
  # Это Deployment (не DaemonSet) - запускается только на storage-нодах

  # Tolerations - разрешает запуск на нодах с taint "workload=ceph:NoSchedule"
  # Storage-ноды имеют этот taint чтобы обычные приложения на них не попали
  provisionerTolerations:
    - key: "workload" # Ключ taint на storage-нодах
      operator: "Equal" # Точное совпадение
      value: "ceph" # Значение taint
      effect: "NoSchedule" # Тип эффекта

  # NodeAffinity - ОБЯЗАТЕЛЬНО запускать только на storage-нодах
  # Storage-ноды помечены label "node-role.kubernetes.io/storage=true"
  provisionerNodeAffinity: |
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/storage
              operator: In
              values: ["true"]

  # Количество реплик Provisioner для High Availability (HA)
  # 2 реплики = если одна storage-нода упадет, вторая продолжит работу
  provisionerReplicas: 2

  # (Опционально) разнести реплики по разным нодам:
  # Начиная с новых версий Rook/CSI это задаётся через podAntiAffinity у самого чарта ограниченно.
  # Проще: пометь storage-ноды разными зонами/labels и добавь topologySpreadConstraints на уровне кластера.

  # ========================================================================
  # NODEPLUGIN - компонент для монтирования дисков на нодах
  # ========================================================================
  # Это DaemonSet - запускается на КАЖДОЙ ноде где будут использоваться PVC
  #
  # ⚠️ ВАЖНО: NodePlugin должен быть на той ноде, где запускается под с PVC!
  #   - Если приложение на worker-ноде → nodeplugin нужен на worker-ноде
  #   - Если приложение на storage-ноде → nodeplugin нужен на storage-ноде
  #   - Masters обычно исключены (на них не запускают приложения)

  # Tolerations - разрешает запуск на storage-нодах (где taint workload=ceph)
  pluginTolerations:
    - key: "workload" # Ключ taint
      operator: "Equal" # Точное совпадение
      value: "ceph" # Значение taint
      effect: "NoSchedule" # Тип эффекта

  # pluginNodeAffinity НЕ задаём - nodeplugin запустится на всех нодах
  # Masters исключаются автоматически (у них taint control-plane без toleration)
  # Результат: nodeplugin на всех worker + storage нодах
  #
  # ⚠️ ВАЖНО: НЕ ограничивайте только storage-нодами!
  # Если ограничите - приложения на worker-нодах не смогут использовать PVC
  #
  # Если хотите ЯВНО исключить masters (необязательно), раскомментируйте:
  # pluginNodeAffinity: |
  #   requiredDuringSchedulingIgnoredDuringExecution:
  #     nodeSelectorTerms:
  #       - matchExpressions:
  #           - key: node-role.kubernetes.io/control-plane
  #             operator: DoesNotExist

  # HostNetwork для CSI-плагинов — полезно в простых/ограниченных сетях.
  enableCSIHostNetwork: true

  # Включаем снапшоттеры (не обязательно, но удобно)
  enableRBDSnapshotter: true
  enableCephfsSnapshotter: false

  # Политика смены владельца/прав при монтировании тома
  rbdFSGroupPolicy: "File"
  cephFSFSGroupPolicy: "File"

  # ========================================================================
  # РЕСУРСЫ (Requests/Limits) - оптимизированы для нод с 4GB RAM
  # ========================================================================
  # Requests - резервирование (K8s не запустит если не хватает)
  # Limits - максимум (под будет killed если превысит)

  # --- RBD Provisioner (Deployment на storage-нодах) ---
  # Создает/удаляет RBD образы по запросам PVC
  csiRBDProvisionerResource: |
    - name : csi-provisioner      # Основной компонент provisioning
      resource: { requests: { memory: 128Mi, cpu: 100m }, limits: { memory: 256Mi } }
    - name : csi-resizer          # Расширение томов (volume expansion)
      resource: { requests: { memory: 128Mi, cpu: 100m }, limits: { memory: 256Mi } }
    - name : csi-attacher         # Attach/Detach томов к нодам
      resource: { requests: { memory: 128Mi, cpu: 100m }, limits: { memory: 256Mi } }
    - name : csi-snapshotter      # Создание снапшотов
      resource: { requests: { memory: 128Mi, cpu: 100m }, limits: { memory: 256Mi } }
    - name : csi-rbdplugin        # RBD драйвер
      resource: { requests: { memory: 384Mi }, limits: { memory: 768Mi } }
    - name : liveness-prometheus  # Health checks + метрики
      resource: { requests: { memory: 64Mi, cpu: 25m }, limits: { memory: 128Mi } }

  # --- RBD NodePlugin (DaemonSet на всех worker/storage нодах) ---
  # Монтирует RBD диски локально на ноде для подов
  # ВАЖНО: Уменьшены requests чтобы запуститься даже на загруженных нодах
  csiRBDPluginResource: |
    - name : driver-registrar     # Регистрация драйвера в kubelet
      resource: { requests: { memory: 32Mi, cpu: 25m }, limits: { memory: 64Mi } }
    - name : csi-rbdplugin        # RBD драйвер для монтирования
      resource: { requests: { memory: 256Mi, cpu: 100m }, limits: { memory: 512Mi } }
    - name : liveness-prometheus  # Health checks
      resource: { requests: { memory: 32Mi, cpu: 25m }, limits: { memory: 64Mi } }
  # Итого на ноду: 320Mi requests (было 512Mi - оптимизировано!)

  # --- CephFS Provisioner (Deployment на storage-нодах) ---
  # Создает/удаляет CephFS volumes (только если enableCephfsDriver: true)
  # csiCephFSProvisionerResource: |
  #   - name : csi-provisioner      # Основной компонент provisioning
  #     resource: { requests: { memory: 128Mi, cpu: 100m }, limits: { memory: 256Mi } }
  #   - name : csi-resizer          # Расширение томов
  #     resource: { requests: { memory: 128Mi, cpu: 100m }, limits: { memory: 256Mi } }
  #   - name : csi-attacher         # Attach/Detach томов
  #     resource: { requests: { memory: 128Mi, cpu: 100m }, limits: { memory: 256Mi } }
  #   - name : csi-snapshotter      # Снапшоты CephFS
  #     resource: { requests: { memory: 128Mi, cpu: 100m }, limits: { memory: 256Mi } }
  #   - name : csi-cephfsplugin     # CephFS драйвер
  #     resource: { requests: { memory: 384Mi, cpu: 150m }, limits: { memory: 768Mi } }
  #   - name : liveness-prometheus  # Health checks
  #     resource: { requests: { memory: 64Mi, cpu: 25m }, limits: { memory: 128Mi } }

  # --- CephFS NodePlugin (DaemonSet на всех worker/storage нодах) ---
  # Монтирует CephFS локально на ноде (только если enableCephfsDriver: true)
  # csiCephFSPluginResource: |
  #   - name : driver-registrar     # Регистрация драйвера
  #     resource: { requests: { memory: 32Mi, cpu: 25m }, limits: { memory: 64Mi } }
  #   - name : csi-cephfsplugin     # CephFS драйвер для монтирования
  #     resource: { requests: { memory: 256Mi, cpu: 100m }, limits: { memory: 512Mi } }
  #   - name : liveness-prometheus  # Health checks
  #     resource: { requests: { memory: 32Mi, cpu: 25m }, limits: { memory: 64Mi } }
  # Итого на ноду: 320Mi requests (было 512Mi - оптимизировано!)

# discoveryDaemon выключен — он авто-сканит устройства. Мы добавляем их руками в кластерной части.
enableDiscoveryDaemon: false
# TODO: Добавить пробы.
```

> values-cluster.yaml (для rook-ceph-cluster)

```yaml
# === rook/rook-ceph-cluster values (готово к применению) ===
operatorNamespace: rook-ceph

cephClusterSpec:
  dataDirHostPath: /var/lib/rook

  cephVersion:
    image: quay.io/ceph/ceph:v18.2.2 # Reef (рабочий тег)

  dashboard:
    enabled: true
    ssl: true

  mon:
    count: 3
    allowMultiplePerNode: false

  mgr:
    count: 1
    allowMultiplePerNode: false
    # Явно включаем модули MGR (если используется Object Storage - обязательно указать rgw)
    modules:
      - name: rgw # Для Object Gateway в Dashboard
        enabled: true

  # ========================================================================
  # PLACEMENT - где запускать Ceph демоны (MON/MGR/OSD)
  # ========================================================================
  # all - применяется ко всем компонентам (mon, mgr, osd)
  placement:
    all:
      # Tolerations - разрешает запуск на storage-нодах с taint
      tolerations:
        - key: "workload" # Ключ taint на storage-нодах
          operator: "Equal"
          value: "ceph" # Значение taint
          effect: "NoSchedule" # Эффект (NoSchedule = обычные поды не попадут)

      # NodeAffinity - ОБЯЗАТЕЛЬНО только на storage-нодах
      # Демоны Ceph запускаются только на нодах с label storage=true
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/storage
                  operator: In
                  values: ["true"]

  # ========================================================================
  # РЕСУРСЫ для Ceph демонов - оптимизированы под 4GB RAM ноды
  # ========================================================================
  # Основано на РЕАЛЬНОМ потреблении в production
  # Requests занижены (реальное потребление выше) для экономии резервирования
  resources:
    # MON (Monitor) - хранит карту кластера, отслеживает состояние
    # Запускается 3 шт для кворума (quorum)
    mon:
      requests: { cpu: "150m", memory: "384Mi" } # реально ~460Mi
      limits: { memory: "1Gi" }

    # MGR (Manager) - мониторинг, Dashboard, метрики
    # Запускается 1-2 шт (active + standby)
    mgr:
      requests: { cpu: "150m", memory: "512Mi" } # реально ~540Mi
      limits: { memory: "1Gi" }

    # OSD (Object Storage Daemon) - хранит данные на дисках
    # Запускается по 1 на каждый диск (у вас 3 OSD)
    osd:
      requests: { cpu: "400m", memory: "512Mi" } # реально ~350Mi
      limits: { memory: "1.5Gi" }

  # Снижаем потребление памяти OSD
  annotations:
    osd:
      rook.io/ceph-osd-memory-target: "1073741824" # ~1GiB

  # ЯВНО задаём диски/разделы (никакого useAll*)
  # ВАЖНО: Для расширенных разделов (через resize) используем LVM!
  storage:
    useAllNodes: false
    useAllDevices: false
    nodes:
      - name: control-worker-7nfqwbbv
        devices:
          - name: /dev/ceph-vg-1/osd-lv # LVM поверх расширенного раздела
      - name: control-worker-sb9u8lc6
        devices:
          - name: /dev/ceph-vg-2/osd-lv # LVM поверх расширенного раздела
      - name: control-worker-qkzswwul
        devices:
          - name: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1 # Отдельный диск

  # Можно выключить сборщик крэшей на маленьких нодах
  crashCollector:
    disable: true

# --- Пул RBD + StorageClass (RWO, под БД и т.п.) ---
cephBlockPools:
  - name: replicapool
    spec:
      failureDomain: host
      replicated:
        size: 2 # стартово экономим место; позже переведёшь на 3
    storageClass:
      enabled: true
      name: ceph-rbd
      isDefault: true # сделаем дефолтным классом
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      volumeBindingMode: WaitForFirstConsumer
      parameters:
        imageFormat: "2"
        imageFeatures: layering
        csi.storage.k8s.io/fstype: ext4
        csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/provisioner-secret-namespace: "{{ .Release.Namespace }}"
        csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/controller-expand-secret-namespace: "{{ .Release.Namespace }}"
        csi.storage.k8s.io/controller-publish-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/controller-publish-secret-namespace: "{{ .Release.Namespace }}"
        csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
        csi.storage.k8s.io/node-stage-secret-namespace: "{{ .Release.Namespace }}"

# ========================================================================
# УПРАВЛЕНИЕ ТИПАМИ ХРАНИЛИЩ
# ========================================================================

# === RBD (Block Storage) - ВСЕГДА ВКЛЮЧЕН ===
# Настраивается выше в cephBlockPools (replicapool)

# === CephFS (File System) - ВКЛЮЧИТЬ/ВЫКЛЮЧИТЬ ПО НЕОБХОДИМОСТИ ===
# Если НЕ нужен shared storage (RWX) - отключите:
#   1. В values-operator.yaml: enableCephfsDriver: false
#   2. Здесь: storageClass.enabled: false (или удалите весь блок cephFileSystems)
#
# Экономия: -48 PG, -2 MDS пода, -80Mi памяти
# Раскомментируйте, если нужен CephFS и в values-cluster.yaml включить enableCephfsDriver: true
# cephFileSystems:
#   - name: cephfs
#     spec:
#       metadataPool:
#         replicated: { size: 2 } # позже можно на 3
#       dataPools:
#         - replicated: { size: 2 }
#       metadataServer:
#         activeCount: 1
#         activeStandby: true
#     storageClass:
#       enabled: false # включи true, когда RWX потребуется
#       name: cephfs
#       allowVolumeExpansion: true
#       reclaimPolicy: Delete
#       volumeBindingMode: WaitForFirstConsumer
#       parameters:
#         mounter: kernel
#         csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
#         csi.storage.k8s.io/provisioner-secret-namespace: "{{ .Release.Namespace }}"
#         csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
#         csi.storage.k8s.io/controller-expand-secret-namespace: "{{ .Release.Namespace }}"
#         csi.storage.k8s.io/controller-publish-secret-name: rook-csi-cephfs-provisioner
#         csi.storage.k8s.io/controller-publish-secret-namespace: "{{ .Release.Namespace }}"
#         csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
#         csi.storage.k8s.io/node-stage-secret-namespace: "{{ .Release.Namespace }}"

# === Object Storage (S3/Swift API) - ВКЛЮЧИТЬ/ВЫКЛЮЧИТЬ ===
# RGW (RADOS Gateway) предоставляет S3-совместимый API для объектного хранилища
#
# ⚠️ ВАЖНО: Создает 11+ пулов и ~200 PG! Большой overhead!
#
# ℹ️ CSI ДРАЙВЕР НЕ НУЖЕН: RGW работает через HTTP/S3 API (не монтируется как volume)
#
# 💡 Альтернатива для малых кластеров: MinIO + PVC на Ceph RBD
#    - Проще в настройке, красивый UI
#    - Но добавляет лишний слой (MinIO → RBD → Ceph)
#
# 🎯 Для выделенных storage нод: используйте Ceph RGW (нативное решение)
#    - RGW поды запустятся на storage нодах рядом с OSD
#    - Прямой доступ к Ceph, меньше overhead
#
# Если НЕ нужен S3 API - закомментируйте весь блок cephObjectStores
# Экономия: -200+ PG, -1 RGW под, -много памяти
#
# Раскомментируйте, если нужен Object Storage:
cephObjectStores:
  - name: ceph-objectstore
    spec:
      # Metadata Pool - метаданные объектов (имена, владельцы)
      metadataPool:
        failureDomain: host
        replicated:
          size: 3 # 3 реплики для надежности метаданных

      # Data Pool - данные объектов (erasure coded для экономии места)
      dataPool:
        failureDomain: host
        erasureCoded:
          dataChunks: 2 # 2 части данных
          codingChunks: 1 # 1 часть для восстановления
        parameters:
          bulk: "true" # Оптимизация для больших объектов

      # Gateway - HTTP сервер (S3 API endpoint)
      gateway:
        instances: 1 # Количество RGW подов
        port: 80
        priorityClassName: system-cluster-critical

        # Placement - запускаем RGW на storage нодах (рядом с OSD)
        placement:
          tolerations:
            - key: workload
              operator: Equal
              value: ceph
              effect: NoSchedule
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
                - matchExpressions:
                    - key: node-role.kubernetes.io/storage
                      operator: In
                      values: ["true"]

        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            memory: 1Gi

      preservePoolsOnDelete: true # Не удалять данные при удалении CRD

    # StorageClass для S3 buckets (через Object Bucket Claims)
    storageClass:
      enabled: true
      name: ceph-bucket
      reclaimPolicy: Delete
      volumeBindingMode: Immediate
      parameters:
        region: us-east-1

# === Toolbox - диагностический под (РЕКОМЕНДУЕТСЯ) ===
# Используется для команд: kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status
toolbox:
  enabled: true
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 1Gi
```

> 🌐 Dashboard - получить пароль

```bash
# Получить автоматически сгенерированный пароль
kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode && echo

# Логин по умолчанию: admin
```

## Настроить Ingress

Создайте Ingress для доступа к Dashboard через браузер:

```yaml
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
    - host: ceph.stroy-track.local
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
