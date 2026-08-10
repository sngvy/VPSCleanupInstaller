#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Запустите от имени root.${NC}"
    exit 1
fi

# --- Определение дистрибутива и пакетного менеджера ---
if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
else
    echo -e "${B_RED}Ошибка: поддерживаются только системы с apt (Ubuntu/Debian) или dnf (Fedora/RHEL). Выход.${NC}"
    exit 1
fi

install_pkg() {
    # install_pkg <apt-имя-пакета> <dnf-имя-пакета>
    local apt_name="$1"
    local dnf_name="$2"
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get install -y "$apt_name" -qq &>/dev/null
    else
        dnf install -y "$dnf_name" -q &>/dev/null
    fi
}

echo -e "${B_CYAN}Обнаружена система: $( [ "$PKG_MANAGER" = "apt" ] && echo "Ubuntu/Debian (apt)" || echo "Fedora/RHEL (dnf)" )${NC}"

if [ "$PKG_MANAGER" = "apt" ]; then
    apt-get update -qq
fi

echo -e "${B_CYAN}Конфигурация автоматической очистки VPS${NC}"

# --- Выбор типа расписания ---
echo -e "\n${B_YELLOW}Выберите частоту очистки:${NC}"
echo -e "1) Каждый день"
echo -e "2) Каждую неделю (с выбором дня)"
echo -e "3) Каждый месяц (с выбором числа)"
read -p "Ваш выбор [1-3]: " SCHEDULE_CHOICE

CRON_DOM="*"
CRON_MON="*"
CRON_DOW="*"

case $SCHEDULE_CHOICE in
    1)
        SCHEDULE_DESC="ежедневно"
        ;;
    2)
        echo -e "\n${B_YELLOW}Выберите день недели:${NC}"
        echo -e "1) Понедельник"
        echo -e "2) Вторник"
        echo -e "3) Среда"
        echo -e "4) Четверг"
        echo -e "5) Пятница"
        echo -e "6) Суббота"
        echo -e "7) Воскресенье"
        read -p "Ваш выбор [1-7]: " DOW_CHOICE
        case $DOW_CHOICE in
            1) CRON_DOW=1; DOW_NAME="понедельникам" ;;
            2) CRON_DOW=2; DOW_NAME="вторникам" ;;
            3) CRON_DOW=3; DOW_NAME="средам" ;;
            4) CRON_DOW=4; DOW_NAME="четвергам" ;;
            5) CRON_DOW=5; DOW_NAME="пятницам" ;;
            6) CRON_DOW=6; DOW_NAME="субботам" ;;
            7) CRON_DOW=0; DOW_NAME="воскресеньям" ;;
            *) echo -e "${B_RED}Неверный выбор. Выход.${NC}"; exit 1 ;;
        esac
        SCHEDULE_DESC="еженедельно по $DOW_NAME"
        ;;
    3)
        echo -e "\n${B_YELLOW}Введите число месяца:${NC}"
        read -p "Ваш выбор [1-31]: " DOM_CHOICE
        if [[ ! "$DOM_CHOICE" =~ ^([1-9]|[12][0-9]|3[01])$ ]]; then
            echo -e "${B_RED}Ошибка: число должно быть от 1 до 31. Выход.${NC}"
            exit 1
        fi
        CRON_DOM="$DOM_CHOICE"
        SCHEDULE_DESC="ежемесячно $DOM_CHOICE числа"
        echo -e "${B_YELLOW}Примечание: в месяцах короче выбранного числа (напр. 30/31 в феврале) запуск в этот месяц будет пропущен — так работает cron.${NC}"
        ;;
    *) echo -e "${B_RED}Неверный выбор. Выход.${NC}"; exit 1 ;;
esac

