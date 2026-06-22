# Практикум: файловая (archive-based) репликация PostgreSQL 17

## Чем отличается от потоковой

**Потоковая:** standby подключается к primary по TCP и получает WAL в реальном
времени через `primary_conninfo` и `pg_stat_replication`.

**Файловая:** primary архивирует готовые WAL-файлы в общую директорию (или
передаёт по SCP/SSH), standby периодически забирает их оттуда через
`restore_command`. Между архивом и восстановлением — задержка (до нескольких
минут).

Файловая репликация **не требует** прямого TCP-доступа к порту PostgreSQL, но
нуждается в общем хранилище для WAL-архива.

## Схема

```
primary (appuse)                  shared storage / SSH-доступ          standby (elated-dijkstra)
┌─────────────────┐               ┌──────────────┐                    ┌──────────────────────┐
│ PostgreSQL 17    │──archive──▶  │ WAL archive   │◀──restore──      │ PostgreSQL 17         │
│  :5433           │   command    │  (файлы WAL)  │   command         │  :5432                │
│                  │              └──────────────┘                    │  standby.signal       │
│ wal_level=replica│                                                │  recovery.conf        │
└─────────────────┘                                                 └──────────────────────┘
```

## Варианты файловой репликации

### Вариант A: SCP на standby (наша конфигурация)

Primary отправляет WAL на standby через SCP. Подходит, когда нет общего NFS/S3.

### Вариант B: общая NFS-шара

Оба сервера монтируют одну NFS-директорию. Primary пишет, standby читает.

### Вариант C: объектное хранилище (S3)

WAL архивируется в S3 (через `wal-g`, `pgbackrest`), standby забирает оттуда.

Мы рассмотрим **Вариант A** — через SCP на standby (elated-dijkstra), так как
у нас уже настроен SSH-доступ standby → primary.

---

## 1. Подготовка primary (PG 17 на appuse)

### 1.1. Проверить параметры

Подключитесь к primary и проверьте текущие настройки:

```sql
SHOW wal_level;
SHOW archive_mode;
SHOW archive_command;
```

### 1.2. Настроить archive_mode и archive_command

На primary (appuse) отредактировать `/etc/postgresql/17/main/postgresql.conf`:

```ini
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/17/wal_archive/%f && cp %p /var/lib/postgresql/17/wal_archive/%f'
```

**Пояснение:** `%p` — путь к готовому WAL-файлу, `%f` — имя файла. Команда
проверяет, что файл ещё не скопирован, и копирует его в локальную папку
`wal_archive`.

### 1.3. Создать директорию для архива

```bash
ssh appuse 'mkdir -p /var/lib/postgresql/17/wal_archive && chown postgres:postgres /var/lib/postgresql/17/wal_archive'
```

### 1.4. Перезагрузить конфиг

```bash
sudo -u postgres psql -p 5433 -c "SELECT pg_reload_conf();"
```

### 1.5. Проверить, что архивация работает

```bash
# принудительно переключить WAL-сегмент:
sudo -u postgres psql -p 5433 -c "SELECT pg_switch_wal();"

# проверить, что файлы появились:
ls -la /var/lib/postgresql/17/wal_archive/
```

Если архив пуст — проверьте лог:
```bash
tail /var/log/postgresql/postgresql-17-main.log
```

### 1.6. Настроить права для SCP с primary → standby

Чтобы primary мог отправлять WAL на standby через SCP, нужен SSH-доступ
**с primary на standby**. Проверьте:

```bash
# с primary (appuse):
ssh root@89.127.200.68 'echo OK'
```

Если не работает — скопируйте ключ appuse на standby:
```bash
# на appuse сгенерировать ключ:
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
ssh-copy-id root@89.127.200.68
```

### 1.7. Перенастроить archive_command на SCP

Если архив будет храниться на standby, поменяйте `archive_command`:

```ini
archive_command = 'scp %p root@89.127.200.68:/var/lib/postgresql/17/wal_archive/%f'
```

---

## 2. Подготовка standby (PG 17 на elated-dijkstra)

### 2.1. Создать директорию для архива

```bash
ssh elated-dijkstra 'mkdir -p /var/lib/postgresql/17/wal_archive && chown postgres:postgres /var/lib/postgresql/17/wal_archive'
```

### 2.2. Создать директорию для данных

```bash
ssh elated-dijkstra 'mkdir -p /var/lib/postgresql/17/main && chown postgres:postgres /var/lib/postgresql/17/main'
```

