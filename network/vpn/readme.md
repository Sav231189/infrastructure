# WireGuard VPN Configuration (/etc/wireguard/wg-home.conf)

[Interface]
Address = <HOST_VPN_ADDRESS> # 10.9.0.1/24
ListenPort = <HOST_LISTEN_PORT> # 51821
PrivateKey = <HOST_PRIVATE_KEY> # wg genkey (/etc/wireguard/wg-home.key)

[Peer]
PublicKey = <PEER_PUBLIC_KEY> # wg pubkey (/etc/wireguard/wg-home.pub)
AllowedIPs = <PEER_ALLOWED_VPN_SUBNET> # 10.9.0.2/32, 10.10.10.0/24
PersistentKeepalive = <HOST_PERSISTENT_KEEPALIVE> # 25

wg-quick up <HOST_VPN_INTERFACE> # wg-home
systemctl enable --now wg-quick@<HOST_VPN_INTERFACE> # wg-quick@wg-home

# Форвардинг + правила (интерфейс наружу — <HOST_NETWORK_INTERFACE> - например ens3)

# Получить интерфейс наружу

HOST_NETWORK_INTERFACE=$(ip route show default | awk '/default/ {print $5}')

# Включить forwarding

sysctl -w net.ipv4.ip_forward=1

# Разрешаем форвард “из WG в интернет”

# Цепь FORWARD — трафик, который пролетает через хост (маршрутизируется между интерфейсами).

# Не путать с INPUT (в хост) и OUTPUT (из хоста).

# -i wg-home -o ens3 — пакеты пришли из туннеля и улетают наружу через интерфейс ens3.

# -j ACCEPT — разрешаем.

# Это позволяет узлам из подсетей WG wg-home выходить в интернет через VPS.

iptables -C FORWARD -i <HOST_VPN_INTERFACE> -o <HOST_NETWORK_INTERFACE> -j ACCEPT || iptables -I FORWARD -i <HOST_VPN_INTERFACE> -o <HOST_NETWORK_INTERFACE> -j ACCEPT

# Разрешаем обратный трафик только как ответ

# Направление наоборот: из интернета → в WG.

# -m conntrack --ctstate RELATED,ESTABLISHED — пропускаем только ответы к соединениям,

# которые уже инициированы «изнутри».

# Это stateful-фильтрация: не открывает произвольный вход снаружи в туннель,

# но позволяет вернуться ответам (TCP ACK/UDP ответы, ICMP ошибки и т.п.).

iptables -C FORWARD -i <HOST_NETWORK_INTERFACE> -o <HOST_VPN_INTERFACE> -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT \
 || iptables -I FORWARD -i <HOST_NETWORK_INTERFACE> -o <HOST_VPN_INTERFACE> -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# NAT (маскарадинг) наружу

# Таблица nat, цепь POSTROUTING — преобразование адресов перед выходом в <HOST_NETWORK_INTERFACE>.

# MASQUERADE — подменяем исходный адрес (<HOST_VPN_ADDRESS>/<PEER_ALLOWED_VPN_SUBNET>) на публичный адрес <HOST_NETWORK_INTERFACE>.

# Нужен, потому что провайдер не знает маршрутов к вашим приватным подсетям и

# возвращать пакеты на них не сможет без NAT.

iptables -t nat -C POSTROUTING -o <HOST_NETWORK_INTERFACE> -j MASQUERADE || iptables -t nat -A POSTROUTING -o <HOST_NETWORK_INTERFACE> -j MASQUERADE

# Инициировать рукопожатие от PVE

ping -I <HOST_VPN_INTERFACE> -c3 <HOST_VPN_ADDRESS> # ping -I wg-home -c3 10.9.0.1

# на сервере VPN (проверка соединения)

tcpdump -ni <HOST_NETWORK_INTERFACE> udp port <HOST_LISTEN_PORT> -c 10 # tcpdump -ni ens3 udp port 51821 -c 10
