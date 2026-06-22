#!/usr/bin/env bash
# ============================================================================
#  Вернуть СТАРЫЙ МАСТЕР в строй как новую РЕПЛИКУ нового primary через pg_rewind
#  (без полного pg_basebackup — синхронизируется только разошедшаяся часть).
#  Запускать НА СТАРОМ МАСТЕРЕ под root/sudo, ПОСЛЕ failover.sh на реплике.
#
#  Новый primary — это бывшая реплика (REPLICA_HOST из config.env).
#  Требования (уже подготовлены create-*.sh):
#    - на мастере включён wal_log_hints=on и data checksums;
#    - роли replicator выданы права на функции pg_rewind (реплицируются на standby);
#    - в pg_hba нового primary разрешён hostssl к базам replication и postgres.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source ./lib.sh
load_config
require_root_or_sudo
require_debian_pg
guard_training_cluster

NEW_PRIMARY="${REPLICA_HOST}"                 # после failover primary — бывшая реплика
BINDIR="/usr/lib/postgresql/${PG_VERSION}/bin"

cluster_exists || die "На этом узле нет учебного кластера ${PG_VERSION}/${CLUSTER_NAME}."

if [ -z "${REPL_PASSWORD:-}" ]; then
  read -rsp "Пароль роли '${REPL_USER}': " REPL_PASSWORD; echo
fi
[ -n "$REPL_PASSWORD" ] || die "Пустой пароль недопустим."

# 1) Остановить кластер и привести к чистому останову — обязательное условие pg_rewind.
if [ "$(cluster_status)" = "online" ]; then
  log "Останавливаю старый мастер…"
  pg_ctlcluster "${PG_VERSION}" "${CLUSTER_NAME}" stop
fi
state="$(sudo -u postgres "${BINDIR}/pg_controldata" "${DATADIR}" \
          | awk -F: '/Database cluster state/{sub(/^[ \t]+/,"",$2);print $2}')"
case "$state" in
  "shut down"|"shut down in recovery") : ;;
  *) log "Состояние кластера: '${state}' — привожу к чистому останову (start+stop)…"
     pg_ctlcluster "${PG_VERSION}" "${CLUSTER_NAME}" start
     pg_ctlcluster "${PG_VERSION}" "${CLUSTER_NAME}" stop ;;
esac

# 2) Подключение к новому primary. Для учебного failover используем sslmode=require
#    (шифруем без обмена сертификатами в обе стороны — так проще; для прода см. README).
SRC="host=${NEW_PRIMARY} port=${PG_PORT} user=${REPL_USER} dbname=postgres sslmode=require"

# 3) pg_rewind: догнать новый primary и записать standby-настройки (--write-recovery-conf).
log "Запускаю pg_rewind против ${NEW_PRIMARY}…"
sudo -u postgres env PGPASSWORD="$REPL_PASSWORD" \
  "${BINDIR}/pg_rewind" \
    --target-pgdata="${DATADIR}" \
    --source-server="${SRC}" \
    --write-recovery-conf \
    --progress

# 4) Пароль для стриминга — в ~postgres/.pgpass (теперь источник = новый primary).
PGPASS="/var/lib/postgresql/.pgpass"
touch "$PGPASS"; chown postgres:postgres "$PGPASS"; chmod 600 "$PGPASS"
sed -i "\#^${NEW_PRIMARY}:${PG_PORT}:replication:${REPL_USER}:#d" "$PGPASS" 2>/dev/null || true
printf '%s:%s:replication:%s:%s\n' "$NEW_PRIMARY" "$PG_PORT" "$REPL_USER" "$REPL_PASSWORD" >> "$PGPASS"
chown postgres:postgres "$PGPASS"

# 5) Запустить как новую реплику.
pg_ctlcluster "${PG_VERSION}" "${CLUSTER_NAME}" start
sleep 2
rec="$(psql_t -d postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null || echo '?')"
if [ "$rec" = "t" ]; then
  ok "Старый мастер вернулся как РЕПЛИКА нового primary ${NEW_PRIMARY}."
  echo "  Проверка:  sudo ./verify.sh   (здесь — standby; на ${NEW_PRIMARY} — в pg_stat_replication)"
else
  warn "Ожидали standby (t), получили '${rec}'. Смотрите лог кластера."
fi
