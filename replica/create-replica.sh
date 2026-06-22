#!/usr/bin/env bash
# ============================================================================
#  Создать УЧЕБНУЮ реплику (standby) через pg_basebackup + потоковую репликацию.
#  Запускать НА СЕРВЕРЕ-РЕПЛИКЕ (приёмник) под root/sudo.
#  Идемпотентно: при повторном запуске пересоздаёт реплику с нуля.
#
#  Перед запуском на мастере должен быть выполнен create-master.sh,
#  открыт порт ${PG_PORT} для этого сервера и (для verify-ca/verify-full)
#  скопирован сертификат мастера в ${ROOTCERT}.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source ./lib.sh
load_config
require_root_or_sudo
require_debian_pg
guard_training_cluster

# Пароль роли репликации — для pg_basebackup и дальнейшего стриминга. Не печатаем.
if [ -z "${REPL_PASSWORD:-}" ]; then
  read -rsp "Пароль роли '${REPL_USER}' (тот же, что на мастере): " REPL_PASSWORD; echo
fi
[ -n "$REPL_PASSWORD" ] || die "Пустой пароль недопустим."

# Корневой сертификат мастера нужен для проверки TLS.
ROOTCERT="${ROOTCERT:-/tmp/master-server.crt}"
case "$SSLMODE" in
  verify-ca|verify-full)
    [ -f "$ROOTCERT" ] || die "Для SSLMODE=${SSLMODE} нужен сертификат мастера в ${ROOTCERT}.
       Скопируйте его с мастера:  scp МАСТЕР:/var/lib/postgresql/${PG_VERSION}/${CLUSTER_NAME}/server.crt ${ROOTCERT}"
    ;;
esac

log "Пересоздаю учебную реплику ${PG_VERSION}/${CLUSTER_NAME} на порту ${PG_PORT}…"

# 1) Чистый старт.
if cluster_exists; then
  warn "Учебный кластер уже существует — удаляю ради чистого старта."
  pg_dropcluster --stop "${PG_VERSION}" "${CLUSTER_NAME}"
fi

# 2) Создаём «скелет» кластера, чтобы получить каталоги /etc и /var и запись в реестре.
pg_createcluster "${PG_VERSION}" "${CLUSTER_NAME}" --port "${PG_PORT}"
pg_ctlcluster "${PG_VERSION}" "${CLUSTER_NAME}" stop >/dev/null 2>&1 || true

# 3) Положить корневой сертификат туда, где его прочитает postgres (вне datadir — он сейчас очистится).
ROOT_DST="${CONFDIR}/root.crt"
if [[ "$SSLMODE" == verify-* ]]; then
  install -o postgres -g postgres -m 600 "$ROOTCERT" "$ROOT_DST"
fi

# 4) Очищаем datadir под базовую копию. Путь уже проверен guard_training_cluster.
log "Очищаю ${DATADIR} под базовую копию…"
find "${DATADIR}" -mindepth 1 -delete
chown postgres:postgres "${DATADIR}"
chmod 700 "${DATADIR}"

# 5) Сформировать строку подключения к мастеру.
CONNINFO="host=${MASTER_HOST} port=${PG_PORT} user=${REPL_USER} sslmode=${SSLMODE}"
if [[ "$SSLMODE" == verify-* ]]; then
  CONNINFO+=" sslrootcert=${ROOT_DST}"
fi

# 6) Базовая копия с мастера:
#    -X stream  — параллельно тянуть WAL, чтобы копия была консистентной
#    -R         — записать standby.signal и primary_conninfo (без пароля)
#    -S slot    — использовать заранее созданный физический слот
log "Снимаю базовую копию с ${MASTER_HOST} (это может занять время)…"
sudo -u postgres env PGPASSWORD="$REPL_PASSWORD" \
  pg_basebackup -d "$CONNINFO" -D "${DATADIR}" -Fp -Xs -P -R -S "${REPL_SLOT}"

# 7) Пароль для постоянного стриминга кладём в ~postgres/.pgpass (primary_conninfo его не хранит).
PGPASS="/var/lib/postgresql/.pgpass"
touch "$PGPASS"; chown postgres:postgres "$PGPASS"; chmod 600 "$PGPASS"
# убрать прежнюю запись для этого мастера, добавить актуальную
sed -i "\#^${MASTER_HOST}:${PG_PORT}:replication:${REPL_USER}:#d" "$PGPASS" 2>/dev/null || true
printf '%s:%s:replication:%s:%s\n' "$MASTER_HOST" "$PG_PORT" "$REPL_USER" "$REPL_PASSWORD" >> "$PGPASS"
chown postgres:postgres "$PGPASS"

# 7.5) Разрешить мастеру подключаться к ЭТОМУ узлу, когда он станет primary после
#      failover: replication — для стриминга, postgres — для pg_rewind. Только по TLS.
HBA="${CONFDIR}/pg_hba.conf"
add_hba() { grep -qF "$1" "$HBA" || printf '%s\n' "$1" >> "$HBA"; }
grep -q "# учебный failover (create-replica.sh)" "$HBA" \
  || printf '\n# учебный failover (create-replica.sh)\n' >> "$HBA"
add_hba "hostssl replication ${REPL_USER} ${MASTER_HOST}/32 scram-sha-256"
add_hba "hostssl postgres     ${REPL_USER} ${MASTER_HOST}/32 scram-sha-256"

# 8) Запустить реплику.
pg_ctlcluster "${PG_VERSION}" "${CLUSTER_NAME}" start
sleep 2

# 9) Быстрая проверка.
rec="$(psql_t -d postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null || echo '?')"
if [ "$rec" = "t" ]; then
  ok "Реплика запущена и находится в режиме восстановления (standby)."
else
  warn "Ожидали standby (t), получили '${rec}'. Смотрите лог: /var/log/postgresql/postgresql-${PG_VERSION}-${CLUSTER_NAME}.log"
fi

echo
echo "  Проверьте репликацию:"
echo "    на реплике:  sudo ./verify.sh"
echo "    на мастере:  sudo ./verify.sh   (увидите реплику в pg_stat_replication)"
