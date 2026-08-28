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
  if tcp_probe smtp.gmail.com 587 8; then
    ok "исходящий порт 587" "открыт (relay возможен)"
  else
    warn "исходящий порт 587" "закрыт — relay через сторонний SMTP не заработает"
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

  local dkim; dkim=$(dns_auth "s1._domainkey.$domain" TXT | head -1)
  if [[ -z $dkim ]]; then
    warn "DKIM (s1._domainkey)" "не найдена — значение появится в админке Poste.io после создания домена"
  else
    ok "DKIM (s1._domainkey)" "${dkim:0:50}..."
  fi

  local dmarc; dmarc=$(dns_auth "_dmarc.$domain" TXT | head -1)
  if [[ -z $dmarc ]]; then warn "DMARC" "запись _dmarc не найдена"
  else ok "DMARC" "${dmarc:0:70}"; fi
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
  local domain=${1:-${MAIL_DOMAIN:-}}
  [[ -n $domain ]] || die "укажи домен: mailstack.sh domain example.com"
  printf '%smailstack domain%s v%s — проверка %s\n' "$C_BLD" "$C_OFF" "$MAILSTACK_VERSION" "$domain"

  if ! have dig; then
    die "нужен dig. Установи: apt-get install -y dnsutils"
  fi

  local ip; ip=$(detect_public_ip)
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
  if [[ ! -f /etc/fail2ban/jail.local ]]; then
    cat > /etc/fail2ban/jail.local <<'CONF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
CONF
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
    check_ports
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
  bootstrap          Подготовка ОС: swap, Docker, ufw, hostname, fail2ban
  doctor             Диагностика: репутация IP, DNS, порты, контейнеры
  relay-test         Проверить SMTP-релей: соединение, STARTTLS, аутентификация
  deploy             Развернуть стек                                  ${C_DIM}(в работе)${C_OFF}
  update             Обновить образы и систему                        ${C_DIM}(в работе)${C_OFF}
  backup / restore   Резервное копирование в S3 (restic)              ${C_DIM}(в работе)${C_OFF}
  migrate            Переезд на другую виртуалку                      ${C_DIM}(в работе)${C_OFF}

${C_BLD}Флаги bootstrap${C_OFF}
  --domain DOMAIN    Основной домен (иначе спросит интерактивно)
  --hostname FQDN    FQDN почтового хоста (по умолчанию mail.\$DOMAIN)
  --email ADDR       Email для Let's Encrypt
  --tz ZONE          Часовой пояс
  --skip-domain-check  Не проверять домен перед установкой
  --no-relay         Продолжить без SMTP-релея (только приём почты)
  -y, --yes          Не задавать вопросов (для автоматизации)

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
    deploy|update|backup|restore|migrate) cmd_todo "$cmd" ;;
    help|--help|-h) usage ;;
    version|--version) echo "mailstack.sh $MAILSTACK_VERSION" ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
