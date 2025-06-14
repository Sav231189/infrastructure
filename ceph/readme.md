# 🔐 Ceph — распределённое хранилище
  - блочные (RBD), файловые (CephFS) и объектные (RADOS Gateway) интерфейсы
  - глубокая интеграция с Kubernetes через CSI

## 📦 Установка Ceph на VPS кластер через Ansible
> [ansible -> ceph -> readme.md](https://github.com/Sav231189/ansible/tree/main/projects/ceph)

## 📦 Установка Ceph в kubernetes
> ./install.md

##  📐 Архитектура кластера
  - MON (монитор демон): минимум 3 ноды для quorum. Обеспечивают согласованность и "истину" о состоянии кластера. Ceph использует кворум: 2 из 3 должны быть доступны, иначе кластер становится HEALTH_ERR.
  - MGR (менеджер демон): 1–2 демона для метрик и дашборда. По умолчанию Ceph сам управляет MGR, и назначает резервный MGR (Node 2).
  - OSD (Object Storage Daemon): 
    - OSD — это демон Ceph, который отвечает за фактическое хранение данных на диске и их репликацию между другими OSD. На каждый физический (или виртуальный) диск в узле вы запускаете по 1–2 экземпляра ceph-osd внутри контейнеров Ceph.
    - Принимать запросы на запись/чтение блоков (RBD), объектов (RGW (Rados Gateway) S3 опционально) или фрагментов файлов (CephFS - MDS (Metadata Server)).
    - Реплицировать данные на другие OSD согласно CRUSH-карте (🧠 CRUSH Map - чтобы при отказе одного диска данные не пропали).
    - Отвечать на pings от мониторных демонов (MON) для поддержания кворума и здоровья.
  - Pool - ceph-пул — это логическая единица хранения, куда Ceph пишет данные. Он определяет:
    - ⚙ Тип	replicated (копии) или erasure (кодирование)
    - 🧱 Кол-во PG (placement groups)	Как разбивать данные по OSD
    - 🔁 Replication	Сколько копий данных хранить
  - Сеть — лучше через WireGuard или VLAN:
    - public_network (клиентский трафик)
    - cluster_network (репликация OSD)
