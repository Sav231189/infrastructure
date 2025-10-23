**Установи Docker и Docker Compose (v2 если не установлено)**
```bash
### 1 — Установить Docker Engine + Buildx + Compose v2
sudo apt-get update -qq
# установить / обновить движок и плагины
sudo apt-get install -y -qq \
  docker.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

**Загрузка и распаковка Harbor (+systemctl daemon-reload)**
```bash
set -euo pipefail

# ░░ Параметры ░░
DOMAIN=harbor.stroy-track.ru
ADMIN_PASS=JfdsEewwR
PORT=8081
HARBOR_DIR=/opt/harbor
HARBOR_VERSION=v2.13.0
# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

echo "▶ Скачиваю Harbor ${HARBOR_VERSION}…"
cd /tmp
wget -q https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-online-installer-${HARBOR_VERSION}.tgz
tar -xzf harbor-online-installer-${HARBOR_VERSION}.tgz
mv harbor "${HARBOR_DIR}"
cd "${HARBOR_DIR}"

echo "▶ Готовлю harbor.yml…"
cp harbor.yml.tmpl harbor.yml
sed -i "                              
  s/^hostname:.*/hostname: ${DOMAIN}/
  s/^harbor_admin_password:.*/harbor_admin_password: ${ADMIN_PASS}/
  /^http:/,/^[^[:space:]]/  s/^[[:space:]]*port:.*/  port: ${PORT}/
  /^https:/,/^[^[:space:]]/d
" harbor.yml

cat >> harbor.yml <<'EOF'
log:
  level: info
  local:
    rotate_count: 50
    rotate_size: 200M
EOF

echo "▶ Генерирую docker‑compose.yml и поднимаю стек…"
./prepare
sudo ./install.sh

# Auto restart
echo "▶ Создаю unit‑файл и включаю автозапуск…"
tee /etc/systemd/system/harbor.service >/dev/null <<EOF
[Unit]
Description=Harbor Registry
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${HARBOR_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now harbor

# Проверка Harbor
check_harbor() {
  echo -n "⏳ Жду, пока Harbor станет healthy"
  for i in {1..60}; do
    if curl -sSf http://localhost:${PORT}/api/v2.0/health |
         grep -q '"status":"healthy"'; then
      echo -e "\n✅ Harbor готов: https://${DOMAIN}  (admin / ${ADMIN_PASS})"
      return          # ← выходит из функции, а не из всей оболочки
    fi
    echo -n "."; sleep 2
  done
  echo -e "\n❌ Не дождался health за 120 с. Проверьте журналы:"
  journalctl -u harbor --no-pager -n 50
}

check_harbor           # вызываем функцию
```

**Удаление Harbor**
```bash
set -euo pipefail

UNIT=/etc/systemd/system/harbor.service
HARBOR_DIR=/opt/harbor        # где лежит docker-compose.yml

echo "▶ Останавливаю Harbor (если запущен)…"
systemctl disable --now harbor 2>/dev/null || true

echo "▶ Отключаю и удаляю контейнеры/тома/сети…"
if [[ -f "${HARBOR_DIR}/docker-compose.yml" ]]; then
  docker compose -f "${HARBOR_DIR}/docker-compose.yml" down -v --remove-orphans
fi

# прибьём всё, что осталось с label goharbor
docker rm -f $(docker ps -aq --filter "ancestor=goharbor/*") 2>/dev/null || true
docker rmi -f $(docker images "goharbor/*" -q)               2>/dev/null || true
docker volume rm $(docker volume ls -q | grep harbor || true) 2>/dev/null || true
docker network rm $(docker network ls -q | grep harbor || true) 2>/dev/null || true

echo "▶ Удаляю каталог Harbor и файл юнита…"
rm -rf "${HARBOR_DIR}"
rm -f  "${UNIT}"
systemctl daemon-reload

echo "✅ Harbor полностью удалён"
```