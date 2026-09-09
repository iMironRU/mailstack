#!/usr/bin/env bash
#
# mailstack.sh — развёртывание и обслуживание почтового стека
#                (Poste.io + Nginx Proxy Manager + Portainer + Uptime Kuma)
#
# Самодостаточный скрипт: не требует ничего, кроме bash 4+ и coreutils.
# Запуск на сервере:
#   curl -fsSL https://raw.githubusercontent.com/iMironRU/mailstack/main/mailstack.sh | bash -s -- preflight
#
# Запуск снаружи (с рабочей машины), проверка портов и DNS со стороны интернета:
#   ./mailstack.sh doctor --external --host mail.example.com
#
set -uo pipefail

MAILSTACK_VERSION="0.1.0"

# ─────────────────────────────────────────────────────────────────────────────
# Конфигурация по умолчанию. Переопределяется через .env, флаги или окружение.
# ─────────────────────────────────────────────────────────────────────────────

# Каталог установки на сервере
: "${MAILSTACK_DIR:=/opt/mailstack}"

# Основной домен стенда (mail.$MAIL_DOMAIN, status.$MAIL_DOMAIN, ...)
: "${MAIL_DOMAIN:=}"

# FQDN самого почтового хоста — попадает в HELO/myhostname Postfix
: "${MAIL_HOSTNAME:=}"

# Образы вынесены в переменные: менять версию правкой сгенерированного
# compose бессмысленно — deploy его перезаписывает.
#
# Uptime Kuma закреплён на ветке 1 намеренно. В 2.0 удалена загрузка
# JSON-бэкапа, и перенос конфигурации возможен только копированием
# каталога данных. Переход на :2 делается осознанно и только после
# бэкапа тома — миграция схемы необратима.
: "${KUMA_IMAGE:=louislam/uptime-kuma:1}"
: "${NPM_IMAGE:=jc21/nginx-proxy-manager:latest}"
: "${PORTAINER_IMAGE:=portainer/portainer-ce:latest}"
: "${POSTE_IMAGE:=analogic/poste.io:latest}"
: "${AUTOCONFIG_IMAGE:=nginx:alpine}"

# Минимальные требования к железу
: "${MIN_RAM_MB:=1800}"      # RAM + swap
: "${MIN_DISK_GB:=10}"       # свободно на /
: "${MIN_CPU:=1}"

# Порты, которые должен занять стек. Если их уже кто-то держит — конфликт.
STACK_PORTS=(25 80 81 443 465 587 993 995 3001 9000 9443)

# Пакеты, которые конфликтуют со стеком (занимают почтовые/веб порты на хосте)
CONFLICT_PKGS=(postfix exim4 exim4-daemon-light dovecot-core sendmail
               apache2 nginx bind9 named opendkim opensmtpd)

# DNS-блоклисты для проверки репутации IP.
# ВАЖНО: dnsbl.sorbs.net намеренно исключён — сервис отключён в 2024,
# зона всегда отвечает "чисто" и создаёт ложное ощущение покрытия.
DNSBL_ZONES=(
  zen.spamhaus.org
  bl.spamcop.net
  psbl.surriel.com
  b.barracudacentral.org
  bl.mailspike.net
  all.s5h.net
  cbl.abuseat.org
  dnsbl-1.uceprotect.net
  dnsbl-2.uceprotect.net
  dnsbl-3.uceprotect.net
)

# ─────────────────────────────────────────────────────────────────────────────
# Вывод
# ─────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_DIM=''; C_BLD=''; C_OFF=''
fi

N_PASS=0; N_WARN=0; N_FAIL=0

ok()   { printf '  %s✓%s %-34s %s\n' "$C_GRN" "$C_OFF" "$1" "${2:-}"; N_PASS=$((N_PASS+1)); }
warn() { printf '  %s!%s %-34s %s\n' "$C_YEL" "$C_OFF" "$1" "${2:-}"; N_WARN=$((N_WARN+1)); }
fail() { printf '  %s✗%s %-34s %s\n' "$C_RED" "$C_OFF" "$1" "${2:-}"; N_FAIL=$((N_FAIL+1)); }
info() { printf '  %s·%s %-34s %s\n' "$C_DIM" "$C_OFF" "$1" "${2:-}"; }
head1(){ printf '\n%s%s%s\n' "$C_BLD" "$1" "$C_OFF"; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Утилиты
# ─────────────────────────────────────────────────────────────────────────────

have() { command -v "$1" >/dev/null 2>&1; }

# Проверка TCP-соединения. Работает и на Linux, и на macOS.
# tcp_probe HOST PORT [TIMEOUT] -> 0 если порт принял соединение
tcp_probe() {
  local host=$1 port=$2 tmo=${3:-6}
  if have python3; then
    python3 - "$host" "$port" "$tmo" <<'PY' >/dev/null 2>&1
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=float(sys.argv[3])).close()
except Exception:
    sys.exit(1)
PY
    return $?
  elif have timeout; then
    timeout "$tmo" bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
    return $?
  else
    ( exec 3<>"/dev/tcp/$host/$port" ) >/dev/null 2>&1
    return $?
  fi
}

# Прочитать SMTP-баннер (первая строка ответа сервера)
smtp_banner() {
  local host=$1 port=$2 tmo=${3:-8}
  have python3 || return 1
  python3 - "$host" "$port" "$tmo" <<'PY' 2>/dev/null
import socket, sys
try:
    s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=float(sys.argv[3]))
    s.settimeout(float(sys.argv[3]))
    print(s.recv(512).decode('utf-8', 'replace').strip().splitlines()[0])
    s.close()
except Exception:
    sys.exit(1)
PY
}

# DNS-запрос. Возвращает значения записи по одному на строку.
# dns_query NAME [TYPE]
#
# При таймауте `dig +short` пишет в stdout служебные строки вида
# ";; connection timed out; no servers could be reached". Без фильтрации
# вызывающий код принимает их за ответ — и проверка DNSBL сообщает о
# несуществующем листинге. Отбрасываем всё, что начинается с ';'.
dns_query() {
  local name=$1 type=${2:-A}
  if have dig; then
    dig +short +time=3 +tries=1 "$name" "$type" 2>/dev/null | grep -v '^;' | grep -v '^[[:space:]]*$'
  elif have host; then
    host -W 3 -t "$type" "$name" 2>/dev/null | awk '/has address|address|text|mail is|domain name/ {print $NF}'
  elif have nslookup; then
    nslookup -type="$type" "$name" 2>/dev/null | awk '/^Address: /{print $2}'
  else
    return 2
  fi
}

# Реверс IPv4 для DNSBL-запроса: 1.2.3.4 -> 4.3.2.1
reverse_ip() {
  awk -F. '{print $4"."$3"."$2"."$1}' <<<"$1"
}

# Назначение порта. Обычной функцией, а не ассоциативным массивом:
# --external запускается с рабочей машины, а на macOS /bin/bash — версии 3.2,
# где `declare -A` ещё не поддерживается.
port_desc() {
  case "$1" in
    25)  echo "SMTP — приём почты от других серверов" ;;
    80)  echo "HTTP — Let's Encrypt challenge и редирект на HTTPS" ;;
    443) echo "HTTPS — webmail и админки за NPM" ;;
    465) echo "SMTPS — отправка клиентом (implicit TLS)" ;;
    587) echo "Submission — отправка клиентом (STARTTLS)" ;;
    993) echo "IMAPS — чтение почты клиентом" ;;
    995) echo "POP3S — чтение почты клиентом" ;;
    *)   echo "порт $1" ;;
  esac
}

# Внешний IPv4 сервера
detect_public_ip() {
  local ip=''
  if have curl; then
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
      ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
      [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
    done
  fi
  # запасной вариант — адрес на интерфейсе по умолчанию
  if have ip; then
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
  fi
}

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "требуются права root. Запусти через sudo."
}

load_env() {
  local f="${MAILSTACK_ENV:-$MAILSTACK_DIR/.env}"
  # shellcheck disable=SC1090
  [[ -r $f ]] && { set -a; . "$f"; set +a; info ".env загружен" "$f"; }
}

# ─────────────────────────────────────────────────────────────────────────────
# PREFLIGHT — можно ли вообще ставить стек на эту машину
# ─────────────────────────────────────────────────────────────────────────────

check_identity() {
  head1 "Права и окружение"
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    ok "root" "uid=0"
  else
    fail "root" "запущено от $(id -un), нужен root"
  fi
  ok "bash" "${BASH_VERSION%%(*}"
}

check_os() {
  head1 "Операционная система"
  if [[ ! -r /etc/os-release ]]; then
    fail "дистрибутив" "/etc/os-release не найден"
    return
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  local id=${ID:-unknown} ver=${VERSION_ID:-0} pretty=${PRETTY_NAME:-unknown}
  case "$id:$ver" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13)
      ok "дистрибутив" "$pretty" ;;
    ubuntu:*|debian:*)
      warn "дистрибутив" "$pretty — не проверялся, Docker может потребовать ручной установки" ;;
    *)
      fail "дистрибутив" "$pretty — поддерживаются Ubuntu 22.04/24.04, Debian 12/13" ;;
  esac

  local arch; arch=$(uname -m)
  case "$arch" in
    x86_64|amd64|aarch64|arm64) ok "архитектура" "$arch" ;;
    *) fail "архитектура" "$arch — образ analogic/poste.io её не собирает" ;;
  esac

  ok "ядро" "$(uname -r)"
}

check_virtualization() {
  head1 "Виртуализация"
  local virt='unknown'
  have systemd-detect-virt && virt=$(systemd-detect-virt 2>/dev/null)
  case "$virt" in
    kvm|qemu|vmware|xen|microsoft|amazon|none)
      ok "тип гипервизора" "$virt" ;;
    openvz|lxc|lxc-libvirt|docker|podman)
      fail "тип гипервизора" "$virt — вложенный Docker работает ненадёжно" ;;
    *)
      warn "тип гипервизора" "$virt — определить не удалось" ;;
  esac

  # Docker на современных ядрах требует cgroup v2
  if [[ -e /sys/fs/cgroup/cgroup.controllers ]]; then
    ok "cgroups" "v2"
  elif [[ -d /sys/fs/cgroup/memory ]]; then
    warn "cgroups" "v1 — работать будет, но лимиты памяти менее точные"
  else
    fail "cgroups" "не смонтированы"
  fi
}

check_resources() {
  head1 "Ресурсы"
  local cpu ram_mb swap_mb total_mb disk_gb
  cpu=$(nproc 2>/dev/null || echo 1)
  ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
  swap_mb=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
  : "${ram_mb:=0}"; : "${swap_mb:=0}"
  total_mb=$((ram_mb + swap_mb))

  if (( cpu >= MIN_CPU )); then ok "CPU" "${cpu} vCPU"
  else fail "CPU" "${cpu} vCPU, нужно минимум ${MIN_CPU}"; fi

  if (( total_mb >= MIN_RAM_MB )); then
    ok "память" "${ram_mb} MB RAM + ${swap_mb} MB swap"
  else
    fail "память" "${total_mb} MB суммарно, нужно минимум ${MIN_RAM_MB} MB"
  fi

  # Отдельная и очень частая проблема: 2 ГБ RAM без swap.
  # Poste.io без ClamAV занимает ~600-700 МБ, любой пик — и OOM-killer
  # прибивает Dovecot посреди сессии.
  if (( swap_mb == 0 )); then
    if (( ram_mb < 4096 )); then
      warn "swap" "отсутствует при ${ram_mb} MB RAM — 'bootstrap' создаст 2 GB"
    else
      info "swap" "отсутствует, но RAM достаточно"
    fi
  else
    ok "swap" "${swap_mb} MB"
  fi

  disk_gb=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
  : "${disk_gb:=0}"
  if (( disk_gb >= MIN_DISK_GB )); then ok "диск /" "${disk_gb} GB свободно"
  else fail "диск /" "${disk_gb} GB свободно, нужно минимум ${MIN_DISK_GB} GB"; fi
}

