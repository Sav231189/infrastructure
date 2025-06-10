# Citus - распределённое хранилище для Postgres

## Интегрировать
  - 📦 ./install.sh -> 🐘 Инициализировать Citus (создать playbook)

## Скрипт инициализации добавит playbooks для проекта <Citus_pg_Deploy> (awx/projects/citus/...)
  - создаст каталог: /var/lib/awx/projects/citus-cluster
  - добавит файлы с нужным содержимым: citus-pg-deploy.yml
**Install Citus - /citus-pg-deploy.yml** - Ansible playbook (2 этапа):
  - Инициализация Citus:
  - Настройка кластера Citus

## Настроить AWX (в Web UI)
> У вас должен быть Inventory c группой all
> Coordinator устанавливается автоматически на первую ноду группы all, если еще не установлен
- Resources → Projects → Add → Project
  - Name: <Citus_pg_Deploy>
  - Source Control Type: manual
  - Playbook Directory: citus-cluster
  - Inventory: citus_pg
  - Project: <Citus_pg_Deploy>
  - Playbook: citus-pg-deploy.yml
  - Credentials: ubuntu-ssh-password
  - Privilege Escalation: включить
  - limit: all
  - Save

## ➕ Масштабирование Citus (в AWX Web UI)
- Добавьте новую VPS в vpn-inventory → группу all (укажите ansible_host и wg_ip).
- Запустите <Citus_pg_Deploy> — playbook подхватит новые ноды, установитCitus и настроит их как worker.