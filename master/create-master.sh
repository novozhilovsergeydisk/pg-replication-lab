#!/usr/bin/env bash
# ============================================================================
#  Создать УЧЕБНЫЙ кластер-мастер (primary) для практикума по репликации.
#  Запускать НА СЕРВЕРЕ-МАСТЕРЕ (источник) под root/sudo.
#  Идемпотентно: при повторном запуске пересоздаёт учебный кластер с нуля.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source ./lib.sh
load_config
require_root_or_sudo
require_debian_pg
guard_training_cluster

log "Пересоздаю учебный кластер-мастер ${PG_VERSION}/${CLUSTER_NAME} на порту ${PG_PORT}…"

# 1) Чистый старт: снести прошлый учебный кластер, если был.
if cluster_exists; then
  warn "Учебный кластер уже существует — удаляю ради чистого старта."
  pg_dropcluster --stop "${PG_VERSION}" "${CLUSTER_NAME}"
fi

# 2) Создать новый кластер (с контрольными суммами страниц данных).
pg_createcluster "${PG_VERSION}" "${CLUSTER_NAME}" --port "${PG_PORT}" -- --data-checksums

# 3) Самоподписанный TLS-сертификат (CN и SAN = адрес мастера).
log "Генерирую самоподписанный TLS-сертификат (CN=${MASTER_HOST})…"
openssl req -new -x509 -days 365 -nodes -text \
  -subj "/CN=${MASTER_HOST}" \
  -addext "subjectAltName=IP:${MASTER_HOST}" \
  -out "${DATADIR}/server.crt" \
  -keyout "${DATADIR}/server.key"
chown postgres:postgres "${DATADIR}/server.crt" "${DATADIR}/server.key"
chmod 600 "${DATADIR}/server.key"
chmod 644 "${DATADIR}/server.crt"

# 4) Параметры репликации — отдельным файлом в conf.d, чтобы не править основной конфиг.
log "Пишу параметры репликации в conf.d…"
install -d -o postgres -g postgres "${CONFDIR}/conf.d"
# Debian обычно уже подключает conf.d; на всякий случай гарантируем include.
grep -q "include_dir = 'conf.d'" "${CONFDIR}/postgresql.conf" \
  || echo "include_dir = 'conf.d'" >> "${CONFDIR}/postgresql.conf"

cat > "${CONFDIR}/conf.d/10-replication.conf" <<EOF
# --- учебная потоковая репликация (создано create-master.sh) ---
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = '512MB'
max_slot_wal_keep_size = '2GB'   # предохранитель: ограничить рост WAL от «забытого» слота
wal_log_hints = on               # понадобится для pg_rewind при учебном failover
password_encryption = scram-sha-256
hot_standby = on
# TLS
ssl = on
ssl_cert_file = '${DATADIR}/server.crt'
ssl_key_file  = '${DATADIR}/server.key'
EOF
chown postgres:postgres "${CONFDIR}/conf.d/10-replication.conf"

# 5) Разрешить подключение реплики по TLS, только с её адреса:
#    - replication — для самого стриминга;
#    - postgres    — нужно для pg_rewind, если позже будете делать failback на этот узел.
log "Добавляю правила в pg_hba.conf…"
HBA="${CONFDIR}/pg_hba.conf"
add_hba() { grep -qF "$1" "$HBA" || printf '%s\n' "$1" >> "$HBA"; }
grep -q "# учебная репликация (create-master.sh)" "$HBA" \
  || printf '\n# учебная репликация (create-master.sh)\n' >> "$HBA"
add_hba "hostssl replication ${REPL_USER} ${REPLICA_HOST}/32 scram-sha-256"
add_hba "hostssl postgres     ${REPL_USER} ${REPLICA_HOST}/32 scram-sha-256"

# 6) Запустить кластер.
pg_ctlcluster "${PG_VERSION}" "${CLUSTER_NAME}" start

# 7) Пароль роли репликации. Не печатаем и не сохраняем в репозитории.
if [ -z "${REPL_PASSWORD:-}" ]; then
  read -rsp "Задайте пароль для роли '${REPL_USER}': " REPL_PASSWORD; echo
fi
[ -n "$REPL_PASSWORD" ] || die "Пустой пароль недопустим."

# 8) Создать/обновить роль (пароль квотируется psql-переменной :'pw', без инъекций).
log "Создаю роль ${REPL_USER}…"
if [ "$(psql_t -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REPL_USER}'")" = "1" ]; then
  psql_t -d postgres -v pw="$REPL_PASSWORD" \
    -c "ALTER ROLE \"${REPL_USER}\" WITH REPLICATION LOGIN PASSWORD :'pw'"
else
  psql_t -d postgres -v pw="$REPL_PASSWORD" \
    -c "CREATE ROLE \"${REPL_USER}\" WITH REPLICATION LOGIN PASSWORD :'pw'"
fi

# 9) Создать физический слот репликации (если ещё нет) — он удержит нужный WAL для реплики.
log "Создаю физический слот ${REPL_SLOT}…"
psql_t -d postgres -tAc \
  "SELECT pg_create_physical_replication_slot('${REPL_SLOT}') \
   WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='${REPL_SLOT}')" >/dev/null

# 9.5) Права для pg_rewind (учебный failback): не-суперпользователю нужны эти функции.
#      Гранты реплицируются на standby, поэтому будут и на будущем новом primary.
log "Выдаю роли ${REPL_USER} права для pg_rewind…"
psql_t -d postgres <<SQL
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean)             TO "${REPL_USER}";
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean)                    TO "${REPL_USER}";
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text)                      TO "${REPL_USER}";
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO "${REPL_USER}";
SQL

# 10) Немного тестовых данных, чтобы было что реплицировать и проверять.
log "Заливаю тестовую таблицу repl_demo…"
psql_t -d postgres <<'SQL'
CREATE TABLE IF NOT EXISTS repl_demo(
  id   bigserial PRIMARY KEY,
  ts   timestamptz DEFAULT now(),
  note text
);
INSERT INTO repl_demo(note) SELECT 'row '||g FROM generate_series(1,1000) g;
SQL

ok "Мастер готов. Слот: ${REPL_SLOT}. Роль: ${REPL_USER}."
echo
echo "  Дальше:"
echo "   1) Откройте порт ${PG_PORT} только для реплики (см. README, раздел про firewall):"
echo "        ufw allow from ${REPLICA_HOST} to any port ${PG_PORT} proto tcp"
echo "   2) Скопируйте сертификат на реплику (для SSLMODE=${SSLMODE}):"
echo "        scp ${DATADIR}/server.crt <реплика>:${ROOTCERT:-/tmp/master-server.crt}"
echo "   3) На реплике запустите:  sudo ./replica/create-replica.sh"
