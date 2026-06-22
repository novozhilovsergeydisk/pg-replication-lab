# Практикум: физическое резервирование PostgreSQL (primary → standby)

Учебный стенд для отработки **физического резервирования** кластера PostgreSQL.
Охватывает **потоковую** (streaming) и **файловую** (archive-based) репликацию,
настройку SSH-туннеля, failover и pg_rewind.

Главная идея — практику можно **повторять сколько угодно раз**: всё крутится в
отдельном **учебном кластере** (`training`) на отдельном порту (`5433`), который
создаётся и сносится одной командой и **не трогает системный PostgreSQL** (5432)
и боевые данные. Когда отработаете — те же шаги переносятся на реальную БД
сменой нескольких значений в `config.env`.

```
master (источник, primary)            replica (приёмник, standby)
  кластер training :5433  ──TLS──▶       кластер training :5433
  слот training_slot                     pg_basebackup + стриминг WAL
```

---

## 0. Требования

- Оба сервера — **Debian/Ubuntu**, одинаковая **мажорная версия PostgreSQL** и
  одинаковая архитектура (amd64/amd64). Физическая репликация этого требует.
- Root или sudo на обоих серверах.
- Сетевая связность: реплика может подключиться к мастеру на порт `5433` (TCP).
- Установленный PostgreSQL нужной версии. Для конкретной версии удобно подключить
  официальный репозиторий PGDG:

  ```bash
  sudo apt install -y curl ca-certificates
  sudo install -d /usr/share/postgresql-common/pgdg
  sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
    https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list
  sudo apt update
  sudo apt install -y postgresql-16   # подставьте свою версию
  ```

  Узнать установленные кластеры/версии: `pg_lsclusters`.

---

## 1. Установка стенда

Скопируйте эту папку **на оба сервера** (например, `scp -r` или `git clone`), затем
на каждом сервере подготовьте конфиг:

```bash
cp config.env.example config.env
nano config.env        # PG_VERSION, MASTER_HOST, REPLICA_HOST, SSLMODE
chmod +x *.sh master/*.sh replica/*.sh
```

`config.env` одинаковый на обоих серверах. Пароль роли репликации **в нём не
хранится** — он спрашивается при запуске или передаётся через переменную
окружения `REPL_PASSWORD`.

---

## 2. Безопасность (трафик идёт через интернет)

1. **Firewall.** Откройте учебный порт только для второго сервера.
   На мастере:
   ```bash
   sudo ufw allow from <IP_РЕПЛИКИ> to any port 5433 proto tcp
   ```
2. **TLS обязателен.** `create-master.sh` генерирует самоподписанный сертификат.
   Для `SSLMODE=verify-ca`/`verify-full` скопируйте его на реплику до её создания:
   ```bash
   scp <МАСТЕР>:/var/lib/postgresql/16/training/server.crt /tmp/master-server.crt
   ```
3. **SSH по ключу.** Рекомендуется перейти с пароля на ключи и затем отключить
   парольный вход. `fail2ban` на доступ к PostgreSQL не влияет (это отдельный
   порт), но при желании добавьте IP второго сервера в `ignoreip` для jail `sshd`.

---

## 3. Запуск практикума

**На мастере** (источник):
```bash
sudo ./master/create-master.sh
# спросит пароль для роли replicator (придумайте и запомните — он же нужен реплике)
```
Затем откройте порт и скопируйте сертификат (см. раздел 2).

**На реплике** (приёмник):
```bash
sudo ./replica/create-replica.sh
# спросит тот же пароль роли replicator
```

**Проверка** (на любом сервере):
```bash
sudo ./verify.sh
```
- На мастере увидите реплику в `pg_stat_replication` (`state=streaming`) и слот
  (`active=t`).
- На реплике увидите `pg_stat_wal_receiver` (`status=streaming`) и отставание в
  секундах.

**Тест «запись → чтение»:**
```bash
# на мастере:
sudo -u postgres psql -p 5433 -c "INSERT INTO repl_demo(note) VALUES ('проверка');"
# на реплике через 1–2 сек:
sudo -u postgres psql -p 5433 -c "SELECT max(id), count(*) FROM repl_demo;"
```
Реплика только для чтения — `INSERT` на ней вернёт ошибку, и это правильно.

---

## 4. Повтор практикума (создать/удалить заново)

Снести учебный кластер **на каждом сервере**:
```bash
sudo ./teardown.sh
```
Порядок при повторе: сначала `teardown.sh` на реплике, потом на мастере (так
слот гарантированно убирается вместе с мастером). Затем заново
`create-master.sh` → `create-replica.sh`.