# --- Запрос времени ---
echo -e "\n${B_YELLOW}Введите время очистки (например, 03:30):${NC}"
read -p "Время [ЧЧ:ММ]: " USER_TIME
if [[ ! "$USER_TIME" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo -e "${B_RED}Ошибка: Неверный формат времени. Используйте ЧЧ:ММ (например, 04:15). Выход.${NC}"
    exit 1
fi
CRON_MIN=$(echo "$USER_TIME" | cut -d: -f2)
CRON_HOUR=$(echo "$USER_TIME" | cut -d: -f1)
CRON_MIN=$((10#$CRON_MIN))
CRON_HOUR=$((10#$CRON_HOUR))

# --- Глубина хранения journalctl ---
echo -e "\n${B_YELLOW}Глубина хранения journalctl в днях (0 - удалять всё):${NC}"
read -p "Дней: " JOURNALCTL_DEPTH
if [[ ! "$JOURNALCTL_DEPTH" =~ ^[0-9]+$ ]]; then
    echo -e "${B_RED}Ошибка: нужно целое число ≥ 0. Выход.${NC}"
    exit 1
fi

# --- Глубина хранения security-логов ---
echo -e "\n${B_YELLOW}Глубина хранения security-логов (syslog/auth.log/ufw.log и др.) в днях (0 - удалять всё):${NC}"
read -p "Дней: " SECLOG_DEPTH
if [[ ! "$SECLOG_DEPTH" =~ ^[0-9]+$ ]]; then
    echo -e "${B_RED}Ошибка: нужно целое число ≥ 0. Выход.${NC}"
    exit 1
fi

if [ "$SECLOG_DEPTH" -gt 0 ] && ! command -v gawk >/dev/null; then
    echo -e "${B_YELLOW}Для частичной очистки security-логов (depth > 0) требуется gawk. Устанавливаю...${NC}"
    install_pkg gawk gawk
fi

# --- fuser (пакет psmisc) нужен для безопасной проверки активных процессов в /tmp ---
if ! command -v fuser >/dev/null; then
    echo -e "${B_YELLOW}Устанавливаю psmisc (нужен для fuser — проверки активных процессов при очистке /tmp)...${NC}"
    install_pkg psmisc psmisc
fi

# --- Docker ---
echo -e "\n${B_YELLOW}Удалять неиспользуемые Docker-контейнеры (включая образы, сети и разделы)? [y/N]:${NC}"
read -p "> " DOCKER_CHOICE
if [[ "$DOCKER_CHOICE" =~ ^[Yy]$ ]]; then
    DOCKER_CLEAN="yes"
else
    DOCKER_CLEAN="no"
fi

# --- Ядра Linux ---
echo -e "\n${B_YELLOW}Удалять неиспользуемые (старые) ядра Linux? [y/N]:${NC}"
read -p "> " KERNEL_CHOICE
if [[ "$KERNEL_CHOICE" =~ ^[Yy]$ ]]; then
    KERNEL_CLEAN="yes"
else
    KERNEL_CLEAN="no"
fi

install_pkg logrotate logrotate

# --- Ротация лога самой уборки: храним только последние 7 дней ---
cat << 'LOGROTATE_EOF' > /etc/logrotate.d/vps-cleanup
/var/log/vps_cleanup.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
}
LOGROTATE_EOF

# --- Генерация скрипта очистки ---
S="/usr/local/bin/vps-cleanup.sh"

cat << 'EOF' > "$S"
#!/bin/bash

JOURNALCTL_DEPTH="__JOURNALCTL_DEPTH__"
SECLOG_DEPTH="__SECLOG_DEPTH__"
DOCKER_CLEAN="__DOCKER_CLEAN__"
KERNEL_CLEAN="__KERNEL_CLEAN__"

LOG_PREFIX="$(date '+%Y-%m-%d %H:%M:%S')"
echo "$LOG_PREFIX Начало очистки VPS"

if [ "$KERNEL_CLEAN" = "yes" ]; then
    if command -v apt-get &>/dev/null; then
        CURRENT_KERNEL=$(uname -r | sed 's/-generic//g')
        OLD_KERNELS=$(dpkg -l | awk '/^ii linux-image-[0-9]/ {print $2}' | grep -v "$CURRENT_KERNEL")
        OLD_HEADERS=$(dpkg -l | awk '/^ii linux-headers-[0-9]/ {print $2}' | grep -v "$CURRENT_KERNEL")
        if [ ! -z "$OLD_KERNELS" ] || [ ! -z "$OLD_HEADERS" ]; then
            apt-get purge -y $OLD_KERNELS $OLD_HEADERS &>/dev/null
        fi
    elif command -v dnf &>/dev/null; then
        dnf remove -y --oldinstallonly --setopt=installonly_limit=2 kernel &>/dev/null
    fi
fi

if command -v apt-get &>/dev/null; then
    apt-get purge -y $(dpkg -l | awk '/^rc/ {print $2}') &>/dev/null
    apt-get autoremove -y &>/dev/null
    apt-get autoclean -y &>/dev/null
    apt-get clean -y &>/dev/null
elif command -v dnf &>/dev/null; then
    dnf autoremove -y &>/dev/null
    dnf clean all -y &>/dev/null
fi

if [ "$JOURNALCTL_DEPTH" -eq 0 ]; then
    journalctl --vacuum-time=1s &>/dev/null
else
    journalctl --vacuum-time="${JOURNALCTL_DEPTH}d" &>/dev/null
fi
systemctl restart systemd-journald &>/dev/null

find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.1" -delete

SECURITY_LOGS="syslog messages auth.log secure kern.log cron.log user.log ufw.log daemon.log"

prune_security_log() {
    local file="$1"
    local depth="$2"

    [ -f "$file" ] || return
    [ -s "$file" ] || return

    if [ "$depth" -eq 0 ]; then
        cat /dev/null > "$file"
        return
    fi

    if ! command -v gawk &>/dev/null; then
        echo "$LOG_PREFIX [WARN] gawk не найден, пропускаю частичную очистку $file"
        return
    fi

    local tmp
    tmp=$(mktemp)

    gawk -v depth="$depth" '
    BEGIN {
        split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
        for (i = 1; i <= 12; i++) monnum[m[i]] = i
        cutoff = systime() - depth * 86400
        cur_year = strftime("%Y")
    }
    {
        mon = $1; day = $2; t = $3
        if (mon in monnum && t ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) {
            split(t, hms, ":")
            epoch = mktime(cur_year" "monnum[mon]" "day+0" "hms[1]" "hms[2]" "hms[3])
            if (epoch == -1 || epoch >= cutoff) print
        } else {
            print
        }
    }
    ' "$file" > "$tmp" 2>/dev/null

    if [ -s "$tmp" ] || [ ! -s "$file" ]; then
        cat "$tmp" > "$file"
    fi
    rm -f "$tmp"
}

for log in $SECURITY_LOGS; do
    prune_security_log "/var/log/$log" "$SECLOG_DEPTH"
done

cleanup_tmp_dir() {
    local dir="$1"
    [ -d "$dir" ] || return
    find "$dir" -mindepth 1 -maxdepth 5 2>/dev/null | sort -r | while read -r f; do
        [ -e "$f" ] || continue
        if command -v fuser &>/dev/null && fuser "$f" &>/dev/null; then
            continue
        fi
        rm -rf "$f" 2>/dev/null
    done
}

cleanup_tmp_dir "/tmp"
cleanup_tmp_dir "/var/tmp"

if [ "$DOCKER_CLEAN" = "yes" ] && command -v docker &>/dev/null; then
    docker system prune -a --volumes -f &>/dev/null
fi

sync
echo 3 > /proc/sys/net/ipv4/route/flush 2>/dev/null

echo "$LOG_PREFIX Очистка завершена"
df -h / | awk 'NR==2 {print "Всего: " $2 " | Занято: " $3 " | Свободно: " $4 " (" $5 ")"}'
EOF

sed -i "s/__JOURNALCTL_DEPTH__/$JOURNALCTL_DEPTH/" "$S"
sed -i "s/__SECLOG_DEPTH__/$SECLOG_DEPTH/" "$S"
sed -i "s/__DOCKER_CLEAN__/$DOCKER_CLEAN/" "$S"
sed -i "s/__KERNEL_CLEAN__/$KERNEL_CLEAN/" "$S"
chmod 700 "$S"

# --- Установка задачи cron ---
C_JOB="$CRON_MIN $CRON_HOUR $CRON_DOM $CRON_MON $CRON_DOW $S >> /var/log/vps_cleanup.log 2>&1"
(crontab -l 2>/dev/null | grep -v "$S" ; echo "$C_JOB") | crontab -

echo -e "\n${B_GREEN}Задача cron успешно создана!${NC}"
echo -e "Очистка будет выполняться ${B_CYAN}${SCHEDULE_DESC}${NC} в ${B_CYAN}${USER_TIME}${NC}."
echo -e "Глубина journalctl: ${B_CYAN}${JOURNALCTL_DEPTH} дн.${NC} | Глубина security-логов: ${B_CYAN}${SECLOG_DEPTH} дн.${NC} | Docker: ${B_CYAN}${DOCKER_CLEAN}${NC} | Старые ядра: ${B_CYAN}${KERNEL_CLEAN}${NC}"
echo -e "Лог выполнения: ${B_CYAN}/var/log/vps_cleanup.log${NC}"