check_packages() {
  head1 "Состояние пакетной системы"

  if have dpkg; then
    local broken; broken=$(dpkg --audit 2>/dev/null | head -1)
    if [[ -n $broken ]]; then
      fail "целостность dpkg" "есть незавершённые установки — нужен 'dpkg --configure -a'"
    else
      ok "целостность dpkg" "нарушений нет"
    fi
  fi

  if have apt-mark; then
    local held; held=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
    if [[ -n ${held// /} ]]; then
      warn "held-пакеты" "$held — могут заблокировать установку Docker"
    else
      ok "held-пакеты" "нет"
    fi
  fi

  # Конфликтующие сервисы на хосте. Это главная причина, по которой
  # Poste.io не стартует: порт 25 или 443 уже занят системным Postfix/nginx.
  local found=()
  for p in "${CONFLICT_PKGS[@]}"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed"; then
      found+=("$p")
    fi
  done
  if (( ${#found[@]} )); then
    fail "конфликтующие пакеты" "${found[*]} — займут порты стека, требуется удаление"
  else
    ok "конфликтующие пакеты" "не найдены"
  fi

  if have docker; then
    info "docker" "$(docker --version 2>/dev/null | head -1)"
    if docker compose version >/dev/null 2>&1; then
      info "docker compose" "$(docker compose version --short 2>/dev/null)"
    else
      warn "docker compose" "plugin отсутствует — 'bootstrap' доустановит"
    fi
  else
    info "docker" "не установлен — 'bootstrap' поставит"
  fi
}

check_ports() {
  head1 "Занятость портов"
  if ! have ss && ! have netstat; then
    warn "проверка портов" "нет ни ss, ни netstat"
    return
  fi
  local listening
  if have ss; then listening=$(ss -tlnpH 2>/dev/null)
  else listening=$(netstat -tlnp 2>/dev/null); fi

  local busy=0
  for port in "${STACK_PORTS[@]}"; do
    local line
    line=$(awk -v p=":$port\$" '$4 ~ p {print}' <<<"$listening" | head -1)
    if [[ -n $line ]]; then
      local who
      who=$(grep -oE 'users:\(\("[^"]+"' <<<"$line" | head -1 | sed 's/.*(("//')
      fail "порт $port" "занят${who:+ процессом $who}"
      busy=$((busy+1))
    fi
  done
  (( busy == 0 )) && ok "порты стека" "все ${#STACK_PORTS[@]} свободны"
}

# После развёртывания смысл проверки портов обратный: занятый порт — это
# норма, потому что его держит наш контейнер. Проверка из preflight здесь
# давала десяток ложных ошибок и итог «найдены проблемы» на исправном стеке.
check_ports_listening() {
  head1 "Порты стека"
  have ss || { warn "проверка портов" "нет ss"; return; }
  local listening; listening=$(ss -tlnpH 2>/dev/null)

  local port desc line
  for port in 25 80 443 465 587 993 995; do
    desc=$(port_desc "$port")
    line=$(awk -v p=":$port\$" '$4 ~ p {print}' <<<"$listening" | head -1)
    if [[ -n $line ]]; then
      ok "порт $port" "$desc"
    else
      fail "порт $port" "никто не слушает — $desc"
    fi
  done

  # Админки должны слушать только на петле: docker обходит правила ufw,
  # поэтому единственная защита — привязка к 127.0.0.1
  for port in 81 3001 9000; do
    line=$(awk -v p=":$port\$" '$4 ~ p {print $4}' <<<"$listening" | head -1)
    if [[ -z $line ]]; then
      info "порт $port" "не слушается"
    elif [[ $line == 127.0.0.1:* || $line == "[::1]:"* ]]; then
      ok "порт $port" "только на 127.0.0.1, как и задумано"
    else
      fail "порт $port" "слушает на $line — админка открыта наружу"
    fi
  done
}

check_network() {
  head1 "Сеть и доступность репозиториев"

  if getent hosts download.docker.com >/dev/null 2>&1; then
    ok "DNS-резолвинг" "работает"
  else
    fail "DNS-резолвинг" "download.docker.com не резолвится"
  fi

  if have curl; then
    local code
    for url in https://download.docker.com/linux/ https://registry-1.docker.io/v2/; do
      code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)
      # registry отвечает 401 без токена — это нормально, значит доступен
      if [[ $code =~ ^(200|301|302|401)$ ]]; then
        ok "доступ ${url#https://}" "HTTP $code"
      else
        fail "доступ ${url#https://}" "HTTP ${code:-нет ответа}"
      fi
    done
  else
    warn "curl" "не установлен — проверка доступности пропущена"
  fi

  # Синхронизация времени. Расхождение ломает и валидацию TLS,
  # и подпись DKIM — письма начнут отбиваться без внятной причины.
  if have timedatectl; then
    local synced tz
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    if [[ $synced == yes ]]; then ok "время (NTP)" "синхронизировано, TZ=$tz"
    else warn "время (NTP)" "не синхронизировано — сломает TLS и подпись DKIM"; fi
  fi

  if have ip && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    warn "IPv6" "есть на интерфейсе — нужен AAAA + PTR, иначе часть почты уйдёт без rDNS"
  else
    info "IPv6" "не настроен (для стенда это упрощение, не проблема)"
  fi
}

check_smtp_egress() {
  head1 "Исходящая почта"
  # Провайдеры массово блокируют исходящий 25 для борьбы со спамом.
  # Без него сервер принимает почту, но не может её доставлять.
  if tcp_probe alt1.aspmx.l.google.com 25 8; then
    ok "исходящий порт 25" "открыт"
  else
    warn "исходящий порт 25" "ЗАБЛОКИРОВАН — нужен тикет провайдеру либо relay/smarthost"
  fi
  # 465 и 587 проверяем отдельно: провайдеры, режущие 25, оставляют за
  # собой право закрыть и их. 2525 в такие списки обычно не попадает и
  # служит запасным путём для релея.
  local open_ports='' p
  for p in 587 465 2525; do
    tcp_probe smtp-relay.brevo.com "$p" 6 && open_ports="$open_ports $p"
  done
  if [[ -n $open_ports ]]; then
    ok "исходящие для релея" "открыты:$open_ports"
  else
    fail "исходящие для релея" "587, 465 и 2525 закрыты — релей невозможен"
    hint "Без них и без 25 сервер не сможет отправлять почту вообще."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Репутация IP и обратная зона
# ─────────────────────────────────────────────────────────────────────────────

check_dnsbl() {
  local ip=${1:-}
  head1 "Репутация IP в блоклистах"
  [[ -z $ip ]] && { warn "DNSBL" "не удалось определить внешний IP"; return; }
  if ! have dig && ! have host && ! have nslookup; then
    warn "DNSBL" "нет dig/host/nslookup — установи dnsutils"
    return
  fi

  info "проверяемый IP" "$ip"
  local rev; rev=$(reverse_ip "$ip")
  local listed=0

  for zone in "${DNSBL_ZONES[@]}"; do
    local res; res=$(dns_query "${rev}.${zone}" A | head -1)
    if [[ -z $res ]]; then
      ok "$zone" "чисто"
    elif [[ $res == 127.255.255.* ]]; then
      # Spamhaus отвечает так на запросы от публичных резолверов (8.8.8.8,
      # 1.1.1.1). Это отказ в обслуживании запроса, а НЕ листинг.
      warn "$zone" "запрос отклонён ($res) — используется публичный резолвер"
    elif [[ ! $res =~ ^127\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      # Листинг в DNSBL — всегда адрес из 127.0.0.0/8. Всё остальное это
      # сбой резолвера или мусор, а не ответ. Сообщать о листинге здесь
      # нельзя: ложное «IP в чёрном списке» дороже пропущенной проверки.
      warn "$zone" "не проверено — резолвер вернул '${res:0:48}'"
    else
      local txt; txt=$(dns_query "${rev}.${zone}" TXT | head -1 | tr -d '"')
      fail "$zone" "В СПИСКЕ: $res ${txt:+— $txt}"
      listed=$((listed+1))
    fi
  done
  (( listed > 0 )) && warn "итог" "IP числится в $listed списках — доставка будет страдать"
}

check_rdns() {
  local ip=${1:-}
  head1 "Обратная зона (PTR) и имя хоста"
  local host_fqdn; host_fqdn=$(hostname -f 2>/dev/null || hostname)

  if [[ $host_fqdn == *.*.* || $host_fqdn == *.* ]] && [[ $host_fqdn != localhost* ]]; then
    ok "hostname" "$host_fqdn"
  else
    warn "hostname" "'$host_fqdn' не FQDN — Postfix подставит его в HELO, письма будут отбиваться"
  fi

  [[ -z $ip ]] && return
  local ptr; ptr=$(dns_query "$(reverse_ip "$ip").in-addr.arpa" PTR | head -1)
  ptr=${ptr%.}
  if [[ -z $ptr ]]; then
    warn "PTR" "не задан для $ip — настраивается в панели провайдера, вне Docker"
    return
  fi
  ok "PTR" "$ip -> $ptr"

  # Forward-confirmed rDNS: имя из PTR должно резолвиться обратно в тот же IP.
  # Крупные почтовики (Google, Microsoft) проверяют именно это.
  local fwd; fwd=$(dns_query "$ptr" A | head -1)
  if [[ $fwd == "$ip" ]]; then
    ok "FCrDNS" "$ptr -> $ip, совпадает"
  else
    warn "FCrDNS" "$ptr резолвится в '${fwd:-ничего}', а не в $ip"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DNS-записи домена
# ─────────────────────────────────────────────────────────────────────────────

check_domain_dns() {
  local domain=$1 ip=${2:-}
  head1 "DNS-записи домена $domain"
  local mail_host="${MAIL_HOSTNAME:-mail.$domain}"

  local a; a=$(dns_auth "$mail_host" A | head -1)
  if [[ -z $a ]]; then
    fail "A $mail_host" "не задана — Let's Encrypt не выдаст сертификат"
  elif [[ -n $ip && $a != "$ip" ]]; then
    fail "A $mail_host" "указывает на $a, а сервер имеет $ip"
  else
    ok "A $mail_host" "$a"
  fi

  for sub in status portainer; do
    local sa; sa=$(dns_auth "$sub.$domain" A | head -1)
    if [[ -z $sa ]]; then warn "A $sub.$domain" "не задана"
    elif [[ -n $ip && $sa != "$ip" ]]; then warn "A $sub.$domain" "указывает на $sa"
    else ok "A $sub.$domain" "$sa"; fi
  done

  local mx; mx=$(dns_auth "$domain" MX | head -3 | tr '\n' ' ')
  if [[ -z $mx ]]; then
    fail "MX $domain" "не задана — входящая почта не придёт"
  elif grep -q "${mail_host%.}" <<<"$mx"; then
    ok "MX $domain" "$mx"
  else
    warn "MX $domain" "$mx — не указывает на $mail_host"
  fi

  local spf; spf=$(dns_auth "$domain" TXT | grep -i 'v=spf1' | head -1)
  if [[ -z $spf ]]; then warn "SPF" "запись v=spf1 не найдена"
  else ok "SPF" "${spf:0:70}"; fi

  check_dkim "$domain"

  local dmarc; dmarc=$(dns_auth "_dmarc.$domain" TXT | head -1)
  if [[ -z $dmarc ]]; then warn "DMARC" "запись _dmarc не найдена"
  else ok "DMARC" "${dmarc:0:70}"; fi

  check_relay_dkim "$domain"
}

# DKIM домена.
#
# Селектор не фиксирован: Poste.io генерирует его при создании ключа в виде
# s<дата><число>, а не s1, как в большинстве примеров. Жёстко зашитое имя
# приводило к «запись не найдена» на корректно настроенном домене.
#
# Опубликованный ключ дополнительно сверяется с тем, что лежит на сервере:
# перевыпуск DKIM без обновления DNS ломает подпись молча — письма уходят,
# но проверку у получателя не проходят.
DKIM_SELECTOR=''

detect_dkim_selector() {
  local domain=$1
  [[ -n ${DKIM_SELECTOR:-} ]] && return 0

  # На самом сервере селектор известен точно
  if have docker && docker ps -q -f name=^poste$ 2>/dev/null | grep -q .; then
    local s
    s=$(docker exec poste sh -c "cat /opt/haraka-smtp/config/dkim/$domain/selector 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
    [[ -n $s ]] && { DKIM_SELECTOR=$s; return 0; }
  fi

  # Иначе перебираем распространённые имена
  local cand
  for cand in s1 default mail dkim selector1 k1; do
    [[ -n $(dns_auth "${cand}._domainkey.$domain" TXT | head -1) ]] && { DKIM_SELECTOR=$cand; return 0; }
  done
  return 1
}

check_dkim() {
  local domain=$1
  if ! detect_dkim_selector "$domain"; then
    warn "DKIM" "селектор не определён — ключ ещё не создан в админке Poste.io"
    hint "Создать: Virtual domains → $domain → DKIM → Create (2048 bit)"
    return
  fi

  local rec; rec=$(dns_auth "${DKIM_SELECTOR}._domainkey.$domain" TXT | tr -d '"' | tr -d ' \n')
  if [[ -z $rec ]]; then
    fail "DKIM ($DKIM_SELECTOR)" "ключ на сервере есть, а записи в DNS нет"
    hint "Добавь TXT ${DKIM_SELECTOR}._domainkey с содержимым k=rsa; p=<ключ>"
    return
  fi

  local pub_dns; pub_dns=$(sed -n 's/.*p=\([A-Za-z0-9+/=]*\).*/\1/p' <<<"$rec")
  if [[ -z $pub_dns ]]; then
    warn "DKIM ($DKIM_SELECTOR)" "запись есть, но не содержит p="
    return
  fi

  # Сверяем с ключом на сервере, если он доступен
  if have docker && docker ps -q -f name=^poste$ 2>/dev/null | grep -q .; then
    local pub_srv
    pub_srv=$(docker exec poste sh -c "cat /opt/haraka-smtp/config/dkim/$domain/public 2>/dev/null" 2>/dev/null \
              | grep -v 'BEGIN\|END' | tr -d '[:space:]')
    if [[ -n $pub_srv ]]; then
      if [[ $pub_srv == "$pub_dns" ]]; then
        ok "DKIM ($DKIM_SELECTOR)" "ключ в DNS совпадает с ключом на сервере"
      else
        fail "DKIM ($DKIM_SELECTOR)" "ключ в DNS НЕ совпадает с ключом на сервере"
        hint "Подпись не пройдёт проверку. Обнови TXT-запись актуальным ключом."
      fi
      return
    fi
  fi
  ok "DKIM ($DKIM_SELECTOR)" "опубликован, ${#pub_dns} символов"
}

# DKIM самого релея. Когда почта уходит через smarthost, он подписывает её
# своим ключом — и у него собственные селекторы, отдельные от s1 у Poste.io.
# Проверяется вся цепочка CNAME до публичного ключа: запись может быть
# прописана верно, но указывать на цель, которой у релея ещё нет.
check_relay_dkim() {
  local domain=$1
  [[ -n ${RELAY_HOST:-} ]] || return 0

  local selectors=''
  case "$RELAY_HOST" in
    *brevo*)     selectors='brevo1 brevo2' ;;
    *mailjet*)   selectors='mailjet' ;;
    *sendgrid*)  selectors='s1 s2' ;;
    *resend*)    selectors='resend' ;;
    *) return 0 ;;
  esac

  local sel target key
  for sel in $selectors; do
    target=$(dns_auth "${sel}._domainkey.$domain" CNAME | head -1 | sed 's/\.$//')
    if [[ -z $target ]]; then
      warn "DKIM релея ($sel)" "запись не задана"
      continue
    fi
    # Цепочку доводим до конца через публичный резолвер: цель лежит в
    # чужой зоне, авторитативный сервер нашего домена о ней не знает.
    key=$(dig +short +time=3 +tries=1 TXT "${sel}._domainkey.$domain" @1.1.1.1 2>/dev/null \
          | grep -i 'p=' | head -1)
    if [[ -n $key ]]; then
      ok "DKIM релея ($sel)" "ключ публикуется"
    else
      warn "DKIM релея ($sel)" "$target — цель пока не отдаёт ключ"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Состояние домена: регистрация, делегирование, что уже настроено
#
# Проверяется ДО установки. Домен может быть не делегирован, просрочен,
# закрыт CAA-записью для Let's Encrypt или обслуживать живую почту на чужих
# MX — всё это дешевле обнаружить сейчас, чем после развёртывания.
# ─────────────────────────────────────────────────────────────────────────────

# Подсказка: что конкретно сделать, чтобы починить найденную проблему
hint() { printf '      %s↳ %s%s\n' "$C_DIM" "$1" "$C_OFF"; }

# Авторитативный NS зоны. Проверять записи через системный резолвер нельзя:
# сразу после правок он ещё отдаёт закэшированное старое состояние, и
# инструмент рапортует «записи не заданы», хотя они уже есть. Спрашиваем
# сервер, который за зону отвечает.
AUTH_NS=''

resolve_auth_ns() {
  local domain=$1
  # NS у регистратора — источник, не зависящий ни от какого кэша
  if [[ -n ${DOMAIN_RDAP_NS:-} && $DOMAIN_RDAP_NS != '-' ]]; then
    AUTH_NS=${DOMAIN_RDAP_NS%%,*}
  else
    # запасной путь — публичный резолвер, он обновляется быстрее провайдерского
    AUTH_NS=$(dig +short +time=3 +tries=1 @1.1.1.1 NS "$domain" 2>/dev/null \
              | grep -v '^;' | head -1 | sed 's/\.$//')
  fi
  [[ -n $AUTH_NS ]] && info "источник DNS" "$AUTH_NS (авторитативный, в обход кэша)"
}

# Запрос к авторитативному серверу зоны
dns_auth() {
  local name=$1 type=${2:-A}
  if [[ -n $AUTH_NS ]] && have dig; then
    dig +short +time=3 +tries=1 "@$AUTH_NS" "$name" "$type" 2>/dev/null \
      | grep -v '^;' | grep -v '^[[:space:]]*$'
  else
    dns_auth "$name" "$type"
  fi
}

# Данные о регистрации через RDAP (преемник whois). Отдаёт JSON по HTTP,
# поэтому не требует установленного whois-клиента.
# Печатает: STATUS|EXPIRY_DAYS|REGISTRAR|NS1,NS2,...
#
# Код парсера передаётся через -c, а не heredoc: heredoc занял бы stdin и
# перекрыл JSON, приходящий по пайпу от curl.
RDAP_PARSER='
import sys, json, datetime
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)

status = ",".join(d.get("status", [])) or "-"

expiry_days = "-"
for ev in d.get("events", []):
    if ev.get("eventAction") == "expiration":
        try:
            s = ev["eventDate"].replace("Z", "+00:00")
            exp = datetime.datetime.fromisoformat(s)
            now = datetime.datetime.now(datetime.timezone.utc)
            expiry_days = str((exp - now).days)
        except Exception:
            pass

registrar = "-"
for ent in d.get("entities", []):
    if "registrar" in ent.get("roles", []):
        for item in ent.get("vcardArray", [[], []])[1]:
            if item[0] == "fn":
                registrar = str(item[3])
                break

ns = ",".join(sorted(n.get("ldhName", "").lower().rstrip(".")
              for n in d.get("nameservers", []) if n.get("ldhName")))
print(status + "|" + expiry_days + "|" + registrar + "|" + (ns or "-"))
'

rdap_lookup() {
  local domain=$1
  have curl || return 1
  have python3 || return 1
  # -L обязателен: rdap.org отвечает 302 на RDAP-сервер конкретного TLD
  curl -fsSL --max-time 12 -H 'Accept: application/json' \
       "https://rdap.org/domain/${domain}" 2>/dev/null \
    | python3 -c "$RDAP_PARSER" 2>/dev/null
}

# Резервный источник для зон без публичного RDAP — например .ru и .рф,
# где RDAP не отдаётся вовсе. Формат ответа тот же, что у rdap_lookup.
WHOIS_PARSER='
import sys, re, datetime

domain = sys.argv[1].lower()
text = sys.stdin.read()

# Ответ whois для .ru начинается с блока о самой зоне RU, и поля из него
# нельзя принимать за данные домена. Берём блок, где domain: равен запросу.
block = text
for b in re.split(r"\n\s*\n", text):
    m = re.search(r"^\s*domain(?:\s+name)?:\s*(\S+)", b, re.I | re.M)
    if m and m.group(1).lower().rstrip(".") == domain:
        block = b
        break

def field(*names):
    for n in names:
        m = re.search(r"^\s*" + n + r":\s*(.+?)\s*$", block, re.I | re.M)
        if m:
            return m.group(1)
    return ""

status = field("state", "domain status", "status") or "-"
registrar = field("registrar", "sponsoring registrar") or "-"

expiry_days = "-"
raw = field("paid-till", "registry expiry date", "expiration date",
            "expires", "expiry date", "renewal date")
if raw:
    s = raw.strip().replace("Z", "+00:00")
    for fmt in (None, "%Y-%m-%d", "%d-%b-%Y", "%Y.%m.%d", "%d.%m.%Y"):
        try:
            exp = datetime.datetime.fromisoformat(s) if fmt is None \
                  else datetime.datetime.strptime(s.split("T")[0], fmt)
            if exp.tzinfo is None:
                exp = exp.replace(tzinfo=datetime.timezone.utc)
            expiry_days = str((exp - datetime.datetime.now(datetime.timezone.utc)).days)
            break
        except Exception:
            continue

ns = ",".join(sorted(set(
    n.lower().rstrip(".").split()[0]
    for n in re.findall(r"^\s*(?:nserver|name server):\s*(.+?)\s*$", block, re.I | re.M)
))) or "-"

print(status + "|" + expiry_days + "|" + registrar + "|" + ns)
'

whois_lookup() {
  local domain=$1
  have whois || return 1
  have python3 || return 1
  whois "$domain" 2>/dev/null | python3 -c "$WHOIS_PARSER" "$domain" 2>/dev/null
}

check_domain_registration() {
  local domain=$1
  head1 "Регистрация домена $domain"

  local rd src='RDAP'
  rd=$(rdap_lookup "$domain")
  if [[ -z $rd ]]; then
    # Зоны .ru, .рф и ряд других публичный RDAP не отдают вовсе
    rd=$(whois_lookup "$domain")
    src='whois'
  fi

  if [[ -z $rd ]]; then
    warn "регистрация" "данных нет — ни RDAP, ни whois не ответили"
    have whois || hint "Установи whois: apt-get install -y whois"
    hint "Проверь вручную: whois $domain"
    return
  fi
  info "источник данных" "$src"

  local status days registrar ns
  IFS='|' read -r status days registrar ns <<<"$rd"

  ok "регистратор" "$registrar"

  # clientHold / serverHold означают, что домен исключён из зоны TLD:
  # он зарегистрирован, но не резолвится вообще ничем.
  if [[ $status == *Hold* || $status == *hold* ]]; then
    fail "статус" "$status — домен снят с делегирования регистратором"
    hint "Домен не будет резолвиться, пока статус не снят."
    hint "Обычная причина — неподтверждённый email владельца или неоплата."
  else
    ok "статус" "$status"
  fi

  if [[ $days == '-' ]]; then
    info "срок регистрации" "дата не раскрыта"
  elif (( days < 0 )); then
    fail "срок регистрации" "истёк ${days#-} дн. назад"
    hint "Продли домен до развёртывания — иначе почта встанет вместе с ним."
  elif (( days < 30 )); then
    warn "срок регистрации" "истекает через $days дн."
    hint "Продли заранее: истечение домена останавливает и почту, и продление сертификатов."
  else
    ok "срок регистрации" "ещё $days дн."
  fi

  DOMAIN_RDAP_NS="$ns"
}

check_domain_delegation() {
  local domain=$1
  head1 "Делегирование $domain"

  # SOA — признак того, что зона вообще существует и обслуживается
  local soa; soa=$(dns_auth "$domain" SOA | head -1)
  if [[ -z $soa ]]; then
    fail "зона (SOA)" "не отвечает — домен не делегирован или NS не настроены"
    hint "В панели регистратора укажи NS-серверы своего DNS-провайдера."
    hint "После смены NS делегирование расходится по интернету до 24 часов."
    return 1
  fi
  ok "зона (SOA)" "${soa%% *}"

  # NS, которые реально отвечают за зону
  local zone_ns; zone_ns=$(dns_auth "$domain" NS | sed 's/\.$//' | sort | tr '\n' ',' | sed 's/,$//')
  if [[ -z $zone_ns ]]; then
    fail "NS в зоне" "не найдены"
    return 1
  fi
  ok "NS в зоне" "${zone_ns//,/ }"

  # Сверка с тем, что прописано у регистратора. Расхождение — классическая
  # причина «поменял записи, а ничего не изменилось»: правки вносятся в
  # панель одного DNS-провайдера, а зону обслуживает другой.
  if [[ -n ${DOMAIN_RDAP_NS:-} && $DOMAIN_RDAP_NS != '-' ]]; then
    if [[ $DOMAIN_RDAP_NS == "$zone_ns" ]]; then
      ok "NS у регистратора" "совпадают с зоной"
    else
      # Расхождение бывает двух разных природ, и лечатся они по-разному.
      # Если NS от регистратора отвечает за зону авторитативно — значит
      # делегирование уже переехало, а устаревшие данные отдаёт кэш
      # резолвера. Если не отвечает — зона действительно ведётся не там.
      local first_ns=${DOMAIN_RDAP_NS%%,*} probe
      probe=$(dig +short +time=3 +tries=1 "@$first_ns" SOA "$domain" 2>/dev/null | grep -v '^;')
      if [[ -n $probe ]]; then
        warn "NS у регистратора" "${DOMAIN_RDAP_NS//,/ }"
        hint "Делегирование уже переехало на эти серверы, они отвечают за зону."
        hint "Старые NS показывает кэш резолвера — это пройдёт само по истечении TTL."
        hint "Проверки ниже идут напрямую к авторитативному серверу, в обход кэша."
      else
        warn "NS у регистратора" "${DOMAIN_RDAP_NS//,/ }"
        hint "Списки NS расходятся, и серверы регистратора за зону не отвечают."
        hint "Правки в панели того DNS, который НЕ указан у регистратора,"
        hint "ни на что не влияют — проверь, где ведёшь зону."
      fi
    fi
  fi

  # DNSSEC: при смене DNS-провайдера с включённым DNSSEC и неснятой DS-записью
  # домен перестаёт резолвиться полностью.
  local ds; ds=$(dns_auth "$domain" DS | head -1)
  if [[ -n $ds ]]; then
    warn "DNSSEC" "включён (есть DS-запись)"
    hint "Если будешь менять DNS-провайдера — сначала сними DS у регистратора,"
    hint "иначе домен перестанет резолвиться целиком, а не частично."
  else
    ok "DNSSEC" "не включён"
  fi
  return 0
}

check_domain_caa() {
  local domain=$1
  head1 "CAA — разрешение на выпуск сертификатов"

  local caa; caa=$(dns_auth "$domain" CAA)
  if [[ -z $caa ]]; then
    ok "CAA" "не задана — выпуск разрешён любому CA"
    return
  fi

  local flat; flat=$(tr '\n' ' ' <<<"$caa")
  if grep -qi 'letsencrypt\.org' <<<"$flat"; then
    ok "CAA" "Let's Encrypt разрешён"
  else
    fail "CAA" "$flat"
    hint "CAA-запись есть, но letsencrypt.org в ней не указан — Let's Encrypt"
    hint "откажет в выпуске, а NPM будет молча получать ошибку валидации."
    hint "Добавь запись:  $domain.  CAA  0 issue \"letsencrypt.org\""
  fi
}

check_domain_existing_mail() {
  local domain=$1
  head1 "Что уже настроено на $domain"

  # Живые MX — главный риск: переключив их, можно оборвать работающую почту
  local mx; mx=$(dns_auth "$domain" MX | sort -n | tr '\n' ';' | sed 's/;$//')
  if [[ -z $mx ]]; then
    ok "MX" "не заданы — домен почту не обслуживает, конфликта нет"
  else
    warn "MX" "${mx//;/  }"
    hint "На домене уже настроена почта. Переключение MX на наш сервер"
    hint "оборвёт доставку в текущие ящики. Убедись, что домен свободен."
  fi

  local a; a=$(dns_auth "$domain" A | head -1)
  [[ -n $a ]] && info "A $domain" "$a" || info "A $domain" "не задана"

  # Wildcard перехватывает mail./status./portainer. и ломает выпуск
  # сертификатов незаметным образом: имя резолвится, но не туда.
  local wild; wild=$(dns_auth "test-mailstack-probe.$domain" A | head -1)
  if [[ -n $wild ]]; then
    warn "wildcard *.$domain" "есть — резолвится в $wild"
    hint "Поддомены mail/status/portainer перехватит wildcard. Задай для них"
    hint "явные A-записи, иначе сертификаты выпустятся не на тот адрес."
  else
    ok "wildcard" "нет"
  fi

  local spf; spf=$(dns_auth "$domain" TXT | grep -i 'v=spf1' | head -1)
  [[ -n $spf ]] && warn "SPF (существующий)" "${spf:0:60}" || info "SPF" "не задан"

  # TTL важен для миграции: сутки TTL означают сутки расщеплённой доставки
  local ttl
  ttl=$(dig +noall +answer +time=3 +tries=1 ${AUTH_NS:+@$AUTH_NS} "$domain" SOA 2>/dev/null | awk '{print $2; exit}')
  if [[ -n $ttl ]]; then
    if (( ttl > 3600 )); then
      warn "TTL зоны" "${ttl}s"
      hint "Перед переключением MX и перед миграцией снизь TTL до 300s"
      hint "заранее — иначе смена записей будет расходиться до ${ttl}s."
    else
      ok "TTL зоны" "${ttl}s"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Проверка SMTP-релея
#
# Ошибку в кредах релея иначе видно только по молчащей очереди Postfix:
# письма принимаются, ставятся в очередь и тихо копятся. Проверяем связку
# заранее — соединение, STARTTLS и собственно аутентификацию.
# ─────────────────────────────────────────────────────────────────────────────

RELAY_TEST='
import smtplib, ssl, sys, os

host = sys.argv[1]
port = int(sys.argv[2])
user = os.environ.get("RELAY_USER", "")
# Пароль передаётся окружением, а не аргументом: аргументы видны в ps
password = os.environ.get("RELAY_PASS", "")

try:
    if port == 465:
        srv = smtplib.SMTP_SSL(host, port, timeout=15)
    else:
        srv = smtplib.SMTP(host, port, timeout=15)
        srv.ehlo()
        if srv.has_extn("starttls"):
            srv.starttls(context=ssl.create_default_context())
            srv.ehlo()
        else:
            print("WARN|сервер не предлагает STARTTLS — пароль уйдёт открытым текстом")
except Exception as e:
    print("CONN|" + str(e))
    sys.exit(1)

banner = (srv.ehlo_resp or b"").decode("utf-8", "replace").splitlines()
print("CONN_OK|" + (banner[0] if banner else host))

if not user:
    print("NOAUTH|логин не задан")
    srv.quit()
    sys.exit(0)

try:
    srv.login(user, password)
    print("AUTH_OK|аутентификация принята")
except smtplib.SMTPAuthenticationError as e:
    code = e.smtp_code
    msg = e.smtp_error.decode("utf-8", "replace") if isinstance(e.smtp_error, bytes) else str(e.smtp_error)
    print("AUTH_FAIL|" + str(code) + " " + msg)
except Exception as e:
    print("AUTH_ERR|" + str(e))
finally:
    try:
        srv.quit()
    except Exception:
        pass
'

check_relay() {
  head1 "SMTP-релей"
  if [[ -z ${RELAY_HOST:-} ]]; then
    info "релей" "не настроен"
    return
  fi
  local port=${RELAY_PORT:-587}
  info "релей" "$RELAY_HOST:$port"

  have python3 || { warn "проверка релея" "нужен python3"; return; }

  local out
  out=$(RELAY_USER="${RELAY_USER:-}" RELAY_PASS="${RELAY_PASS:-}" \
        python3 -c "$RELAY_TEST" "$RELAY_HOST" "$port" 2>&1)

  local line kind text
  while IFS= read -r line; do
    kind=${line%%|*}; text=${line#*|}
    case "$kind" in
      CONN_OK)   ok   "соединение" "$text" ;;
      CONN)      fail "соединение" "$text"
                 hint "Проверь хост и порт, а также что исходящий $port не заблокирован." ;;
      AUTH_OK)   ok   "аутентификация" "$text" ;;
      NOAUTH)    warn "аутентификация" "$text" ;;
      AUTH_FAIL) fail "аутентификация" "$text"
                 if [[ ${RELAY_HOST:-} == *brevo* ]]; then
                   # Самая частая ошибка с Brevo: подставляют email аккаунта
                   # вместо выданного логина, либо API key вместо SMTP key.
                   hint "У Brevo логин — не email аккаунта, а адрес вида xxxxx@smtp-brevo.com."
                   hint "Пароль — SMTP key, не API key и не пароль от аккаунта."
                   hint "Оба значения: Settings → SMTP & API → вкладка SMTP."
                   # Отказ на ранее работавших кредах — почти всегда allowlist.
                   # Brevo включает блокировку неизвестных IP автоматически
                   # через 30 дней, поэтому после переезда на другую машину
                   # прежние креды перестают приниматься с нового адреса.
                   hint "Если те же креды раньше работали — проверь список разрешённых IP:"
                   hint "Security → Authorized IPs. После смены сервера новый IP нужно"
                   hint "добавить вручную, иначе Brevo отклонит отправку с него."
                 else
                   hint "Проверь логин и пароль на релее."
                 fi ;;
      AUTH_ERR)  warn "аутентификация" "$text" ;;
      WARN)      warn "STARTTLS" "$text" ;;
    esac
  done <<<"$out"
}

