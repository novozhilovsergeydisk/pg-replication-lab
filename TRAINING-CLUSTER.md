# Практикум: учебный кластер PostgreSQL 16 (training)

Учебный кластер **training** — изолированная среда для отработки репликации
без риска для боевого `main`. Работает на порту **5433** (primary, appuse)
и **5435** (standby, elated-dijkstra) через SSH-туннель.

## Подготовка

Проект должен быть скопирован на оба сервера в `/root/pg-practikum/`:

```bash
# с вашего Мака:
cd /root/pg-practikum
tar czf - --exclude=.git . | ssh appuse 'tar xzf - -C /root/pg-practikum'
tar czf - --exclude=.git . | ssh elated-dijkstra 'tar xzf - -C /root/pg-practikum'
```

На обоих серверах сделать скрипты исполняемыми:

```bash
ssh appuse 'chmod +x /root/pg-practikum/*.sh /root/pg-practikum/master/*.sh /root/pg-practikum/replica/*.sh'
ssh elated-dijkstra 'chmod +x /root/pg-practikum/*.sh /root/pg-practikum/master/*.sh /root/pg-practikum/replica/*.sh'
```

## Создание primary (на appuse)

### 1. Запустить create-master.sh

```bash
ssh appuse 'cd /root/pg-practikum && REPL_PASSWORD="training_pass" bash master/create-master.sh'
```

Скрипт:
- Создаёт кластер **16/training** на порту **5433**
- Генерирует TLS-сертификат
- Создаёт пользователя `replicator` и слот `training_slot`
- Заливает тестовую таблицу `repl_demo` (1000 строк)

### 2. Если скрипт упал на создании роли

Создать вручную:

```bash
ssh appuse "sudo -u postgres psql -p 5433 -c \"CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'training_pass';\""
ssh appuse "sudo -u postgres psql -p 5433 -c \"SELECT pg_create_physical_replication_slot('training_slot');\""
ssh appuse "sudo -u postgres psql -p 5433 -c \"CREATE TABLE IF NOT EXISTS repl_demo(id bigserial PRIMARY KEY, ts timestamptz DEFAULT now(), note text); INSERT INTO repl_demo(note) SELECT 'row '||g FROM generate_series(1,1000) g;\""
```

### 3. Проверить

```bash
ssh appuse 'pg_lsclusters | grep training'
# 16  training 5433 online postgres ...

ssh appuse "sudo -u postgres psql -p 5433 -c \"SELECT count(*) FROM repl_demo;\""
# 1000
```

## Настройка SSH-туннеля

Если туннель ещё не настроен на порт 5434 → appuse:5433:

```bash
ssh elated-dijkstra '
systemctl stop pg-tunnel && \
sed -i "s|-L 5433:localhost:5432|-L 5433:localhost:5432 -L 5434:localhost:5433|" /etc/systemd/system/pg-tunnel.service && \
systemctl daemon-reload && systemctl start pg-tunnel && sleep 2
'
```

Проверить:

```bash
ssh elated-dijkstra 'ss -tlnp | grep -E "5433|5434"'
# 5433 — туннель к PG 16 main (appuse:5432)
# 5434 — туннель к training (appuse:5433)
```

## Копирование сертификата

Через ваш Mac (если appuse не имеет SSH-ключа на elated-dijkstra):

```bash
ssh appuse 'cat /var/lib/postgresql/16/training/server.crt' | ssh elated-dijkstra 'cat > /tmp/master-server.crt'
```

## Создание standby (на elated-dijkstra)

### 1. Удалить старый учебный кластер (если был)

```bash
ssh elated-dijkstra 'pg_lsclusters -h | grep -q "16.*training" && pg_dropcluster --stop 16 training 2>/dev/null; true'
```

### 2. Создать скелет

```bash
ssh elated-dijkstra 'pg_createcluster 16 training --port 5435 && pg_ctlcluster 16 training stop 2>/dev/null; true'
```

Порт **5435**, потому что 5433 занят туннелем PG 16 main.

### 3. Установить корневой сертификат

```bash
ssh elated-dijkstra 'install -o postgres -g postgres -m 600 /tmp/master-server.crt /etc/postgresql/16/training/root.crt 2>/dev/null; true'
```

### 4. Очистить datadir

```bash
ssh elated-dijkstra '
DATADIR="/var/lib/postgresql/16/training"
find "$DATADIR" -mindepth 1 -delete
chown postgres:postgres "$DATADIR"
chmod 700 "$DATADIR"
'
```