Предохранители (`guard_training_cluster`) не дадут `teardown.sh` тронуть ничего,
кроме кластера `training` на порту `5433`.

---

## 5. Учебный failover и возврат старого мастера

Сценарий: «мастер отказал → повышаем реплику → возвращаем старый мастер как
новую реплику» — без полного копирования, через `pg_rewind`.

1. **Имитируем отказ мастера** (на мастере):
   ```bash
   sudo pg_ctlcluster 16 training stop
   ```
2. **Повышаем реплику до primary** (на реплике):
   ```bash
   sudo ./replica/failover.sh
   ```
   Теперь запись идёт на бывшую реплику. Проверка: `sudo ./verify.sh`.
3. **Возвращаем старый мастер как новую реплику** (на старом мастере):
   ```bash
   sudo ./master/rewind-old-master.sh
   ```
   `pg_rewind` синхронизирует только разошедшуюся часть данных (это возможно
   благодаря `wal_log_hints=on` и контрольным суммам, которые включает
   `create-master.sh`) и настроит узел как standby нового primary.

Подготовка для этого уже заложена в `create-*.sh`: правила `hostssl` в обе
стороны и гранты роли `replicator` на функции, нужные `pg_rewind`.

> **Замечания для прода.** Для failback мы используем `sslmode=require`
> (шифрование без проверки сертификата), чтобы не раздавать сертификаты в обе
> стороны на учебном стенде. На проде распределите сертификаты обоих узлов и
> используйте `verify-ca`/`verify-full`, а для `pg_rewind` заведите отдельную
> роль с минимальными правами вместо переиспользования `replicator`. Также после
> возврата мастера имеет смысл создать на новом primary физический слот для него.

Всегда работающая (но более медленная) альтернатива `pg_rewind` — заново снять
базовую копию: на старом мастере поменять роли в `config.env` местами и запустить
`create-replica.sh`.

---

## 6. Перенос на реальную БД

Логика 1:1 переносится на боевой кластер. Отличия:
- работаете со штатным кластером (обычно `main`, порт `5432`), а не `training`;
- базовую копию снимаете тем же `pg_basebackup` со слотом и TLS;
- параметры из `master/create-master.sh` (`wal_level`, `max_wal_senders`,
  слот, `pg_hba` с `hostssl`) применяете к боевому `postgresql.conf`/`pg_hba.conf`.

Скрипты намеренно держат всё в переменных `config.env`, чтобы переход свёлся к
смене `CLUSTER_NAME`/`PG_PORT` и аккуратному применению конфигов на проде.
**На проде предохранители не дадут переиспользовать teardown** — это сделано
специально; удалением боевого кластера такие скрипты заниматься не должны.

---

## Структура

```
pg-practikum/
├── README.md                           # этот файл
├── config.env.example                  # шаблон конфига
├── lib.sh                              # общие функции
├── master/create-master.sh             # создать учебный мастер
├── master/rewind-old-master.sh         # pg_rewind
├── replica/create-replica.sh           # создать учебную реплику
├── replica/failover.sh                 # повысить реплику
├── teardown.sh                         # снести кластер
├── verify.sh                           # проверка репликации
│
├── REPLICATION-GUIDE.md                # полное руководство по streaming replication
├── ARCHIVE-REPLICATION-GUIDE.md        # файловая репликация
├── SETUP-PG17-REPLICATION.md           # тренинг: установка PG 17
├── SSH-TUNNEL.md                       # SSH-туннель + WireGuard
├── FAILOVER-COMMANDS.md                # команды failover для серверов
├── INTERVIEW-QUESTIONS.md              # 50 вопросов для собеседования DBA
├── CICD.md                             # CI/CD через GitHub Actions
├── pg-quiz.sh                          # интерактивный тест (25 вопросов)
└── .github/workflows/deploy.yml        # workflow автодеплоя
```

## Диагностика

- Логи: `/var/log/postgresql/postgresql-16-training.log`.
- Реплика не подключается → проверьте firewall (порт 5433), `pg_hba.conf` на
  мастере (`hostssl replication ...`), совпадение пароля, наличие сертификата на
  реплике для `verify-ca`.
- `could not connect ... no pg_hba.conf entry` → адрес реплики не совпал с
  `REPLICA_HOST/32` в правиле; проверьте реальный исходящий IP реплики.
- Слот `active=f` на мастере при работающей реплике → реплика не запущена или не
  достучалась; смотрите её лог.
```
