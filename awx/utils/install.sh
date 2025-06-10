#!/usr/bin/env bash
set -euo pipefail

# ==== Проверка root-доступа ====
if [[ $EUID -ne 0 ]]; then
  echo "❌ Этот скрипт должен быть запущен от имени root."
  exit 1
fi

# ==== Конфигурация ====
AWX_NAMESPACE="awx"
SECRET_NAME="awx-admin-password"
AWX_CR_FILE="awx-cr.yaml"
NODE_PORT="30080"
HELM_RELEASE="awx-operator"
HELM_REPO_NAME="awx-operator"
HELM_REPO_URL="https://ansible-community.github.io/awx-operator-helm/"
KUBECONFIG_FILE="/etc/rancher/k3s/k3s.yaml"
export KUBECONFIG=${KUBECONFIG:-$KUBECONFIG_FILE}
TIMEOUT="10m"

# ==== Проверка зависимостей ====
function check_deps() {
  for cmd in kubectl helm openssl fallocate free df; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "❌ Требуется установить: $cmd"
      exit 1
    fi
  done
}

# ==== Проверка ресурсов ====
function check_resources() {
  echo "🔍 Проверка ресурсов..."
  local free_space_gb=$(df -BG / | awk 'NR==2 {gsub("G", "", $4); print $4}')
  local mem_total=$(free -m | awk '/^Mem:/ {print $2}')
  local mem_free=$(free -m | awk '/^Mem:/ {print $7}')
  local swap_total=$(free -m | awk '/^Swap:/ {print $2}')
  local swap_used=$(free -m | awk '/^Swap:/ {print $3}')

  echo "📊 RAM: ${mem_total} MB total, ${mem_free} MB free"
  echo "💽 Disk: ${free_space_gb} GB available"
  echo "🔄 Swap: ${swap_total} MB total, ${swap_used} MB used"

  if (( free_space_gb < 3 )); then
    echo "⚠️ Недостаточно места на / (<3GB). Освободите диск."
    exit 1
  fi

  if (( mem_free < 1500 )); then
    echo "⚠️ Недостаточно свободной памяти (<1.5GB). Добавим swap."
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
}

