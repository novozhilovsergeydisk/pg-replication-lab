#!/usr/bin/env bash
# ============================================================================
#  Показать роль ЭТОГО учебного кластера и состояние репликации.
#  Запускать на любом из серверов под root/sudo. Ничего не меняет.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
load_config

if ! cluster_exists; then
  die "Учебного кластера ${PG_VERSION}/${CLUSTER_NAME} нет. Сначала создайте его."
fi
if [ "$(cluster_status)" != "online" ]; then
  die "Кластер ${PG_VERSION}/${CLUSTER_NAME} не запущен (статус: $(cluster_status))."
fi

rec="$(psql_t -d postgres -tAc 'SELECT pg_is_in_recovery()')"

if [ "$rec" = "f" ]; then
  echo "================ РОЛЬ: МАСТЕР (primary) ================"
  echo
  echo "Подключённые реплики (pg_stat_replication):"
  psql_t -d postgres -x -c "
    SELECT application_name, client_addr, state, sync_state,
           sent_lsn, write_lsn, flush_lsn, replay_lsn,
           write_lag, flush_lag, replay_lag
    FROM pg_stat_replication"
  echo "Слоты репликации (pg_replication_slots):"
  psql_t -d postgres -c "
    SELECT slot_name, slot_type, active, restart_lsn, wal_status, safe_wal_size
    FROM pg_replication_slots"
  echo "Текущая позиция WAL и счётчик тестовой таблицы:"
  psql_t -d postgres -c "SELECT pg_current_wal_lsn() AS wal_lsn"
  psql_t -d postgres -c "SELECT count(*) AS rows, max(id) AS max_id FROM repl_demo" 2>/dev/null \
    || echo "  (таблицы repl_demo нет)"
else
  echo "================ РОЛЬ: РЕПЛИКА (standby) ================"
  echo
  echo "Приёмник WAL (pg_stat_wal_receiver):"
  psql_t -d postgres -x -c "
    SELECT status, sender_host, sender_port, slot_name,
           received_lsn, latest_end_lsn, last_msg_receipt_time
    FROM pg_stat_wal_receiver"
  lag="$(psql_t -d postgres -tAc \
    "SELECT COALESCE(round(EXTRACT(epoch FROM now() - pg_last_xact_replay_timestamp()))::text,'нет данных')")"
  echo "Отставание применения, сек: ${lag}"
  echo "Позиции WAL на реплике:"
  psql_t -d postgres -c "SELECT pg_last_wal_receive_lsn() AS received, pg_last_wal_replay_lsn() AS replayed"
  echo "Счётчик тестовой таблицы (должен догонять мастер):"
  psql_t -d postgres -c "SELECT count(*) AS rows, max(id) AS max_id FROM repl_demo" 2>/dev/null \
    || echo "  (таблицы repl_demo пока нет)"
fi