cmd_relay_test() {
  printf '%smailstack relay-test%s v%s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION"
  load_env
  while (( $# )); do
    case "$1" in
      --host) RELAY_HOST=${2:-}; shift 2 ;;
      --port) RELAY_PORT=${2:-}; shift 2 ;;
      --user) RELAY_USER=${2:-}; shift 2 ;;
      *) die "неизвестный флаг relay-test: $1" ;;
    esac
  done

  [[ -n ${RELAY_HOST:-} ]] || die "релей не настроен. Укажи --host или заполни RELAY_* в .env"

  # Пароль не принимаем аргументом — он остался бы в history и в ps
  if [[ -z ${RELAY_PASS:-} ]] && has_tty; then
    printf '  %s?%s Пароль (SMTP key): ' "$C_BLU" "$C_OFF" > /dev/tty
    stty -echo < /dev/tty 2>/dev/null
    IFS= read -r RELAY_PASS < /dev/tty || RELAY_PASS=''
    stty echo < /dev/tty 2>/dev/null
    printf '\n' > /dev/tty
  fi

  check_relay
  summary "Релей работает — письма смогут уходить наружу" "Релей не работает"
}

cmd_domain() {
  local domain='' want_ip=''
  while (( $# )); do
    case "$1" in
      --ip) want_ip=${2:-}; shift 2 ;;
      --dkim-selector) DKIM_SELECTOR=${2:-}; shift 2 ;;
      -*)   die "неизвестный флаг domain: $1" ;;
      *)    domain=$1; shift ;;
    esac
  done
  : "${domain:=${MAIL_DOMAIN:-}}"
  [[ -n $domain ]] || die "укажи домен: mailstack.sh domain example.com"
  printf '%smailstack domain%s v%s — проверка %s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION" "$domain"

  if ! have dig; then
    die "нужен dig. Установи: apt-get install -y dnsutils"
  fi

  # Без --ip сравниваем с адресом машины, где запущена проверка. Это верно
  # на самом сервере, но с рабочей машины даёт ложные расхождения.
  local ip=${want_ip:-$(detect_public_ip)}
  check_domain_registration "$domain"
  resolve_auth_ns "$domain"
  if check_domain_delegation "$domain"; then
    check_domain_caa "$domain"
    check_domain_existing_mail "$domain"
    check_domain_dns "$domain" "$ip"
  fi

  summary "Домен готов к развёртыванию" "Домен требует настройки — см. подсказки выше"
}

# ─────────────────────────────────────────────────────────────────────────────
# Состояние работающего стека
# ─────────────────────────────────────────────────────────────────────────────

check_stack() {
  head1 "Состояние контейнеров"
  if ! have docker; then info "docker" "не установлен — стек ещё не развёрнут"; return; fi
  if ! docker info >/dev/null 2>&1; then fail "docker daemon" "не отвечает"; return; fi
  ok "docker daemon" "работает"

  # userland-proxy подменяет source IP входящих SMTP-соединений на адрес
  # docker-моста. Rspamd тогда видит все письма как пришедшие с 172.17.0.1,
  # и RBL с greylisting перестают работать.
  if [[ -r /etc/docker/daemon.json ]] && grep -q '"userland-proxy"[[:space:]]*:[[:space:]]*false' /etc/docker/daemon.json 2>/dev/null; then
    ok "userland-proxy" "отключён — source IP входящих SMTP сохраняется"
  else
    warn "userland-proxy" "включён — Rspamd увидит все письма с IP docker-моста"
  fi

  local names; names=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
  if [[ -z $names ]]; then info "контейнеры" "нет ни одного"; return; fi
  while read -r n; do
    [[ -z $n ]] && continue
    local status health
    status=$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null)
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$n" 2>/dev/null)
    case "$status" in
      running) [[ -z $health || $health == healthy ]] && ok "$n" "running${health:+ / $health}" \
                                                       || warn "$n" "running / $health" ;;
      restarting) fail "$n" "перезапускается в цикле — смотри логи" ;;
      *) warn "$n" "$status" ;;
    esac
  done <<<"$names"
}

check_cert_expiry() {
  local host=$1
  head1 "TLS-сертификат $host"
  have python3 || { warn "проверка сертификата" "нужен python3"; return; }
  python3 - "$host" <<'PY'
import ssl, socket, sys, datetime
host = sys.argv[1]
try:
    ctx = ssl.create_default_context()
    with socket.create_connection((host, 443), timeout=8) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as ss:
            cert = ss.getpeercert()
    exp = datetime.datetime.strptime(cert['notAfter'], '%b %d %H:%M:%S %Y %Z')
    days = (exp - datetime.datetime.utcnow()).days
    cn = dict(x[0] for x in cert['subject']).get('commonName', '?')
    issuer = dict(x[0] for x in cert['issuer']).get('organizationName', '?')
    print(f"OK|{cn}|{issuer}|{days}")
except ssl.SSLCertVerificationError as e:
    print(f"BAD|{e.verify_message if hasattr(e,'verify_message') else e}")
except Exception as e:
    print(f"ERR|{e}")
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# Команды
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# Интерактивный опрос
#
# Скрипт запускают через `curl ... | bash`, поэтому stdin занят пайпом и
# обычный `read` немедленно вернёт пустоту. Читаем с управляющего терминала
# напрямую через /dev/tty; если его нет (cron, CI) — требуем флаги.
# ─────────────────────────────────────────────────────────────────────────────

ASSUME_YES=0
SKIP_RELAY=0

has_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }

# ask ПЕРЕМЕННАЯ "Вопрос" "значение-по-умолчанию"
ask() {
  local var=$1 prompt=$2 def=${3:-} cur ans
  eval "cur=\${$var:-}"
  [[ -n $cur ]] && { info "$prompt" "$cur (из окружения)"; return; }

  if ! has_tty; then
    [[ -n $def ]] && { eval "$var=\$def"; return; }
    die "нет терминала для вопроса «$prompt». Передай значение флагом или через .env"
  fi

  if [[ -n $def ]]; then
    printf '  %s?%s %s [%s]: ' "$C_BLU" "$C_OFF" "$prompt" "$def" > /dev/tty
  else
    printf '  %s?%s %s: ' "$C_BLU" "$C_OFF" "$prompt" > /dev/tty
  fi
  IFS= read -r ans < /dev/tty || ans=''
  [[ -z $ans ]] && ans=$def
  eval "$var=\$ans"
}

# confirm "Вопрос" -> 0 если да
confirm() {
  local prompt=$1 ans
  (( ASSUME_YES )) && return 0
  has_tty || return 1
  printf '  %s?%s %s [y/N]: ' "$C_BLU" "$C_OFF" "$prompt" > /dev/tty
  IFS= read -r ans < /dev/tty || ans=''
  [[ $ans =~ ^[yYдД] ]]
}

valid_domain() {
  [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}

valid_email() { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$ ]]; }

# Опрос параметров стенда на старте bootstrap
interview() {
  head1 "Параметры стенда"

  while :; do
    ask MAIL_DOMAIN "Основной домен (например example.com)"
    valid_domain "${MAIL_DOMAIN:-}" && break
    warn "домен" "'${MAIL_DOMAIN:-}' не похож на доменное имя"
    MAIL_DOMAIN=''
    has_tty || die "домен не задан"
  done

  ask MAIL_HOSTNAME "FQDN почтового хоста" "mail.$MAIL_DOMAIN"

  while :; do
    ask LE_EMAIL "Email для Let's Encrypt и уведомлений"
    valid_email "${LE_EMAIL:-}" && break
    warn "email" "'${LE_EMAIL:-}' не похож на адрес"
    LE_EMAIL=''
    has_tty || die "email не задан"
  done

  ask TZ_SETTING "Часовой пояс" "$(cat /etc/timezone 2>/dev/null || echo UTC)"
  ask MAILSTACK_DIR "Каталог установки" "$MAILSTACK_DIR"

  ask_relay
}