function ensure_namespace() {
  kubectl create ns "$AWX_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

function ensure_helm_repo() {
  helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" 2>/dev/null || true
  helm repo update
}

function ensure_local_path_provisioner() {
  echo "🔍 Проверка local-path-provisioner..."

  if ! kubectl get ns local-path-storage &>/dev/null || \
    ! kubectl get pods -n local-path-storage 2>/dev/null | grep -q 'local-path-provisioner.*Running'; then
    echo "📦 Устанавливаем local-path-provisioner..."
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

    echo "⏳ Ожидание запуска local-path-provisioner..."
    kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=60s || {
      echo "❌ Не удалось запустить local-path-provisioner."
      exit 1
    }
  else
    echo "✅ local-path-provisioner уже установлен."
  fi
}

function wait_for_pods() {
  echo "⏳ Ожидание готовности pod’ов в namespace $AWX_NAMESPACE..."
  kubectl wait pod -n "$AWX_NAMESPACE" --for=condition=Ready --all --timeout=$TIMEOUT || true
}

# Добавим загрузку demo-плейбука после установки AWX
function add_demo_playbook() {
  echo "📁 Ожидание запуска pod'а awx-task..."

  for i in {1..60}; do
    pod_name=$(kubectl get pod -n "$AWX_NAMESPACE" | grep awx-task | awk '{print $1}' | head -n 1)

    if [[ -n "$pod_name" ]]; then
      pod_status=$(kubectl get pod "$pod_name" -n "$AWX_NAMESPACE" -o jsonpath="{.status.phase}")
      if [[ "$pod_status" == "Running" ]]; then
        echo "✅ Найден готовый pod: $pod_name"
        break
      fi
    fi

    echo -n "."; sleep 2
  done

  if [[ -z "$pod_name" ]] || [[ "$pod_status" != "Running" ]]; then
    echo -e "\n❌ Под awx-task не найден или не готов. Пропускаем создание demo-playbook."
    return
  fi

  echo "📁 Добавляем demo-playbook в $pod_name..."

  kubectl exec -n "$AWX_NAMESPACE" "$pod_name" -- /bin/bash -c '
    mkdir -p /var/lib/awx/projects/demo-playbook && \
    cat > /var/lib/awx/projects/demo-playbook/ping.yml <<EOF
- name: Test ping
  hosts: localhost
  tasks:
    - name: Ping localhost
      ping:
EOF
    chown -R 1000:1000 /var/lib/awx/projects/demo-playbook
  '

  echo "✅ demo-playbook добавлен."
}

# Функция, создающая в awx-task manual-проект "ceph"
function add_ceph_playbook() {
  echo "📁 Ожидание запуска pod'а awx-task..."
  local pod_name pod_status
  for i in {1..60}; do
    pod_name=$(kubectl get pod -n "$AWX_NAMESPACE" | awk '/awx-task/ {print $1; exit}')
    [[ -n "$pod_name" ]] || { echo -n "."; sleep 2; continue; }
    pod_status=$(kubectl get pod "$pod_name" -n "$AWX_NAMESPACE" -o jsonpath="{.status.phase}")
    [[ "$pod_status" == "Running" ]] && break
    echo -n "."; sleep 2
  done

  if [[ -z "$pod_name" || "$pod_status" != "Running" ]]; then
    echo -e "\n❌ pod awx-task не запущен — прерываю."
    return 1
  fi

  echo "✅ Найден pod: $pod_name"
  TMP_DIR=$(mktemp -d)
  mkdir -p "$TMP_DIR/project"

  echo "📁 Создаём playbook cephadm_deploy.yml..."
  cat > "$TMP_DIR/project/cephadm_deploy.yml" <<'EOF'
---
- name: Загружаем образ ceph и устанавливаем cephadm, podman, lvm2 и chrony
  hosts: all
  become: true
  gather_facts: yes
  vars:
    ceph_image: quay.io/ceph/ceph:v17
  tasks:
    - name: Проверяем, установлен ли podman
      shell: which podman
      register: podman_check
      changed_when: false
      failed_when: false
    - name: Устанавливаем podman, если не установлен
      apt:
        name: podman
        state: present
        update_cache: true
        force_apt_get: true
      when: podman_check.rc != 0
    - name: Устанавливаем lvm2 и chrony
      apt:
        name:
          - lvm2
          - chrony
        state: present
        update_cache: true
    - name: Проверка, работает ли systemd
      stat:
        path: /run/systemd/system
      register: systemd_present
    - name: Пропускаем запуск chrony, если systemd не активен (например, LXC)
      meta: end_play
      when: not systemd_present.stat.exists
    - name: Включаем и запускаем chrony
      systemd:
        name: chrony
        enabled: true
        state: started
      when: systemd_present.stat.exists



    - name: Проверка podman
      command: podman --version
      register: podman_version
      changed_when: false
    - name: Проверка lvm2
      command: vgdisplay
      register: lvm2_check
      changed_when: false
      ignore_errors: true
    - name: Проверка времени
      command: timedatectl status
      register: time_status
      changed_when: false



    - name: Проверяем наличие нужного образа Ceph в podman
      shell: podman image exists "{{ ceph_image }}"
      register: ceph_image_check
      failed_when: false
      changed_when: false
    - name: Скачиваем образ Ceph, если отсутствует
      shell: podman pull "{{ ceph_image }}"
      when: ceph_image_check.rc != 0
    - name: Получаем список образов Ceph
      # shell: podman images --format "{{ '{{.Repository}} {{.Tag}}' }}" | grep quay.io/ceph/ceph
      shell: podman images | grep quay.io/ceph/ceph
      register: cephadm_image_tags
      changed_when: false
      ignore_errors: true
    - name: Показываем список образов Ceph
      debug:
        msg: "{{ cephadm_image_tags.stdout_lines }}"



    - name: Проверяем наличие cephadm в системе
      shell: which cephadm
      register: cephadm_exists
      changed_when: false
      failed_when: false
    - name: Устанавливаем cephadm, если не установлен
      apt:
        name: cephadm
        state: present
        force_apt_get: true
        update_cache: true
      when: cephadm_exists.rc != 0

    - name: Получаем текущий hostname
      command: hostname -s
      register: current_hostname
      changed_when: false



    - name: Устанавливаем корректный hostname, если отличается
      hostname:
        name: "{{ inventory_hostname }}"
      when: current_hostname.stdout != inventory_hostname

    - name: Обновляем hostname через systemd (если требуется)
      systemd:
        name: systemd-hostnamed
        state: restarted
      when: current_hostname.stdout != inventory_hostname
EOF

  echo "📁 Создаём playbook cephadm_bootstrap.yml"
  cat > "$TMP_DIR/project/cephadm_bootstrap.yml" <<'EOF'
---
- name: Bootstrap первой ceph-ноды (так же автоматически обновляет версию quay.io/ceph/ceph). Назначается mgr (Manager daemon).
  hosts: bootstrap
  become: true
  vars:
    mon_ip: "{{ hostvars[inventory_hostname]['ansible_host'] }}"
  tasks:
    - name: Проверяем, был ли bootstrap
      stat:
        path: /etc/ceph/ceph.conf
      register: ceph_bootstrapped

    - name: Выполняем bootstrap если ещё не выполнен
      shell: cephadm bootstrap --mon-ip {{ mon_ip }} --initial-dashboard-user admin --initial-dashboard-password admin
      when: not ceph_bootstrapped.stat.exists
EOF

  echo "📁 Создаём playbook cephadm_add_mon.yml"
  cat > "$TMP_DIR/project/cephadm_add_mon.yml" <<'EOF'
---
- name: Detect bootstrap node
  hosts: mon_nodes
  gather_facts: false
  become: true
  tasks:
    - name: Check if this node is the bootstrap node (has ceph.admin keyring)
      stat:
        path: /etc/ceph/ceph.client.admin.keyring
      register: ceph_admin_key

    - name: Set fact on bootstrap node
      set_fact:
        is_bootstrap_node: true
      when: ceph_admin_key.stat.exists

- name: Install cephadm SSH public key on all mon_nodes
  hosts: mon_nodes
  gather_facts: false
  become: true

  vars:
    bootstrap_host: >-
      {{ hostvars | dict2items
                  | selectattr('value.is_bootstrap_node', 'defined')
                  | selectattr('value.is_bootstrap_node')
                  | map(attribute='key') | list | first }}

  tasks:
    - name: Fetch cephadm SSH public key from bootstrap node
      delegate_to: "{{ bootstrap_host }}"
      run_once: true
      command: cephadm shell -- ceph cephadm get-pub-key
      register: ceph_pubkey

    - name: Install cephadm SSH public key
      authorized_key:
        user: root
        key: "{{ ceph_pubkey.stdout }}"

- name: Add all hosts to Ceph orchestrator by IP
  hosts: mon_nodes
  gather_facts: false
  become: true
  vars:
    bootstrap_host: >-
      {{ hostvars | dict2items
                  | selectattr('value.is_bootstrap_node', 'defined')
                  | selectattr('value.is_bootstrap_node')
                  | map(attribute='key') | list | first }}
  tasks:
    - name: Add this host to Ceph orchestrator by IP
      delegate_to: "{{ bootstrap_host }}"
      run_once: false
      shell: |
        cephadm shell -- ceph orch host add {{ inventory_hostname }} {{ hostvars[inventory_hostname]['ansible_host'] }} --labels mon
      register: orch_add_output
    - name: Show Ceph host-add result
      debug:
        var: orch_add_output

- name: Add hosts to Ceph cluster and deploy MONs
  hosts: mon_nodes
  gather_facts: false
  become: true

  vars:
    bootstrap_host: >-
      {{ hostvars | dict2items
                  | selectattr('value.is_bootstrap_node', 'defined')
                  | selectattr('value.is_bootstrap_node')
                  | map(attribute='key') | list | first }}

  tasks:
    - name: Get short hostname
      command: hostname -s
      register: short_hostname

    - name: Add this host to Ceph orchestrator by IP
      delegate_to: "{{ bootstrap_host }}"
      run_once: false
      shell: |
        cephadm shell -- ceph orch host add {{ short_hostname.stdout }} {{ hostvars[inventory_hostname]['ansible_host'] }} --labels mon
      ignore_errors: true

    - name: Apply MONs to all nodes
      delegate_to: "{{ bootstrap_host }}"
      run_once: true
      shell: |
        cephadm shell -- ceph orch apply mon --placement="{{ groups['mon_nodes'] | join(',') }}"

EOF



  echo "📁 Создаём playbook ceph_auto_osd.yml"
  cat > "$TMP_DIR/project/ceph_auto_osd.yml" <<'EOF'
---
- name: Определяем bootstrap-ноду
  hosts: all
  gather_facts: false
  become: true

  tasks:
    - name: Проверяем, является ли узел bootstrap-нодой (наличие ключа администратора)
      stat:
        path: /etc/ceph/ceph.client.admin.keyring
      register: ceph_admin_key

    - name: Устанавливаем флаг is_bootstrap_node
      set_fact:
        is_bootstrap_node: true
      when: ceph_admin_key.stat.exists

- name: Автоматическое добавление OSD на свободные диски
  hosts: all
  become: true
  gather_facts: true

  vars:
    excluded_devices:
      - sda
      - sr0
      - loop
      - dm
      - zram
    device_filter: "^sd|^vd|^nvme"

    bootstrap_host: >-
      {{ hostvars | dict2items
                  | selectattr('value.is_bootstrap_node', 'defined')
                  | selectattr('value.is_bootstrap_node')
                  | map(attribute='key') | list | first }}

  tasks:
    - name: Получаем список блоковых устройств (через JSON)
      command: lsblk -J -o NAME,TYPE
      register: lsblk_json

    - name: Фильтруем устройства под OSD
      set_fact:
        osd_devices: >-
          {{
            lsblk_json.stdout | from_json
            | dict2items
            | selectattr('key', 'equalto', 'blockdevices')
            | map(attribute='value')
            | list | first
            | selectattr('type', 'equalto', 'disk')
            | selectattr('name', 'match', device_filter)
            | rejectattr('name', 'search', excluded_devices | join('|'))
            | rejectattr('children', 'defined')
            | map(attribute='name') | list
          }}

    - name: Показываем найденные устройства под OSD
      debug:
        msg: "На {{ inventory_hostname }} обнаружены устройства: {{ osd_devices }}"

    - name: Пропускаем хост, если нет подходящих устройств
      meta: end_host
      when: osd_devices | length == 0

    - name: Добавляем OSD через cephadm для каждого устройства
      delegate_to: "{{ bootstrap_host }}"
      loop: "{{ osd_devices }}"
      loop_control:
        label: "{{ inventory_hostname }}:/dev/{{ item }}"
      shell: >
        cephadm shell -- ceph orch daemon add osd {{ inventory_hostname }}:/dev/{{ item }}
      register: osd_add_result
      changed_when: "'Created osd' in osd_add_result.stdout or 'Created new service' in osd_add_result.stdout"
      ignore_errors: true

    - name: Вывод результата по OSD
      debug:
        var: osd_add_result.stdout_lines

EOF



#   echo "📁 Создаём ansible.cfg..."
#   cat > "$TMP_DIR/project/ansible.cfg" <<EOF
# [defaults]
# timeout = 60
# EOF

  echo "📤 Копируем проект в pod AWX..."
  kubectl exec -n "$AWX_NAMESPACE" "$pod_name" -- mkdir -p /var/lib/awx/projects/ceph
  kubectl cp "$TMP_DIR/project/." "$AWX_NAMESPACE/$pod_name:/var/lib/awx/projects/ceph"

  rm -rf "$TMP_DIR"
  echo "✅ Проект загружен. Запускай Job Templates"
}


function add_citus_pg_playbook() {
  echo "📁 Ожидание запуска pod'а awx-task..."
  local pod_name pod_status
  for i in {1..60}; do
    pod_name=$(kubectl get pod -n "$AWX_NAMESPACE" | awk '/awx-task/ {print $1; exit}')
    [[ -n "$pod_name" ]] || { echo -n "."; sleep 2; continue; }
    pod_status=$(kubectl get pod "$pod_name" -n "$AWX_NAMESPACE" -o jsonpath="{.status.phase}")
    [[ "$pod_status" == "Running" ]] && break
    echo -n "."; sleep 2
  done

  if [[ -z "$pod_name" || "$pod_status" != "Running" ]]; then
    echo -e "\n❌ pod awx-task не запущен — прерываю."
    return 1
  fi

  echo "✅ Найден pod: $pod_name"
  TMP_DIR=$(mktemp -d)
  mkdir -p "$TMP_DIR/project"



  echo "📁 Создаём playbook citus-pg-deploy.yml..."
  cat > "$TMP_DIR/project/citus-pg-deploy.yml" <<'EOF'
---
- name: Install & configure PostgreSQL + Citus everywhere
  hosts: all
  become: true
  gather_facts: true
  vars:
    pg_version: 17
    citus_version: '13.0'
    postgres_password: "ChangeMe123"
    subnet_cidr: "10.0.0.0/24"
    repl_factor: 1

  tasks:
    - name: Ensure APT prerequisites
      apt:
        name:
          - apt-transport-https
          - ca-certificates
          - curl
          - gnupg
          - lsb-release
        state: present
        update_cache: yes

    - name: Add PostgreSQL APT key
      apt_key:
        url: https://www.postgresql.org/media/keys/ACCC4CF8.asc
        state: present

    - name: Add PostgreSQL PGDG repo
      apt_repository:
        repo: "deb http://apt.postgresql.org/pub/repos/apt {{ ansible_distribution_release }}-pgdg main"
        filename: pgdg
        state: present

    - name: Add Citus community repo via script
      shell: |
        DISTRO=jammy bash -c "$(curl -fsSL https://install.citusdata.com/community/deb.sh)"
      args:
        creates: /etc/apt/sources.list.d/citusdata_community.list

    - name: Workaround for Ubuntu 24.04 (noble → jammy)
      replace:
        path: /etc/apt/sources.list.d/citusdata_community.list
        regexp: '\bnoble\b'
        replace: jammy
      when: ansible_distribution_release == "noble"

    - name: Refresh APT cache (ensure Citus jammy lists are loaded)
      apt:
        update_cache: yes
        cache_valid_time: 0

    - name: Install PostgreSQL and Citus
      apt:
        name:
          - "postgresql-{{ pg_version }}"
          - "postgresql-{{ pg_version }}-citus-{{ citus_version }}"
        state: present

    - name: Ensure remote_tmp exists for postgres
      file:
        path: /var/lib/postgresql/.ansible/tmp
        state: directory
        owner: postgres
        group: postgres
        mode: '0700'

    - name: Set number of workers (all except coordinator)
      set_fact:
        num_workers: "{{ groups['all'] | length - 1 }}"

    - name: Patch postgresql.conf (listen_addresses, shared_preload_libraries, tuning)
      blockinfile:
        path: "/etc/postgresql/{{ pg_version }}/main/postgresql.conf"
        marker: "#--- citus-auto --- {mark}"
        block: |
          listen_addresses = '*'
          shared_preload_libraries = 'citus'
          max_connections = {{ ansible_facts.processor_vcpus | int * 100 }}
          shared_buffers  = {{ ((ansible_facts.memtotal_mb | int) * 50 // 100) | int }}MB
          citus.shard_count = {{ (ansible_facts.processor_vcpus | int) * (num_workers | int | default(1)) * 2 }}
          citus.shard_replication_factor = {{ repl_factor }}
      notify: restart postgresql

    - name: Allow cluster subnet access in pg_hba.conf
      lineinfile:
        path: "/etc/postgresql/{{ pg_version }}/main/pg_hba.conf"
        regexp: '^host\s+all\s+all\s+{{ subnet_cidr }}'
        line: "host all all {{ subnet_cidr }} md5"
        state: present
        create: yes
      notify: restart postgresql

    - name: Ensure master access on all workers (for future connections)
      lineinfile:
        path: "/etc/postgresql/{{ pg_version }}/main/pg_hba.conf"
        insertafter: '^#.*IPv4 local connections:'
        line: "host    all             all             0.0.0.0/0           md5"
        state: present
        create: yes
      notify: restart postgresql

    - name: Проверить, является ли эта нода участником кластера
      become_user: postgres
      shell: |
        psql -d postgres -tAc "SELECT 1 FROM pg_extension WHERE extname='citus';" | grep -q 1 && \
        psql -d postgres -tAc "SELECT 1 FROM pg_dist_node WHERE nodename = inet_server_addr()::text" | grep -q 1 && echo "worker" || \
        psql -d postgres -tAc "SELECT 1 FROM pg_extension WHERE extname='citus';" | grep -q 1 && echo "coordinator" || \
        echo "not_citus"
      register: citus_node_status
      changed_when: false
      failed_when: false

    - name: Установить пароль для postgres (Только если НЕ воркер и НЕ координатор)
      become_user: postgres
      command: >
        psql -d postgres -c "ALTER USER postgres PASSWORD '{{ postgres_password }}';"
      when: citus_node_status.stdout.strip() == 'not_citus'
      register: pass_out
      changed_when: "'ALTER ROLE' in pass_out.stdout"
      failed_when: pass_out.rc != 0 and ('ALTER ROLE' not in pass_out.stdout)
      no_log: true

  handlers:
    - name: restart postgresql
      service:
        name: "postgresql@{{ pg_version }}-main"
        state: restarted

# --- ВТОРОЙ PLAY: настройка кластера Citus ---

- name: STEP 2 — Citus cluster auto-setup (master registration, workers registration)
  hosts: all
  become: true
  gather_facts: true

  vars:
    pg_version: 17
    postgres_port: 5432
    postgres_password: "ChangeMe123"

  tasks:
    - name: Find coordinator (master)
      set_fact:
        coordinator_host: "{{ groups['master'][0] if 'master' in groups and groups['master']|length > 0 else groups['all'][0] }}"

    - name: Set flag if current host is coordinator
      set_fact:
        is_coordinator: "{{ inventory_hostname == coordinator_host }}"

    - name: Ensure Citus extension is present on ALL nodes
      become_user: postgres
      command: psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS citus;"

    - name: Build list of worker IPs (excluding coordinator)
      set_fact:
        worker_ips: >-
          {{
            groups['all']
            | difference([coordinator_host])
            | map('extract', hostvars)
            | map(attribute='ansible_host')
            | list
          }}
      when: is_coordinator

    - name: Create .pgpass for postgres user (coordinator)
      become_user: postgres
      copy:
        dest: "/var/lib/postgresql/.pgpass"
        content: |
          {% for ip in worker_ips %}
          {{ ip }}:{{ postgres_port }}:postgres:postgres:{{ postgres_password }}
          {% endfor %}
        owner: postgres
        group: postgres
        mode: '0600'
      when: is_coordinator

    - name: Get current active workers from Citus (coordinator)
      become_user: postgres
      command: >
        psql -At -d postgres -c "SELECT node_name || ':' || node_port FROM master_get_active_worker_nodes();"
      register: current_workers
      when: is_coordinator

    - name: Build list of current worker addresses (coordinator)
      set_fact:
        current_worker_addresses: "{{ current_workers.stdout_lines }}"
      when: is_coordinator

    - name: Register new worker nodes (coordinator, idempotent)
      become_user: postgres
      command: >
        psql -d postgres -c "SELECT master_add_node('{{ item }}', {{ postgres_port }});"
      loop: "{{ worker_ips }}"
      loop_control:
        label: "{{ item }}"
      when: is_coordinator and (item ~ ':' ~ postgres_port) not in current_worker_addresses
      register: citus_node_reg

    - name: Show all connected worker IPs (coordinator)
      debug:
        msg: "Connected workers: {{ (current_worker_addresses | default([])) | map('split', ':') | map('first') | list | unique | join(', ') }}"
      when: is_coordinator

EOF



  echo "📁 Создаём playbook create-db.yml..."
  cat > "$TMP_DIR/project/create-db.yml" <<'EOF'
---
- name: Создание новой базы данных и пользователя PostgreSQL
  hosts: master
  become: true
  vars:
    db_name: "{{ db_name | mandatory }}"
    db_user: "{{ db_user | mandatory }}"
    db_password: "{{ db_password | mandatory }}"
    db_name_full: "{{ db_name }}_db"
  tasks:
    - name: Проверка, существует ли база
      become_user: postgres
      postgresql_query:
        query: "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname='{{ db_name_full }}');"
      register: db_exists

    - name: Прервать, если база уже существует
      fail:
        msg: "База данных '{{ db_name_full }}' уже существует!"
      when: db_exists.query_result[0].exists

    - name: Проверка, существует ли пользователь
      become_user: postgres
      postgresql_query:
        query: "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='{{ db_user }}');"
      register: user_exists

    - name: Прервать, если пользователь уже существует
      fail:
        msg: "Пользователь '{{ db_user }}' уже существует!"
      when: user_exists.query_result[0].exists

    - name: Создание PostgreSQL пользователя
      become_user: postgres
      postgresql_user:
        name: "{{ db_user }}"
        password: "{{ db_password }}"
        role_attr_flags: LOGIN

    - name: Создание базы данных
      become_user: postgres
      postgresql_db:
        name: "{{ db_name_full }}"
        owner: "{{ db_user }}"
        encoding: "UTF8"
        lc_collate: "C"
        lc_ctype: "C"
        template: "template0"

    - name: Подключение расширения citus
      become_user: postgres
      postgresql_ext:
        name: citus
        db: "{{ db_name_full }}"
EOF

  echo "📁 Создаём playbook delete-db.yml..."
  cat > "$TMP_DIR/project/delete-db.yml" <<'EOF'
---
- name: Удаление базы данных и пользователя PostgreSQL
  hosts: master
  become: true
  vars:
    db_name: "{{ db_name | mandatory }}"
    db_user: "{{ db_user | mandatory }}"
    db_name_full: "{{ db_name }}_db"
  tasks:
    - name: Проверка, существует ли база
      become_user: postgres
      postgresql_query:
        query: "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname='{{ db_name_full }}');"
      register: db_exists
      ignore_errors: true

    - name: Удаление базы, если существует
      become_user: postgres
      postgresql_db:
        name: "{{ db_name_full }}"
        state: absent
      when: db_exists.query_result[0].exists | default(false)

    - name: Проверка, существует ли пользователь
      become_user: postgres
      postgresql_query:
        query: "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='{{ db_user }}');"
      register: user_exists
      ignore_errors: true

    - name: Удаление пользователя, если существует
      become_user: postgres
      postgresql_user:
        name: "{{ db_user }}"
        state: absent
      when: user_exists.query_result[0].exists | default(false)
EOF

  echo "📤 Копируем проект в pod AWX..."
  kubectl exec -n "$AWX_NAMESPACE" "$pod_name" -- mkdir -p /var/lib/awx/projects/citus-cluster
  kubectl cp "$TMP_DIR/project/." "$AWX_NAMESPACE/$pod_name:/var/lib/awx/projects/citus-cluster"

  rm -rf "$TMP_DIR"
  echo "✅ Проект успешно обновлён и загружен в AWX. Готово к запуску templates!"
}




# ---------------------------------------------------

function install_awx() {
  echo -e "\n🚀 Установка AWX Operator и AWX..."
  read -rp "Введите домен для AWX (например ansible.stroy-track.ru): " domain
  read -rp "Логин администратора [admin]: " admin_user
  admin_user=${admin_user:-admin}
  read -rp "Введите NodePort [30080]: " node_port
  node_port=${node_port:-30080}

  NODE_PORT="$node_port" # переопределяем глобальную переменную

  ensure_namespace
  ensure_helm_repo
  ensure_local_path_provisioner
  helm upgrade --install "$HELM_RELEASE" "$HELM_REPO_NAME/awx-operator" -n "$AWX_NAMESPACE"

  admin_pass=$(openssl rand -base64 16)
  kubectl create secret generic "$SECRET_NAME" \
    --from-literal=password="$admin_pass" -n "$AWX_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  cat > "$AWX_CR_FILE" <<EOF
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
  namespace: $AWX_NAMESPACE
spec:
  service_type: NodePort
  ingress_type: none
  hostname: $domain
  replicas: 1
  admin_user: $admin_user
  admin_password_secret: $SECRET_NAME
  projects_persistence: true
  projects_storage_size: 1Gi
  projects_storage_class: local-path
  projects_storage_access_mode: ReadWriteOnce
EOF

  echo "🔧 Применяем CR..."
  kubectl apply -f "$AWX_CR_FILE"

  echo "⏳ Ожидание появления awx-service..."
  for i in {1..60}; do
    if kubectl get svc awx-service -n "$AWX_NAMESPACE" &>/dev/null; then
      echo "✅ Сервис найден. Патчим порт $NODE_PORT..."
      kubectl patch svc awx-service -n "$AWX_NAMESPACE" --type='json' -p \
        "[{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${NODE_PORT}}]"
      break
    fi
    echo -n "."; sleep 5
  done

  if ! kubectl get svc awx-service -n "$AWX_NAMESPACE" &>/dev/null; then
    echo -e "\n⚠️  Сервис awx-service не появился. Порт не пропатчен."
  fi

  wait_for_pods
  add_demo_playbook

  echo -e "\n✅ AWX установлен!"
  echo "🌐 URL: http://${domain}:${NODE_PORT}"
  echo "👤 Логин: $admin_user"
  echo "🔑 Пароль: $admin_pass"
}

function get_bootstrap_password() {
  echo -e "\n🔑 Bootstrap-пароль:"
  kubectl get secret "$SECRET_NAME" -n "$AWX_NAMESPACE" -o jsonpath="{.data.password}" | base64 -d
  echo
}

function check_status() {
  echo -e "\n🔍 Статус в namespace $AWX_NAMESPACE:"
  kubectl get pods,svc -n "$AWX_NAMESPACE" || true
}

function uninstall_awx() {
  echo -e "\n🧹 Удаление AWX и Operator..."
  kubectl delete -f "$AWX_CR_FILE" --ignore-not-found
  kubectl delete secret "$SECRET_NAME" -n "$AWX_NAMESPACE" --ignore-not-found
  kubectl delete pvc --all -n "$AWX_NAMESPACE" --ignore-not-found
  helm uninstall "$HELM_RELEASE" -n "$AWX_NAMESPACE" --timeout 2m || true
  kubectl delete namespace "$AWX_NAMESPACE" --ignore-not-found
  echo "✅ Удалено."
}

function install_vault_collection() {
  echo -e "\n📦 Установка коллекции community.hashi_vault..."
  if ! command -v ansible-galaxy &>/dev/null; then
    echo "⚠️ ansible-galaxy не найден. Установите Ansible."
    return 1
  fi
  ansible-galaxy collection install community.hashi_vault
  echo -e "\n📦 Проверка:"
  ansible-galaxy collection list | grep -q community.hashi_vault && \
    echo "✅ Коллекция установлена." || echo "❌ Не удалось установить коллекцию."
}

function connect_to_awx() {
  kubectl exec -n "$AWX_NAMESPACE" awx-task -- /bin/bash
  # kubectl exec -n awx -it awx-task-65644cc448-bsm6w -- bash
  # cd /var/lib/awx/projects
  # ls -l
}

# ===== Меню =====
while true; do
  clear
  echo "==============================="
  echo "      🛠️  AWX Manager"
  echo "==============================="
  echo "1) 🚀 Установить AWX"
  echo "2) 🔍 Проверить статус"
  echo "3) 🔑 Получить bootstrap-пароль"
  echo "4) 🧹 Удалить AWX и Operator"
  echo "5) 📦 Установить Vault Collection"
  echo "6) 🐘 Инициализировать Ceph (создать playbook)"
  echo "7) 🐘 Инициализировать Citus+PostgreSQL (создать playbook)"
  echo "0) ❌ Выход"
  echo "==============================="
  read -rp "Выберите действие [0-7]: " choice
  case "$choice" in
    1) check_deps; check_resources; install_awx ;;
    2) check_status ;;
    3) get_bootstrap_password ;;
    4) uninstall_awx ;;
    5) install_vault_collection ;;
    6) add_ceph_playbook ;;
    7) add_citus_pg_playbook ;;
    0) echo "👋 До встречи!"; exit 0 ;;
    *) echo "❌ Неверный выбор."; sleep 1 ;;
  esac
  echo -e "\nНажмите Enter для продолжения..."
  read -r
done