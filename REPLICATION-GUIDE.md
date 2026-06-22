# Настройка физической streaming репликации PostgreSQL (пошаговое руководство)

**Физическая репликация** (physical streaming replication) — копия кластера
целиком на уровне WAL. Все базы, роли, таблицы — всё реплицируется. Standby
только для чтения.

```
primary:5432  ──── WAL stream ───▶  standby:5432
         (или через SSH-туннель)
```

---

## Оглавление

- [1. Терминология](#1-терминология)
- [2. Требования](#2-требования)
- [3. Подготовка первичного сервера (primary)](#3-подготовка-первичного-сервера-primary)
- [4. Создание пользователя репликации](#4-создание-пользователя-репликации)
- [5. Firewall: открыть порт](#5-firewall-открыть-порт)
- [6. Настройка SSH-туннеля (если порт напрямую не открыть)](#6-настройка-ssh-туннеля-если-порт-напрямую-не-открыть)
- [7. Установка PostgreSQL на standby](#7-установка-postgresql-на-standby)
- [8. Базовый бэкап (pg_basebackup)](#8-базовый-бэкап-pg_basebackup)
- [9. Запуск standby](#9-запуск-standby)
- [10. Проверка репликации](#10-проверка-репликации)
- [11. Что дальше](#11-что-дальше)

---

## 1. Терминология

| Термин | Описание |
|--------|---------|
| **Primary** | Сервер-источник, куда пишут приложения |
| **Standby** | Сервер-приёмник (replica), только чтение |
| **Streaming replication** | Непрерывная передача WAL-журналов по TCP |
| **WAL** | Write-Ahead Log — журнал изменений PostgreSQL |
| **pg_basebackup** | Утилита для снятия базовой копии кластера |
| **autossh** | Обёртка над SSH, автоматически перезапускающая туннель при обрыве |
| **SSH-туннель** | Проброс TCP-порта через шифрованное SSH-соединение |

---

## 2. Требования

- Debian/Ubuntu на обоих серверах
- Одинаковая **мажорная версия** PostgreSQL (например, 16) и архитектура (amd64)
- Root (или sudo) на обоих серверах
- SSH по ключу с вашего рабочего места на оба сервера
- Standby должен дозваниваться до primary: порт 5432 (или SSH-туннель)

---

## 3. Подготовка первичного сервера (primary)

### 3.1. Проверить, что PostgreSQL уже работает

```bash
pg_lsclusters
```

Пример вывода:
```
Ver Cluster Port Status Owner    Data directory
16  main    5432 online postgres /var/lib/postgresql/16/main
```

Если не установлен — установить через PGDG-репозиторий (см. раздел 7).

### 3.2. Проверить/настроить postgresql.conf

Файл: `/etc/postgresql/16/main/postgresql.conf`

Параметры, критичные для репликации:

```ini
listen_addresses = '*'              # слушать на всех интерфейсах
wal_level = replica                 # уровень WAL: minimal → replica → logical
max_wal_senders = 10                # максимум процессов отправки WAL
wal_keep_size = 1GB                 # сколько WAL хранить (чтобы standby не отстал)
hot_standby = on                    # разрешить чтение на standby
```

Проверить текущие значения:

```bash
sudo -u postgres psql -c "SHOW listen_addresses;"
sudo -u postgres psql -c "SHOW wal_level;"
sudo -u postgres psql -c "SHOW max_wal_senders;"
```

Если что-то не так — отредактировать `postgresql.conf`, затем перезагрузить:

```bash
sudo -u postgres psql -c "SELECT pg_reload_conf();"
# ИЛИ для параметров, требующих рестарта:
# pg_ctlcluster 16 main restart
```

### 3.3. Настроить pg_hba.conf

Файл: `/etc/postgresql/16/main/pg_hba.conf`

Добавить строку для репликации (в конце файла):

```
host    replication     replicator      <IP_СТЭНДБИ>/32       scram-sha-256
```

Где:
- `replicator` — имя роли для репликации
- `<IP_СТЭНДБИ>` — IP-адрес сервера standby

Если репликация пойдёт через SSH-туннель — указать `localhost` или `127.0.0.1`:

```
host    replication     replicator      127.0.0.1/32            scram-sha-256
```

Применить:

```bash
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

---

## 4. Создание пользователя репликации

На primary выполнить:

```bash
sudo -u postgres psql -c "CREATE USER replicator WITH REPLICATION PASSWORD 'НАДЁЖНЫЙ_ПАРОЛЬ';"
```

Где `replicator` — имя роли (может быть любым), атрибут `REPLICATION` обязателен.

Проверить:

```bash
sudo -u postgres psql -c "\du"
```

---

## 5. Firewall: открыть порт

Если провайдер не блокирует входящие порты — на primary:

```bash
ufw allow from <IP_СТЭНДБИ> to any port 5432 proto tcp
```

Проверить:

```bash
ufw status | grep 5432
```

Если провайдер блокирует порт (как в нашем случае с Mnogoweb) — переходим к
SSH-туннелю (раздел 6). С портом разберёмся потом.

---

## 6. Настройка SSH-туннеля (если порт напрямую не открыть)

### 6.1. Когда это нужно

Провайдер (Mnogoweb, Timeweb, Beget, и т.д.) блокирует входящие соединения
на нестандартные порты через свой сетевой файрвол. SSH (порт 22) открыт —
используем его как транзит.

### 6.2. Скопировать SSH-ключ на standby

На **своём ПК** (откуда есть доступ к обоим серверам):

```bash
cat ~/.ssh/КЛЮЧ_ОТ_PRIMARY | ssh root@IP_STANDBY 'cat >> ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519'
```

Либо на **самом standby**:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
ssh-copy-id root@IP_PRIMARY
```

### 6.3. Проверить SSH с standby на primary

```bash
ssh root@IP_PRIMARY 'hostname'
# должно вернуть hostname primary
```

### 6.4. Установить autossh на standby

```bash
apt update && apt install -y autossh
```

### 6.5. Создать systemd-сервис туннеля

На standby создать `/etc/systemd/system/pg-tunnel.service`:

```ini
[Unit]
Description=PostgreSQL SSH Tunnel to primary
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/autossh -M 0 \
  -o "ServerAliveInterval=30" \
  -o "ServerAliveCountMax=3" \
  -o "StrictHostKeyChecking=no" \
  -N \
  -L 5433:localhost:5432 \
  root@IP_PRIMARY \
  -i /root/.ssh/id_ed25519
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
```

**Пояснение:** `-L 5433:localhost:5432` означает: «на локальной машине слушать
порт 5433, все соединения на него перенаправлять через SSH на localhost:5432
primary».

### 6.6. Запустить туннель

```bash
systemctl daemon-reload
systemctl enable pg-tunnel
systemctl start pg-tunnel
systemctl status pg-tunnel
# Должен быть active (running)
```

### 6.7. Проверить туннель

```bash
# Убедиться, что порт слушается:
ss -tlnp | grep 5433

# Проверить, что через туннель виден PostgreSQL primary:
sudo -u postgres PGPASSWORD="ПАРОЛЬ" psql -h localhost -p 5433 -U replicator -d postgres -c "SELECT pg_is_in_recovery();"
# Должен вернуть f — значит, подключились к primary
```

---

## 7. Установка PostgreSQL на standby

Если PostgreSQL не установлен — установить ту же версию, что на primary:

```bash
apt install -y curl ca-certificates
install -d /usr/share/postgresql-common/pgdg
curl -s https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
apt update
apt install -y postgresql-16
```

После установки Debian/Ubuntu автоматически создают и запускают кластер `main`.
Остановить его и удалить данные — они нам не нужны, мы примем копию с primary:

```bash
pg_ctlcluster 16 main stop
rm -rf /var/lib/postgresql/16/main
```

---

## 8. Базовый бэкап (pg_basebackup)

pg_basebackup — утилита, которая снимает полную копию кластера primary «на лету»,
без остановки сервера.

### 8.1. Если порт открыт напрямую

```bash
sudo -u postgres PGPASSWORD="ПАРОЛЬ" pg_basebackup \
  -h IP_PRIMARY \
  -p 5432 \
  -U replicator \
  -D /var/lib/postgresql/16/main \
  -P -v \
  --wal-method=stream
```

### 8.2. Если через SSH-туннель

Подключаемся к туннелю (локальный порт 5433 → primary):

```bash
sudo -u postgres PGPASSWORD="ПАРОЛЬ" pg_basebackup \
  -h localhost \
  -p 5433 \
  -U replicator \
  -D /var/lib/postgresql/16/main \
  -P -v \
  --wal-method=stream
```

**Ключи:**
- `-h`, `-p` — хост и порт primary
- `-U` — пользователь репликации
- `-D` — куда сохранить данные на standby
- `-P` — показывать прогресс
- `-v` — подробный вывод
- `--wal-method=stream` — WAL передавать вместе с бэкапом (чтобы standby сразу начал догонять)

### 8.3. Поправить права

```bash
chmod 0700 /var/lib/postgresql/16/main
chown -R postgres:postgres /var/lib/postgresql/16/main
```

---

## 9. Запуск standby

### 9.1. Сигнальный файл standby.signal

Этот файл говорит PostgreSQL: «ты — реплика, не пиши сам, принимай WAL от primary».

```bash
touch /var/lib/postgresql/16/main/standby.signal
chown postgres:postgres /var/lib/postgresql/16/main/standby.signal
```

### 9.2. Конфигурация primary_conninfo

Создать `/etc/postgresql/16/main/conf.d/standby.conf`:

```ini
primary_conninfo = 'host=localhost port=5433 user=replicator password=ПАРОЛЬ'
hot_standby = on
```

**Важно:** если порт открыт напрямую — укажите `host=IP_PRIMARY port=5432`.

Где `primary_conninfo` — строка подключения к primary (те же параметры, что
использовались в pg_basebackup).

### 9.3. Запустить PostgreSQL standby

```bash
pg_ctlcluster 16 main start
```

Проверить статус:

```bash
pg_lsclusters
# Должен показать: 16  main    5432 online,recovery postgres ...
# Статус "online,recovery" — это нормально для standby
```

---

## 10. Проверка репликации

### 10.1. На primary

```bash
sudo -u postgres psql -c "SELECT client_addr, application_name, state, sync_state, write_lag FROM pg_stat_replication;"
```

Если репликация работает — увидите строку:
```
 client_addr | application_name |   state   | sync_state | write_lag
-------------+------------------+-----------+------------+-----------
 127.0.0.1   | 16/main          | streaming | async      |
```

- `state = streaming` — репликация активна
- `sync_state = async` — асинхронный режим (нет гарантии «ноль потерь»)

### 10.2. На standby

```bash
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Должен вернуть: t  (true)

sudo -u postgres psql -c "SELECT pg_stat_get_wal_receiver();"
# Покажет процесс приёма WAL
```

### 10.3. Проверка передачи данных

На **primary**:

```bash
sudo -u postgres psql -c "CREATE TABLE repl_test (id serial, data text, ts timestamptz DEFAULT now()); INSERT INTO repl_test(data) VALUES ('проверка'); SELECT * FROM repl_test;"
```

На **standby** (через 1-2 секунды):

```bash
sudo -u postgres psql -c "SELECT * FROM repl_test;"
# Должна быть та же строка
```

Очистить тестовую таблицу (на primary):

```bash
sudo -u postgres psql -c "DROP TABLE repl_test;"
```

---

## 11. Что дальше

### 11.1. Переключение на прямое соединение (когда откроют порт)

```bash
# на standby:
systemctl stop pg-tunnel
systemctl disable pg-tunnel

# поменять primary_conninfo
# было: host=localhost port=5433
# стало: host=IP_PRIMARY port=5432

pg_ctlcluster 16 main restart
```

### 11.2. Учебный failover и возврат старого primary (pg_rewind)

Эмуляция полной аварии: primary упал → повышаем standby → чиним старый primary
и возвращаем его как реплику через `pg_rewind`.

**Важно:** `pg_rewind` работает только если на старом primary включены
`wal_log_hints = on` или `data_checksums = on`. Проверьте перед началом:

```bash
# на primary (appuse):
sudo -u postgres psql -c "SHOW wal_log_hints;"
sudo -u postgres psql -c "SHOW data_checksums;"
```

Если оба `off` — `pg_rewind` не сработает.

#### Этап A: Имитация отказа primary

```bash
# 1. Остановить PostgreSQL на primary (appuse)
ssh appuse 'pg_ctlcluster 16 main stop'

# 2. Убедиться, что он упал
ssh appuse 'pg_lsclusters'
# Должен показать: 16  main    5432 down postgres ...
```

#### Этап B: Повышение standby

```bash
# 3. На standby (elated-dijkstra) выполнить promote
ssh elated-dijkstra 'pg_ctlcluster 16 main promote'

# 4. Проверить, что standby стал primary
ssh elated-dijkstra "sudo -u postgres psql -c \"SELECT pg_is_in_recovery();\""
# Должен показать: f  (false — уже не recovery)

# 5. Проверить статус кластера
ssh elated-dijkstra 'pg_lsclusters'
# Должен показать: 16  main    5432 online postgres ... (без recovery)

# 6. Убедиться, что новый primary принимает запись
ssh elated-dijkstra "sudo -u postgres psql -c \"CREATE TABLE dr_test (id serial, ts timestamptz DEFAULT now()); INSERT INTO dr_test DEFAULT VALUES; SELECT * FROM dr_test; DROP TABLE dr_test;\""
```

**Важно:** после этого данные есть на elated-dijkstra. Приложения нужно
перенастроить на него (пока старый primary лежит).

#### Этап C: Возврат старого primary через pg_rewind

Теперь appuse догоним до нового primary и включим как реплику.

```bash
# 7. Проверить, что старый primary (appuse) не работает
ssh appuse 'pg_lsclusters'
# Если статус не down — остановить: pg_ctlcluster 16 main stop

# 8. На старом primary (appuse) — настроить pg_hba для подключения нового primary
#    через SSH-туннель (новый primary будет подключаться как standby)
#    Ничего делать не нужно — pg_hba уже разрешает 127.0.0.1

# 9. На старом primary (appuse) — выполнить pg_rewind
#    Эта команда откатывает "разошедшиеся" WAL на старом primary до состояния
#    нового primary, сохраняя пользовательские данные.
ssh appuse "sudo -u postgres PGPASSWORD='ПАРОЛЬ' pg_rewind \
  -D /var/lib/postgresql/16/main \
  --source-server='host=146.185.235.4 port=5433 user=replicator password=ПАРОЛЬ' \
  -P"

#    Пояснение: --source-server указывает на туннельный порт 5433, который
#    сейчас должен быть настроен в другую сторону. Если туннель ещё не
#    переконфигурирован — можно использовать IP нового primary напрямую
#    (если порт открыт) или переделать туннель.
#
#    Альтернатива: заново снять pg_basebackup (медленнее, но проще).
```

#### Этап D: Настройка нового primary как источника

После pg_rewind старый primary (appuse) будет в состоянии "готов к старту
как standby". Нужно:

```bash
# 10. Создать standby.signal на appuse
ssh appuse 'touch /var/lib/postgresql/16/main/standby.signal'
ssh appuse 'chown postgres:postgres /var/lib/postgresql/16/main/standby.signal'

# 11. Настроить primary_conninfo на appuse — чтобы он тянул данные
#     с нового primary (elated-dijkstra, 89.127.200.68)
ssh appuse 'cat > /etc/postgresql/16/main/conf.d/standby.conf << STANDYCONF
primary_conninfo = '\''host=89.127.200.68 port=5432 user=replicator password=ПАРОЛЬ'\''
hot_standby = on
STANDYCONF'

# 12. Запустить PostgreSQL на appuse
ssh appuse 'pg_ctlcluster 16 main start'

# 13. Проверить статус — appuse должен быть online,recovery
ssh appuse 'pg_lsclusters'
# 16  main    5432 online,recovery postgres ...

# 14. На новом primary (elated-dijkstra) проверить, что appuse виден как реплика
ssh elated-dijkstra "sudo -u postgres psql -c \"SELECT client_addr, state FROM pg_stat_replication;\""
```

#### Этап E: Возврат в исходную топологию (appuse ← primary, Германия ← standby)

Восстанавливаем исходную топологию — appuse снова primary, elated-dijkstra —
standby.

```bash
# 15. Остановить appuse (сейчас он standby)
ssh appuse 'pg_ctlcluster 16 main stop'

# 16. Удалить standby.signal и primary_conninfo на appuse
ssh appuse 'rm -f /var/lib/postgresql/16/main/standby.signal /etc/postgresql/16/main/conf.d/standby.conf'

# 17. Запустить appuse как primary
ssh appuse 'pg_ctlcluster 16 main start'
ssh appuse 'pg_lsclusters'
# 16  main    5432 online postgres ... (без recovery)

# 18. На elated-dijkstra (сейчас primary) — переделать его обратно в standby
#     Остановить, снести данные, снять pg_basebackup, настроить standby
ssh elated-dijkstra 'pg_ctlcluster 16 main stop'
ssh elated-dijkstra 'rm -rf /var/lib/postgresql/16/main'

# 19. Снять свежий бэкап с appuse (через SSH-туннель)
sudo -u postgres PGPASSWORD='ПАРОЛЬ' pg_basebackup \
  -h localhost -p 5433 -U replicator \
  -D /var/lib/postgresql/16/main -P -v --wal-method=stream

# 20. Включить standby-режим
ssh elated-dijkstra 'touch /var/lib/postgresql/16/main/standby.signal && chown postgres:postgres /var/lib/postgresql/16/main/standby.signal'

# 21. Настроить primary_conninfo обратно на туннель
#     (файл уже должен быть, проверить/пересоздать)

# 22. Запустить
ssh elated-dijkstra 'pg_ctlcluster 16 main start'
```

После этого топология исходная:
- appuse — primary
- elated-dijkstra — standby через SSH-туннель

**Коротко про pg_rewind:** утилита синхронизирует только разошедшуюся часть
WAL между старым и новым primary, не требуя полного копирования. Это сильно
быстрее pg_basebackup при больших объёмах данных (минуты вместо часов).
Работает только с `wal_log_hints = on` или `data_checksums = on`.

### 11.3. Synchronous replication (синхронный режим)

В асинхронном режиме primary не ждёт, пока standby запишет данные. Если нужно
гарантировать "ноль потерь" — включить синхронный режим (но это увеличит
latency на запись).

### 11.4. Полезные команды

```bash
# На primary — все реплики
SELECT client_addr, application_name, state, sync_state, write_lag, flush_lag, replay_lag FROM pg_stat_replication;

# На standby — отставание в байтах
SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());

# На primary — размер отставания для каждой реплики
SELECT application_name,
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lag) AS bytes_behind
FROM pg_stat_replication;

# На primary — физические слоты репликации
SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;
```

---

## Полная схема нашей конфигурации

```
Ваш Mac                     appuse (primary)              elated-dijkstra (standby)
┌─────────────┐              ┌─────────────────┐          ┌──────────────────────┐
│ ssh appuse  │─── туннель   │ PostgreSQL 16    │          │ PostgreSQL 16        │
│ ssh elated- │   через мак  │  :5432           │          │  :5432               │
│ dijkstra    │              │                  │          │      ↑               │
│             │              │  pg_hba:         │          │  localhost:5433      │
│ ~/.ssh/     │              │  127.0.0.1/32    │          │      ↑               │
│  appuse     │              │  scram-sha-256   │          │  autossh (pg-tunnel) │
│  elated-    │              │                  │          │      ↑               │
│  dijkstra   │              │  replicator      │          │  SSH → primary:22    │
└─────────────┘              │  пароль...       │          └──────────────────────┘
                              └─────────────────┘
```

**Поток данных:**
`postgres на standby → localhost:5433 → autossh/ssh → primary:22 → localhost:5432 → postgres на primary`

---

## Приложение: вопросы на собеседовании DBA по теме репликации

### Базовые

**Q: Чем physical replication отличается от logical?**
A: Physical копирует весь кластер на уровне WAL (все базы, роли, схемы).
Logical — выборочно, через декодирование WAL в SQL, можно реплицировать
отдельные таблицы между разными версиями PostgreSQL.

**Q: Что такое WAL?**
A: Write-Ahead Log — журнал изменений. PostgreSQL сначала пишет в WAL,
потом в data files. Репликация читает WAL и применяет на standby.

**Q: В чём разница между синхронной и асинхронной репликацией?**
A: Синхронная — primary ждёт подтверждения от standby (гарантия 0 потерь,
но выше latency). Асинхронная — не ждёт (быстрее, но возможна потеря
последних транзакций при падении primary).

**Q: Что такое слот репликации?**
A: Гарантирует, что primary не удалит WAL, нужный отставшему standby.
Без слота — если standby отстал, WAL может быть перезаписан.

### Средние

**Q: Как узнать отставание реплики?**
A: `pg_stat_replication.write_lag / flush_lag / replay_lag` на primary.
`pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())` на standby.

**Q: Что такое pg_rewind и зачем он нужен?**
A: После promote одного узла и возврата старого primary — pg_rewind
откатывает «разошедшиеся» WAL, не требуя полного pg_basebackup.
Работает только с `wal_log_hints=on` или `data_checksums=on`.

**Q: Почему может не работать репликация?**
A: Firewall, pg_hba.conf (нет записи для standby), неправильный пароль,
разные мажорные версии PostgreSQL, несовпадение архитектур, нет места
на диске standby, слот репликации неактивен.

### Продвинутые

**Q: Что такое cascade replication?**
A: Standby может принимать репликацию не напрямую от primary, а от другого
standby. Снижает нагрузку на primary.

**Q: Как сделать switchover без потери данных?**
A: Переключить синхронную репликацию, дождаться sync-состояния, выполнить
promote на standby, переключить приложения.

**Q: Какие подводные камни у SSH-туннеля для репликации?**
A: TCP-over-TCP — при потерях пакетов деградация из-за двойного контроля
передачи. Альтернатива: WireGuard (UDP-туннель, нет этой проблемы).
