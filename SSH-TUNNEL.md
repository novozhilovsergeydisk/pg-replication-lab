# SSH-туннель для PostgreSQL streaming replication

## Зачем это нужно

Провайдер блокирует прямые входящие соединения на порт 5432 (и/или не даёт открыть
порт через панель управления / поддержка отвечает долго). SSH-туннель решает
проблему: standby инициирует SSH-соединение к primary и «пробрасывает» PostgreSQL
порт через шифрованный канал.

```
standby (elated-dijkstra)                    primary (appuse)
┌─────────────────────┐                     ┌─────────────────────┐
│  PostgreSQL standby │                     │  PostgreSQL primary │
│  :5432              │                     │  :5432              │
│       ↑             │                     │       ↑             │
│  localhost:5433 ────│─── SSH туннель ────▶│  localhost:5432     │
│       ↑             │  (autossh)          │       ↑             │
│  SSH клиент ────────│─── tcp/22 ─────────▶│  SSH сервер         │
└─────────────────────┘                     └─────────────────────┘
```

---

## Наш случай (appuse → elated-dijkstra)

### Схема

| Сервер | Роль | IP | SSH |
|--------|------|----|-----|
| appuse (mnogoweb.ru) | Primary | 146.185.235.4 | ssh root@146.185.235.4 (порт 22, ключ `~/.ssh/appuse`) |
| elated-dijkstra (fornex) | Standby | 89.127.200.68 | ssh root@89.127.200.68 (порт 22, ключ elated-dijkstra) |

### Что настроено

1. SSH-ключ от appuse скопирован на elated-dijkstra: `/root/.ssh/id_ed25519`
2. На elated-dijkstra запущен `autossh` как systemd-сервис `pg-tunnel.service`
3. Туннель: `localhost:5433` на standby → `localhost:5432` на primary
4. PostgreSQL standby стримит через `localhost:5433`

### Проверка

```bash
# Статус туннеля
ssh elated-dijkstra 'systemctl status pg-tunnel'

# Статус репликации на primary
ssh appuse "sudo -u postgres psql -c \"SELECT application_name, state, sync_state FROM pg_stat_replication;\""

# Статус standby
ssh elated-dijkstra "sudo -u postgres psql -c \"SELECT pg_is_in_recovery();\""
```

### Если туннель упал

`autossh` перезапускает его автоматически. Если нет:

```bash
ssh elated-dijkstra 'systemctl restart pg-tunnel'
```

### Если поддержка Mnogoweb откроет порт 5432

1. Остановить туннель:
   ```bash
   ssh elated-dijkstra 'systemctl stop pg-tunnel && systemctl disable pg-tunnel'
   ```

2. Поменять `primary_conninfo` на прямое соединение:
   ```bash
   ssh elated-dijkstra 'cat > /etc/postgresql/16/main/conf.d/standby.conf << EOF
   primary_conninfo = '\''host=146.185.235.4 port=5432 user=replicator password=<ПАРОЛЬ>'\''
   primary_slot_name = '\'\''
   hot_standby = on
   EOF
   pg_ctlcluster 16 main restart'
   ```

---

## Общий случай: инструкция с нуля

### 1. Требования

- SSH-доступ с **standby** на **primary** по ключу (без пароля)
- `autossh` на standby (`apt install autossh`)
- Оба сервера — Linux

### 2. Копирование SSH-ключа на standby

На **локальной машине** (откуда есть доступ к обоим серверам):

```bash
# скопировать закрытый ключ от primary на standby
cat ~/.ssh/KEY_NAME | ssh root@STANDBY_IP 'cat >> ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519'
```

Либо на **самом standby** сгенерировать новый ключ и добавить его на primary:

```bash
# на standby:
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
ssh-copy-id root@PRIMARY_IP
```

### 3. Проверка SSH с standby на primary

```bash
ssh root@PRIMARY_IP 'echo OK'
```

### 4. Установка autossh (на standby)

```bash
apt update && apt install -y autossh
```

### 5. Создание systemd-сервиса (на standby)

```bash
cat > /etc/systemd/system/pg-tunnel.service << 'EOF'
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
  -L LOCAL_PORT:localhost:PRIMARY_PG_PORT \
  root@PRIMARY_IP \
  -i /root/.ssh/id_ed25519
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
```

