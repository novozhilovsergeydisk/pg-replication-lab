#!/usr/bin/env bash
# Тест по общим вопросам PostgreSQL (для самопроверки)
# Запуск: bash pg-quiz.sh

set -e

SCORE=0
TOTAL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ask() {
    local question="$1"
    local answer="$2"
    local hint="$3"
    TOTAL=$((TOTAL + 1))

    echo ""
    echo -e "${CYAN}Вопрос #$TOTAL${NC}"
    echo -e "${YELLOW}$question${NC}"
    echo "----------------------------------------"
    echo -n "Ваш ответ: "
    read user_answer

    # нормализуем: нижний регистр, удаляем пробелы по краям
    normalized_user=$(echo "$user_answer" | tr '[:upper:]' '[:lower:]' | xargs)
    normalized_answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]' | xargs)

    if [ "$normalized_user" = "$normalized_answer" ]; then
        echo -e "${GREEN}✓ Верно!${NC}"
        SCORE=$((SCORE + 1))
    else
        echo -e "${RED}✗ Неверно.${NC}"
        echo -e "Правильный ответ: ${GREEN}$answer${NC}"
        if [ -n "$hint" ]; then
            echo -e "Пояснение: ${YELLOW}$hint${NC}"
        fi
    fi
    echo ""
    echo "Нажмите Enter для продолжения..."
    read
}

ask_advanced() {
    local question="$1"
    local correct=0
    local answers=()
    local idx=0
    TOTAL=$((TOTAL + 1))

    echo ""
    echo -e "${CYAN}Вопрос #$TOTAL (выберите один или несколько)${NC}"
    echo -e "${YELLOW}$question${NC}"
    echo "----------------------------------------"

    # сдвигаем аргументы: вопрос, правильные индексы (через запятую), варианты...
    local correct_indices="$2"
    shift 2

    local i=1
    for opt in "$@"; do
        echo "  $i) $opt"
        answers[$i]="$opt"
        i=$((i + 1))
    done

    echo ""
    echo -n "Введите номер(а) через пробел: "
    read -a choices

    local user_correct=1
    for c in "${choices[@]}"; do
        if ! echo "$correct_indices" | grep -q "\b$c\b"; then
            user_correct=0
        fi
    done

    # также проверим, что выбраны все правильные
    local correct_count=0
    IFS=',' read -ra correct_arr <<< "$correct_indices"
    for c in "${correct_arr[@]}"; do
        c=$(echo "$c" | xargs)
        local found=0
        for uc in "${choices[@]}"; do
            if [ "$uc" = "$c" ]; then
                found=1
                break
            fi
        done
        if [ $found -eq 0 ]; then
            user_correct=0
        fi
    done

    if [ $user_correct -eq 1 ]; then
        echo -e "${GREEN}✓ Верно!${NC}"
        SCORE=$((SCORE + 1))
    else
        echo -e "${RED}✗ Неверно.${NC}"
        echo -e "Правильный ответ: ${GREEN}$correct_indices${NC}"
    fi
    echo ""
    echo "Нажмите Enter для продолжения..."
    read
}

clear
echo "========================================"
echo "  ТЕСТ: Общие вопросы по PostgreSQL"
echo "  25 вопросов. Для ответа — Enter."
echo "========================================"

# ===== ПРОЦЕССЫ =====

ask "Как называется главный процесс PostgreSQL, родитель всех остальных?" \
     "postmaster" \
     "Он запускается первым и порождает остальные процессы (checkpointer, bgwriter, walwriter, и т.д.)"

ask_advanced "Какие процессы относятся к WAL?" \
    "2,4" \
    "checkpointer" \
    "walwriter" \
    "bgwriter" \
    "archiver" \
    "autovacuum launcher"

# ===== EXPLAIN =====

ask_advanced "Какие узлы плана выполняют JOIN?" \
    "2,5,6" \
    "Seq Scan" \
    "Nested Loop" \
    "Index Scan" \
    "Index Only Scan" \
    "Hash Join" \
    "Merge Join"

ask "Как называется узел плана, читающий только индекс без обращения к таблице?" \
    "Index Only Scan" \
    "Помечается как Index Only Scan в EXPLAIN. Данные берутся только из индекса."

ask "Какая команда показывает реальное время выполнения запроса и плана?" \
    "EXPLAIN ANALYZE" \
    "EXPLAIN ANALYZE выполняет запрос и показывает фактические затраты."

