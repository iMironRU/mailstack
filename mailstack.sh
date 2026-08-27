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
dns_query() {
  local name=$1 type=${2:-A}
  if have dig; then
    dig +short +time=3 +tries=1 "$name" "$type" 2>/dev/null
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

  local a; a=$(dns_query "$mail_host" A | head -1)
  if [[ -z $a ]]; then
    fail "A $mail_host" "не задана — Let's Encrypt не выдаст сертификат"
  elif [[ -n $ip && $a != "$ip" ]]; then
    fail "A $mail_host" "указывает на $a, а сервер имеет $ip"
  else
    ok "A $mail_host" "$a"
  fi

  for sub in status portainer; do
    local sa; sa=$(dns_query "$sub.$domain" A | head -1)
    if [[ -z $sa ]]; then warn "A $sub.$domain" "не задана"
    elif [[ -n $ip && $sa != "$ip" ]]; then warn "A $sub.$domain" "указывает на $sa"
    else ok "A $sub.$domain" "$sa"; fi
  done

  local mx; mx=$(dns_query "$domain" MX | head -3 | tr '\n' ' ')
  if [[ -z $mx ]]; then
    fail "MX $domain" "не задана — входящая почта не придёт"
  elif grep -q "${mail_host%.}" <<<"$mx"; then
    ok "MX $domain" "$mx"
  else
    warn "MX $domain" "$mx — не указывает на $mail_host"
  fi

  local spf; spf=$(dns_query "$domain" TXT | grep -i 'v=spf1' | head -1)
  if [[ -z $spf ]]; then warn "SPF" "запись v=spf1 не найдена"
  else ok "SPF" "${spf:0:70}"; fi

  local dkim; dkim=$(dns_query "s1._domainkey.$domain" TXT | head -1)
  if [[ -z $dkim ]]; then
    warn "DKIM (s1._domainkey)" "не найдена — значение появится в админке Poste.io после создания домена"
  else
    ok "DKIM (s1._domainkey)" "${dkim:0:50}..."
  fi

  local dmarc; dmarc=$(dns_query "_dmarc.$domain" TXT | head -1)
  if [[ -z $dmarc ]]; then warn "DMARC" "запись _dmarc не найдена"
  else ok "DMARC" "${dmarc:0:70}"; fi
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

summary() {
  local good=$1 bad=$2
  printf '\n%s─────────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"
  printf '  %s%d пройдено%s   %s%d предупреждений%s   %s%d ошибок%s\n' \
    "$C_GRN" "$N_PASS" "$C_OFF" "$C_YEL" "$N_WARN" "$C_OFF" "$C_RED" "$N_FAIL" "$C_OFF"
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
  doctor             Диагностика: репутация IP, DNS, порты, контейнеры
  bootstrap          Подготовка ОС: swap, Docker, ufw, hostname      ${C_DIM}(в работе)${C_OFF}
  deploy             Развернуть стек                                  ${C_DIM}(в работе)${C_OFF}
  update             Обновить образы и систему                        ${C_DIM}(в работе)${C_OFF}
  backup / restore   Резервное копирование в S3 (restic)              ${C_DIM}(в работе)${C_OFF}
  migrate            Переезд на другую виртуалку                      ${C_DIM}(в работе)${C_OFF}

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
    bootstrap|deploy|update|backup|restore|migrate) cmd_todo "$cmd" ;;
    help|--help|-h) usage ;;
    version|--version) echo "mailstack.sh $MAILSTACK_VERSION" ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
