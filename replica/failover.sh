#!/usr/bin/env bash
# ============================================================================
#  Учебный failover: повысить ЭТУ реплику до самостоятельного primary
#  (имитация отказа мастера или плановое переключение).
#  Запускать НА РЕПЛИКЕ (standby) под root/sudo.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source ./lib.sh
load_config
require_root_or_sudo
require_debian_pg
guard_training_cluster

cluster_exists || die "Нет учебного кластера ${PG_VERSION}/${CLUSTER_NAME}."
[ "$(cluster_status)" = "online" ] || die "Кластер не запущен (статус: $(cluster_status))."

rec="$(psql_t -d postgres -tAc 'SELECT pg_is_in_recovery()')"
[ "$rec" = "t" ] || die "Этот узел уже primary (не в recovery) — повышать нечего."

warn "ВАЖНО: сначала убедитесь, что старый мастер ОСТАНОВЛЕН, иначе будет split-brain"
warn "(две независимые primary-базы, расходящиеся данные)."
log  "Повышаю реплику до primary…"
pg_ctlcluster "${PG_VERSION}" "${CLUSTER_NAME}" promote

# Дождаться выхода из режима восстановления.
rec="t"
for _ in $(seq 1 30); do
  rec="$(psql_t -d postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null || echo t)"
  [ "$rec" = "f" ] && break
  sleep 1
done

if [ "$rec" = "f" ]; then
  ok "Готово: этот узел теперь самостоятельный primary. Запись идёт сюда."
  echo
  echo "  Проверка:        sudo ./verify.sh"
  echo "  Вернуть старый мастер как реплику — на СТАРОМ МАСТЕРЕ выполните:"
  echo "      sudo ./master/rewind-old-master.sh"
else
  die "Промоушен не завершился за 30 сек. Смотрите лог: /var/log/postgresql/postgresql-${PG_VERSION}-${CLUSTER_NAME}.log"
fi