ask "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)"

# ===== ТЮНИНГ =====

ask "Какой параметр определяет объём памяти под кеш данных PostgreSQL? (в процентах от RAM)" \
    "shared_buffers" \
    "Обычно 15-25% от RAM. Для сервера с 4 GB — примерно 1 GB."

ask "Какой параметр нужно увеличить для SSD-дисков относительно HDD?" \
    "random_page_cost" \
    "Для SSD ставят 1.1, для HDD — 4.0. Это говорит планировщику, что random read — быстрый."

ask "Какой параметр подсказывает планировщику размер файлового кеша ОС?" \
    "effective_cache_size" \
    "50-75% от RAM. Чем выше — тем чаще планировщик выбирает Index Scan вместо Seq Scan."

# ===== VACUUM / AUTOVACUUM =====

ask "Что удаляет VACUUM?" \
    "мёртвые строки" \
    "PostgreSQL не удаляет строки сразу (MVCC), а помечает как dead. VACUUM очищает это место."

ask_advanced "Какие утверждения про VACUUM верны?" \
    "1,3" \
    "VACUUM не блокирует чтение/запись" \
    "VACUUM FULL не блокирует таблицу" \
    "VACUUM FREEZE защищает от wraparound" \
    "VACUUM дефрагментирует индексы"

ask "Как называется автоматический сборщик мусора в PostgreSQL?" \
    "autovacuum" \
    "Включён по умолчанию. Запускается каждую минуту (autovacuum_naptime)."

ask "Какой параметр задаёт минимальное количество мёртвых строк для запуска autovacuum?" \
    "autovacuum_vacuum_threshold" \
    "По умолчанию 50. Второй параметр — autovacuum_vacuum_scale_factor (по умолчанию 0.2)."

# ===== pg_stat_statements / мониторинг =====

ask "Какое расширение собирает статистику по всем запросам?" \
    "pg_stat_statements" \
    "Показывает calls, total_time, rows, mean_time. Основной инструмент поиска медленных запросов."

ask "Какое системное представление показывает текущие подключения и их запросы?" \
    "pg_stat_activity" \
    "Поля: pid, state (active/idle), query, wait_event, backend_start."

ask "Как завершить зависшее подключение по PID?" \
    "pg_terminate_backend" \
    "SELECT pg_terminate_backend(pid);"

# ===== БЛОКИРОВКИ =====

ask_advanced "Какие из перечисленного — row-level блокировки?" \
    "2,4" \
    "ACCESS EXCLUSIVE" \
    "FOR UPDATE" \
    "ROW EXCLUSIVE" \
    "FOR SHARE" \
    "ACCESS SHARE"

ask "Как узнать, какие процессы блокируют текущий запрос?" \
    "pg_blocking_pids" \
    "SELECT pg_blocking_pids(pid);"

# ===== PgBouncer =====

ask "Как называется лёгкий connection pooler для PostgreSQL?" \
    "PgBouncer" \
    "Позволяет держать сотни клиентских подключений при небольшом пуле к БД."

ask_advanced "Какие режимы работы есть у PgBouncer?" \
    "1,2,3" \
    "Session pooling" \
    "Transaction pooling" \
    "Statement pooling"

# ===== БЭКАПЫ =====

ask "Какая утилита делает физическую копию кластера на лету без остановки БД?" \
    "pg_basebackup" \
    "Используется для настройки репликации и бэкапов."

ask "Какой инструмент подходит для бэкапа кластеров几百 GB/TB (S3, шифрование, параллельность)?" \
    "pgbackrest" \
    "Или wal-g. Оба умеют параллельный бэкап, сжатие, шифрование, бэкап в S3."

# ===== ИТОГ =====

echo ""
echo "========================================"
echo -e "  Результат: ${GREEN}$SCORE из $TOTAL${NC}"
echo "========================================"
PERCENT=$((SCORE * 100 / TOTAL))
if [ "$PERCENT" -ge 80 ]; then
    echo -e "${GREEN}Отлично!$NC"
elif [ "$PERCENT" -ge 60 ]; then
    echo -e "${YELLOW}Хорошо, но есть над чем поработать.${NC}"
else
    echo -e "${RED}Стоит повторить материал.${NC}"
fi
echo "========================================"
