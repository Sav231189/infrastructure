# Сетевая безопасность

## Обзор

Многоуровневая защита сети:

1. **Firewall на уровне VPS** (ufw/iptables)
2. **Kubernetes NetworkPolicy** (микросегментация)
3. **Приватная сеть между кластерами**
4. **Public API через TLS**

## 1. Firewall на VPS (ufw)

### Базовая конфигурация

```bash
# Установка на всех нодах через AWX
sudo apt install ufw

# Default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH (только из офиса или VPN)
sudo ufw allow from 203.0.113.0/24 to any port 22 comment 'Office IP'

# Kubernetes API (только для админов)
sudo ufw allow from 203.0.113.0/24 to any port 6443 comment 'K8s API from office'

# NodePort range (для внутренней сети)
sudo ufw allow from 10.0.0.0/8 to any port 30000:32767 comment 'NodePorts internal'

# Приватная сеть между кластерами
sudo ufw allow from 10.0.0.0/8 comment 'Inter-cluster communication'

# HTTP/HTTPS только на control nodes (для Nginx Proxy Manager)
sudo ufw allow 80/tcp comment 'HTTP public'
sudo ufw allow 443/tcp comment 'HTTPS public'

# Включить firewall
sudo ufw enable
```

### Rate Limiting для SSH

```bash
# Защита от brute-force
sudo ufw limit 22/tcp comment 'SSH rate limit'

# Это ограничит подключения до 6 попыток за 30 секунд
```

### Geo-blocking (опционально)

```bash
# Заблокировать весь мир, кроме России и СНГ
# Используя ipset и списки IP по странам

# Скрипт обновления списков (запускать через cron)
curl https://www.ipdeny.com/ipblocks/data/countries/ru.zone -o /etc/ufw/ru.zone

# Создать ipset
sudo ipset create allowed-countries hash:net

# Загрузить IP России
while read ip; do
  sudo ipset add allowed-countries $ip
done < /etc/ufw/ru.zone

# Правило ufw
sudo ufw insert 1 deny from any to any
sudo ufw insert 1 allow from allowed-countries to any
```

## 2. Kubernetes NetworkPolicy

### Default Deny All

```yaml
# Применить ко всем namespaces
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: apps
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### Микросегментация по namespace

#### Apps namespace

```yaml
# apps/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: apps-network-policy
  namespace: apps
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress

  ingress:
    # Разрешить ingress controller
    - from:
        - namespaceSelector:
            matchLabels:
              name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080

  egress:
    # Разрешить DNS
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53

    # Разрешить доступ к Data кластеру (Citus, Kafka)
    - to:
        - namespaceSelector:
            matchLabels:
              cluster: data
      ports:
        - protocol: TCP
          port: 5432 # Citus
        - protocol: TCP
          port: 9092 # Kafka

    # Разрешить доступ к Storage кластеру (MinIO)
    - to:
        - namespaceSelector:
            matchLabels:
              cluster: storage
      ports:
        - protocol: TCP
          port: 9000 # MinIO S3

    # Разрешить HTTPS для внешних API
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 443
```

#### Gateway микросервис

```yaml
# apps/gateway-network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: gateway-policy
  namespace: apps
spec:
  podSelector:
    matchLabels:
      app: gateway

  policyTypes:
    - Ingress
    - Egress

  ingress:
    # Принимать запросы от ingress
    - from:
        - namespaceSelector:
            matchLabels:
              name: ingress-nginx
      ports:
        - protocol: TCP
          port: 3000

  egress:
    # Может обращаться ко всем микросервисам
    - to:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 3000

    # Может обращаться к Citus
    - to:
        - namespaceSelector:
            matchLabels:
              cluster: data
        - podSelector:
            matchLabels:
              app: citus
      ports:
        - protocol: TCP
          port: 5432
```

#### Auth микросервис

```yaml
# apps/auth-network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: auth-policy
  namespace: apps
spec:
  podSelector:
    matchLabels:
      app: auth

  policyTypes:
    - Ingress
    - Egress

  ingress:
    # Принимать запросы только от gateway
    - from:
        - podSelector:
            matchLabels:
              app: gateway
      ports:
        - protocol: TCP
          port: 3001

  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53

    # Только к Citus
    - to:
        - namespaceSelector:
            matchLabels:
              cluster: data
      ports:
        - protocol: TCP
          port: 5432

    # Доступ к Vault за секретами
    - to:
        - namespaceSelector:
            matchLabels:
              name: control
        - podSelector:
            matchLabels:
              app: vault
      ports:
        - protocol: TCP
          port: 8200
