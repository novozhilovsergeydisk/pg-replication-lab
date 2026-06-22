#!/usr/bin/env bash
# ============================================================================
#  Общие функции и ПРЕДОХРАНИТЕЛИ для скриптов практикума.
#  Подключается из скриптов так:
#      cd "$(dirname "$0")/.."   # перейти в корень репозитория
#      source ./lib.sh
#      load_config
# ============================================================================
set -euo pipefail

# --- логирование ---------------------------------------------------------
log()  { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --- загрузка конфига ----------------------------------------------------
load_config() {
  local here cfg
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cfg="${here}/config.env"
  [ -f "$cfg" ] || die "Нет ${cfg}. Скопируйте config.env.example → config.env и заполните."
  # shellcheck disable=SC1090
  source "$cfg"
  : "${PG_VERSION:?нужно задать PG_VERSION в config.env}"
  : "${CLUSTER_NAME:?нужно задать CLUSTER_NAME в config.env}"
  : "${PG_PORT:?нужно задать PG_PORT в config.env}"
  : "${MASTER_HOST:?нужно задать MASTER_HOST в config.env}"
  : "${REPLICA_HOST:?нужно задать REPLICA_HOST в config.env}"
  : "${REPL_USER:?нужно задать REPL_USER в config.env}"
  : "${REPL_SLOT:?нужно задать REPL_SLOT в config.env}"
  : "${SSLMODE:?нужно задать SSLMODE в config.env}"

  # Debian/Ubuntu держит данные и конфиг учебного кластера здесь:
  DATADIR="/var/lib/postgresql/${PG_VERSION}/${CLUSTER_NAME}"
  CONFDIR="/etc/postgresql/${PG_VERSION}/${CLUSTER_NAME}"
}

# --- ПРЕДОХРАНИТЕЛИ ------------------------------------------------------
# Не дать случайно тронуть системный кластер (порт 5432, чужой datadir).
guard_training_cluster() {
  [ "$CLUSTER_NAME" = "training" ] \
    || die "CLUSTER_NAME='${CLUSTER_NAME}' ≠ 'training'. Предохранитель: работаю только с учебным кластером."
  [ "$PG_PORT" != "5432" ] \
    || die "PG_PORT=5432 запрещён: учебный кластер обязан жить на отдельном порту, чтобы не задеть боевой."
  [ "$DATADIR" = "/var/lib/postgresql/${PG_VERSION}/${CLUSTER_NAME}" ] \
    || die "Неожиданный DATADIR='${DATADIR}'. Останавливаюсь ради безопасности."
}

# --- проверки окружения -------------------------------------------------
require_root_or_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null || die "Нужны права root или установленный sudo."
  fi
}

require_debian_pg() {
  command -v pg_lsclusters   >/dev/null || die "Нет pg_lsclusters: поставьте пакет postgresql-common (Debian/Ubuntu)."
  command -v pg_createcluster >/dev/null || die "Нет pg_createcluster (postgresql-common)."
  [ -d "/usr/lib/postgresql/${PG_VERSION}/bin" ] \
    || die "Не установлен PostgreSQL ${PG_VERSION}: 'apt install postgresql-${PG_VERSION}' (см. README про PGDG-репозиторий)."
}

# Существует ли наш учебный кластер?
cluster_exists() {
  pg_lsclusters -h 2>/dev/null | awk '{print $1" "$2}' | grep -qx "${PG_VERSION} ${CLUSTER_NAME}"
}

# Статус кластера (online/down/...) или пусто, если кластера нет.
cluster_status() {
  pg_lsclusters -h 2>/dev/null | awk -v v="$PG_VERSION" -v c="$CLUSTER_NAME" '$1==v && $2==c {print $4}'
}

# psql на учебном кластере под системным пользователем postgres (peer-auth по локальному сокету).
psql_t() {
  sudo -u postgres psql -p "$PG_PORT" -X -v ON_ERROR_STOP=1 "$@"
}
