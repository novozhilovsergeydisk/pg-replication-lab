# Настройка репликации PostgreSQL 17 (отдельный кластер для практики)

Используем уже установленный PG 17 на appuse (порт 5433) как primary и
устанавливаем PG 17 на elated-dijkstra как standby.

## Схема

| Сервер | Роль | Версия | Порт | Туннель |
|--------|------|--------|------|---------|
| appuse | Primary | 17 | 5433 | — |
| elated-dijkstra | Standby | 17 | 5432 | localhost:5434 → appuse:5433 |

Туннель: elated-dijkstra:5434 → appuse:5433 (добавляем к существующему
сервису pg-tunnel, где уже есть 5433→5432 для PG 16).

---

## 1. Настройка primary (PG 17 на appuse)

### 1.1. Включить параметры репликации

```bash
ssh appuse 'cat >> /etc/postgresql/17/main/postgresql.conf << EOF

# --- replication settings ---
listen_addresses = '\''*'\''
wal_level = replica
max_wal_senders = 10
wal_keep_size = 1GB
hot_standby = on
EOF'
```

### 1.2. Создать пользователя репликации

```bash
ssh appuse "sudo -u postgres psql -p 5433 -c \"CREATE USER replicator_17 WITH REPLICATION PASSWORD 'НАДЁЖНЫЙ_ПАРОЛЬ';\""
```

### 1.3. Настроить pg_hba.conf

```bash
ssh appuse 'cat >> /etc/postgresql/17/main/pg_hba.conf << EOF

host    replication     replicator_17   127.0.0.1/32            scram-sha-256
host    replication     replicator_17   ::1/128                 scram-sha-256
EOF'
```

### 1.4. Перезагрузить конфиг

```bash
ssh appuse "sudo -u postgres psql -p 5433 -c \"SELECT pg_reload_conf();\""
```

### 1.5. Проверить

```bash
ssh appuse "sudo -u postgres psql -p 5433 -c \"SHOW wal_level; SHOW max_wal_senders;\""
```

---

## 2. Настроить SSH-туннель

Добавляем второй проброс порта к существующему сервису pg-tunnel.

### 2.1. Остановить туннель и отредактировать сервис

```bash
ssh elated-dijkstra 'systemctl stop pg-tunnel'
```

```bash
ssh elated-dijkstra 'sed -i "s|-L 5433:localhost:5432|-L 5433:localhost:5432 -L 5434:localhost:5433|" /etc/systemd/system/pg-tunnel.service'
```

### 2.2. Перезагрузить и запустить

```bash
ssh elated-dijkstra 'systemctl daemon-reload && systemctl start pg-tunnel && systemctl status pg-tunnel --no-pager | head -5'
```

### 2.3. Проверить оба порта

```bash
ssh elated-dijkstra 'ss -tlnp | grep -E "5433|5434"'
```

Должны быть два слушающих порта:
- 5433 — туннель к PG 16 (appuse:5432)
- 5434 — туннель к PG 17 (appuse:5433)

---

## 3. Установить PostgreSQL 17 на standby

```bash
ssh elated-dijkstra 'apt update && apt install -y postgresql-17 2>&1 | tail -3'
```

### 3.1. Остановить дефолтный кластер и очистить данные

```bash
ssh elated-dijkstra 'pg_ctlcluster 17 main stop 2>/dev/null; rm -rf /var/lib/postgresql/17/main'
```

---

## 4. Базовый бэкап через туннель

```bash
ssh elated-dijkstra "sudo -u postgres PGPASSWORD='НАДЁЖНЫЙ_ПАРОЛЬ' pg_basebackup \
  -h localhost \
  -p 5434 \
  -U replicator_17 \
  -D /var/lib/postgresql/17/main \
  -P -v \
  --wal-method=stream"
```

```bash
ssh elated-dijkstra 'chmod 0700 /var/lib/postgresql/17/main && chown -R postgres:postgres /var/lib/postgresql/17/main'
```

---

## 5. Запуск standby

### 5.1. Сигнальный файл

```bash
ssh elated-dijkstra 'touch /var/lib/postgresql/17/main/standby.signal && chown postgres:postgres /var/lib/postgresql/17/main/standby.signal'
```

### 5.2. Конфигурация подключения

```bash
ssh elated-dijkstra 'cat > /etc/postgresql/17/main/conf.d/standby.conf << EOF
primary_conninfo = '\''host=localhost port=5434 user=replicator_17 password=НАДЁЖНЫЙ_ПАРОЛЬ'\''
hot_standby = on
EOF'
```

### 5.3. Запустить

```bash
ssh elated-dijkstra 'pg_ctlcluster 17 main start && pg_lsclusters'
```

Ожидаемый вывод:
```
17  main    5432 online,recovery postgres ...
```

---

## 6. Проверка

### На primary (appuse, PG 17)

```bash
ssh appuse "sudo -u postgres psql -p 5433 -c \"SELECT client_addr, state, sync_state FROM pg_stat_replication;\""
```

Должен показать: `127.0.0.1 | streaming | async`

### Передача данных

```bash
# на primary:
ssh appuse "sudo -u postgres psql -p 5433 -c \"CREATE TABLE test_pg17 (id serial, ts timestamptz DEFAULT now()); INSERT INTO test_pg17 DEFAULT VALUES; SELECT * FROM test_pg17;\""

# на standby:
ssh elated-dijkstra "sudo -u postgres psql -p 5432 -d postgres -c \"SELECT * FROM test_pg17;\""
```

---

## Итоговая схема портов

```
elated-dijkstra                    appuse
┌───────────────┐                 ┌──────────────────┐
│ PG 16 (stby)   │                 │ PG 16 (primary)   │
│  :5432         │                 │  :5432            │
│     ↑          │                 │      ↑            │
│ localhost:5433 ─│── SSH tunnel ─▶│ localhost:5432    │
│     ↑          │                 │                   │
│ PG 17 (stby)   │                 │ PG 17 (primary)   │
│  :5432         │                 │  :5433            │
│     ↑          │                 │      ↑            │
│ localhost:5434 ─│── SSH tunnel ─▶│ localhost:5433    │
└───────────────┘                 └──────────────────┘
```