# SMTP-релей (smarthost). Нужен, когда провайдер блокирует исходящий порт 25:
# сервер продолжает принимать почту, но доставлять её напрямую не может.
# Настройка опциональна — её можно пропустить и вернуться к ней позже.
ask_relay() {
  [[ -n ${RELAY_HOST:-} ]] && { info "SMTP-релей" "$RELAY_HOST (из окружения)"; return; }
  if (( ${SKIP_RELAY:-0} )); then
    warn "SMTP-релей" "пропущен по --no-relay — отправка наружу работать не будет"
    return
  fi

  # Спрашиваем только если 25-й действительно закрыт — иначе релей не нужен
  if tcp_probe alt1.aspmx.l.google.com 25 6; then
    info "SMTP-релей" "не требуется, исходящий порт 25 открыт"
    return
  fi

  printf '\n  %sИсходящий порт 25 заблокирован провайдером.%s\n' "$C_YEL" "$C_OFF"
  printf '  Почта будет приниматься, но не сможет уходить наружу напрямую.\n'
  printf '  Без релея стенд проверит только половину тракта — приём, но не отправку.\n\n'
  printf '  Рекомендуемый вариант — %sBrevo%s: smtp-relay.brevo.com:587,\n' "$C_BLD" "$C_OFF"
  printf '  300 писем в сутки бесплатно и бессрочно, регистрация занимает пару минут.\n'
  printf '  Ключ берётся в панели: SMTP & API → SMTP.\n\n'
  printf '  Подойдёт и любой другой свой сервер с открытым 25-м портом.\n\n'

  if ! confirm "Настроить релей сейчас?"; then
    # Прерываемся осознанно: без релея и без открытого 25 отправка не
    # заработает вовсе, и это выяснится уже после развёртывания — когда
    # причину будут искать в конфигурации Poste.io, а не в блокировке порта.
    printf '\n  %sУстановка остановлена.%s Что делать дальше — любой из вариантов:\n\n' "$C_YEL" "$C_OFF"
    printf '  %s1.%s Открыть 25-й порт — решение навсегда, и оно всё равно понадобится для прода.\n' "$C_BLD" "$C_OFF"
    printf '     Тикет в панели Selectel с обоснованием, что это почтовый сервер.\n'
    printf '     После разблокировки просто запусти bootstrap снова — вопрос не появится.\n\n'
    printf '  %s2.%s Завести релей и вернуться:\n' "$C_BLD" "$C_OFF"
    printf '     Brevo — https://app.brevo.com → SMTP & API → SMTP → создать ключ.\n'
    printf '     Затем: mailstack.sh bootstrap\n\n'
    printf '  %s3.%s Использовать свой другой почтовый сервер как релей:\n' "$C_BLD" "$C_OFF"
    printf '     нужны его хост, порт 587, логин и пароль ящика.\n\n'
    printf '  %s4.%s Продолжить без отправки — стенд будет только принимать почту:\n' "$C_BLD" "$C_OFF"
    printf '     mailstack.sh bootstrap --no-relay\n\n'
    die "релей не настроен"
  fi

  ask RELAY_HOST "Хост релея" "smtp-relay.brevo.com"
  ask RELAY_PORT "Порт релея" "587"

  # Провайдеры, блокирующие 25, нередко оставляют за собой право закрыть и
  # 587 с 465. Порт 2525 в такие списки обычно не входит — это негласный
  # запасной submission, который поддерживают Brevo, Mailjet и SMTP2GO.
  if ! tcp_probe "$RELAY_HOST" "${RELAY_PORT:-587}" 6; then
    warn "порт ${RELAY_PORT:-587}" "до $RELAY_HOST не достучаться"
    if tcp_probe "$RELAY_HOST" 2525 6; then
      hint "Порт 2525 у этого релея открыт — провайдеры его обычно не блокируют."
      if confirm "Использовать 2525 вместо ${RELAY_PORT:-587}?"; then
        RELAY_PORT=2525
        ok "порт релея" "2525"
      fi
    else
      hint "Ни ${RELAY_PORT:-587}, ни 2525 недоступны — проверь блокировки провайдера."
    fi
  fi

  # У Brevo логин — не email аккаунта, а выданный адрес вида xxx@smtp-brevo.com,
  # а пароль — SMTP key, не API key и не пароль от аккаунта. Оба берутся в
  # Settings → SMTP & API → SMTP; ключ показывается только при создании.
  if [[ ${RELAY_HOST:-} == *brevo* ]]; then
    hint "Логин Brevo — не email аккаунта, а адрес вида xxxxx@smtp-brevo.com"
    hint "Пароль — SMTP key (не API key). Settings → SMTP & API → SMTP."
  fi
  ask RELAY_USER "Логин на релее"
  # Пароль читаем без эха: он попадёт в .env с правами 600, но светить
  # его в терминале и в истории всё равно незачем.
  if has_tty; then
    printf '  %s?%s %s: ' "$C_BLU" "$C_OFF" "Пароль на релее" > /dev/tty
    stty -echo < /dev/tty 2>/dev/null
    IFS= read -r RELAY_PASS < /dev/tty || RELAY_PASS=''
    stty echo < /dev/tty 2>/dev/null
    printf '\n' > /dev/tty
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BOOTSTRAP — подготовка чистой ОС
# ─────────────────────────────────────────────────────────────────────────────

# Снимок исходного состояния машины — делается ДО любых изменений.
# Без него откат получается гадательным: неизвестно, на какое имя возвращать
# hostname, был ли Docker установлен до нас и включал ли кто-то ufw раньше.
# Всё, чего в снимке нет как «было», uninstall вправе удалить.
save_state() {
  mkdir -p "$MAILSTACK_DIR"
  local f="$MAILSTACK_DIR/.bootstrap-state"
  cat > "$f" <<CONF
# Состояние машины до установки. Используется командой uninstall.
ORIG_HOSTNAME=$(hostname)
ORIG_FQDN=$(hostname -f 2>/dev/null || hostname)
HAD_DOCKER=$(have docker && echo 1 || echo 0)
HAD_SWAP=$(swapon --show 2>/dev/null | grep -q . && echo 1 || echo 0)
HAD_UFW_ACTIVE=$(ufw status 2>/dev/null | grep -q '^Status: active' && echo 1 || echo 0)
HAD_FAIL2BAN=$([[ -d /etc/fail2ban ]] && echo 1 || echo 0)
HAD_DAEMON_JSON=$([[ -f /etc/docker/daemon.json ]] && echo 1 || echo 0)
BOOTSTRAP_AT=$(date '+%Y-%m-%d %H:%M:%S %Z')
CONF
  chmod 600 "$f"
  ok "снимок состояния" "$f"
}

load_state() {
  local f="$MAILSTACK_DIR/.bootstrap-state"
  if [[ -r $f ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
    info "снимок состояния" "от ${BOOTSTRAP_AT:-неизвестно}"
    return 0
  fi
  return 1
}

# Выполнить шаг установки, прервавшись с внятным сообщением при ошибке
run_step() {
  local desc=$1; shift
  if "$@" >/tmp/mailstack-step.log 2>&1; then
    ok "$desc" "готово"
  else
    fail "$desc" "ошибка (последние строки лога ниже)"
    sed 's/^/        /' /tmp/mailstack-step.log | tail -8
    die "шаг «$desc» не выполнен"
  fi
}

setup_swap() {
  local size_mb=${1:-2048}
  if swapon --show 2>/dev/null | grep -q .; then
    ok "swap" "уже настроен"
    return
  fi
  # fallocate быстрее, но на некоторых ФС даёт разреженный файл,
  # непригодный под swap — тогда откатываемся на dd.
  if ! fallocate -l "${size_mb}M" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none 2>/dev/null
  fi
  chmod 600 /swapfile
  run_step "swap: mkswap" mkswap /swapfile
  run_step "swap: включение" swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  # На почтовом сервере активный своп предпочтительнее, чем OOM-killer,
  # прибивающий Dovecot посреди сессии, но и увлекаться им не стоит.
  sysctl -qw vm.swappiness=10
  grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
  ok "swap" "${size_mb} MB создан и включён"
}

setup_hostname() {
  local fqdn=$1
  local current; current=$(hostname -f 2>/dev/null || hostname)
  if [[ $current == "$fqdn" ]]; then
    ok "hostname" "$fqdn (уже задан)"
    return
  fi
  local short=${fqdn%%.*}
  run_step "hostname: $fqdn" hostnamectl set-hostname "$fqdn"
  # Без записи в /etc/hosts `hostname -f` не разрешится, и Postfix
  # подставит в HELO неполное имя.
  if ! grep -qE "^127\.0\.1\.1[[:space:]]+$fqdn" /etc/hosts; then
    sed -i "/^127\.0\.1\.1/d" /etc/hosts
    echo -e "127.0.1.1\t$fqdn $short" >> /etc/hosts
  fi
  ok "hostname" "$fqdn"
}

setup_packages() {
  export DEBIAN_FRONTEND=noninteractive
  run_step "apt update" apt-get update -qq
  run_step "apt upgrade" apt-get -y -qq upgrade
  run_step "базовые пакеты" apt-get install -y -qq \
    ca-certificates curl gnupg dnsutils whois jq ufw fail2ban \
    unattended-upgrades apt-transport-https
}

setup_docker() {
  if have docker && docker compose version >/dev/null 2>&1; then
    ok "docker" "уже установлен: $(docker --version | awk '{print $3}' | tr -d ,)"
  else
    local codename id
    # shellcheck disable=SC1091
    . /etc/os-release
    id=$ID
    codename=${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}
    install -m 0755 -d /etc/apt/keyrings
    run_step "ключ репозитория Docker" bash -c \
      "curl -fsSL https://download.docker.com/linux/$id/gpg -o /etc/apt/keyrings/docker.asc && chmod a+r /etc/apt/keyrings/docker.asc"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$id $codename stable" \
      > /etc/apt/sources.list.d/docker.list
    run_step "apt update (docker)" apt-get update -qq
    run_step "установка Docker" apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  # userland-proxy подменяет source IP входящих соединений на адрес
  # docker-моста. Для почты это критично: Rspamd увидит все письма как
  # пришедшие с 172.17.0.1, и RBL с greylisting перестанут работать.
  local dj=/etc/docker/daemon.json
  if [[ -f $dj ]] && grep -q '"userland-proxy"' "$dj"; then
    ok "daemon.json" "userland-proxy уже настроен"
  else
    mkdir -p /etc/docker
    if [[ -f $dj ]] && have jq; then
      jq '. + {"userland-proxy": false, "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' \
        "$dj" > "$dj.new" && mv "$dj.new" "$dj"
    else
      cat > "$dj" <<'JSON'
{
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
    fi
    run_step "перезапуск Docker" systemctl restart docker
    ok "daemon.json" "userland-proxy отключён, логи ограничены 30 MB на контейнер"
  fi
  systemctl enable -q docker 2>/dev/null
}

setup_firewall() {
  # Порядок критичен: сначала разрешаем SSH, только потом включаем ufw.
  # Обратный порядок обрывает текущую сессию и запирает снаружи.
  ufw allow 22/tcp    >/dev/null 2>&1
  ufw allow 80/tcp    >/dev/null 2>&1
  ufw allow 443/tcp   >/dev/null 2>&1
  for p in 25 465 587 993 995; do ufw allow "$p/tcp" >/dev/null 2>&1; done
  ufw default deny incoming  >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    ok "ufw" "уже активен, правила обновлены"
  else
    run_step "включение ufw" bash -c "echo y | ufw enable"
  fi
  ok "ufw" "открыты 22, 80, 443, 25, 465, 587, 993, 995"

  # ufw не фильтрует опубликованные Docker-порты: docker вставляет свои
  # правила в цепочку DOCKER-USER раньше правил ufw. Поэтому админки
  # защищаются не файрволом, а привязкой к 127.0.0.1 на этапе deploy.
  hint "Админки NPM/Portainer/Kuma ufw не закроет — docker обходит его правила."
  hint "На этапе deploy они публикуются только на 127.0.0.1 и доступны через SSH-туннель."
}

setup_fail2ban() {
  [[ -d /etc/fail2ban ]] || { warn "fail2ban" "не установлен"; return; }

  # Адреса администратора не банятся никогда. Без этого fail2ban блокирует
  # того, кто сервером управляет: клиент ssh предлагает все ключи из ~/.ssh
  # до попытки пароля, упирается в MaxAuthTries, и каждое такое соединение
  # засчитывается как неудачная аутентификация — пяти хватает для бана.
  local ignore="127.0.0.1/8 ::1"
  [[ -n ${TRUSTED_IPS:-} ]] && ignore="$ignore ${TRUSTED_IPS//,/ }"

  # Адрес текущей ssh-сессии добавляем автоматически: почти всегда это и
  # есть машина администратора
  local cur_ip=${SSH_CLIENT%% *}
  [[ $cur_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ignore="$ignore $cur_ip"

  if [[ ! -f /etc/fail2ban/jail.local ]]; then
    cat > /etc/fail2ban/jail.local <<CONF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = $ignore

[sshd]
enabled = true
CONF
    ok "fail2ban: не банить" "$ignore"
  else
    # Дополняем существующий список, не затирая чужие настройки
    if grep -q '^ignoreip' /etc/fail2ban/jail.local; then
      local ip
      for ip in $ignore; do
        grep -q "$ip" /etc/fail2ban/jail.local || sed -i "s|^ignoreip *=.*|& $ip|" /etc/fail2ban/jail.local
      done
    else
      sed -i "/^\[DEFAULT\]/a ignoreip = $ignore" /etc/fail2ban/jail.local
    fi
    ok "fail2ban: не банить" "$ignore"
  fi
  systemctl enable -q fail2ban 2>/dev/null
  run_step "fail2ban" systemctl restart fail2ban
}

save_env() {
  local dir=$MAILSTACK_DIR
  mkdir -p "$dir"
  local f="$dir/.env"
  # .env содержит адреса и пути, а впоследствии — пароли S3 и restic.
  # Права 600 задаются до записи, чтобы файл не существовал открытым даже
  # доли секунды.
  touch "$f"; chmod 600 "$f"
  cat > "$f" <<CONF
# Создано mailstack.sh $MAILSTACK_VERSION
MAIL_DOMAIN=$MAIL_DOMAIN
MAIL_HOSTNAME=$MAIL_HOSTNAME
LE_EMAIL=$LE_EMAIL
TZ=$TZ_SETTING
MAILSTACK_DIR=$MAILSTACK_DIR
TRUSTED_IPS=${TRUSTED_IPS:-}

# Версии образов. Uptime Kuma держим на ветке 1: в 2.0 удалён импорт
# JSON-бэкапа, переход туда — только через копирование каталога данных.
KUMA_IMAGE=$KUMA_IMAGE
NPM_IMAGE=$NPM_IMAGE
PORTAINER_IMAGE=$PORTAINER_IMAGE
POSTE_IMAGE=$POSTE_IMAGE
AUTOCONFIG_IMAGE=$AUTOCONFIG_IMAGE
CONF

  # SMTP-релей: заполняется, только если провайдер блокирует исходящий 25
  if [[ -n ${RELAY_HOST:-} ]]; then
    cat >> "$f" <<CONF

# SMTP-релей (smarthost) — обход блокировки исходящего порта 25
RELAY_HOST=$RELAY_HOST
RELAY_PORT=${RELAY_PORT:-587}
RELAY_USER=${RELAY_USER:-}
RELAY_PASS='${RELAY_PASS:-}'
CONF
  fi

  # Бэкап настраивается отдельно и в любой момент — он намеренно не
  # блокирует развёртывание. Оставляем заготовку с подсказками.
  if ! grep -q '^RESTIC_REPOSITORY=' "$f" 2>/dev/null; then
    cat >> "$f" <<'CONF'

# Резервное копирование — настраивается командой: mailstack.sh backup setup
# Примеры строки репозитория restic:
#   sftp:backup@backup-host:/srv/mailstack     — по ssh, нативно, без лишних слоёв
#   /mnt/backup/mailstack                      — локальный каталог или примонтированный диск
#   s3:https://s3.storage.selcloud.ru/bucket   — S3 (Selectel, MinIO, Yandex)
#   s3:https://s3.us-west-004.backblazeb2.com/bucket  — Backblaze B2 через S3 API
#   rclone:remote:path                         — всё остальное, включая FTP и WebDAV
# RESTIC_REPOSITORY=
CONF
  fi

  ok ".env сохранён" "$f (права 600)"
}

cmd_bootstrap() {
  local skip_domain=0
  while (( $# )); do
    case "$1" in
      --domain)   MAIL_DOMAIN=${2:-}; shift 2 ;;
      --hostname) MAIL_HOSTNAME=${2:-}; shift 2 ;;
      --email)    LE_EMAIL=${2:-}; shift 2 ;;
      --tz)       TZ_SETTING=${2:-}; shift 2 ;;
      --skip-domain-check) skip_domain=1; shift ;;
      --no-relay) SKIP_RELAY=1; shift ;;
      --trusted-ip) TRUSTED_IPS="${TRUSTED_IPS:+$TRUSTED_IPS,}${2:-}"; shift 2 ;;
      -y|--yes)   ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг bootstrap: $1" ;;
    esac
  done

  printf '%smailstack bootstrap%s v%s — %s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION" "$(date '+%Y-%m-%d %H:%M')"
  need_root
  load_env

  : "${TZ_SETTING:=${TZ:-UTC}}"
  interview

  # dig нужен для проверок домена, а его на чистой Ubuntu может не быть
  if ! have dig; then
    info "dnsutils" "устанавливаю, нужен для проверки DNS"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsutils >/dev/null 2>&1
  fi

  if (( ! skip_domain )); then
    local ip; ip=$(detect_public_ip)
    check_domain_registration "$MAIL_DOMAIN"
    resolve_auth_ns "$MAIL_DOMAIN"
    if check_domain_delegation "$MAIL_DOMAIN"; then
      check_domain_caa "$MAIL_DOMAIN"
      check_domain_existing_mail "$MAIL_DOMAIN"
      check_domain_dns "$MAIL_DOMAIN" "$ip"
    fi

    if (( N_FAIL > 0 )); then
      printf '\n  %sНайдено %d проблем с доменом.%s Установить систему можно и сейчас —\n' "$C_YEL" "$N_FAIL" "$C_OFF"
      printf '  DNS понадобится только на этапе deploy, когда будут выпускаться сертификаты.\n'
      confirm "Продолжить установку, разобравшись с DNS позже?" || die "прервано. Исправь DNS и запусти снова."
    elif (( N_WARN > 0 )); then
      printf '\n  %s%d предупреждений по домену%s — на установку не влияют.\n' "$C_YEL" "$N_WARN" "$C_OFF"
    fi
  fi

  head1 "План изменений на этой машине"
  info "swap" "создать 2 GB, если отсутствует"
  info "hostname" "$MAIL_HOSTNAME"
  info "часовой пояс" "$TZ_SETTING"
  info "пакеты" "обновление системы + curl, dnsutils, jq, ufw, fail2ban"
  info "docker" "Docker CE + compose plugin, userland-proxy отключён"
  info "firewall" "ufw: 22, 80, 443, 25, 465, 587, 993, 995"
  info "fail2ban" "защита ssh"
  printf '\n'
  confirm "Применить?" || die "прервано пользователем"

  N_PASS=0; N_WARN=0; N_FAIL=0

  head1 "Установка"
  save_state          # снимок делается до первых изменений, иначе откат вслепую
  setup_swap 2048
  run_step "часовой пояс: $TZ_SETTING" timedatectl set-timezone "$TZ_SETTING"
  setup_hostname "$MAIL_HOSTNAME"
  setup_packages
  setup_docker
  setup_firewall
  setup_fail2ban
  save_env

  head1 "Готово"
  info "следующий шаг" "mailstack.sh deploy"
  [[ -n ${MAIL_DOMAIN:-} ]] && info "проверка домена" "mailstack.sh domain $MAIL_DOMAIN"
  summary "Машина подготовлена" "Установка завершилась с ошибками"
}

# ─────────────────────────────────────────────────────────────────────────────
# BACKUP — restic
#
# Настройка намеренно не входит в deploy: развёртывание не должно упираться
# в неготовое хранилище. Репозиторий подключается в любой момент.
#
# Тома бэкапятся прямо из /var/lib/docker/volumes — без промежуточной
# распаковки в tar, которая требовала бы вдвое больше места на диске.
# ─────────────────────────────────────────────────────────────────────────────

RESTIC_PW_FILE=''
RESTIC_ENV_FILE=''

restic_paths() {
  # Тома стека плюс каталог с compose-файлами, .env и конфигами autoconfig
  local v
  for v in /var/lib/docker/volumes/mailstack_*; do
    [[ -d $v/_data ]] && echo "$v/_data"
  done
  [[ -d $MAILSTACK_DIR ]] && echo "$MAILSTACK_DIR"
}

ensure_restic() {
  if have restic; then
    info "restic" "$(restic version 2>/dev/null | awk '{print $2}')"
    return 0
  fi
  info "restic" "устанавливаю"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq restic >/dev/null 2>&1
  have restic || die "не удалось установить restic"
  ok "restic установлен" "$(restic version 2>/dev/null | awk '{print $2}')"
}

# Окружение для вызова restic: пароль репозитория и, для S3, ключи доступа
restic_env() {
  RESTIC_PW_FILE="$MAILSTACK_DIR/.restic-password"
  RESTIC_ENV_FILE="$MAILSTACK_DIR/.restic-env"
  [[ -r $RESTIC_PW_FILE ]] || return 1
  export RESTIC_PASSWORD_FILE="$RESTIC_PW_FILE"
  export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
  if [[ -r $RESTIC_ENV_FILE ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$RESTIC_ENV_FILE"
    set +a
  fi
  [[ -n $RESTIC_REPOSITORY ]]
}

backup_configured() {
  [[ -n ${RESTIC_REPOSITORY:-} ]] && [[ -r "$MAILSTACK_DIR/.restic-password" ]]
}

cmd_backup_setup() {
  local repo='' kind=''
  while (( $# )); do
    case "$1" in
      --repo) repo=${2:-}; shift 2 ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг: $1" ;;
    esac
  done

  head1 "Настройка резервного копирования"
  ensure_restic

  if [[ -z $repo ]]; then
    if ! has_tty; then
      die "укажи хранилище флагом --repo (примеры см. в .env)"
    fi
    printf '\n  Куда складывать бэкапы:\n\n'
    printf '    %s1%s  SFTP на другой сервер   %sнативно, по ssh, без лишних слоёв%s\n' "$C_BLD" "$C_OFF" "$C_DIM" "$C_OFF"
    printf '    %s2%s  Локальный каталог       %sбыстро, но не переживёт потерю сервера%s\n' "$C_BLD" "$C_OFF" "$C_DIM" "$C_OFF"
    printf '    %s3%s  S3                      %sSelectel, Backblaze B2, MinIO, Yandex%s\n' "$C_BLD" "$C_OFF" "$C_DIM" "$C_OFF"
    printf '    %s4%s  rclone                  %sвсё остальное: FTP, WebDAV, Диск%s\n\n' "$C_BLD" "$C_OFF" "$C_DIM" "$C_OFF"
    local choice
    printf '  %s?%s Вариант [1-4]: ' "$C_BLU" "$C_OFF" > /dev/tty
    IFS= read -r choice < /dev/tty || choice=''
    case "$choice" in
      1) kind=sftp;   ask repo "SFTP-путь (user@host:/путь)" ;;
      2) kind=local;  ask repo "Каталог" "/mnt/backup/mailstack" ;;
      3) kind=s3;     ask repo "S3 URL (s3:https://endpoint/bucket)" ;;
      4) kind=rclone; ask repo "rclone-путь (remote:path)" ;;
      *) die "непонятный выбор" ;;
    esac
    [[ $kind == sftp   ]] && repo="sftp:$repo"
    [[ $kind == rclone ]] && repo="rclone:$repo"
  fi

  # S3 требует ключей доступа — сохраняем отдельно от .env, с правами 600
  if [[ $repo == s3:* ]] && has_tty; then
    local akey skey
    ask akey "S3 Access Key ID"
    printf '  %s?%s S3 Secret Access Key: ' "$C_BLU" "$C_OFF" > /dev/tty
    stty -echo < /dev/tty 2>/dev/null
    IFS= read -r skey < /dev/tty || skey=''
    stty echo < /dev/tty 2>/dev/null
    printf '\n' > /dev/tty
    umask 077
    cat > "$MAILSTACK_DIR/.restic-env" <<CONF