```

### Data namespace (Citus, Kafka)

```yaml
# data/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: data-network-policy
  namespace: data
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress

  ingress:
    # Разрешить подключения только от Apps кластеров (Stage/Prod)
    - from:
        - namespaceSelector:
            matchLabels:
              cluster: apps
      ports:
        - protocol: TCP
          port: 5432 # Citus
        - protocol: TCP
          port: 9092 # Kafka

    # Разрешить подключения между узлами Citus/Kafka
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 5432
        - protocol: TCP
          port: 9092
        - protocol: TCP
          port: 2181 # Zookeeper

  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53

    # Между узлами в namespace
    - to:
        - podSelector: {}

    # К Longhorn для PVC
    - to:
        - namespaceSelector:
            matchLabels:
              name: longhorn-system
      ports:
        - protocol: TCP
          port: 9500

    # К Vault за секретами
    - to:
        - namespaceSelector:
            matchLabels:
              cluster: control
        - podSelector:
            matchLabels:
              app: vault
      ports:
        - protocol: TCP
          port: 8200
```

## 3. Приватная сеть между кластерами

### Настройка через WireGuard

```bash
# На каждой ноде каждого кластера

# Установка WireGuard
sudo apt install wireguard

# Генерация ключей
wg genkey | tee privatekey | wg pubkey > publickey

# Конфигурация /etc/wireguard/wg0.conf
[Interface]
Address = 10.10.0.1/24  # Уникальный IP для каждой ноды
PrivateKey = <privatekey>
ListenPort = 51820

[Peer]
# Для каждой ноды в других кластерах
PublicKey = <peer-publickey>
AllowedIPs = 10.10.0.2/32
Endpoint = peer-public-ip:51820

# Запуск
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
```

### Проверка связности

```bash
# Ping другого кластера через приватную сеть
ping 10.10.0.2

# Проверка маршрутов
ip route show

# Проверка подключений WireGuard
sudo wg show
```

## 4. TLS/SSL для Public API

### Cert-Manager для автоматических сертификатов

```yaml
# Install cert-manager в Control кластере
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Создать ClusterIssuer для Let's Encrypt
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@stroy-track.ru
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
```

### Ingress с TLS

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: stroy-track-ingress
  namespace: apps
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - stroy-track.ru
        - www.stroy-track.ru
      secretName: stroy-track-tls

  rules:
    - host: stroy-track.ru
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gateway
                port:
                  number: 3000
```

### Mutual TLS (mTLS) между кластерами

```yaml
# Для критичных межкластерных коммуникаций
apiVersion: v1
kind: Secret
metadata:
  name: cluster-mtls-cert
  namespace: apps
type: kubernetes.io/tls
data:
  tls.crt: <base64-cert>
  tls.key: <base64-key>
  ca.crt: <base64-ca>

---
# В deployment использовать сертификаты
volumeMounts:
  - name: mtls-certs
    mountPath: /etc/ssl/cluster
    readOnly: true
```

## Мониторинг сетевой безопасности

### Falco для runtime security

```yaml
# Установка Falco через Helm
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco-system --create-namespace

# Правила для StoryTrack
# /etc/falco/rules.d/stroy-track.yaml
- rule: Unauthorized Network Connection from Apps
  desc: Detect network connections to unauthorized destinations from apps namespace
  condition: >
    outbound and
    k8s.ns.name = "apps" and
    not fd.sip in (10.0.0.0/8) and
    not fd.sport in (443, 80)
  output: >
    Unauthorized outbound connection from apps
    (pod=%k8s.pod.name dest=%fd.name:%fd.sport)
  priority: WARNING
```

### Prometheus alerts

```yaml
- alert: UnauthorizedNetworkAccess
  expr: increase(falco_events{rule="Unauthorized Network Connection"}[5m]) > 0
  for: 1m

- alert: SSHBruteForce
  expr: rate(node_network_receive_packets{device="eth0",port="22"}[5m]) > 100
  for: 2m

- alert: WireGuardDown
  expr: wireguard_latest_handshake_seconds > 300
  for: 5m
```

## Аудит сетевых подключений

```bash
# Логирование через iptables
sudo iptables -A INPUT -j LOG --log-prefix "UFW-INPUT: "
sudo iptables -A OUTPUT -j LOG --log-prefix "UFW-OUTPUT: "

# Логи в /var/log/syslog
tail -f /var/log/syslog | grep UFW

# Анализ логов через ELK/Loki
```

## Checklist

- [ ] ufw настроен на всех нодах (default deny)
- [ ] SSH доступен только с офисных IP
- [ ] Rate limiting для SSH
- [ ] NetworkPolicy: default deny all
- [ ] NetworkPolicy для каждого микросервиса
- [ ] WireGuard настроен между кластерами
- [ ] TLS сертификаты через cert-manager
- [ ] Все публичные домены используют HTTPS
- [ ] Falco установлен и настроен
- [ ] Мониторинг сетевых подключений
- [ ] Регулярный аудит правил firewall