### 5. Снять базовый бэкап

```bash
ssh elated-dijkstra "sudo -u postgres env PGPASSWORD='training_pass' pg_basebackup \
  -d 'host=localhost port=5434 user=replicator sslmode=require' \
  -D /var/lib/postgresql/16/training -Fp -Xs -P -v -S training_slot"
```

### 6. Настроить standby-режим

```bash
ssh elated-dijkstra '
# сигнальный файл
touch /var/lib/postgresql/16/training/standby.signal
chown postgres:postgres /var/lib/postgresql/16/training/standby.signal

# primary_conninfo
cat > /etc/postgresql/16/training/conf.d/training-replica.conf << EOF
primary_conninfo = '\''host=localhost port=5434 user=replicator password=training_pass sslmode=require'\''
primary_slot_name = '\''training_slot'\''
hot_standby = on
EOF

# pgpass
PGPASS="/var/lib/postgresql/.pgpass"
touch "$PGPASS"; chown postgres:postgres "$PGPASS"; chmod 600 "$PGPASS"
sed -i "\#^localhost:5434:replication:replicator:#d" "$PGPASS" 2>/dev/null; true
printf "%s:%s:replication:%s:%s\n" "localhost" "5434" "replicator" "training_pass" >> "$PGPASS"

# pg_hba для failover
HBA="/etc/postgresql/16/training/pg_hba.conf"
grep -q "# failover" "$HBA" || printf "\n# failover\nhostssl replication replicator 146.185.235.4/32 scram-sha-256\nhostssl postgres replicator 146.185.235.4/32 scram-sha-256\n" >> "$HBA"
'
```

### 7. Запустить standby

```bash
ssh elated-dijkstra 'pg_ctlcluster 16 training start && pg_lsclusters | grep training'
```

Ожидаемый вывод:
```
16  training 5435 online,recovery postgres ...
```

## Проверка репликации

### На primary (appuse, порт 5433)

```bash
ssh appuse "sudo -u postgres psql -p 5433 -c \"SELECT client_addr, application_name, state, sync_state FROM pg_stat_replication;\""
```

Должен показать: `::1 | 16/training | streaming | async`

### На standby (elated-dijkstra, порт 5435)

```bash
ssh elated-dijkstra "sudo -u postgres psql -p 5435 -c \"SELECT pg_is_in_recovery(); SELECT count(*) FROM repl_demo;\""
```

- `pg_is_in_recovery` → `t` (true)
- `count` → `1000`

## Схема портов (текущая)

```
elated-dijkstra                    appuse
┌───────────────────┐             ┌────────────────────┐
│ PG 16 main (stby) │             │ PG 16 main (prim)  │
│  :5432             │             │  :5432              │
│    ↑               │             │    ↑                │
│  localhost:5433 ───│── tunnel ──▶│  localhost:5432     │
│                    │             │                    │
│ PG 16 training     │             │ PG 16 training     │
│  (stby)  :5435     │             │  (prim) :5433       │
│    ↑               │             │    ↑                │
│  localhost:5434 ───│── tunnel ──▶│  localhost:5433     │
└───────────────────┘             └────────────────────┘
```

## Удаление учебного кластера

### На appuse (primary)

```bash
ssh appuse 'pg_dropcluster --stop 16 training'
```

### На elated-dijkstra (standby)

```bash
ssh elated-dijkstra 'pg_dropcluster --stop 16 training'
```

**Порядок:** сначала удалить standby, потом primary (чтобы слот на primary
не остался висеть).

## Полная перестройка с нуля

Повторить все шаги раздела «Создание standby». Перед этим:

```bash
# на standby:
ssh elated-dijkstra 'pg_dropcluster --stop 16 training 2>/dev/null; true'
# на primary — если нужно пересоздать:
ssh appuse 'pg_dropcluster --stop 16 training 2>/dev/null; true'
ssh appuse 'cd /root/pg-practikum && REPL_PASSWORD="training_pass" bash master/create-master.sh'
```

## Отличие от боевого кластера

| Параметр | Боевой (main) | Учебный (training) |
|----------|--------------|-------------------|
| Порт primary | 5432 | 5433 |
| Порт standby | 5432 | 5435 |
| Туннель | 5433 → appuse:5432 | 5434 → appuse:5433 |
| Пароль | gC8V47Ka/... | training_pass |
| Настройка | autossh tunnel | autossh tunnel |
| Риск при ошибке | Потеря данных | Нет риска |