Заменить:
- `LOCAL_PORT` — порт на standby, через который будет доступен primary (например, `5433`)
- `PRIMARY_PG_PORT` — порт PostgreSQL на primary (обычно `5432`)
- `PRIMARY_IP` — IP-адрес primary

### 6. Запуск туннеля

```bash
systemctl daemon-reload
systemctl enable pg-tunnel
systemctl start pg-tunnel
systemctl status pg-tunnel
```

### 7. Проверка туннеля

```bash
# с standby:
psql -h localhost -p LOCAL_PORT -U replicator -d postgres -c "SELECT pg_is_in_recovery();"
# должен вернуть f (false) — это primary
```

### 8. Настройка standby

После создания standby через `pg_basebackup` (через туннель: `-h localhost -p LOCAL_PORT`) — указать в `primary_conninfo`:

```ini
# /etc/postgresql/VERSION/main/conf.d/standby.conf
primary_conninfo = 'host=localhost port=LOCAL_PORT user=replicator password=PASSWORD'
hot_standby = on
```

### 9. Переключение на прямое соединение (когда откроют порт)

```bash
# 1. Остановить туннель
systemctl stop pg-tunnel
systemctl disable pg-tunnel

# 2. Поменять primary_conninfo
primary_conninfo = 'host=PRIMARY_IP port=5432 user=replicator password=PASSWORD'

# 3. Перезапустить PostgreSQL
pg_ctlcluster VERSION main restart
```

---

## Дополнительно

### Почему autossh, а не просто ssh

`ssh -L` при обрыве соединения не восстанавливается. `autossh` мониторит
соединение и перезапускает ssh при падении. Это критично для репликации.

### Несколько туннелей

Если нужно пробросить несколько портов — добавьте несколько `-L`:

```bash
ExecStart=/usr/bin/autossh -M 0 \
  -L 5433:localhost:5432 \
  -L 5434:localhost:5432 \
  root@PRIMARY_IP
```

### Безопасность

- `-o "StrictHostKeyChecking=no"` удобно при первой настройке, но в проде
  уберите его и добавьте fingerprint primary в `~/.ssh/known_hosts` заранее:
  ```bash
  ssh-keyscan -H PRIMARY_IP >> ~/.ssh/known_hosts
  ```
- Пароль в `primary_conninfo` — временная мера. В проде используйте `.pgpass`
  или `pg_service.conf`.
- SSH-ключ на standby должен быть с ограниченными правами (`chmod 600`).

---

## Альтернатива: WireGuard

### Чем WireGuard лучше SSH-туннеля

| Критерий | SSH-туннель | WireGuard |
|----------|-------------|-----------|
| Двойной TCP-over-TCP | Да (проблемы при потерях пакетов) | Нет (UDP-туннель) |
| Разрывы при переконнекте | autossh перезапускает | Автоматически, без потери пакетов |
| Поверхностный порт | Через SSH (22) | Любой UDP-порт |
| Сложность настройки | Просто | Чуть сложнее |
| Можно пустить весь трафик | Нет (только проброшенные порты) | Да (весь L3) |

### Когда выбирать WireGuard

- Провайдер не блокирует UDP
- Есть root на обоих серверах
- Нужен не только PostgreSQL, но и другие сервисы
- Потери пакетов > 0.5% (TCP-over-TCP начнёт деградировать)

### Настройка WireGuard (пошагово)

#### На primary

```bash
# установка
apt update && apt install -y wireguard

# генерация ключей
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
```

Создать `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <содержимое private.key>

# разрешить forwarding
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT

[Peer]
PublicKey = <публичный ключ standby>
AllowedIPs = 10.0.0.2/32
```

#### На standby

```bash
apt update && apt install -y wireguard
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
```

Создать `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.0.0.2/24
PrivateKey = <содержимое private.key>

[Peer]
PublicKey = <публичный ключ primary>
Endpoint = PRIMARY_IP:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

#### Запуск на обоих серверах

```bash
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
```

#### Проверка

```bash
ping 10.0.0.1   # с standby → primary
ping 10.0.0.2   # с primary → standby
```

#### Переключение standby на WireGuard

Поменять `primary_conninfo` на адрес WireGuard:

```ini
primary_conninfo = 'host=10.0.0.1 port=5432 user=replicator password=PASSWORD'
```

После этого SSH-туннель больше не нужен — `systemctl stop pg-tunnel && systemctl disable pg-tunnel`.
