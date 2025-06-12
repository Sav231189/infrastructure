# [AWX](https://github.com/ansible/awx) - Open Source Automation Platform

# 🔐 Ansible AWX — Установка через кластер k3s

## 🧠 Что такое Ansible AWX? 📌
- **Ansible** — agentless-инструмент автоматизации конфигурации и развёртывания (установки программ, настройки серверов, управления конфигурациями, deploy приложений). Он работает по SSH, без установки агентов на серверах.
- **AWX** — Web-UI с базой данных, API, правами доступа и удобной визуализацией для управления Ansible. Встроен Ansible Engine.
- AWX Web UI работает через NGINX proxy с SSL: https://ansible.<domain> → http://localhost:30080
- RBAC: Можно настраивать ACL политики и роли в AWX.

## 🛠️ Требования
1. 🖥️ Выделенный VPS (Предварительные требования) - **2 CPU / 4 GB RAM / 30+ GB Disk**, ОС: Ubuntu 20.04+, 
2. 🛡️ Настроенный HTTPS-прокси на NGINX (под домен https://ansible.<domain>)

## 📦 Установка Ansible AWX в кластер k3s
> обязательно для установки: k3s
> Установить AWX Operator
> Установить AWX
- 📦 ./install.sh

## Интеграция с Vault
> ./vault/readme.md
- 📦 ./install.sh -> Установить Vault Collection

## Интеграция с Ceph
> ./ceph/readme.md
> Необходимо Inventory (с группой ceph) для настройки Ceph
- 📦 ./install.sh -> 🐘 Инициализировать Ceph (создать playbook)

## Интеграция с Citus(Postgres)
> ./citus_pg/readme.md
- 📦 ./install.sh -> 🐘 Инициализировать Citus + PostgreSQL (создать playbook)

## 🧩 Основные понятия в Ansible 
1. Inventory — список хостов, и можешь делить его на группы (есть default группы: all,ungrouped)
2. Groups - Позволяют делать hosts по группам и применить разные роли/настройки к каждой группе.
3. Project — откуда брать плейбуки. Это ссылка на Git-репозиторий (или локальный каталог), где хранятся .yml файлы Ansible.
4. Playbook — что сделать. Это .yml файл со списком задач.
5. Credentials — как подключаться (SSH ключ, GitHub token, Vault password, Логины к облакам). Ansible подключается по SSH или по API (например, к AWS/Git).
6. Job Template — как запускать playbook. Шаблон можно запускать: вручную (из UI или API), по расписанию, при событии (в Webhook)
7. Variables — Переменные. Можешь передавать их: в playbook, в Inventory, в шаблон запуска, в Credentials (Vault-пароль и т.д.)

## 📊 Как всё это работает вместе
- Ты создаёшь Inventory (например, выбрать группу "все [prod] сервера").
- Создаёшь Project, указываешь путь к Git-плейбукам или локальным.
- Создаёшь Credentials — например секреты для подключения.
- Создаёшь Job Template, указываешь, какой playbook, inventory и credentials.
- Запускаешь Job — и он выполняет задачи на серверах (например, все [prod] сервера).

## 💥 Что ты можешь делать с Ansible
- Устанавливать/обновлять ПО
- Настраивать файрволы, nginx, базы
- Создавать пользователей, ssh-ключи, sudo
- Автоматизировать деплой приложений
- Работать с k8s (есть k8s модули)
- Работать с AWS, GCP, Docker, GitLab, Vault

## Пример использования с добавлением Inventory, Groups, Hosts, Credentials
  - Add Inventory (обычное статическое инвентори): 
    - {name: stage, organization: Default}
    - сохранить
  - Resources → Inventories → stage → Groups → Add:
    - {name: ceph, description: Только ноды Ceph}
    - {name: app, description: Только ноды Kubernetes}
  - Resources → Inventories → stage → Hosts → Add host (публичные IP и желаемые WireGuard IP):
    - {name: app-stage-01, inventory: stage, variables (YAML режим): ansible_host: 192.168.3.56 /n wg_ip: 10.10.0.1}
    - {name: ceph-stage-01, inventory: stage, variables (YAML режим): ansible_host: 192.168.3.77 /n wg_ip: 10.10.0.2}
  - Resources → Inventories → stage → Groups:
    - ceph: Hosts → Add → existing host - отметить только ноды Ceph
    - app: Hosts → Add → existing host - отметить только ноды Kubernetes
  - Создаём Credential c логином/паролем:
    - Resources → Credentials → Add → Credential Type: Machine.
    - {name: ubuntu-ssh-password (или любое удобное), username: ubuntu (или ваш юзер на VPS), password: ваш SSH-пароль}
  - Проверяем видимость хостов через Ad-hoc команду через Credentials:
    - Resources → Inventories → stage → Hosts → Run Command 
    - {Module: ping, limit: ceph (группа с нодами Ceph), credential: ubuntu-ssh-password}
    - Launch
