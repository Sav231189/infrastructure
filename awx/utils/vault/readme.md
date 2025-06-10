# 🔐 Vault - безопасное хранилище секретов

## Интегрировать
- 📦 ./install.sh -> Установить Vault Collection

## Настроить Vault (в UI Vault)
✅ Всё через Web-интерфейс:

1. Включить AppRole
→ Access → Enable new method → AppRole.

2. Создать политику awx-policy:
→ Policies → Create Policy → awx-policy.
```h
path "secret/data/ansible/*" {
  capabilities = ["read"]
}
```

3. Создать роль AppRole awx-role:
Политика: awx-policy
Token TTL: 1h
Max TTL: 4h

4. Скопировать:
RoleID
Сгенерировать новый SecretID

## Настроить AWX (в Web UI)
✅ Всё через Web-интерфейс:

1. Создать новый Credential Type
→ Settings → Credential Types → Add

Настройка:
Name: Vault AppRole
Injectors: передавать переменные через Environment Variables.
Inputs:
```json
{
  "fields": [
    {"id": "VAULT_ADDR", "label": "Vault Address", "type": "string"},
    {"id": "VAULT_ROLE_ID", "label": "Vault Role ID", "type": "string"},
    {"id": "VAULT_SECRET_ID", "label": "Vault Secret ID", "type": "string"}
  ],
  "required": ["VAULT_ADDR", "VAULT_ROLE_ID", "VAULT_SECRET_ID"]
}
```

2. Создать Credential на основе Vault AppRole
Тип: Vault AppRole
Поля заполнить:
VAULT_ADDR: https://vault.stroy-track.ru
VAULT_ROLE_ID: (то что получили в Vault)
VAULT_SECRET_ID: (то что получили в Vault)

## 5. Использовать Vault в playbook'ах
🔥 ВАЖНО: Без блока vault_read в playbook данные из Vault НЕ подставятся автоматически!
Выберите любой удобный способ:
  - через Job Template в UI:
      Добавьте созданный Credential в секцию Credentials вашего Job Template — при запуске переменные автоматически попадут в окружение контейнера.
      VAULT_ADDR: https://vault.stroy-track.ru
      VAULT_ROLE_ID: (то что получили в Vault)
      VAULT_SECRET_ID: (то что получили в Vault)
      прочесть через "{{ lookup('env','VAULT_ADDR') }}"
  - через поле Extra Variables в UI:
      VAULT_ADDR: https://vault.stroy-track.ru
      VAULT_ROLE_ID: (то что получили в Vault)
      VAULT_SECRET_ID: (то что получили в Vault)
      прочесть через "{{ VAULT_ADDR }}"
  - через CLI --extra-vars при запуске ansible-playbook:
      ansible-playbook playbook.yml \
      --extra-vars "VAULT_ADDR=https://vault.stroy-track.ru" \
      --extra-vars "VAULT_ROLE_ID=(то что получили в Vault)" \
      --extra-vars "VAULT_SECRET_ID=(то что получили в Vault)" 
      прочесть через "{{ VAULT_ADDR }}"
```yaml
- name: Получить секрет из Vault
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Чтение секрета
      community.hashi_vault.vault_read:
        url: "{{ lookup('env','VAULT_ADDR') }}"
        role_id: "{{ lookup('env','VAULT_ROLE_ID') }}"
        secret_id: "{{ lookup('env','VAULT_SECRET_ID') }}"
        # url: "{{ VAULT_ADDR }}"
        # role_id: "{{ VAULT_ROLE_ID }}"
        # secret_id: "{{ VAULT_SECRET_ID }}"
        secret: "secret/data/ansible/db"
      register: vault_secret

    - name: Показать секрет
      debug:
        msg: "{{ vault_secret.data.data }}"
```

