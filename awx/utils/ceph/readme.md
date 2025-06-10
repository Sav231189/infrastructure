# Ceph - распределённое хранилище

## Интегрировать
  - 📦 ./install.sh -> 🐘 Инициализировать Ceph (создать playbook)

## Скрипт инициализации добавит playbooks для проекта <Ceph_Deploy> (awx/projects/ceph/...)
  - создаст каталог: /var/lib/awx/projects/ceph
  - добавит файлы с нужным содержимым: ceph-only.yml и requirements.yml
  - проставит владельца awx:awx
**Install Ceph - /ceph-only.yml** - Ansible playbook (2 этапа):
  - Bootstrap первого MON (на ceph-01):
    - Удаляет старые репозитории/ключи.
    - Восстанавливает сломанные зависимости.
    - Устанавливает cephadm.
    - Проверяет и скачивает образ Ceph.
    - Проверяет установку (cephadm и образ).
  - Bootstrap первой ceph-ноды из groups['ceph'][0]
    - Проверка, был ли bootstrap
    - Выполняем bootstrap если ещё не выполнен
  - Scale-out (тоже как shell-таски на ceph-01):
    - host add — регистрирует все хосты из группы ceph в Ceph-оркестраторе
    - orch apply mon — разворачивает 3 MON
    - orch apply osd — разворачивает OSD на всех доступных устройствах
    - Финальный ceph -s для проверки здоровья
**Requirements - /requirements.yml** 
  - Execution Environment
    - В AWX укажите для проекта ceph-ansible путь к requirements.yml, чтобы автоматически установить роль geerlingguy.wireguard.

## Настроить AWX (в Web UI)
> У вас должен быть Inventory c группой ceph (см. ansible/readme.md)
> Минимум 3 хоста в группе ceph
> Bootstrap только на 1 ноду
- Resources → Projects → Add → Project
  - Name: <Ceph_Deploy>
  - Source Control Type: manual
  - Playbook Directory: ceph
  - Save
- Resources → Templates → Add → Job Template → Создать Job Template
  - Name: <Add_Cephadm>
  - Inventory: ceph-inventory
  - Project: <Ceph_Deploy>
  - Playbook: cephadm_deploy.yml
  - Credentials: ubuntu-ssh-password
  - Privilege Escalation: включить
  - limit: all
  - Save
- Resources → Templates → Add → Job Template → Создать Job Template
  - Name: <Bootstrap_Ceph>
  - Inventory: ceph-inventory
  - Project: <Ceph_Deploy>
  - Playbook: cephadm_bootstrap.yml
  - Credentials: ubuntu-ssh-password
  - Privilege Escalation: включить
  - limit: bootstrap
  - Save
- Resources → Templates → Add → Job Template → Создать Job Template
  - Name: <Add_MON>
  - Inventory: ceph-inventory
  - Project: <Ceph_Deploy>
  - Playbook: cephadm_add_mon.yml
  - Credentials: ubuntu-ssh-password
  - Privilege Escalation: включить
  - limit: mon_nodes
  - Save
- Resources → Templates → Add → Job Template → Создать Job Template
  - Name: <Add_auto_OSD>
  - Inventory: ceph-inventory
  - Project: <Ceph_Deploy>
  - Playbook: ceph_auto_osd.yml
  - Credentials: ubuntu-ssh-password
  - Privilege Escalation: включить
  - limit: all
  - Save

> После этого в один клик AWX установит и настроит ваш Ceph-кластер на трёх нодах, и вы сразу увидите HEALTH_OK.

## ➕ Масштабирование Ceph (в AWX Web UI)
- Добавьте новую VPS в vpn-inventory → группу ceph (укажите ansible_host и wg_ip).
- Запустите <Add_Cephadm> — плейбук подхватит всех, скачает всем образы Ceph и установит Cephadm.
- Запустите <Bootstrap_Ceph> — плейбук на 1 ноду для инициализации кластера, группа bootstrap (1 нода).
- Запустите <Add_MON> — плейбук для добавления MON на хосты группы mon-nodes.
- Запустите <Add_auto_OSD> — плейбук для добавления OSD на хосты группы all.