AWS_ACCESS_KEY_ID=$akey
AWS_SECRET_ACCESS_KEY=$skey
CONF
    chmod 600 "$MAILSTACK_DIR/.restic-env"
    ok "ключи S3 сохранены" ".restic-env (права 600)"
  fi

  # Пароль репозитория. Генерируем сам: без него бэкап не расшифровать
  # ничем и никогда — restic шифрует на стороне клиента.
  local pwf="$MAILSTACK_DIR/.restic-password"
  if [[ ! -f $pwf ]]; then
    umask 077
    head -c 32 /dev/urandom | base64 | tr -d '\n=/+' > "$pwf"
    chmod 600 "$pwf"
    ok "пароль репозитория" "сгенерирован"
  else
    info "пароль репозитория" "уже существует"
  fi

  # Записываем в .env
  local envf="$MAILSTACK_DIR/.env"
  sed -i '/^RESTIC_REPOSITORY=/d' "$envf" 2>/dev/null
  echo "RESTIC_REPOSITORY=$repo" >> "$envf"
  ok "хранилище" "$repo"

  export RESTIC_REPOSITORY=$repo
  restic_env >/dev/null 2>&1

  head1 "Инициализация репозитория"
  if restic snapshots >/dev/null 2>&1; then
    ok "репозиторий" "уже существует и открывается"
  elif restic init >/dev/null 2>&1; then
    ok "репозиторий" "создан"
  else
    fail "репозиторий" "не удалось создать"
    hint "Проверь доступность хранилища и права."
    hint "Для S3 — что бакет существует и ключи верны."
    summary "" "Хранилище не готово"
    return 1
  fi

  head1 "ВАЖНО — сохрани пароль отдельно"
  printf '  %s%s%s\n\n' "$C_BLD" "$(cat "$pwf")" "$C_OFF"
  printf '  restic шифрует данные на стороне клиента. Без этого пароля бэкап\n'
  printf '  не расшифровать ничем — ни нам, ни владельцу хранилища.\n'
  printf '  Файл лежит в %s, но если погибнет сервер, погибнет и он.\n\n' "$pwf"

  summary "Резервное копирование настроено" "Настройка не завершена"
}

cmd_backup() {
  local sub=${1:-run}
  case "$sub" in
    setup|init) shift; printf '%smailstack backup setup%s\n' "$C_BLD" "$C_OFF"
                need_root; load_env; cmd_backup_setup "$@" ;;
    list|snapshots) shift; backup_simple_cmd snapshots ;;
    check)      shift; backup_simple_cmd check ;;
    run|"")     shift 2>/dev/null
                if backup_run "$@"; then summary "Бэкап снят" ""; else summary "" "Бэкап не снят"; fi ;;
    *) die "неизвестная подкоманда backup: $sub" ;;
  esac
}

backup_simple_cmd() {
  need_root; load_env
  ensure_restic
  restic_env || die "бэкап не настроен — выполни: mailstack.sh backup setup"
  restic "$@"
}

backup_run() {
  local no_stop=0
  while (( $# )); do
    case "$1" in
      --no-stop) no_stop=1; shift ;;
      *) die "неизвестный флаг backup: $1" ;;
    esac
  done

  printf '%smailstack backup%s v%s — %s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION" "$(date '+%Y-%m-%d %H:%M')"
  need_root; load_env
  ensure_restic
  restic_env || die "бэкап не настроен — выполни: mailstack.sh backup setup"

  head1 "Подготовка"
  info "репозиторий" "$RESTIC_REPOSITORY"
  local paths; paths=$(restic_paths)
  [[ -n $paths ]] || die "нечего бэкапить — стек не развёрнут"
  local n; n=$(wc -l <<<"$paths" | tr -d ' ')
  ok "путей к архивации" "$n"

  # Poste.io держит настройки в SQLite. Копия «на живую» может застать базу
  # в середине транзакции, и снапшот окажется битым — обнаружится это уже
  # при восстановлении. Пауза в полминуты дешевле такого сюрприза.
  local stopped=0
  if (( ! no_stop )) && docker ps -q -f name=^poste$ 2>/dev/null | grep -q .; then
    docker stop poste >/dev/null 2>&1 && { stopped=1; ok "poste остановлен" "на время снимка"; }
  fi

  head1 "Архивация"
  local rc=0
  # shellcheck disable=SC2086
  if restic backup --tag mailstack --host "${MAIL_HOSTNAME:-$(hostname)}" $paths 2>&1 \
       | tail -6 | sed 's/^/  /'; then
    ok "снимок создан" ""
  else
    rc=1; fail "архивация" "завершилась с ошибкой"
  fi

  if (( stopped )); then
    docker start poste >/dev/null 2>&1 && ok "poste запущен" "работа возобновлена" \
      || fail "poste" "НЕ ЗАПУСТИЛСЯ — почта не работает, подними вручную"
  fi

  head1 "Политика хранения"
  if restic forget --tag mailstack \
       --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >/dev/null 2>&1; then
    ok "старые снимки" "7 дневных, 4 недельных, 6 месячных"
  else
    warn "очистка" "не выполнена"
  fi

  restic snapshots --tag mailstack --latest 3 --compact 2>/dev/null | tail -6 | sed 's/^/  /'
  return $rc
}

# Очистка целевых путей перед восстановлением.
#
# restic restore восстанавливает файлы из снимка, но не удаляет те, которых
# в снимке нет: это слияние, а не замена состояния. Флаг --delete появился
# только в restic 0.17, а в 24.04 приезжает 0.16 — поэтому чистим сами.
#
# Удаляем строго содержимое известных путей и только после проверки шаблона:
# ошибка здесь стирает не тот каталог.
restore_clean_targets() {
  local p removed=0
  while read -r p; do
    [[ -z $p ]] && continue
    case "$p" in
      /var/lib/docker/volumes/mailstack_*/_data|"$MAILSTACK_DIR")
        if [[ -d $p ]]; then
          find "$p" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
          ok "очищено" "$p"
          removed=$((removed+1))
        fi ;;
      *)
        warn "пропущено" "$p — путь не соответствует ожидаемому шаблону" ;;
    esac
  done <<<"$(restic_paths)"
  info "очищено путей" "$removed"
}

