# Failover / Recovery: адаптированные команды для appuse + elated-dijkstra

Конфигурация:
- Primary: appuse (146.185.235.4), PostgreSQL 16 main, порт 5432
- Standby: elated-dijkstra (89.127.200.68), PostgreSQL 16 main, порт 5432
- Туннель: elated-dijkstra:5433 → appuse:5432 (autossh, pg-tunnel.service)
- Пароль replicator: <ПАРОЛЬ>

---

## Симуляция отказа

### 1. Остановить PostgreSQL на appuse (эмуляция аварии)

```bash
ssh appuse 'pg_ctlcluster 16 main stop && pg_lsclusters'
```

Ожидаемый вывод: `16  main    5432 down postgres ...`

### 2. Повысить standby до primary

```bash
ssh elated-dijkstra 'pg_ctlcluster 16 main promote && pg_lsclusters'
```

Ожидаемый вывод: `16  main    5432 online postgres ...` (без `recovery`)

### 3. Проверить, что новый primary пишет

```bash
ssh elated-dijkstra "sudo -u postgres psql -c \"SELECT pg_is_in_recovery();\""
```
Должен вернуть: `f`

---

## Возврат в исходное состояние

### 4. Удалить тестовую таблицу и остановить PostgreSQL в Германии

```bash
# необязательно — таблица создана только для проверки
ssh elated-dijkstra "sudo -u postgres psql -c \"DROP TABLE IF EXISTS fail_test;\""
ssh elated-dijkstra 'pg_ctlcluster 16 main stop'
```

### 5. Запустить appuse обратно как primary

```bash
ssh appuse 'pg_ctlcluster 16 main start && pg_lsclusters'
```

Ожидаемый вывод: `16  main    5432 online postgres ...`

### 6. Стереть данные standby и снять свежий бэкап

```bash
ssh elated-dijkstra 'rm -rf /var/lib/postgresql/16/main'
ssh elated-dijkstra "sudo -u postgres PGPASSWORD='<ПАРОЛЬ>' pg_basebackup -h localhost -p 5433 -U replicator -D /var/lib/postgresql/16/main -P -v --wal-method=stream"
```

### 7. Включить standby-режим и запустить

```bash
ssh elated-dijkstra 'chmod 0700 /var/lib/postgresql/16/main && chown -R postgres:postgres /var/lib/postgresql/16/main && touch /var/lib/postgresql/16/main/standby.signal && chown postgres:postgres /var/lib/postgresql/16/main/standby.signal && pg_ctlcluster 16 main start && pg_lsclusters'
```

Ожидаемый вывод: `16  main    5432 online,recovery postgres ...`

### 8. Финальная проверка

```bash
ssh appuse "sudo -u postgres psql -c \"SELECT client_addr, state, sync_state FROM pg_stat_replication;\""
```

Ожидаемый вывод: `::1 | streaming | async`
