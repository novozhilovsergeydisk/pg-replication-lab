#!/usr/bin/env bash
# ============================================================================
#  Полностью удалить УЧЕБНЫЙ кластер на ЭТОМ сервере.
#  Запускать на любом из серверов (мастер или реплика) под root/sudo.
#  Предохранители не дадут тронуть системный кластер (5432).
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_config
require_root_or_sudo
require_debian_pg
guard_training_cluster

role="неизвестна"
if cluster_exists; then
  # Определим роль до удаления, чтобы дать правильную подсказку.
  if [ "$(cluster_status)" = "online" ]; then
    rec="$(psql_t -d postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null || echo '')"
    [ "$rec" = "t" ] && role="реплика (standby)"
    [ "$rec" = "f" ] && role="мастер (primary)"
  fi
  warn "Удаляю учебный кластер ${PG_VERSION}/${CLUSTER_NAME} (роль: ${role})…"
  pg_dropcluster --stop "${PG_VERSION}" "${CLUSTER_NAME}"
  ok "Учебный кластер удалён."
else
  warn "Учебного кластера ${PG_VERSION}/${CLUSTER_NAME} нет — удалять нечего."
fi

# Подчистить локальные артефакты практикума.
rm -f "${CONFDIR}/root.crt" 2>/dev/null || true
sed -i "\#^${MASTER_HOST}:${PG_PORT}:replication:${REPL_USER}:#d" /var/lib/postgresql/.pgpass 2>/dev/null || true

case "$role" in
  *реплика*)
    echo
    warn "Это была РЕПЛИКА. Слот '${REPL_SLOT}' на мастере остался."
    echo "    Если мастер НЕ будете пересоздавать — удалите слот на мастере, иначе там будет копиться WAL:"
    echo "      sudo -u postgres psql -p ${PG_PORT} -c \"SELECT pg_drop_replication_slot('${REPL_SLOT}')\""
    echo "    (рост WAL ограничен max_slot_wal_keep_size=2GB, но слот лучше убрать явно)."
    ;;
  *мастер*)
    echo
    log "Это был МАСТЕР. Слот '${REPL_SLOT}' удалён вместе с кластером."
    ;;
esac