cmd_restore() {
  local snap=latest clean=0
  while (( $# )); do
    case "$1" in
      --snapshot) snap=${2:-latest}; shift 2 ;;
      --clean)    clean=1; shift ;;
      -y|--yes)   ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг restore: $1" ;;
    esac
  done

  printf '%smailstack restore%s v%s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION"
  need_root; load_env
  ensure_restic
  restic_env || die "бэкап не настроен — нужен RESTIC_REPOSITORY и .restic-password"

  head1 "Снимок"
  info "репозиторий" "$RESTIC_REPOSITORY"
  restic snapshots --tag mailstack --latest 5 2>/dev/null | tail -7 | sed 's/^/  /'

  if (( clean )); then
    printf '\n  %s--clean: содержимое томов будет удалено перед восстановлением.%s\n' "$C_YEL" "$C_OFF"
    printf '  Состояние станет ровно таким, как в снимке.\n\n'
  else
    printf '\n  %sВосстановление перезапишет файлы из снимка, но НЕ удалит те,%s\n' "$C_YEL" "$C_OFF"
    printf '  %sкоторых в снимке нет — restic делает слияние, а не замену.%s\n' "$C_YEL" "$C_OFF"
    printf '  Для точного отката к состоянию снимка добавь --clean.\n\n'
  fi
  confirm "Восстановить из снимка $snap?" || die "отменено"

  head1 "Остановка стека"
  local svc
  for svc in poste npm portainer uptime-kuma autoconfig; do
    docker stop "$svc" >/dev/null 2>&1 && ok "остановлен" "$svc"
  done

  if (( clean )); then
    head1 "Очистка перед восстановлением"
    # Пароль репозитория лежит внутри очищаемого каталога. Без него после
    # очистки нечем расшифровать снимок — сохраняем и возвращаем обратно.
    local keep; keep=$(mktemp -d)
    cp -a "$MAILSTACK_DIR/.restic-password" "$keep/" 2>/dev/null
    cp -a "$MAILSTACK_DIR/.restic-env" "$keep/" 2>/dev/null
    cp -a "$MAILSTACK_DIR/.env" "$keep/" 2>/dev/null
    restore_clean_targets
    mkdir -p "$MAILSTACK_DIR"
    cp -a "$keep/.restic-password" "$MAILSTACK_DIR/" 2>/dev/null
    cp -a "$keep/.restic-env" "$MAILSTACK_DIR/" 2>/dev/null
    cp -a "$keep/.env" "$MAILSTACK_DIR/" 2>/dev/null
    rm -rf "$keep"
    ok "ключи репозитория" "сохранены на время очистки"
  fi

  head1 "Восстановление"
  # Пути в снимке абсолютные, поэтому цель — корень: тома лягут обратно в
  # /var/lib/docker/volumes, конфигурация — в каталог установки
  if restic restore "$snap" --target / 2>&1 | tail -4 | sed 's/^/  /'; then
    ok "данные восстановлены" ""
  else
    fail "восстановление" "не удалось"
    summary "" "Восстановление не выполнено"
    return 1
  fi

  head1 "Запуск стека"
  if [[ -d "$MAILSTACK_DIR/compose" ]]; then
    local f
    for f in "$MAILSTACK_DIR"/compose/*.yml; do
      [[ -f $f ]] || continue
      docker compose --env-file "$MAILSTACK_DIR/.env" -f "$f" up -d >/dev/null 2>&1 \
        && ok "$(basename "$f")" "поднят" || warn "$(basename "$f")" "не поднялся"
    done
  else
    warn "compose-файлы" "не найдены — запусти deploy"
  fi

  head1 "Дальше"
  info "проверить" "mailstack.sh doctor"
  info "сертификаты" "mailstack.sh certs-sync"
  summary "Восстановление завершено" "Восстановление с ошибками"
}

# ─────────────────────────────────────────────────────────────────────────────
# UPDATE
# ─────────────────────────────────────────────────────────────────────────────

cmd_update() {
  local skip_backup=0 with_system=0
  while (( $# )); do
    case "$1" in
      --no-backup)  skip_backup=1; shift ;;
      --system)     with_system=1; shift ;;
      -y|--yes)     ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг update: $1" ;;
    esac
  done

  printf '%smailstack update%s v%s — %s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION" "$(date '+%Y-%m-%d %H:%M')"
  need_root; load_env
  have docker || die "Docker не установлен"
  [[ -d "$MAILSTACK_DIR/compose" ]] || die "стек не развёрнут"

  # Обновление образа Poste.io необратимо: откатиться к прежней версии
  # можно только из бэкапа, потому что миграции данных выполняются при
  # первом запуске новой версии.
  if (( ! skip_backup )); then
    head1 "Бэкап перед обновлением"
    if backup_configured; then
      backup_run || die "бэкап не снят — обновление прервано"
    else
      warn "бэкап" "не настроен"
      hint "Обновление образа Poste.io необратимо: миграции данных выполняются"
      hint "при первом запуске новой версии, и откат возможен только из бэкапа."
      confirm "Обновлять без бэкапа?" || die "отменено. Настрой: mailstack.sh backup setup"
    fi
  fi

  head1 "Образы"
  local f changed=0
  for f in "$MAILSTACK_DIR"/compose/*.yml; do
    [[ -f $f ]] || continue
    local before after name; name=$(basename "$f")
    before=$(docker compose --env-file "$MAILSTACK_DIR/.env" -f "$f" images -q 2>/dev/null | sort | md5sum)
    if docker compose --env-file "$MAILSTACK_DIR/.env" -f "$f" pull >/dev/null 2>&1; then
      after=$(docker compose --env-file "$MAILSTACK_DIR/.env" -f "$f" images -q 2>/dev/null | sort | md5sum)
      if [[ $before != "$after" ]]; then
        ok "$name" "есть новая версия"
        changed=1
      else
        info "$name" "уже актуально"
      fi
    else
      warn "$name" "не удалось загрузить образы"
    fi
  done

  head1 "Перезапуск"
  for f in "$MAILSTACK_DIR"/compose/*.yml; do
    [[ -f $f ]] || continue
    docker compose --env-file "$MAILSTACK_DIR/.env" -f "$f" up -d >/dev/null 2>&1 \
      && ok "$(basename "$f")" "актуален" || fail "$(basename "$f")" "не поднялся"
  done

  if (( with_system )); then
    head1 "Система"
    export DEBIAN_FRONTEND=noninteractive
    run_step "apt update" apt-get update -qq
    run_step "apt upgrade" apt-get -y -qq upgrade
    if [[ -f /var/run/reboot-required ]]; then
      warn "перезагрузка" "требуется для применения обновлений ядра"
    fi
  fi

  head1 "Очистка"
  local freed; freed=$(docker image prune -af 2>/dev/null | tail -1)
  ok "неиспользуемые образы" "${freed:-удалены}"

  head1 "Проверка"
  check_stack
  (( changed )) && info "сертификаты" "после обновления Poste.io выполни certs-sync"
  summary "Обновление завершено" "Обновление с ошибками"
}

# ─────────────────────────────────────────────────────────────────────────────
# MIGRATE
#
# Переезд целиком через бэкап: снимаем свежий снимок на старой машине,
# на новой разворачиваем из него. Отдельного канала передачи не нужно —
# хранилище уже общее для обеих машин.
# ─────────────────────────────────────────────────────────────────────────────

cmd_migrate() {
  local sub=${1:-help}
  shift 2>/dev/null || true

  printf '%smailstack migrate%s v%s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION"

  case "$sub" in
    prepare)
      need_root; load_env
      backup_configured || die "нужен настроенный бэкап: mailstack.sh backup setup"

      head1 "Финальный снимок на этой машине"
      backup_run || die "бэкап не снят — переезжать нельзя"

      local ip; ip=$(detect_public_ip)
      head1 "Что сделать на новой машине"
      printf '  %s1.%s Подготовить систему:\n' "$C_BLD" "$C_OFF"
      printf '     curl -fsSL %s | bash -s -- bootstrap \\\n' \
             "https://raw.githubusercontent.com/iMironRU/mailstack/main/mailstack.sh"
      printf '       --domain %s --hostname %s --email %s --tz %s\n\n' \
             "${MAIL_DOMAIN:-домен}" "${MAIL_HOSTNAME:-хост}" "${LE_EMAIL:-email}" "${TZ:-UTC}"
      printf '  %s2.%s Подключить то же хранилище бэкапов:\n' "$C_BLD" "$C_OFF"
      printf '     mailstack.sh backup setup --repo %s\n' "${RESTIC_REPOSITORY:-<репозиторий>}"
      printf '     %sи положить туда тот же .restic-password — иначе снимок не расшифровать%s\n\n' "$C_YEL" "$C_OFF"
      printf '  %s3.%s Восстановить и поднять:\n' "$C_BLD" "$C_OFF"
      printf '     mailstack.sh restore\n\n'

      head1 "Не забыть при переключении"
      info "TTL" "снизить до 300 заранее, иначе смена A-записей будет расходиться часами"
      info "A-записи" "перевести mail/status/portainer/autoconfig/autodiscover на новый IP"
      info "PTR" "задать на новом IP в панели провайдера — иначе почту начнут отбивать"
      [[ -n ${RELAY_HOST:-} && ${RELAY_HOST} == *brevo* ]] && \
        info "Brevo" "добавить новый IP в Security → Authorized IPs ДО переключения"
      info "старый сервер" "не гасить сразу — дать почте дойти по старым MX"
      info "текущий IP" "${ip:-неизвестен}"
      summary "Снимок готов, машина к переезду подготовлена" ""
      ;;
    finish)
      need_root; load_env
      head1 "Проверка после переезда"
      local ip; ip=$(detect_public_ip)
      check_stack
      check_rdns "$ip"
      [[ -n ${MAIL_DOMAIN:-} ]] && { resolve_auth_ns "$MAIL_DOMAIN"; check_domain_dns "$MAIL_DOMAIN" "$ip"; }
      check_relay
      summary "Переезд выглядит завершённым" "Есть проблемы — см. выше"
      ;;
    *)
      printf '\n  Переезд состоит из двух шагов:\n\n'
      printf '    %sНа старой машине:%s  mailstack.sh migrate prepare\n' "$C_BLD" "$C_OFF"
      printf '      снимет финальный бэкап и выдаст команды для новой машины\n\n'
      printf '    %sНа новой машине:%s   bootstrap → backup setup → restore\n' "$C_BLD" "$C_OFF"
      printf '      затем mailstack.sh migrate finish — проверка после переключения DNS\n\n'
      exit 0
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# DEPLOY — генерация compose-файлов и запуск стека
#
# Сервисы разнесены по отдельным стекам: перезапуск Poste.io не должен
# ронять NPM, который держит 443 для всех остальных поддоменов.
#
# Админки (NPM, Portainer, Kuma) публикуются только на 127.0.0.1. Закрыть
# их файрволом нельзя: docker вставляет свои правила в цепочку DOCKER-USER
# раньше правил ufw, поэтому опубликованный порт остаётся доступен снаружи
# вопреки «deny» в ufw. Доступ к ним — через ssh-туннель.
# ─────────────────────────────────────────────────────────────────────────────

COMPOSE_DIR=''

write_compose_npm() {
  cat > "$COMPOSE_DIR/10-npm.yml" <<'YML'
# Nginx Proxy Manager — единственный владелец 80 и 443.
# Он же выпускает сертификаты Let's Encrypt для всех поддоменов.
services:
  npm:
    image: ${NPM_IMAGE}
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"        # HTTP: ACME-проверка Let's Encrypt и редирект на HTTPS
      - "443:443"      # HTTPS: webmail, админки, autoconfig
      - "127.0.0.1:81:81"   # админка NPM — только локально, доступ через ssh-туннель
    volumes:
      - npm_data:/data
      - npm_letsencrypt:/etc/letsencrypt
    environment:
      - TZ=${TZ}
      - DISABLE_IPV6=true
    networks: [proxy]
    healthcheck:
      test: ["CMD", "/usr/bin/check-health"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  npm_data:
    name: mailstack_npm_data
  npm_letsencrypt:
    name: mailstack_npm_letsencrypt

networks:
  proxy:
    external: true
YML
}

write_compose_portainer() {
  cat > "$COMPOSE_DIR/20-portainer.yml" <<'YML'
# Portainer — управление Docker через веб.
# Публикуется порт 9000 (HTTP), а не 9443: за NPM шифрование уже есть,
# а самоподписанный сертификат на 9443 потребовал бы отключать проверку
# сертификата в настройках прокси.
services:
  portainer:
    image: ${PORTAINER_IMAGE}
    container_name: portainer
    restart: unless-stopped
    ports:
      - "127.0.0.1:9000:9000"   # только локально, наружу — через NPM
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    environment:
      - TZ=${TZ}
    networks: [proxy]

volumes:
  portainer_data:
    name: mailstack_portainer_data

networks:
  proxy:
    external: true
YML
}

write_compose_poste() {
  cat > "$COMPOSE_DIR/30-poste.yml" <<'YML'
# Poste.io — Postfix + Dovecot + Rspamd + Roundcube в одном контейнере.
#
# Порты 80/443 НЕ публикуются: их держит NPM, который проксирует веб-морду
# на внутренний порт 80 этого контейнера.
#
# Почтовые порты публикуются напрямую — reverse-proxy их не обслуживает,
# TLS для них терминирует сам Dovecot/Postfix внутри контейнера. Отсюда
# требование к сертификату в /data/ssl, который кладёт команда certs-sync.
services:
  poste:
    image: ${POSTE_IMAGE}
    container_name: poste
    restart: unless-stopped
    hostname: ${MAIL_HOSTNAME}
    ports:
      - "25:25"      # SMTP — приём почты от других серверов
      - "465:465"    # SMTPS — отправка клиентом, implicit TLS
      - "587:587"    # Submission — отправка клиентом, STARTTLS
      - "993:993"    # IMAPS — чтение почты
      - "995:995"    # POP3S — чтение почты
    volumes:
      - poste_data:/data
      - /etc/localtime:/etc/localtime:ro
    environment:
      - TZ=${TZ}
      # HTTPS=OFF — шифрование веб-морды берёт на себя NPM, а редиректы
      # изнутри контейнера ломали бы проксирование
      - HTTPS=OFF
      # ClamAV отключён ради экономии памяти: он один съедает больше,
      # чем весь остальной стек. Rspamd остаётся включённым
      - DISABLE_CLAMAV=TRUE
      - VIRTUAL_HOST=${MAIL_HOSTNAME}
    networks: [proxy]

volumes:
  poste_data:
    name: mailstack_poste_data

networks:
  proxy:
    external: true
YML
}

write_compose_kuma() {
  cat > "$COMPOSE_DIR/40-kuma.yml" <<'YML'
# Uptime Kuma — мониторинг доступности сервисов и почтовых портов
services:
  uptime-kuma:
    image: ${KUMA_IMAGE}
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "127.0.0.1:3001:3001"   # только локально, наружу — через NPM
    volumes:
      - kuma_data:/app/data
    environment:
      - TZ=${TZ}
    networks: [proxy]

volumes:
  kuma_data:
    name: mailstack_kuma_data

networks:
  proxy:
    external: true
YML
}

write_compose_autoconfig() {
  local dir="$MAILSTACK_DIR/autoconfig"
  mkdir -p "$dir"

  # Thunderbird: Mozilla autoconfig
  cat > "$dir/config-v1.1.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<clientConfig version="1.1">
  <emailProvider id="${MAIL_DOMAIN}">
    <domain>${MAIL_DOMAIN}</domain>
    <displayName>${MAIL_DOMAIN}</displayName>
    <displayShortName>${MAIL_DOMAIN}</displayShortName>
    <incomingServer type="imap">
      <hostname>${MAIL_HOSTNAME}</hostname>
      <port>993</port>
      <socketType>SSL</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </incomingServer>
    <outgoingServer type="smtp">
      <hostname>${MAIL_HOSTNAME}</hostname>
      <port>465</port>
      <socketType>SSL</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </outgoingServer>
  </emailProvider>
</clientConfig>
XML

  # Outlook: Microsoft autodiscover
  cat > "$dir/autodiscover.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/responseschema/2006">
  <Response xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a">
    <Account>
      <AccountType>email</AccountType>
      <Action>settings</Action>
      <Protocol>
        <Type>IMAP</Type>
        <Server>${MAIL_HOSTNAME}</Server>
        <Port>993</Port>
        <SSL>on</SSL>
        <SPA>off</SPA>
        <AuthRequired>on</AuthRequired>
      </Protocol>
      <Protocol>
        <Type>SMTP</Type>
        <Server>${MAIL_HOSTNAME}</Server>
        <Port>465</Port>
        <SSL>on</SSL>
        <SPA>off</SPA>
        <AuthRequired>on</AuthRequired>
      </Protocol>
    </Account>
  </Response>
</Autodiscover>
XML

  cat > "$dir/nginx.conf" <<'CONF'
server {
    listen 80;
    server_name _;

    root /srv/autoconfig;
    default_type application/xml;

    # Outlook обращается к autodiscover методом POST, а nginx на POST к
    # статическому файлу отвечает 405. Это самая частая причина, по которой
    # самописный autodiscover «не работает без видимых ошибок».
    error_page 405 =200 $uri;

    location = /mail/config-v1.1.xml {
        alias /srv/autoconfig/config-v1.1.xml;
    }

    # Второй путь Thunderbird — через well-known на самом домене
    location = /.well-known/autoconfig/mail/config-v1.1.xml {
        alias /srv/autoconfig/config-v1.1.xml;
    }

    location = /autodiscover/autodiscover.xml {
        alias /srv/autoconfig/autodiscover.xml;
    }

    # Outlook пишет путь в разном регистре
    location = /Autodiscover/Autodiscover.xml {
        alias /srv/autoconfig/autodiscover.xml;
    }

    location = /healthz {
        add_header Content-Type text/plain;
        return 200 'ok';
    }

    location / { return 404; }
}
CONF

  cat > "$COMPOSE_DIR/50-autoconfig.yml" <<'YML'
# Автонастройка почтовых клиентов: Thunderbird (autoconfig) и Outlook
# (autodiscover). Наружу не публикуется — только через NPM на поддоменах
# autoconfig.<домен> и autodiscover.<домен>.
services:
  autoconfig:
    image: ${AUTOCONFIG_IMAGE}
    container_name: autoconfig
    restart: unless-stopped
    volumes:
      - ${MAILSTACK_DIR}/autoconfig/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ${MAILSTACK_DIR}/autoconfig/config-v1.1.xml:/srv/autoconfig/config-v1.1.xml:ro
      - ${MAILSTACK_DIR}/autoconfig/autodiscover.xml:/srv/autoconfig/autodiscover.xml:ro
    environment:
      - TZ=${TZ}
    networks: [proxy]

networks:
  proxy:
    external: true
YML
}

# ─────────────────────────────────────────────────────────────────────────────
# NPM-SETUP — proxy hosts и сертификаты через API
#
# Настройка пяти хостов руками занимает минут десять и повторяется после
# каждого uninstall. API избавляет от этого полностью.
#
# Сертификат заказывается отдельным вызовом ДО создания хоста: так ошибка
# выпуска (лимит Let's Encrypt, недоступный порт 80, неверная A-запись)
# отличима от ошибки конфигурации самого хоста.
# ─────────────────────────────────────────────────────────────────────────────

NPM_API='http://127.0.0.1:81/api'
NPM_TOKEN=''

# Список проксируемых сервисов: поддомен|контейнер|порт
# Массив строк, а не ассоциативный: скрипт должен разбираться и на bash 3.2
NPM_HOSTS=(
  "mail|poste|80"
  "status|uptime-kuma|3001"
  "portainer|portainer|9000"
  "autoconfig|autoconfig|80"
  "autodiscover|autoconfig|80"
)

npm_api() {
  local method=$1 path=$2 data=${3:-}
  local args=(-sS -X "$method" -H 'Content-Type: application/json')
  [[ -n $NPM_TOKEN ]] && args+=(-H "Authorization: Bearer $NPM_TOKEN")
  [[ -n $data ]] && args+=(-d "$data")
  curl "${args[@]}" --max-time 120 "${NPM_API}${path}" 2>/dev/null
}

npm_login() {
  local email=$1 pass=$2
  local resp; resp=$(npm_api POST /tokens \
    "$(jq -nc --arg i "$email" --arg s "$pass" '{identity:$i,secret:$s}')")
  local tok; tok=$(jq -r '.token // empty' <<<"$resp" 2>/dev/null)
  [[ -n $tok ]] && { NPM_TOKEN=$tok; return 0; }
  return 1
}

npm_save_creds() {
  local email=$1 pass=$2
  NPM_ADMIN_EMAIL=$email
  NPM_ADMIN_PASS=$pass
  # Без сохранения повторный npm-setup не сможет войти: пароль
  # сгенерирован и больше нигде не хранится
  local envf="$MAILSTACK_DIR/.env"
  sed -i '/^NPM_ADMIN_EMAIL=/d;/^NPM_ADMIN_PASS=/d' "$envf" 2>/dev/null
  printf 'NPM_ADMIN_EMAIL=%s\nNPM_ADMIN_PASS=%s\n' "$email" "$pass" >> "$envf"
  chmod 600 "$envf"
}

npm_gen_password() {
  local p; p=$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-20)
  [[ ${#p} -ge 12 ]] && { echo "$p"; return; }
  echo "ms$(date +%s)$RANDOM"
}

# Учётная запись администратора NPM.
#
# В NPM 2.15 первого пользователя автоматически больше нет: /api/ отдаёт
# setup:false, и пока он false, POST /api/users создаёт админа БЕЗ
# авторизации. В версиях до этого пользователь заводился сам с
# admin@example.com / changeme. Поддерживаем оба пути.
npm_ensure_admin() {
  head1 "Учётная запись NPM"

  local setup_done
  setup_done=$(curl -sS --max-time 10 "$NPM_API/" 2>/dev/null | jq -r '.setup // false' 2>/dev/null)
  info "состояние NPM" "setup=${setup_done:-неизвестно}"

  if [[ $setup_done == false ]]; then
    # Логин администратора NPM и адрес для Let's Encrypt — разные вещи,
    # хотя обычно совпадают. Задаётся флагом --admin-email, иначе берётся
    # LE_EMAIL, и лишь в последнюю очередь admin@<домен>.
    local email=${NPM_ADMIN_EMAIL:-${LE_EMAIL:-admin@$MAIL_DOMAIN}}
    local pass; pass=$(npm_gen_password)
    local resp; resp=$(npm_api POST /users "$(jq -nc --arg e "$email" --arg s "$pass" \
      '{name:"Administrator",nickname:"Admin",email:$e,roles:["admin"],is_disabled:false,
        auth:{type:"password",secret:$s}}')")

    if ! jq -e '.id' <<<"$resp" >/dev/null 2>&1; then
      fail "создание админа" "$(jq -r '.error.message // "нет ответа"' <<<"$resp" 2>/dev/null | cut -c1-90)"
      return 1
    fi
    ok "администратор создан" "$email"
    npm_save_creds "$email" "$pass"
    npm_login "$email" "$pass" || { fail "вход" "созданной учёткой войти не удалось"; return 1; }
    ok "вход" "$email"
    return 0
  fi

  # setup=true — учётка уже есть
  if [[ -n ${NPM_ADMIN_EMAIL:-} && -n ${NPM_ADMIN_PASS:-} ]] \
     && npm_login "$NPM_ADMIN_EMAIL" "$NPM_ADMIN_PASS"; then
    ok "вход" "$NPM_ADMIN_EMAIL (из .env)"
    return 0
  fi

  # Старые версии NPM заводили пользователя сами — меняем дефолтные креды
  if npm_login "admin@example.com" "changeme"; then
    ok "вход" "дефолтные креды приняты — меняю их"
    local new_email=${LE_EMAIL:-admin@$MAIL_DOMAIN}
    local new_pass; new_pass=$(npm_gen_password)
    npm_api PUT /users/1 "$(jq -nc --arg e "$new_email" \
      '{name:"Administrator",nickname:"Admin",email:$e,roles:["admin"],is_disabled:false}')" >/dev/null
    local r; r=$(npm_api PUT /users/1/auth \
      "$(jq -nc --arg c changeme --arg s "$new_pass" '{type:"password",current:$c,secret:$s}')")
    if jq -e '.error' <<<"$r" >/dev/null 2>&1; then
      fail "смена пароля" "$(jq -r '.error.message' <<<"$r")"
      return 1
    fi
    npm_save_creds "$new_email" "$new_pass"
    npm_login "$new_email" "$new_pass" || { fail "повторный вход" "не удался"; return 1; }
    ok "учётка изменена" "$new_email, пароль в .env"
    return 0
  fi

  fail "вход в NPM" "учётка уже создана, но пароль неизвестен"
  hint "Впиши NPM_ADMIN_EMAIL и NPM_ADMIN_PASS в $MAILSTACK_DIR/.env,"
  hint "либо пересоздай NPM начисто: docker volume rm mailstack_npm_data"
  return 1
}

# Ищем уже выпущенный сертификат: при пересборках стенда это единственный
# способ не упереться в лимит Let's Encrypt (5 неудачных проверок в час
# и 50 сертификатов в неделю на зарегистрированный домен).
npm_find_cert() {
  local fqdn=$1
  npm_api GET /nginx/certificates | jq -r --arg d "$fqdn" \
    '[.[] | select(.domain_names | index($d)) | .id] | first // empty' 2>/dev/null
}

# В NPM 2.15 схема meta допускает только dns_challenge, key_type,
# propagation_seconds и поля DNS-провайдера. Полей letsencrypt_email и
# letsencrypt_agree в ней нет — с ними запрос отвергается валидатором
# ещё до обращения к Let's Encrypt.
npm_request_cert() {
  local fqdn=$1
  local payload; payload=$(jq -nc --arg d "$fqdn" \
    '{provider:"letsencrypt",nice_name:$d,domain_names:[$d],meta:{dns_challenge:false}}')
  npm_api POST /nginx/certificates "$payload"
}

# Привязать сертификат к уже существующему хосту: при повторном запуске
# хост может быть создан ранее без HTTPS, и тогда его нужно обновить,
# а не пересоздавать
npm_attach_cert() {
  local host_id=$1 cert_id=$2
  npm_api PUT "/nginx/proxy-hosts/$host_id" \
    "$(jq -nc --argjson c "$cert_id" '{certificate_id:$c,ssl_forced:true,http2_support:true}')"
}

npm_host_exists() {
  local fqdn=$1
  npm_api GET /nginx/proxy-hosts | jq -r --arg d "$fqdn" \
    '[.[] | select(.domain_names | index($d)) | .id] | first // empty' 2>/dev/null
}

npm_create_host() {
  local fqdn=$1 upstream=$2 port=$3 cert_id=$4
  local payload; payload=$(jq -nc \
    --arg d "$fqdn" --arg h "$upstream" --argjson p "$port" --argjson c "$cert_id" \
    '{domain_names:[$d],forward_scheme:"http",forward_host:$h,forward_port:$p,
      certificate_id:$c,ssl_forced:true,http2_support:true,hsts_enabled:false,
      hsts_subdomains:false,block_exploits:true,caching_enabled:false,
      allow_websocket_upgrade:true,access_list_id:0,advanced_config:"",locations:[]}')
  npm_api POST /nginx/proxy-hosts "$payload"
}

cmd_npm_setup() {
  local skip_certs=0
  while (( $# )); do
    case "$1" in
      --no-certs)    skip_certs=1; shift ;;
      --admin-email) NPM_ADMIN_EMAIL=${2:-}; shift 2 ;;
      -y|--yes)   ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг npm-setup: $1" ;;
    esac
  done

  printf '%smailstack npm-setup%s v%s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION"
  need_root
  load_env
  [[ -n ${MAIL_DOMAIN:-} ]] || die "не задан MAIL_DOMAIN — сначала bootstrap"
  have jq || die "нужен jq: apt-get install -y jq"

  head1 "Доступность NPM"
  if ! tcp_probe 127.0.0.1 81 5; then
    fail "админка NPM" "127.0.0.1:81 не отвечает"
    hint "Стек запущен? Проверь: mailstack.sh deploy"
    die "NPM недоступен"
  fi
  ok "админка NPM" "отвечает на 127.0.0.1:81"

  npm_ensure_admin || die "не удалось войти в NPM"

  head1 "Proxy hosts"
  local entry sub upstream port fqdn cert_id resp existing
  local created=0 reused=0

  for entry in "${NPM_HOSTS[@]}"; do
    IFS='|' read -r sub upstream port <<<"$entry"
    fqdn="$sub.$MAIL_DOMAIN"

    existing=$(npm_host_exists "$fqdn")
    if [[ -n $existing ]]; then
      local has_cert
      has_cert=$(npm_api GET "/nginx/proxy-hosts/$existing" | jq -r '.certificate_id // 0')
      if [[ ${has_cert:-0} != 0 ]] || (( skip_certs )); then
        ok "$fqdn" "уже настроен (id $existing)"
        reused=$((reused+1))
        continue
      fi
      # Хост есть, но без HTTPS — выпускаем сертификат и привязываем
      cert_id=$(npm_find_cert "$fqdn")
      if [[ -z $cert_id ]]; then
        resp=$(npm_request_cert "$fqdn")
        cert_id=$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)
      fi
      if [[ -n $cert_id ]]; then
        npm_attach_cert "$existing" "$cert_id" >/dev/null
        ok "$fqdn" "сертификат привязан к существующему хосту (cert $cert_id)"
        reused=$((reused+1))
      else
        fail "$fqdn" "$(jq -r '.error.message // "сертификат не выпущен"' <<<"${resp:-{}}" 2>/dev/null | cut -c1-80)"
      fi
      continue
    fi

    # A-запись обязана указывать на этот сервер, иначе Let's Encrypt не
    # пройдёт проверку и потратит попытку из часового лимита
    local a; a=$(dns_query "$fqdn" A | head -1)
    if [[ -z $a ]]; then
      fail "$fqdn" "A-запись не задана — пропускаю"
      continue
    fi

    cert_id=0
    if (( ! skip_certs )); then
      cert_id=$(npm_find_cert "$fqdn")
      if [[ -n $cert_id ]]; then
        ok "$fqdn" "переиспользую сертификат id $cert_id"
      else
        resp=$(npm_request_cert "$fqdn")
        cert_id=$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)
        if [[ -z $cert_id ]]; then
          local msg; msg=$(jq -r '.error.message // "нет ответа"' <<<"$resp" 2>/dev/null)
          fail "$fqdn" "сертификат не выпущен: ${msg:0:90}"
          case "$msg" in
            *[Rr]ate*|*too\ many*)
              hint "Лимит Let's Encrypt: 5 неудачных проверок в час на домен." 
              hint "Подожди час либо запусти с --no-certs и выпусти позже." ;;
            *additional\ properties*|*must\ NOT*)
              hint "Запрос отвергнут валидатором API, до Let's Encrypt он не дошёл." 
              hint "Схема payload разошлась с версией NPM — это дефект скрипта." ;;
            *)
              hint "Проверь, что порт 80 доступен снаружи и A-запись верна." ;;
          esac
          cert_id=0
        else
          ok "$fqdn" "сертификат выпущен (id $cert_id)"
        fi
      fi
    fi

    resp=$(npm_create_host "$fqdn" "$upstream" "$port" "${cert_id:-0}")
    if jq -e '.id' <<<"$resp" >/dev/null 2>&1; then
      ok "$fqdn" "→ $upstream:$port$([[ ${cert_id:-0} != 0 ]] && echo ', HTTPS' || echo ', без HTTPS')"
      created=$((created+1))
    else
      fail "$fqdn" "$(jq -r '.error.message // "не создан"' <<<"$resp" 2>/dev/null | cut -c1-90)"
    fi
  done

  info "итого" "создано $created, переиспользовано $reused"

  head1 "Дальше"
  info "сертификат для SMTP/IMAP" "mailstack.sh certs-sync"
  info "админка Poste.io" "https://${MAIL_HOSTNAME:-mail.$MAIL_DOMAIN}"
  info "админка NPM" "ssh -L 8181:127.0.0.1:81 root@<адрес>, вход ${NPM_ADMIN_EMAIL:-?}"

  summary "NPM настроен" "Настройка завершилась с ошибками"
}

# ─────────────────────────────────────────────────────────────────────────────
# Сертификаты для SMTP/IMAP
#
# NPM терминирует TLS только для HTTP. Порты 465/993 и STARTTLS на 587
# обслуживают Postfix и Dovecot внутри контейнера Poste.io, и им нужен
# сертификат в собственной файловой системе. Сам Poste.io получить его не
# может — порт 80 занят NPM, поэтому копируем выпущенный NPM сертификат.
# ─────────────────────────────────────────────────────────────────────────────

cmd_certs_sync() {
  printf '%smailstack certs-sync%s v%s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION"
  need_root
  load_env
  local host=${MAIL_HOSTNAME:-mail.${MAIL_DOMAIN:-}}
  [[ -n ${MAIL_DOMAIN:-} ]] || die "не задан MAIL_DOMAIN — запусти bootstrap"
  have docker || die "Docker не установлен"

  head1 "Поиск сертификата для $host"

  # Каталог npm-<N> в томе NPM соответствует certificate_id из API.
  # Спросить API надёжнее, чем разбирать сертификаты: в alpine нет openssl,
  # и попытка определить владельца по SAN молча не находила ничего.
  local cert_id=''
  if have jq && tcp_probe 127.0.0.1 81 5; then
    if npm_login "${NPM_ADMIN_EMAIL:-}" "${NPM_ADMIN_PASS:-}" 2>/dev/null; then
      cert_id=$(npm_find_cert "$host")
      [[ -n $cert_id ]] && ok "сертификат" "npm-$cert_id (по данным API)"
    else
      warn "API NPM" "войти не удалось — ищу перебором"
    fi
  fi

  # Запасной путь: openssl внутри контейнера npm, он там есть
  if [[ -z $cert_id ]] && docker ps -q -f name=^npm$ | grep -q .; then
    local d
    for d in $(docker exec npm sh -c 'ls -1 /etc/letsencrypt/live 2>/dev/null' 2>/dev/null); do
      [[ $d == README ]] && continue
      if docker exec npm sh -c "openssl x509 -in /etc/letsencrypt/live/$d/fullchain.pem -noout -text 2>/dev/null" 2>/dev/null \
         | grep -q "DNS:$host"; then
        cert_id=${d#npm-}
        ok "сертификат" "$d (найден перебором)"
        break
      fi
    done
  fi

  if [[ -z $cert_id ]]; then
    fail "сертификат" "для $host не найден"
    hint "Выпусти его: mailstack.sh npm-setup"
    hint "Без него порты 465 и 993 отдадут клиентам ошибку TLS."
    summary "" "Сертификат не готов"
    return 1
  fi

  head1 "Копирование в Poste.io"
  docker ps -q -f name=^poste$ | grep -q . || { fail "poste" "контейнер не запущен"; summary "" "Poste.io не работает"; return 1; }

  # Раскладка по README самого образа: server.crt — ровно один сертификат,
  # промежуточные отдельно в ca.crt. Положить сюда fullchain.pem нельзя:
  # в нём цепочка, и службы такой файл не принимают.
  local tmp; tmp=$(mktemp -d)
  docker run --rm -v mailstack_npm_letsencrypt:/le -v "$tmp:/out" alpine:latest \
    sh -c "cp /le/live/npm-$cert_id/cert.pem /out/server.crt \
        && cp /le/live/npm-$cert_id/chain.pem /out/ca.crt \
        && cp /le/live/npm-$cert_id/privkey.pem /out/server.key" \
    >/dev/null 2>&1 || { fail "чтение сертификата" "npm-$cert_id недоступен"; rm -rf "$tmp"; return 1; }

  local cn; cn=$(openssl x509 -in "$tmp/server.crt" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
  ok "прочитан" "CN=$cn"

  # Перезапускать почтовые службы на каждый прогон незачем — это разрывает
  # активные сессии клиентов. Сравниваем отпечатки.
  local new_fp old_fp
  new_fp=$(openssl x509 -in "$tmp/server.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
  old_fp=$(docker exec poste sh -c 'openssl x509 -in /data/ssl/server.crt -noout -fingerprint -sha256 2>/dev/null' 2>/dev/null | cut -d= -f2)

  # Одного отпечатка мало: он считается по первому сертификату в файле,
  # поэтому fullchain.pem и cert.pem дают одинаковый результат. Раскладка
  # при этом разная, и без проверки состава файлов обновление молча
  # пропускалось — ca.crt так и не появлялся.
  local ca_ok=1 single_cert=1
  docker exec poste test -s /data/ssl/ca.crt 2>/dev/null || ca_ok=0
  local n_certs
  n_certs=$(docker exec poste sh -c 'grep -c "BEGIN CERTIFICATE" /data/ssl/server.crt 2>/dev/null' 2>/dev/null | tr -dc '0-9')
  [[ ${n_certs:-0} -eq 1 ]] || single_cert=0

  if [[ -n $old_fp && $new_fp == "$old_fp" ]] && (( ca_ok && single_cert )); then
    ok "сертификат" "уже актуален, перезапуск не требуется"
    rm -rf "$tmp"
    summary "Сертификаты в порядке" ""
    return 0
  fi
  (( ca_ok )) || info "ca.crt" "отсутствует — раскладку нужно обновить"
  if (( ! single_cert )); then
    if [[ ${n_certs:-0} -eq 0 ]]; then
      info "server.crt" "отсутствует или пуст"
    else
      info "server.crt" "содержит $n_certs сертификата вместо одного"
    fi
  fi

  docker exec poste mkdir -p /data/ssl >/dev/null 2>&1
  docker cp "$tmp/server.crt" poste:/data/ssl/server.crt >/dev/null 2>&1 \
    && docker cp "$tmp/ca.crt"    poste:/data/ssl/ca.crt     >/dev/null 2>&1 \
    && docker cp "$tmp/server.key" poste:/data/ssl/server.key >/dev/null 2>&1 \
    && ok "скопирован" "/data/ssl/{server.crt,ca.crt,server.key}" \
    || { fail "копирование" "не удалось"; rm -rf "$tmp"; return 1; }
  docker exec poste chmod 600 /data/ssl/server.key >/dev/null 2>&1
  rm -rf "$tmp"

  # Нужен полный перезапуск контейнера, а не отдельных служб. Файлы из
  # /data/ssl не читаются напрямую: init образа копирует их по местам при
  # старте (об этом и говорит README в этом каталоге). Перезапуск haraka,
  # dovecot и nginx через s6 сертификат не подхватывал — порты продолжали
  # отдавать самоподписанный. Заодно supervisorctl в образе нет вовсе:
  # процессами управляет s6.
  if docker restart poste >/dev/null 2>&1; then
    ok "poste" "перезапущен для применения сертификата"
  else
    fail "перезапуск" "не удался"
    hint "Примени вручную: docker restart poste"
    summary "" "Сертификат скопирован, но не применён"
    return 1
  fi

  local i
  for (( i = 1; i <= 45; i++ )); do
    if tcp_probe 127.0.0.1 993 2; then
      ok "IMAPS" "отвечает после перезапуска"
      break
    fi
    sleep 2
  done

  summary "Сертификаты синхронизированы" "Синхронизация не удалась"
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH: ключи вместо пароля
#
# Имя файла начинается с 01 не для красоты. В OpenSSH выигрывает ПЕРВОЕ
# вхождение параметра, а Include в sshd_config стоит раньше большинства
# директив. Облачные образы кладут туда 50-cloud-init.conf с
# PasswordAuthentication yes, и файл с именем 99-* проиграл бы ему: отчёт
# сообщил бы об успехе, а вход по паролю продолжал бы работать.
# ─────────────────────────────────────────────────────────────────────────────

SSHD_DROPIN=/etc/ssh/sshd_config.d/01-mailstack.conf

ssh_add_key() {
  local src=$1 key=''

  if [[ $src == http*://* ]]; then
    key=$(curl -fsSL --max-time 15 "$src" 2>/dev/null)
  elif [[ -r $src ]]; then
    key=$(cat "$src")
  else
    # Строку с самим ключом тоже принимаем
    key=$src
  fi

  # Валидируем именно как публичный ключ: мусор в authorized_keys приведёт
  # к отказу входа, который потом долго ищут
  local tmp; tmp=$(mktemp)
  printf '%s\n' "$key" > "$tmp"
  if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    fail "публичный ключ" "не распознан: ${src:0:60}"
    return 1
  fi
  local fp; fp=$(ssh-keygen -l -f "$tmp" 2>/dev/null | head -1)
  rm -f "$tmp"

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys

  if grep -qxF "$key" /root/.ssh/authorized_keys 2>/dev/null; then
    ok "ключ уже добавлен" "$fp"
  else
    printf '%s\n' "$key" >> /root/.ssh/authorized_keys
    ok "ключ добавлен" "$fp"
  fi
  return 0
}

ssh_count_keys() {
  [[ -f /root/.ssh/authorized_keys ]] || { echo 0; return; }
  # grep -c печатает число и БЕЗ совпадений, но выходит с кодом 1.
  # Ветка || echo 0 дописывала вторую строку — получалось "0\n0", и
  # арифметическое сравнение падало, пропуская защиту.
  local n
  n=$(grep -cvE '^[[:space:]]*(#|$)' /root/.ssh/authorized_keys 2>/dev/null)
  n=${n//[^0-9]/}
  echo "${n:-0}"
}

cmd_ssh_key() {
  printf '%smailstack ssh-key%s v%s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION"
  need_root
  [[ $# -gt 0 ]] || die "укажи ключ: mailstack.sh ssh-key ~/.ssh/id_ed25519.pub | URL | 'ssh-ed25519 AAAA...'"
  head1 "Добавление публичного ключа"
  local a
  for a in "$@"; do ssh_add_key "$a"; done
  info "ключей в authorized_keys" "$(ssh_count_keys)"
  head1 "Дальше"
  info "1. проверь вход" "ssh -i <приватный ключ> root@<адрес>"
  info "2. отключи пароль" "mailstack.sh ssh-harden"
  summary "Ключ на месте" "Ключ добавить не удалось"
}

cmd_ssh_harden() {
  local confirm_only=0 rollback=0 minutes=10 TESTED_KEY=0
  while (( $# )); do
    case "$1" in
      --confirm)  confirm_only=1; shift ;;
      --i-tested-key-login) TESTED_KEY=1; shift ;;
      --rollback) rollback=1; shift ;;
      --timeout)  minutes=${2:-10}; shift 2 ;;
      -y|--yes)   ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг ssh-harden: $1" ;;
    esac
  done

  printf '%smailstack ssh-harden%s v%s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION"
  need_root

  if (( confirm_only )); then
    # Отменяем автооткат — значит вход по ключу подтверждён
    systemctl stop mailstack-ssh-rollback.timer >/dev/null 2>&1
    systemctl reset-failed mailstack-ssh-rollback.timer mailstack-ssh-rollback.service >/dev/null 2>&1
    head1 "Подтверждено"
    ok "автооткат отменён" "парольный вход остаётся отключённым"
    summary "Готово" ""
  fi

  if (( rollback )); then
    rm -f "$SSHD_DROPIN"
    systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1
    head1 "Откат"
    ok "парольный вход восстановлен" "$(sshd -T 2>/dev/null | grep '^passwordauthentication')"
    summary "Откат выполнен" ""
  fi

  head1 "Проверка перед отключением пароля"
  local n; n=$(ssh_count_keys)
  if [[ ${n:-0} -lt 1 ]]; then
    fail "authorized_keys" "ключей нет — отключать пароль нельзя"
    hint "Сначала добавь ключ: mailstack.sh ssh-key <файл|URL>"
    die "нет ни одного публичного ключа"
  fi
  ok "authorized_keys" "$n ключ(ей)"
  info "текущее значение" "$(sshd -T 2>/dev/null | grep '^passwordauthentication')"

  printf '\n  %sОтключение пароля до проверки входа по ключу запирает снаружи.%s\n' "$C_YEL" "$C_OFF"
  printf '  Убедись в другом терминале, что вход по ключу работает.\n\n'
  # ASSUME_YES сюда намеренно не пускаем: этот шаг при ошибке отрезает
  # доступ к машине, поэтому требует либо живого человека у терминала,
  # либо отдельного явного флага.
  if (( TESTED_KEY )); then
    info "подтверждение" "--i-tested-key-login"
  elif has_tty; then
    local ans
    printf '  %s?%s Вход по ключу проверен, отключаем пароль? [y/N]: ' "$C_BLU" "$C_OFF" > /dev/tty
    IFS= read -r ans < /dev/tty || ans=''
    [[ $ans =~ ^[yYдД] ]] || die "отменено"
  else
    die "нет терминала. Для неинтерактивного запуска нужен флаг --i-tested-key-login"
  fi

  cat > "$SSHD_DROPIN" <<'CONF'
# mailstack: вход только по ключу.
# Имя файла начинается с 01 намеренно — в OpenSSH выигрывает первое
# вхождение параметра, а 50-cloud-init.conf включает пароль обратно.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
CONF
  chmod 644 "$SSHD_DROPIN"

  if ! sshd -t 2>/tmp/sshd-test.log; then
    fail "конфигурация sshd" "не проходит проверку"
    sed 's/^/        /' /tmp/sshd-test.log
    rm -f "$SSHD_DROPIN"
    die "конфиг откачен, ничего не изменено"
  fi
  ok "конфигурация sshd" "синтаксис корректен"

  # reload, а не restart: перезагрузка конфига не рвёт текущие сессии
  systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1
  local eff; eff=$(sshd -T 2>/dev/null | grep '^passwordauthentication')
  if [[ $eff == *no ]]; then
    ok "парольный вход" "отключён ($eff)"
  else
    fail "парольный вход" "всё ещё включён ($eff)"
    hint "Проверь порядок файлов в /etc/ssh/sshd_config.d/ — выигрывает первый."
  fi

  # Страховка: если вход по ключу всё-таки не работает, конфиг вернётся сам
  systemd-run --unit=mailstack-ssh-rollback --on-active="${minutes}min" \
    /bin/bash -c "rm -f $SSHD_DROPIN; systemctl reload ssh 2>/dev/null || systemctl reload sshd" \
    >/dev/null 2>&1 \
    && ok "автооткат" "через ${minutes} мин, если не подтвердить" \
    || warn "автооткат" "не удалось запланировать — откат только вручную"

  head1 "Важно"
  printf '  %sСейчас открой НОВОЕ соединение по ключу и проверь вход.%s\n' "$C_BLD" "$C_OFF"
  info "получилось" "mailstack.sh ssh-harden --confirm   (отменит автооткат)"
  info "не получилось" "ничего не делай — через ${minutes} мин пароль вернётся сам"
  info "откатить сразу" "mailstack.sh ssh-harden --rollback"
  summary "Пароль отключён, автооткат взведён" "Есть проблемы"
}

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL — откат сделанного
#
# Два уровня. Без флагов сносится только стек: контейнеры, тома, каталог
# установки — то, что нужно для повторной итерации. С --purge откатываются
# и системные изменения, но лишь те, которых на машине не было до нас:
# снимок состояния из bootstrap не даёт снести чужой Docker или выключить
# ufw, включённый кем-то раньше.
# ─────────────────────────────────────────────────────────────────────────────

MAILSTACK_CONTAINERS=(poste npm portainer uptime-kuma autoconfig backrest)

remove_stack() {
  have docker || { info "стек" "Docker не установлен, удалять нечего"; return; }
  docker info >/dev/null 2>&1 || { warn "стек" "Docker не отвечает"; return; }

  # Сначала штатная остановка через compose, если файлы на месте
  local cf via_compose=0
  for cf in "$MAILSTACK_DIR"/compose/*.yml "$MAILSTACK_DIR"/docker-compose.yml; do
    [[ -f $cf ]] || continue
    via_compose=1
    docker compose -f "$cf" down -v --remove-orphans >/dev/null 2>&1 \
      && ok "compose down" "$(basename "$cf")" \
      || warn "compose down" "$(basename "$cf") — не удалось, удалю вручную"
  done

  # Затем добиваем всё, что осталось с нашими именами
  local c left=0
  for c in "${MAILSTACK_CONTAINERS[@]}"; do
    if docker ps -aq -f "name=^${c}$" 2>/dev/null | grep -q .; then
      docker rm -f "$c" >/dev/null 2>&1 && ok "контейнер удалён" "$c" || { fail "контейнер" "$c"; left=1; }
    fi
  done
  (( via_compose == 0 && left == 0 )) && info "контейнеры" "наших контейнеров не найдено"

  local v
  for v in $(docker volume ls -q 2>/dev/null | grep -E '^(mailstack|poste|npm|portainer|uptime|backrest)' || true); do
    docker volume rm "$v" >/dev/null 2>&1 && ok "том удалён" "$v"
  done

  docker network rm proxy >/dev/null 2>&1 && ok "сеть удалена" "proxy"
}

purge_docker() {
  if (( ${HAD_DOCKER:-0} )); then
    info "Docker" "был установлен до нас — оставляю"
    return
  fi
  # Без этой проверки отчёт рапортует об удалении того, чего не было
  if ! have docker && [[ ! -d /var/lib/docker ]]; then
    info "Docker" "не установлен"
    return
  fi
  # Чужие контейнеры — повод не сносить Docker целиком
  local others
  others=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
  if [[ ${others:-0} -gt 0 ]]; then
    warn "Docker" "остались посторонние контейнеры ($others) — не удаляю"
    hint "Удали их сам, если Docker больше не нужен."
    return
  fi
  systemctl stop docker docker.socket containerd >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >/dev/null 2>&1
  rm -rf /var/lib/docker /var/lib/containerd
  rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
  (( ${HAD_DAEMON_JSON:-0} )) || rm -f /etc/docker/daemon.json
  rmdir /etc/docker 2>/dev/null
  ok "Docker удалён" "вместе с образами и томами"
}

purge_swap() {
  if (( ${HAD_SWAP:-0} )); then
    info "swap" "был до нас — оставляю"
    return
  fi
  [[ -f /swapfile ]] || { info "swap" "/swapfile отсутствует"; return; }
  swapoff /swapfile >/dev/null 2>&1
  rm -f /swapfile
  sed -i '\|^/swapfile |d' /etc/fstab
  sed -i '/^vm.swappiness=10$/d' /etc/sysctl.conf
  ok "swap удалён" "/swapfile, запись в fstab и vm.swappiness"
}

purge_hostname() {
  local orig=${ORIG_HOSTNAME:-}
  if [[ -z $orig ]]; then
    warn "hostname" "исходное имя неизвестно — оставляю как есть"
    return
  fi
  local current; current=$(hostname)
  [[ $current == "$orig" ]] && { info "hostname" "$orig — уже исходный"; return; }
  hostnamectl set-hostname "$orig" >/dev/null 2>&1
  # Убираем только строку, которую добавляли сами
  [[ -n ${MAIL_HOSTNAME:-} ]] && sed -i "\|^127\.0\.1\.1[[:space:]].*$MAIL_HOSTNAME|d" /etc/hosts
  ok "hostname возвращён" "$orig"
}

purge_firewall() {
  have ufw || { info "ufw" "не установлен"; return; }
  if (( ${HAD_UFW_ACTIVE:-0} )); then
    info "ufw" "был активен до нас — оставляю правила"
    return
  fi
  # reset выключает ufw и очищает правила; политика возвращается к ACCEPT,
  # поэтому текущая ssh-сессия не рвётся
  ufw --force reset >/dev/null 2>&1 && ok "ufw сброшен" "правила удалены, файрвол выключен"
}

purge_fail2ban() {
  if (( ${HAD_FAIL2BAN:-0} )); then
    info "fail2ban" "был до нас — оставляю"
    return
  fi
  if [[ ! -d /etc/fail2ban ]] && ! have fail2ban-server; then
    info "fail2ban" "не установлен"
    return
  fi
  systemctl stop fail2ban >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq fail2ban >/dev/null 2>&1
  rm -rf /etc/fail2ban
  ok "fail2ban удалён" ""
}

purge_ssh_hardening() {
  [[ -f $SSHD_DROPIN ]] || { info "ssh" "парольный вход не отключался"; return; }
  rm -f "$SSHD_DROPIN"
  systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1
  ok "ssh" "парольный вход восстановлен"
}

cmd_uninstall() {
  local purge=0 keep_env=0
  while (( $# )); do
    case "$1" in
      --purge)    purge=1; shift ;;
      --keep-env) keep_env=1; shift ;;
      -y|--yes)   ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг uninstall: $1" ;;
    esac
  done

  printf '%smailstack uninstall%s v%s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION"
  need_root
  load_env
  load_state || warn "снимок состояния" "не найден — системные изменения откатить не смогу"

  head1 "Что будет удалено"
  info "контейнеры и тома" "почта, настройки NPM, сертификаты — безвозвратно"
  info "каталог" "$MAILSTACK_DIR"
  if (( purge )); then
    (( ${HAD_DOCKER:-0} ))     || info "Docker" "будет удалён вместе с образами"
    (( ${HAD_SWAP:-0} ))       || info "swap" "/swapfile будет удалён"
    (( ${HAD_UFW_ACTIVE:-0} )) || info "ufw" "правила будут сброшены, файрвол выключен"
    (( ${HAD_FAIL2BAN:-0} ))   || info "fail2ban" "будет удалён"
    [[ -n ${ORIG_HOSTNAME:-} ]] && info "hostname" "вернётся на ${ORIG_HOSTNAME}"
  else
    info "системные изменения" "останутся (Docker, swap, ufw) — для --purge укажи флаг"
  fi

  printf '\n  %sПочтовые данные и сертификаты восстановлению не подлежат.%s\n\n' "$C_YEL" "$C_OFF"
  confirm "Удалить?" || die "отменено"

  N_PASS=0; N_WARN=0; N_FAIL=0

  head1 "Удаление стека"
  remove_stack

  # .env хранит креды релея — его сохранение экономит время на повторной
  # установке, но по умолчанию он всё же удаляется вместе с каталогом.
  if (( keep_env )) && [[ -f "$MAILSTACK_DIR/.env" ]]; then
    cp "$MAILSTACK_DIR/.env" "/root/mailstack.env.saved"
    chmod 600 /root/mailstack.env.saved
    ok ".env сохранён" "/root/mailstack.env.saved"
  fi

  if [[ -d $MAILSTACK_DIR ]]; then
    rm -rf "$MAILSTACK_DIR" && ok "каталог удалён" "$MAILSTACK_DIR"
  fi

  if (( purge )); then
    head1 "Откат системных изменений"
    purge_docker
    purge_swap
    purge_hostname
    purge_firewall
    purge_fail2ban
    purge_ssh_hardening
    info "пакеты" "curl, jq, dnsutils, whois оставлены — общесистемные"
    info "apt upgrade" "откату не подлежит, и в этом нет нужды"
  fi

  head1 "Готово"
  if (( purge )); then
    info "машина" "приведена к состоянию до bootstrap"
  else
    info "повторная установка" "mailstack.sh deploy — Docker и swap уже на месте"
  fi
  summary "Удаление завершено" "Удаление завершилось с ошибками"
}

compose_up() {
  local file=$1 name=$2
  docker compose --env-file "$MAILSTACK_DIR/.env" -f "$file" up -d >/tmp/mailstack-up.log 2>&1 \
    && ok "$name" "запущен" \
    || { fail "$name" "не запустился"; sed 's/^/        /' /tmp/mailstack-up.log | tail -6; return 1; }
}

# Ждём, пока контейнер действительно начнёт отвечать. Docker сообщает
# «running» сразу после старта процесса, задолго до готовности сервиса,
# и следующий шаг по этому признаку запускать рано.
wait_for_port() {
  local host=$1 port=$2 name=$3 tries=${4:-30}
  local i
  for (( i = 1; i <= tries; i++ )); do
    if tcp_probe "$host" "$port" 2; then
      ok "$name" "отвечает на $host:$port"
      return 0
    fi
    sleep 2
  done
  warn "$name" "не ответил за $((tries * 2)) с — проверь логи"
  return 1
}

cmd_deploy() {
  local do_pull=0
  while (( $# )); do
    case "$1" in
      --pull)   do_pull=1; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг deploy: $1" ;;
    esac
  done

  printf '%smailstack deploy%s v%s — %s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION" "$(date '+%Y-%m-%d %H:%M')"
  need_root
  load_env

  [[ -n ${MAIL_DOMAIN:-} ]]   || die "не задан MAIL_DOMAIN — сначала выполни bootstrap"
  [[ -n ${MAIL_HOSTNAME:-} ]] || MAIL_HOSTNAME="mail.$MAIL_DOMAIN"
  : "${TZ:=UTC}"
  export TZ MAIL_DOMAIN MAIL_HOSTNAME MAILSTACK_DIR
  export KUMA_IMAGE NPM_IMAGE PORTAINER_IMAGE POSTE_IMAGE AUTOCONFIG_IMAGE

  have docker || die "Docker не установлен — сначала выполни bootstrap"
  docker info >/dev/null 2>&1 || die "Docker не отвечает"

  COMPOSE_DIR="$MAILSTACK_DIR/compose"
  mkdir -p "$COMPOSE_DIR"

  head1 "Параметры"
  info "домен" "$MAIL_DOMAIN"
  info "почтовый хост" "$MAIL_HOSTNAME"
  info "часовой пояс" "$TZ"
  info "каталог" "$MAILSTACK_DIR"
  if [[ -n ${RELAY_HOST:-} ]]; then
    info "SMTP-релей" "$RELAY_HOST:${RELAY_PORT:-587}"
  else
    warn "SMTP-релей" "не настроен — отправка наружу возможна только при открытом 25"
  fi

  head1 "Генерация compose-файлов"
  write_compose_npm        && ok "10-npm.yml" "NPM — 80, 443, админка на 127.0.0.1:81"
  write_compose_portainer  && ok "20-portainer.yml" "Portainer — 127.0.0.1:9000"
  write_compose_poste      && ok "30-poste.yml" "Poste.io — 25, 465, 587, 993, 995"
  write_compose_kuma       && ok "40-kuma.yml" "Uptime Kuma — 127.0.0.1:3001"
  write_compose_autoconfig && ok "50-autoconfig.yml" "autoconfig/autodiscover"

  head1 "Сеть"
  if docker network inspect proxy >/dev/null 2>&1; then
    ok "сеть proxy" "уже существует"
  else
    docker network create proxy >/dev/null 2>&1 && ok "сеть proxy" "создана" \
      || { fail "сеть proxy" "не создана"; die "без общей сети сервисы не увидят друг друга"; }
  fi

  if (( do_pull )); then
    head1 "Загрузка образов"
    local f
    for f in "$COMPOSE_DIR"/*.yml; do
      docker compose --env-file "$MAILSTACK_DIR/.env" -f "$f" pull >/dev/null 2>&1 \
        && ok "$(basename "$f")" "образы обновлены" \
        || warn "$(basename "$f")" "не удалось обновить образы"
    done
  fi

  head1 "Запуск"
  # NPM первым: он владеет 80 и 443, и если порты заняты — остальное
  # поднимать бессмысленно
  compose_up "$COMPOSE_DIR/10-npm.yml" "npm" || die "NPM не запустился, дальше нет смысла"
  wait_for_port 127.0.0.1 81 "админка NPM" 30

  compose_up "$COMPOSE_DIR/20-portainer.yml" "portainer"
  compose_up "$COMPOSE_DIR/30-poste.yml" "poste"
  compose_up "$COMPOSE_DIR/40-kuma.yml" "uptime-kuma"
  compose_up "$COMPOSE_DIR/50-autoconfig.yml" "autoconfig"

  head1 "Готовность сервисов"
  # Poste.io при первом запуске разворачивает базу и генерирует ключи —
  # это заметно дольше остальных контейнеров
  wait_for_port 127.0.0.1 25 "poste (SMTP)" 60
  wait_for_port 127.0.0.1 9000 "portainer" 20
  wait_for_port 127.0.0.1 3001 "uptime-kuma" 20

  head1 "Что дальше"
  printf '  %s1.%s Админка NPM — только локально, поэтому через ssh-туннель:\n' "$C_BLD" "$C_OFF"
  printf '     ssh -L 8181:127.0.0.1:81 root@<адрес сервера>\n'
  printf '     затем http://localhost:8181  —  вход admin@example.com / changeme\n'
  printf '     %sпароль меняется при первом входе%s\n\n' "$C_YEL" "$C_OFF"
  printf '  %s2.%s Создать в NPM proxy hosts (Add Proxy Host → вкладка SSL → Request new certificate):\n' "$C_BLD" "$C_OFF"
  printf '     %-28s → poste:80\n'        "$MAIL_HOSTNAME"
  printf '     %-28s → uptime-kuma:3001\n' "status.$MAIL_DOMAIN"
  printf '     %-28s → portainer:9000\n'   "portainer.$MAIL_DOMAIN"
  printf '     %-28s → autoconfig:80\n'    "autoconfig.$MAIL_DOMAIN"
  printf '     %-28s → autoconfig:80\n\n'  "autodiscover.$MAIL_DOMAIN"
  printf '  %s3.%s Подтянуть сертификат в Poste.io — иначе порты 465 и 993\n' "$C_BLD" "$C_OFF"
  printf '     отдадут клиентам ошибку TLS:\n'
  printf '     mailstack.sh certs-sync\n\n'
  printf '  %s4.%s Создать домен и первый ящик в админке https://%s\n' "$C_BLD" "$C_OFF" "$MAIL_HOSTNAME"
  printf '     Там же появится значение DKIM для записи s1._domainkey\n'
  printf '     %sИ там же задать hostname сервера — по умолчанию образ%s\n' "$C_YEL" "$C_OFF"
  printf '     %sпредставляется как mail.example.com. Gmail и Microsoft сверяют%s\n' "$C_YEL" "$C_OFF"
  printf '     %sHELO с PTR и снижают репутацию при несовпадении.%s\n\n' "$C_YEL" "$C_OFF"
  printf '  %s5.%s Добавить MX: %s  MX 10 %s\n\n' "$C_BLD" "$C_OFF" "$MAIL_DOMAIN" "$MAIL_HOSTNAME"

  summary "Стек запущен" "Запуск завершился с ошибками"
}

cmd_preflight() {
  printf '%smailstack preflight%s v%s — %s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  need_root
  local ip; ip=$(detect_public_ip)

  check_identity
  check_os
  check_virtualization
  check_resources
  check_packages
  check_ports
  check_network
  check_smtp_egress
  check_rdns "$ip"
  check_dnsbl "$ip"

  summary "Машина готова к 'mailstack.sh bootstrap'" \
          "Установка невозможна — устрани ошибки выше"
}

cmd_doctor() {
  local external=0 host='' domain="${MAIL_DOMAIN:-}"
  while (( $# )); do
    case "$1" in
      --external) external=1; shift ;;
      --host)     host=${2:-}; shift 2 ;;
      --domain)   domain=${2:-}; shift 2 ;;
      *) die "неизвестный флаг doctor: $1" ;;
    esac
  done

  printf '%smailstack doctor%s v%s — %s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

  if (( external )); then
    [[ -n $host ]] || die "для --external нужен --host <mail.example.com или IP>"
    doctor_external "$host" "$domain"
  else
    need_root
    load_env
    local ip; ip=$(detect_public_ip)
    check_resources
    check_ports_listening
    check_stack
    check_relay
    check_rdns "$ip"
    check_dnsbl "$ip"
    [[ -n $domain ]] && check_domain_dns "$domain" "$ip"
    summary "Стек в порядке" "Найдены проблемы — см. выше"
  fi
}

# Проверка снаружи: то, что принципиально не видно с самого сервера.
# Локальный ss покажет LISTEN, даже если провайдер режет порт на своём фильтре.
doctor_external() {
  local host=$1 domain=${2:-}
  head1 "Внешняя проверка $host"

  local ip
  if [[ $host =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip=$host
  else
    ip=$(dns_query "$host" A | head -1)
    if [[ -z $ip ]]; then fail "A $host" "не резолвится"; summary "" "Проверка невозможна"; return; fi
    ok "A $host" "$ip"
  fi

  head1 "Доступность портов из интернета"
  for p in 25 80 443 465 587 993 995; do
    local desc; desc=$(port_desc "$p")
    if tcp_probe "$ip" "$p" 6; then
      ok "порт $p" "$desc"
    else
      fail "порт $p" "недоступен — $desc"
    fi
  done

  head1 "Порты, которые НЕ должны быть открыты наружу"
  for p in 81 9000 9443 3001; do
    if tcp_probe "$ip" "$p" 4; then
      fail "порт $p" "открыт наружу — админка доступна всему интернету, закрой в ufw"
    else
      ok "порт $p" "закрыт, как и задумано"
    fi
  done

  head1 "SMTP-баннеры"
  for p in 25 587; do
    local b; b=$(smtp_banner "$ip" "$p" 8)
    if [[ -n $b ]]; then
      ok "баннер :$p" "$b"
      # HELO-имя в баннере должно совпадать с PTR, иначе Gmail снижает
      # репутацию отправителя.
      [[ $b == *"$host"* ]] || warn "баннер :$p" "не содержит $host — проверь myhostname"
    else
      warn "баннер :$p" "нет ответа"
    fi
  done

  local ptr; ptr=$(dns_query "$(reverse_ip "$ip").in-addr.arpa" PTR | head -1); ptr=${ptr%.}
  head1 "Обратная зона"
  if [[ -z $ptr ]]; then warn "PTR" "не задан для $ip"
  elif [[ $ptr == "$host" ]]; then ok "PTR" "$ip -> $ptr, совпадает с хостом"
  else warn "PTR" "$ip -> $ptr, а ожидался $host"; fi

  check_dnsbl "$ip"

  if [[ ! $host =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    local res; res=$(check_cert_expiry "$host")
    IFS='|' read -r st f2 f3 f4 <<<"$res"
    case "$st" in
      OK)  if (( f4 < 14 )); then warn "сертификат" "CN=$f2, $f3, истекает через $f4 дн."
           else ok "сертификат" "CN=$f2, $f3, ещё $f4 дн."; fi ;;
      BAD) fail "сертификат" "не проходит проверку: $f2" ;;
      *)   warn "сертификат" "${f2:-нет ответа на 443}" ;;
    esac
  fi

  [[ -n $domain ]] && check_domain_dns "$domain" "$ip"

  summary "Стенд доступен снаружи корректно" "Есть проблемы с доступностью"
}

# Русское склонение после числительного: 1 ошибка, 2 ошибки, 5 ошибок
plural() {
  local n=$1 one=$2 few=$3 many=$4
  local n100=$((n % 100)) n10=$((n % 10))
  if (( n100 >= 11 && n100 <= 14 )); then echo "$many"
  elif (( n10 == 1 )); then echo "$one"
  elif (( n10 >= 2 && n10 <= 4 )); then echo "$few"
  else echo "$many"; fi
}

summary() {
  local good=$1 bad=$2
  printf '\n%s─────────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"
  printf '  %s%d пройдено%s   %s%d %s%s   %s%d %s%s\n' \
    "$C_GRN" "$N_PASS" "$C_OFF" \
    "$C_YEL" "$N_WARN" "$(plural "$N_WARN" предупреждение предупреждения предупреждений)" "$C_OFF" \
    "$C_RED" "$N_FAIL" "$(plural "$N_FAIL" ошибка ошибки ошибок)" "$C_OFF"
  if (( N_FAIL > 0 )); then
    printf '  %s%s%s\n\n' "$C_RED" "$bad" "$C_OFF"
    exit 1
  fi
  printf '  %s%s%s\n\n' "$C_GRN" "$good" "$C_OFF"
  exit 0
}

cmd_todo() {
  die "команда '$1' ещё не реализована — сейчас доступны preflight и doctor"
}

usage() {
  cat <<EOF
${C_BLD}mailstack.sh${C_OFF} v$MAILSTACK_VERSION — почтовый стек на Poste.io

${C_BLD}Команды${C_OFF}
  preflight          Проверить, можно ли ставить стек на эту машину
  domain DOMAIN      Проверить домен: регистрация, делегирование, CAA, записи
                     --ip ADDR — с каким адресом сверять A-записи
  bootstrap          Подготовка ОС: swap, Docker, ufw, hostname, fail2ban
  doctor             Диагностика: репутация IP, DNS, порты, контейнеры
  relay-test         Проверить SMTP-релей: соединение, STARTTLS, аутентификация
  ssh-key FILE|URL   Добавить публичный ключ в authorized_keys
  ssh-harden         Отключить вход по паролю (только после проверки ключа)
  uninstall          Удалить стек; с --purge — откатить и системные изменения
  deploy             Развернуть стек (--pull — обновить образы)
  npm-setup          Создать proxy hosts и выпустить сертификаты через API NPM
  certs-sync         Подтянуть сертификат из NPM в Poste.io для SMTP/IMAP
  update             Обновить образы (--system — и пакеты ОС)
  backup             Снять бэкап; backup setup — настроить хранилище
  restore            Восстановить из бэкапа (--clean — точный откат к снимку)
  migrate            Переезд: migrate prepare / migrate finish

${C_BLD}Флаги bootstrap${C_OFF}
  --domain DOMAIN    Основной домен (иначе спросит интерактивно)
  --hostname FQDN    FQDN почтового хоста (по умолчанию mail.\$DOMAIN)
  --email ADDR       Email для Let's Encrypt
  --tz ZONE          Часовой пояс
  --skip-domain-check  Не проверять домен перед установкой
  --no-relay         Продолжить без SMTP-релея (только приём почты)
  --trusted-ip ADDR  Не банить этот адрес в fail2ban (можно повторять)
  -y, --yes          Не задавать вопросов (для автоматизации)

${C_BLD}Флаги backup / update${C_OFF}
  backup setup --repo REPO   Подключить хранилище без вопросов
  backup --no-stop           Не останавливать Poste.io на время снимка
  update --system            Обновить и пакеты ОС
  update --no-backup         Не снимать бэкап перед обновлением

${C_BLD}Флаги ssh-harden${C_OFF}
  --confirm          Подтвердить, что вход по ключу работает (отменяет автооткат)
  --rollback         Немедленно вернуть парольный вход
  --timeout MIN      Через сколько минут сработает автооткат (по умолчанию 10)

${C_BLD}Флаги npm-setup${C_OFF}
  --admin-email ADDR Логин администратора NPM (по умолчанию — email для LE)
  --no-certs         Создать хосты без выпуска сертификатов

${C_BLD}Флаги uninstall${C_OFF}
  --purge            Откатить и системные изменения: Docker, swap, ufw,
                     fail2ban, hostname — но только те, которых не было до нас
  --keep-env         Сохранить .env в /root/mailstack.env.saved
  -y, --yes          Не спрашивать подтверждения

${C_BLD}Флаги doctor${C_OFF}
  --external         Проверка снаружи (запускать с рабочей машины, не с сервера)
  --host HOST        Хост или IP для внешней проверки
  --domain DOMAIN    Проверить A/MX/SPF/DKIM/DMARC этого домена

${C_BLD}Примеры${C_OFF}
  # на чистом сервере
  curl -fsSL https://raw.githubusercontent.com/iMironRU/mailstack/main/mailstack.sh | bash -s -- preflight

  # снаружи, после развёртывания
  ./mailstack.sh doctor --external --host mail.example.com --domain example.com

${C_BLD}Переменные окружения${C_OFF}
  MAILSTACK_DIR      Каталог установки (по умолчанию /opt/mailstack)
  MAIL_DOMAIN        Основной домен стенда
  MAIL_HOSTNAME      FQDN почтового хоста (по умолчанию mail.\$MAIL_DOMAIN)
EOF
}

main() {
  local cmd=${1:-help}
  shift || true
  case "$cmd" in
    preflight) cmd_preflight "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    domain)    cmd_domain "$@" ;;
    relay-test) cmd_relay_test "$@" ;;
    bootstrap) cmd_bootstrap "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    ssh-key)    cmd_ssh_key "$@" ;;
    ssh-harden) cmd_ssh_harden "$@" ;;
    deploy)     cmd_deploy "$@" ;;
    certs-sync) cmd_certs_sync "$@" ;;
    npm-setup)  cmd_npm_setup "$@" ;;
    backup)  cmd_backup "$@" ;;
    restore) cmd_restore "$@" ;;
    update)  cmd_update "$@" ;;
    migrate) cmd_migrate "$@" ;;
    help|--help|-h) usage ;;
    version|--version) echo "mailstack.sh $MAILSTACK_VERSION" ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
