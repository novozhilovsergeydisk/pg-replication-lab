# DBA: шпаргалка основных команд PostgreSQL

## Управление кластерами

```bash
# список всех кластеров
pg_lsclusters

# остановить кластер
pg_ctlcluster 16 main stop
pg_ctlcluster 17 main stop

# запустить кластер
pg_ctlcluster 16 main start
pg_ctlcluster 17 main start

# перезапустить кластер
pg_ctlcluster 16 main restart

# перезагрузить конфиг (без остановки)
sudo -u postgres psql -c "SELECT pg_reload_conf();"

# статус конкретного кластера
pg_ctlcluster 16 main status

# статус через systemd
systemctl status postgresql@16-main
```

## Подключение к PostgreSQL

```bash
# подключиться от postgres (локально)
sudo -u postgres psql
sudo -u postgres psql -p 5433
sudo -u postgres psql -d database_name

# подключиться удалённо
psql -h HOST -p PORT -U USER -d DB

# выполнить один запрос
sudo -u postgres psql -c "SELECT version();"
sudo -u postgres psql -p 5433 -c "SELECT pg_is_in_recovery();"
```

## Пользователи и роли

```sql
-- список ролей
\du

-- создать роль для репликации
CREATE USER replicator WITH REPLICATION PASSWORD 'пароль';

-- создать обычную роль
CREATE USER app_user WITH PASSWORD 'пароль';

-- дать права на БД
GRANT ALL PRIVILEGES ON DATABASE db_name TO app_user;

-- сменить пароль
ALTER USER replicator PASSWORD 'новый_пароль';
```

## Репликация

```sql
-- статус репликации (на primary)
SELECT client_addr, application_name, state, sync_state, write_lag
FROM pg_stat_replication;

-- статус standby (на реплике)
SELECT pg_is_in_recovery();

-- слоты репликации
SELECT slot_name, slot_type, active, restart_lsn
FROM pg_replication_slots;

-- создать слот
SELECT pg_create_physical_replication_slot('slot_name');

-- удалить слот
SELECT pg_drop_replication_slot('slot_name');

-- отставание standby (в байтах)
SELECT pg_wal_lsn_diff(
  pg_last_wal_receive_lsn(),
  pg_last_wal_replay_lsn()
);
```

## Promote / Failover

```bash
# повысить standby до primary
pg_ctlcluster 16 main promote

# pg_rewind (на старом primary, после promote)
sudo -u postgres pg_rewind \
  -D /var/lib/postgresql/16/main \
  --source-server='host=HOST port=PORT user=replicator password=ПАРОЛЬ' \
  -P
```

## Бэкапы

```bash
# физический бэкап всего кластера
sudo -u postgres pg_basebackup \
  -h HOST -p PORT -U replicator \
  -D /backup/dir -P -v --wal-method=stream

# логический дамп одной БД
pg_dump -U postgres -d db_name -f dump.sql

# восстановление из дампа
psql -U postgres -d db_name -f dump.sql

# дамп всех БД
pg_dumpall -U postgres -f all.sql
```

## Мониторинг

```sql
-- активные подключения и запросы
SELECT pid, usename, state, wait_event,
       now() - query_start AS duration,
       LEFT(query, 100) AS query
FROM pg_stat_activity
WHERE state IS NOT NULL
  AND pid <> pg_backend_pid()
ORDER BY duration DESC;

-- найти долгие запросы (> 5 сек)
SELECT pid, now() - query_start AS duration, query
FROM pg_stat_activity
WHERE state = 'active'
  AND now() - query_start > interval '5 seconds'
ORDER BY duration DESC;

-- завершить процесс
SELECT pg_terminate_backend(PID);

-- кто кого блокирует
SELECT pid, pg_blocking_pids(pid), wait_event, query
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
  AND pid <> pg_backend_pid();

-- топ-10 больших таблиц
SELECT relname,
  pg_size_pretty(pg_total_relation_size(relid)) AS total,
  n_live_tup AS rows,
  n_dead_tup AS dead
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 10;

-- статистика по запросам (pg_stat_statements)
SELECT query, calls, total_exec_time, mean_exec_time, rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 5;
```

## VACUUM

```sql
-- ручной VACUUM (не блокирует)
VACUUM table_name;
VACUUM;

-- VACUUM с заморозкой (профилактика wraparound)
VACUUM FREEZE;

-- VACUUM FULL (блокирует таблицу, дефрагментация)
VACUUM FULL table_name;

-- информация по VACUUM для таблицы
SELECT relname, n_dead_tup, last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
WHERE relname = 'table_name';
```

## EXPLAIN ANALYZE

```sql
-- базовый план
EXPLAIN SELECT * FROM orders WHERE id = 42;

-- с выполнением и деталями
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE user_id = 42;

-- в JSON (удобно для чтения программами)
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM orders WHERE user_id = 42;
```

## PostgreSQL config

```bash
# основные параметры
sudo -u postgres psql -c "SHOW all;"             # все параметры
sudo -u postgres psql -c "SHOW shared_buffers;"
sudo -u postgres psql -c "SHOW wal_level;"
sudo -u postgres psql -c "SHOW max_connections;"
sudo -u postgres psql -c "SHOW archive_mode;"

# пути к конфигам
sudo -u postgres psql -c "SHOW config_file;"
sudo -u postgres psql -c "SHOW hba_file;"
sudo -u postgres psql -c "SHOW data_directory;"
```

## SSH-туннель

```bash
# запустить туннель вручную
ssh -N -L LOCAL_PORT:localhost:REMOTE_PORT user@HOST

# пример: локальный порт 5434 → appuse:5433
ssh -N -L 5434:localhost:5433 root@146.185.235.4

# статус сервиса туннеля
systemctl status pg-tunnel

# перезапустить
systemctl restart pg-tunnel

# проверить, какие порты слушает туннель
ss -tlnp | grep -E "5433|5434"
```

## Логи

```bash
# логи PostgreSQL
tail -f /var/log/postgresql/postgresql-16-main.log
tail -f /var/log/postgresql/postgresql-17-main.log

# системные логи (журнал)
journalctl -xeu postgresql@16-main --no-pager | tail -30

# поиск ошибок в логах
grep -i "error\|fatal\|panic" /var/log/postgresql/postgresql-16-main.log
```

## Диск и память

```bash
# место на диске
df -h /

# размер данных PostgreSQL
du -sh /var/lib/postgresql/*/main

# память
free -h

# загрузка CPU
top
htop
```
