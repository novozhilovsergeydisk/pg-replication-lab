# CI/CD для PostgreSQL: автоматический деплой через GitHub Actions

## Как это работает

1. Вы пушите изменения в конфиги PostgreSQL на GitHub
2. GitHub Actions запускает workflow
3. По SSH подключается к серверам
4. Применяет изменения и перезагружает конфиг

## Настройка

### Шаг 1. Добавить секреты в GitHub

В репозитории → **Settings → Secrets and variables → Actions** → **New repository secret**:

| Secret | Значение |
|--------|----------|
| `PRIMARY_HOST` | `146.185.235.4` (appuse) |
| `STANDBY_HOST` | `89.127.200.68` (elated-dijkstra) |
| `SSH_PRIVATE_KEY` | Содержимое `~/.ssh/appuse` (закрытый ключ) |

**SSH_PRIVATE_KEY** — скопируйте целиком:
```bash
cat ~/.ssh/appuse
# скопировать вывод, вставить в секрет
```

### Шаг 2. Создать папку с конфигами

В корне репозитория создать `config/pg/` и положить туда нужные файлы:
- `postgresql.conf`
- `pg_hba.conf`
- `standby.conf`

Workflow будет копировать их на сервер при пуше.

### Шаг 3. Проверить работу

Изменить любой файл в `config/pg/`, закоммитить, запушить. Через минуту
зайти в **Actions** на GitHub → увидеть выполнение workflow.

## Что можно автоматизировать

- ✅ Применение новых параметров `postgresql.conf`
- ✅ Обновление `pg_hba.conf` (новые правила доступа)
- ✅ Запуск `VACUUM` / `ANALYZE` по расписанию
- ✅ Рассылка уведомлений в Telegram/Slack при сбоях
- ✅ Автоматический pg_dump и загрузка в S3

## Шаблон

Файл `.github/workflows/deploy.yml` уже создан в репозитории. Его нужно
только довести до ума под свои задачи.