### 2.3. Снять базовую копию с primary

Через SSH-туннель (как в streaming):

```bash
ssh elated-dijkstra "sudo -u postgres PGPASSWORD='<ПАРОЛЬ>' pg_basebackup \
  -h localhost -p 5434 -U replicator_17 \
  -D /var/lib/postgresql/17/main -P -v --wal-method=none"
```

**Важно:** `--wal-method=none` — WAL при бэкапе не передаётся, standby
будет получать их из архива.

```bash
ssh elated-dijkstra 'chmod 0700 /var/lib/postgresql/17/main && chown -R postgres:postgres /var/lib/postgresql/17/main'
```

---

## 3. Запуск файловой репликации

### 3.1. Сигнальный файл

```bash
ssh elated-dijkstra 'touch /var/lib/postgresql/17/main/standby.signal && chown postgres:postgres /var/lib/postgresql/17/main/standby.signal'
```

### 3.2. Настройка restore_command

Создать `/etc/postgresql/17/main/conf.d/standby.conf`:

```ini
restore_command = 'cp /var/lib/postgresql/17/wal_archive/%f %p'
hot_standby = on
```

**Пояснение:** `restore_command` — команда, которую standby вызывает для
каждого недостающего WAL-файла.

### 3.3. Синхронизировать архив

Перед запуском standby нужно скопировать все WAL-файлы с primary:

```bash
# на appuse:
scp /var/lib/postgresql/17/wal_archive/* root@89.127.200.68:/var/lib/postgresql/17/wal_archive/
```

### 3.4. Запустить standby

```bash
ssh elated-dijkstra 'pg_ctlcluster 17 main start && pg_lsclusters'
```

Ожидаемый вывод: `17  main    5432 online,recovery postgres ...`

---

## 4. Проверка файловой репликации

### На primary

```bash
# создать тестовые данные:
sudo -u postgres psql -p 5433 -c "CREATE TABLE test_archive (id serial, ts timestamptz DEFAULT now()); INSERT INTO test_archive DEFAULT VALUES;"

# принудительно переключить WAL:
sudo -u postgres psql -p 5433 -c "SELECT pg_switch_wal();"
```

### На standby

Подождите 1-2 минуты (пока WAL-сегмент заархивируется, скопируется, и standby
его применит):

```bash
sudo -u postgres psql -c "SELECT * FROM test_archive;"
```

Должна появиться та же строка.

### Мониторинг

```bash
# на primary — последний заархивированный WAL:
sudo -u postgres psql -p 5433 -c "SELECT * FROM pg_stat_archiver;"

# на standby — какой WAL сейчас восстанавливается:
sudo -u postgres psql -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_is_in_recovery();"
```

---

## 5. Сравнение с потоковой репликацией

| Параметр | Потоковая | Файловая |
|----------|-----------|----------|
| Задержка | Миллисекунды | Секунды–минуты |
| Сетевое соединение | Постоянный TCP | Периодический SCP/S3 |
| Нужен открытый порт БД | Да (5432) | Нет |
| Сложность | Ниже | Выше (archive_command, restore_command) |
| Защита от перезаписи WAL | Слот репликации | Сам архив |
| Дополнительное хранилище | Нет | Нужен WAL-архив |
| Комбинирование | ✅ Можно подстраховать архивом | ✅ Можно добавить streaming |

### Лучшая практика: streaming + archive (гибрид)

В production часто включают оба режима:

```ini
wal_level = replica
archive_mode = on
archive_command = 'scp %p root@STANDBY:/wal_archive/%f'
max_wal_senders = 5
```

- **Streaming** — основной канал (минимальная задержка)
- **Archive** — fallback (если standby отстал и WAL на primary перезаписан)

---

## 6. Восстановление при отставании

Если standby сильно отстал, а WAL на primary уже перезаписан:

1. **Снять свежий pg_basebackup** (как при настройке)
2. **Скопировать архив** со всеми WAL с primary
3. **Запустить standby** — он догонит через archive, а потом можно
   добавить streaming для снижения задержки

---

## Итог

Файловая репликация — более «грубый» и медленный метод, чем streaming, но:

- Не требует открытого порта PostgreSQL
- Надёжнее при нестабильной сети (файлы сохраняются, даже если второй
  сервер временно недоступен)
- Позволяет восстановиться на любой момент времени (PITR)

В современном production используют **streaming** как основной канал,
а файловую архивацию — как подстраховку и для PITR-восстановления.
