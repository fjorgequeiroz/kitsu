#!/usr/bin/env bash
# =============================================================================
# Kitsu Installer & Manager for Debian (bare-metal, no Docker for app services)
# Based on: https://dev.kitsu.cloud/self-hosting/setup.html
# Requires: Debian 12 (Bookworm) or later
#
# Unattended install:
#   sudo ./install_kitsu_debian.sh --config /path/to/kitsu_install.conf
#
# Config file template:  kitsu_install.conf.example  (auto-generated on first run)
# =============================================================================

set -euo pipefail

# ── Unattended config ─────────────────────────────────────────────────────────
UNATTENDED_CONFIG=""   # set via --config flag
declare -A _CONF       # key=value map loaded from the config file

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $*${NC}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"; }

# ── Paths & defaults ──────────────────────────────────────────────────────────
ZOU_DIR="/opt/zou"
ZOU_ENV="${ZOU_DIR}/zouenv"
ZOU_BIN="${ZOU_ENV}/bin"
ZOU_ENV_FILE="/etc/zou/zou.env"
KITSU_DIST="/opt/kitsu/dist"
NGINX_CONF="/etc/nginx/sites-available/zou"
NGINX_ENABLED="/etc/nginx/sites-enabled/zou"
BACKUP_DIR="${ZOU_DIR}/backups"
BACKUP_CRON_FILE="/etc/cron.d/kitsu-backup"
BACKUP_CONFIG_FILE="/etc/zou/backup.conf"
BACKUP_INSTALL_BIN="/usr/local/bin/kitsu"
DEFAULT_KEEP_VERSIONS=7
KEEP_VERSIONS="$DEFAULT_KEEP_VERSIONS"
REPORT_EMAIL=""
GMAIL_FROM=""
KITSU_HTTP_PORT=80
DB_PORT=5432
KITSU_CONF="/etc/zou/kitsu.conf"

# ── Root check ────────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi
}

# ── Unattended config helpers ────────────────────────────────────────────────
load_unattended_config() {
    local cfg="$1"
    if [[ ! -f "$cfg" ]]; then
        error "Config file not found: ${cfg}"
        exit 1
    fi
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key="${key// /}"
        val="${val%%#*}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        _CONF["$key"]="$val"
    done < "$cfg"
}

validate_unattended_config() {
    header "Validating Config File"

    local ok=true
    local -a errs warns

    # ── Required keys (missing = fatal) ──────────────────────────────────────
    _req() {
        local k="$1" desc="$2"
        if [[ -z "${_CONF[$k]:-}" ]]; then
            errs+=("MISSING   ${k}  (${desc})")
            ok=false
        fi
    }

    _req "DB_PASSWORD"    "PostgreSQL password"
    _req "ADMIN_EMAIL"    "Admin user email"
    _req "ADMIN_PASSWORD" "Admin user password"

    # ── Value checks ──────────────────────────────────────────────────────────

    # ADMIN_PASSWORD length
    local ap="${_CONF[ADMIN_PASSWORD]:-}"
    if [[ -n "$ap" && ${#ap} -lt 8 ]]; then
        errs+=("INVALID   ADMIN_PASSWORD  (too short — minimum 8 characters, got ${#ap})")
        ok=false
    fi

    # ADMIN_EMAIL format
    local ae="${_CONF[ADMIN_EMAIL]:-}"
    if [[ -n "$ae" && ! "$ae" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        errs+=("INVALID   ADMIN_EMAIL  (does not look like an email address: '${ae}')")
        ok=false
    fi

    # HTTP_PORT
    local hp="${_CONF[HTTP_PORT]:-80}"
    if ! [[ "$hp" =~ ^[0-9]+$ ]] || (( hp < 1 || hp > 65535 )); then
        errs+=("INVALID   HTTP_PORT  (must be 1–65535, got '${hp}')")
        ok=false
    fi

    # DB_PORT
    local dp="${_CONF[DB_PORT]:-5432}"
    if ! [[ "$dp" =~ ^[0-9]+$ ]] || (( dp < 1 || dp > 65535 )); then
        errs+=("INVALID   DB_PORT  (must be 1–65535, got '${dp}')")
        ok=false
    fi

    # ENABLE_SEARCH / ENABLE_JOBS must be y/n
    for _yn_key in ENABLE_SEARCH ENABLE_JOBS; do
        local _v="${_CONF[$_yn_key]:-y}"
        if [[ ! "$_v" =~ ^[yYnN]$ ]]; then
            errs+=("INVALID   ${_yn_key}  (must be y or n, got '${_v}')")
            ok=false
        fi
    done

    # ── Optional-but-paired checks (warn, not fatal) ──────────────────────────

    # Email (msmtp notifications): if GMAIL_FROM set, APP_PASSWORD must be set
    if [[ -n "${_CONF[GMAIL_FROM]:-}" && -z "${_CONF[GMAIL_APP_PASSWORD]:-}" ]]; then
        warns+=("GMAIL_FROM is set but GMAIL_APP_PASSWORD is empty — email notifications will be skipped")
    fi

    # Password-recovery SMTP: if MAIL_SERVER set, username+password must follow
    if [[ -n "${_CONF[MAIL_SERVER]:-}" ]]; then
        [[ -z "${_CONF[MAIL_USERNAME]:-}" ]] && \
            warns+=("MAIL_SERVER is set but MAIL_USERNAME is empty — password-recovery email will not work")
        [[ -z "${_CONF[MAIL_PASSWORD]:-}" ]] && \
            warns+=("MAIL_SERVER is set but MAIL_PASSWORD is empty — password-recovery email will not work")
    fi

    # ── Report ────────────────────────────────────────────────────────────────
    if [[ ${#errs[@]} -gt 0 ]]; then
        echo -e "\n  ${RED}${BOLD}Errors (must fix before install):${NC}"
        for e in "${errs[@]}"; do
            echo -e "  ${RED}✗${NC}  ${e}"
        done
    fi

    if [[ ${#warns[@]} -gt 0 ]]; then
        echo -e "\n  ${YELLOW}${BOLD}Warnings (install can proceed, but check these):${NC}"
        for w in "${warns[@]}"; do
            echo -e "  ${YELLOW}!${NC}  ${w}"
        done
    fi

    if [[ "$ok" == true && ${#warns[@]} -eq 0 ]]; then
        success "Config file looks good — all required values are present and valid."
        return 0
    fi

    echo
    if [[ "$ok" == false ]]; then
        error "Fix the errors above in ${UNATTENDED_CONFIG} then re-run."
        exit 1
    fi

    # Warnings only — ask to continue
    if ! prompt_yn "Warnings found. Continue anyway?" "n"; then
        info "Aborted."
        exit 0
    fi
}

conf_value() {
    local key="$1" prompt_text="$2" default_val="$3"
    if [[ -n "$UNATTENDED_CONFIG" ]]; then
        echo "${_CONF[$key]:-$default_val}"
    else
        prompt_value "$prompt_text" "$default_val"
    fi
}

conf_secret() {
    local key="$1" prompt_text="$2"
    if [[ -n "$UNATTENDED_CONFIG" ]]; then
        echo "${_CONF[$key]:-}"
    else
        prompt_secret "$prompt_text"
    fi
}

conf_yn() {
    local key="$1" prompt_text="$2" default_val="${3:-n}"
    if [[ -n "$UNATTENDED_CONFIG" ]]; then
        local v="${_CONF[$key]:-$default_val}"
        [[ "${v,,}" == "y" ]] && echo "y" || echo "n"
    else
        prompt_yn "$prompt_text" "$default_val" && echo "y" || echo "n"
    fi
}

write_config_example() {
    local dest="${1:-kitsu_install.conf.example}"
    cat > "$dest" <<EOF
# =============================================================================
# Kitsu unattended install configuration
# Usage: sudo ./install_kitsu_debian.sh --config kitsu_install.conf
#
# Copy this file, fill in your values, then run with --config.
# Lines starting with # are comments. Inline comments after # are also stripped.
# =============================================================================

# ── Server ────────────────────────────────────────────────────────────────────
SERVER_NAME=$(hostname -I | awk '{print $1}')
HTTP_PORT=80

# ── PostgreSQL ────────────────────────────────────────────────────────────────
DB_PASSWORD=mysecretpassword
DB_PORT=5432

# ── Kitsu admin account ───────────────────────────────────────────────────────
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=changeme123

# ── Storage paths ─────────────────────────────────────────────────────────────
PREVIEW_FOLDER=${ZOU_DIR}/previews
TMP_DIR=${ZOU_DIR}/tmp

# ── Optional features ─────────────────────────────────────────────────────────
ENABLE_SEARCH=y
ENABLE_JOBS=y

# ── Admin notifications (installer summary via msmtp) ─────────────────────────
# Leave GMAIL_FROM blank to skip.
GMAIL_FROM=
GMAIL_APP_PASSWORD=
REPORT_EMAIL=

# ── Password-recovery email (sent by Zou/Kitsu to users) ─────────────────────
# SMTP server Zou uses when a user clicks "Forgot password".
# For Gmail use smtp.gmail.com port 587 with an App Password.
MAIL_SERVER=smtp.gmail.com
MAIL_PORT=587
MAIL_USERNAME=
MAIL_PASSWORD=
MAIL_USE_TLS=true
MAIL_USE_SSL=false
MAIL_DEFAULT_SENDER=no-reply@your-studio.com
# DOMAIN_NAME must match the URL your users access Kitsu on (used in reset links)
DOMAIN_NAME=
EOF
    success "Config example written to: ${dest}"
}

# ── Service check ─────────────────────────────────────────────────────────────
require_zou_running() {
    if ! systemctl is-active --quiet zou; then
        error "Zou service is not running. Start it first: sudo systemctl start zou"
        exit 1
    fi
}

# ── Prompt helpers ────────────────────────────────────────────────────────────
prompt_value() {
    local prompt_text="$1"
    local default_val="$2"
    local value
    printf "${CYAN}%s${NC} [default: ${YELLOW}%s${NC}]: " "$prompt_text" "$default_val" >/dev/tty
    read -r value </dev/tty
    printf '%s' "${value:-$default_val}"
}

prompt_yn() {
    local prompt_text="$1"
    local default_val="${2:-n}"
    local answer
    printf "${CYAN}%s${NC} (y/n) [${YELLOW}%s${NC}]: " "$prompt_text" "$default_val" >/dev/tty
    read -r answer </dev/tty
    answer="${answer:-$default_val}"
    [[ "${answer,,}" == "y" ]]
}

prompt_secret() {
    local prompt_text="$1"
    local value
    printf "${CYAN}%s${NC}: " "$prompt_text" >/dev/tty
    read -rs value </dev/tty
    echo >/dev/tty
    printf '%s' "$value"
}

prompt_choice() {
    local question="$1"; shift
    local options=("$@")
    local i answer
    echo -e "${CYAN}${question}${NC}" >/dev/tty
    for i in "${!options[@]}"; do
        echo -e "  ${YELLOW}$((i+1)))${NC} ${options[$i]}" >/dev/tty
    done
    while true; do
        printf "${CYAN}Choice [1-%d]: ${NC}" "${#options[@]}" >/dev/tty
        read -r answer </dev/tty
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#options[@]} )); then
            printf '%s' "${options[$((answer-1))]}"
            return
        fi
        warn "Please enter a number between 1 and ${#options[@]}." >/dev/tty
    done
}

# ── Package helpers ───────────────────────────────────────────────────────────
ensure_package() {
    local pkg="$1"
    if dpkg -s "$pkg" &>/dev/null 2>&1; then
        success "Package '$pkg' already installed."
    else
        info "Installing '$pkg'..."
        apt-get install -y "$pkg" -qq
        success "Package '$pkg' installed."
    fi
}

# ── Detect existing installation ──────────────────────────────────────────────
detect_existing() {
    local found=false
    systemctl list-unit-files zou.service &>/dev/null 2>&1 \
        && systemctl list-unit-files zou.service | grep -q zou.service \
        && found=true
    [[ -d "$ZOU_DIR" ]] && found=true
    [[ -f "$ZOU_ENV_FILE" ]] && found=true
    [[ "$found" == "true" ]]
}

# ── Load / save env helpers ───────────────────────────────────────────────────
load_zou_env() {
    if [[ -f "$ZOU_ENV_FILE" ]]; then
        # shellcheck source=/dev/null
        set -a; source "$ZOU_ENV_FILE"; set +a
    fi
}

# ── Redis service name (varies: redis-server on Ubuntu, redis on Debian/others) ─
_redis_service() {
    for _svc in redis-server redis; do
        # Native unit file
        local _frag
        _frag=$(systemctl show -p FragmentPath "${_svc}" 2>/dev/null | cut -d= -f2)
        if [[ -n "$_frag" && -f "$_frag" ]]; then
            echo "${_svc}"; return
        fi
        # SysV init script
        if [[ -x "/etc/init.d/${_svc}" ]]; then
            echo "${_svc}"; return
        fi
        # Package is installed — unit file may not be visible until daemon-reload;
        # trust the conventional name so _redis_start can drive it via init.d or systemctl
        if dpkg -s "${_svc}" &>/dev/null 2>&1; then
            echo "${_svc}"; return
        fi
    done
    # Last resort: any loaded redis unit
    systemctl list-units --type=service --state=loaded 2>/dev/null \
        | awk '/redis/{gsub(/[[:space:]].*/, "", $1); print $1; exit}'
}

# ── Redis enable+start (handles native units and SysV-wrapped services) ──────
_redis_start() {
    local svc="$1"
    local initd="/etc/init.d/${svc}"

    if [[ -x "$initd" ]]; then
        # SysV init script — avoid all systemctl calls (they fail on SysV-only units).
        "$initd" stop  2>/dev/null || true
        "$initd" start
    else
        systemctl reset-failed "$svc" 2>/dev/null || true
        systemctl enable "$svc"
        systemctl stop   "$svc" 2>/dev/null || true
        systemctl start  "$svc"
    fi
}

# ── Log rotation setup ────────────────────────────────────────────────────────
setup_logrotate() {
    cat > /etc/logrotate.d/kitsu <<'EOF'
/opt/zou/logs/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 zou www-data
    sharedscripts
    postrotate
        systemctl reload zou zou-events 2>/dev/null || true
        systemctl reload zou-jobs 2>/dev/null || true
    endscript
}
EOF
    success "Log rotation configured (daily, 30 days retention)."
}

# =============================================================================
# PYTHON 3.12 INSTALL (apt main → backports → compile from source)
# =============================================================================

_install_python312() {
    if python3.12 --version &>/dev/null 2>&1; then
        success "Python 3.12 already installed ($(python3.12 --version 2>&1))."
        return
    fi

    local codename; codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

    # 1. Try standard repo (already updated above)
    if apt-cache show python3.12 &>/dev/null 2>&1; then
        info "Installing Python 3.12 from standard repo..."
        apt-get install -y python3.12 python3.12-venv python3.12-dev -qq
        success "Python 3.12 installed from apt."
        return
    fi

    # 2. Try backports
    info "python3.12 not in standard repo — trying ${codename}-backports..."
    if ! grep -qF "${codename}-backports" /etc/apt/sources.list \
            /etc/apt/sources.list.d/*.list 2>/dev/null; then
        echo "deb http://deb.debian.org/debian ${codename}-backports main" \
            > /etc/apt/sources.list.d/backports.list
    fi
    apt-get update -qq
    if apt-cache show python3.12 &>/dev/null 2>&1; then
        apt-get install -y -t "${codename}-backports" \
            python3.12 python3.12-venv python3.12-dev -qq
        success "Python 3.12 installed from backports."
        return
    fi

    # 3. Compile from source
    warn "python3.12 not available in apt — compiling from source (this takes ~5 min)..."
    local py_ver="3.12.7"
    local py_src="/tmp/Python-${py_ver}"
    local py_tar="/tmp/Python-${py_ver}.tgz"

    # Build dependencies
    apt-get install -y \
        build-essential libssl-dev zlib1g-dev libncurses5-dev libncursesw5-dev \
        libreadline-dev libsqlite3-dev libgdbm-dev libdb5.3-dev libbz2-dev \
        libexpat1-dev liblzma-dev libffi-dev uuid-dev wget -qq

    info "Downloading Python ${py_ver} source..."
    wget -q -O "$py_tar" \
        "https://www.python.org/ftp/python/${py_ver}/Python-${py_ver}.tgz"
    tar xzf "$py_tar" -C /tmp
    cd "$py_src"

    info "Configuring..."
    ./configure --enable-optimizations --with-ensurepip=install \
        --prefix=/usr/local --enable-shared \
        LDFLAGS="-Wl,-rpath /usr/local/lib" \
        > /tmp/python312_configure.log 2>&1

    info "Compiling (using $(nproc) cores)..."
    make -j"$(nproc)" > /tmp/python312_make.log 2>&1
    make altinstall > /tmp/python312_install.log 2>&1

    cd /
    rm -rf "$py_src" "$py_tar"

    # Link python3.12 into PATH if not already there
    if ! command -v python3.12 &>/dev/null; then
        ln -sf /usr/local/bin/python3.12 /usr/bin/python3.12
    fi

    # Install venv module (pip is included via --with-ensurepip)
    python3.12 -m ensurepip --upgrade &>/dev/null || true

    success "Python $(python3.12 --version 2>&1) compiled and installed."
}

load_kitsu_conf() {
    if [[ -f "$KITSU_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$KITSU_CONF"
    fi
    KITSU_HTTP_PORT="${KITSU_HTTP_PORT:-80}"
    DB_PORT="${DB_PORT:-5432}"
}

save_kitsu_conf() {
    mkdir -p "$(dirname "$KITSU_CONF")"
    cat > "$KITSU_CONF" <<EOF
KITSU_HTTP_PORT=${KITSU_HTTP_PORT}
DB_PORT=${DB_PORT:-5432}
KITSU_SERVER_NAME=${KITSU_SERVER_NAME:-}
KITSU_ADMIN_EMAIL=${KITSU_ADMIN_EMAIL:-}
EOF
    chmod 640 "$KITSU_CONF"
}

port_is_free() {
    local port="$1"
    ! ss -tlnp 2>/dev/null | grep -q ":${port} "
}

prompt_http_port() {
    local port
    while true; do
        port=$(prompt_value "HTTP port for Kitsu web UI" "${KITSU_HTTP_PORT}")
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            warn "Invalid port — enter a number between 1 and 65535." >/dev/tty
            continue
        fi
        if ! port_is_free "$port"; then
            local pid comm
            pid=$(ss -tlnp 2>/dev/null | grep ":${port} " \
                | grep -o 'pid=[0-9]*' | grep -o '[0-9]*' | head -1 || true)
            comm=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "unknown")
            warn "Port ${port} is already in use by PID ${pid} (${comm})." >/dev/tty
            warn "Choose a different port, or the installer will stop the occupant." >/dev/tty
            if prompt_yn "Use port ${port} anyway (occupant will be stopped)?" "n"; then
                break
            fi
            continue
        fi
        break
    done
    KITSU_HTTP_PORT="$port"
}

# =============================================================================
# INSTALLATION
# =============================================================================

_prompt_report_email() {
    local gmail_addr gmail_app_pass dest_addr

    if [[ -n "$UNATTENDED_CONFIG" ]]; then
        gmail_addr="${_CONF[GMAIL_FROM]:-}"
        gmail_app_pass="${_CONF[GMAIL_APP_PASSWORD]:-}"
        dest_addr="${_CONF[REPORT_EMAIL]:-$gmail_addr}"
    else
        echo -e "\n${BOLD}Email notification (Google / Gmail)${NC}"
        echo -e "  The script can send the installation summary to your email."
        echo -e "  You need a Gmail address and a ${CYAN}Google App Password${NC}."
        echo -e "  Generate one at: ${YELLOW}https://myaccount.google.com/apppasswords${NC}\n"

        printf "${CYAN}Gmail address to send FROM${NC} (leave blank to skip): " >/dev/tty
        read -r gmail_addr </dev/tty

        if [[ -z "$gmail_addr" ]]; then
            REPORT_EMAIL=""
            return
        fi

        gmail_app_pass=$(prompt_secret "Google App Password (spaces are OK, will be stripped)")
        gmail_app_pass="${gmail_app_pass// /}"
        if [[ -z "$gmail_app_pass" ]]; then
            warn "No app password entered — email notifications skipped."
            REPORT_EMAIL=""
            return
        fi

        dest_addr=$(prompt_value "Send report TO email address" "$gmail_addr")
    fi

    gmail_app_pass="${gmail_app_pass// /}"   # msmtp requires no spaces

    if [[ -z "$gmail_addr" || -z "$gmail_app_pass" ]]; then
        REPORT_EMAIL=""
        return
    fi

    REPORT_EMAIL="$dest_addr"
    GMAIL_FROM="$gmail_addr"

    ensure_package "msmtp" 2>/dev/null || true
    cat > /root/.msmtprc <<EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        gmail
host           smtp.gmail.com
port           587
from           ${gmail_addr}
user           ${gmail_addr}
password       ${gmail_app_pass}

account default : gmail
EOF
    chmod 600 /root/.msmtprc
    success "msmtp configured for ${gmail_addr}."
}

install_fresh() {
    header "Fresh Kitsu Installation (Debian, bare-metal)"

    # ── Unattended / config-file mode ────────────────────────────────────────
    if [[ -z "$UNATTENDED_CONFIG" ]]; then
        if prompt_yn "Use a configuration file for unattended install?" "n"; then
            local _default_conf="$(pwd)/kitsu_install.conf"
            local _conf_path
            _conf_path=$(prompt_value "Path to config file" "$_default_conf")
            if [[ ! -f "$_conf_path" ]]; then
                if prompt_yn "File not found. Generate an example config at ${_conf_path}?" "y"; then
                    write_config_example "$_conf_path"
                    echo
                    info "Edit ${_conf_path} with your values, then re-run the installer."
                    exit 0
                else
                    info "Continuing with interactive prompts."
                fi
            else
                UNATTENDED_CONFIG="$_conf_path"
                load_unattended_config "$UNATTENDED_CONFIG"
                info "Loaded config from: ${UNATTENDED_CONFIG}"
                validate_unattended_config
            fi
        fi
    fi

    _prompt_report_email
    echo

    # ── Collect configuration ─────────────────────────────────────────────────
    local db_password secret_key admin_email admin_password server_name db_port
    local enable_search enable_jobs

    if [[ -z "$UNATTENDED_CONFIG" ]]; then
        echo -e "${BOLD}Configure your Kitsu instance${NC} (press Enter to accept defaults)\n"
    else
        info "Unattended install — reading config from: ${UNATTENDED_CONFIG}"
    fi

    server_name=$(conf_value "SERVER_NAME" "Server hostname or IP (for Nginx)" "$(hostname -I | awk '{print $1}')")
    if [[ -n "$UNATTENDED_CONFIG" ]]; then
        KITSU_HTTP_PORT="${_CONF[HTTP_PORT]:-80}"
    else
        prompt_http_port
    fi
    db_password=$(conf_secret "DB_PASSWORD" "PostgreSQL password (hidden)")
    [[ -z "$db_password" ]] && db_password="mysecretpassword"
    db_port=$(conf_value "DB_PORT" "PostgreSQL port" "5432")
    [[ "$db_port" =~ ^[0-9]+$ ]] && (( db_port >= 1 && db_port <= 65535 )) || db_port=5432
    DB_PORT="$db_port"
    secret_key=$(python3 -c "import secrets; print(secrets.token_hex(16))" 2>/dev/null \
        || cat /proc/sys/kernel/random/uuid | tr -d '-')
    admin_email=$(conf_value "ADMIN_EMAIL" "Admin email" "admin@example.com")
    admin_password=$(conf_secret "ADMIN_PASSWORD" "Admin password (min 8 chars, hidden)")
    [[ -z "$admin_password" ]] && admin_password="changeme123"
    local preview_folder tmp_dir
    preview_folder=$(conf_value "PREVIEW_FOLDER" "Preview files folder" "${ZOU_DIR}/previews")
    tmp_dir=$(conf_value "TMP_DIR" "Temporary files folder" "${ZOU_DIR}/tmp")
    enable_search=$(conf_yn "ENABLE_SEARCH" "Enable full-text search (Meilisearch)?" "y")
    enable_jobs=$(conf_yn "ENABLE_JOBS" "Enable asynchronous job queue (RQ)?" "y")
    # ── Password-recovery email ───────────────────────────────────────────────
    local mail_server mail_port mail_user mail_pass mail_sender mail_tls mail_ssl domain_name
    if [[ -n "$UNATTENDED_CONFIG" ]]; then
        mail_server="${_CONF[MAIL_SERVER]:-}"
        mail_port="${_CONF[MAIL_PORT]:-587}"
        mail_user="${_CONF[MAIL_USERNAME]:-}"
        mail_pass="${_CONF[MAIL_PASSWORD]:-}"
        mail_tls="${_CONF[MAIL_USE_TLS]:-true}"
        mail_ssl="${_CONF[MAIL_USE_SSL]:-false}"
        mail_sender="${_CONF[MAIL_DEFAULT_SENDER]:-no-reply@your-studio.com}"
        domain_name="${_CONF[DOMAIN_NAME]:-${server_name}}"
        if [[ -n "$mail_server" && -n "$mail_user" ]]; then
            info "Password-recovery email: ${mail_user}@${mail_server}:${mail_port}"
        else
            info "Password-recovery email not configured (MAIL_SERVER/MAIL_USERNAME blank in config)."
        fi
    else
        echo -e "\n${BOLD}Password-recovery email${NC} (sent by Kitsu when users click \"Forgot password\")"
        echo -e "Leave SMTP server blank to skip.\n"
        mail_server=$(prompt_value "SMTP server" "smtp.gmail.com")
        if [[ -n "$mail_server" ]]; then
            mail_port=$(prompt_value "SMTP port (587=STARTTLS, 465=SSL)" "587")
            if [[ "$mail_port" == "587" ]]; then
                mail_tls="true"; mail_ssl="false"
            elif [[ "$mail_port" == "465" ]]; then
                mail_tls="false"; mail_ssl="true"
            else
                mail_tls="false"; mail_ssl="false"
            fi
            mail_user=$(prompt_value "SMTP username / email address" "")
            mail_pass=$(prompt_secret "SMTP password / App Password")
            mail_sender=$(prompt_value "From address shown to users" "${mail_user:-no-reply@your-studio.com}")
            local _port_suffix=""; [[ "${KITSU_HTTP_PORT:-80}" != "80" ]] && _port_suffix=":${KITSU_HTTP_PORT}"
            domain_name=$(prompt_value "Kitsu domain (used in reset links)" "${server_name}${_port_suffix}")
        else
            mail_port="587"; mail_user=""; mail_pass=""
            mail_tls="true"; mail_ssl="false"
            mail_sender="no-reply@your-studio.com"
            domain_name="${server_name}"
        fi
    fi

    if [[ -z "$UNATTENDED_CONFIG" ]]; then
        echo
        if ! prompt_yn "Proceed with installation?" "y"; then
            info "Installation cancelled."
            exit 0
        fi
    fi

    # ── System packages ───────────────────────────────────────────────────────
    header "Installing System Packages"
    apt-get update -qq

    ensure_package "build-essential"
    ensure_package "postgresql"
    ensure_package "postgresql-client"
    ensure_package "postgresql-server-dev-all"
    # Always install redis-server explicitly; we create a native systemd unit below
    # if the package ships only a SysV init script (avoids "Unit not found" errors)
    apt-get install -y redis-server
    ensure_package "redis-server"
    systemctl daemon-reload
    ensure_package "nginx"
    ensure_package "xmlsec1"
    ensure_package "ffmpeg"
    ensure_package "curl"
    ensure_package "msmtp"
    ensure_package "pwgen"

    # Python 3.12 — try apt first (main → backports), compile from source as last resort
    _install_python312

    # ── PostgreSQL setup ──────────────────────────────────────────────────────
    header "Configuring PostgreSQL"

    # Update postgresql.conf port if non-default
    if [[ "$DB_PORT" != "5432" ]]; then
        local _pg_conf
        _pg_conf=$(find /etc/postgresql -name postgresql.conf 2>/dev/null | head -1 || true)
        if [[ -n "$_pg_conf" ]]; then
            sed -i "s/^#*port[[:space:]]*=.*/port = ${DB_PORT}/" "$_pg_conf"
            info "PostgreSQL port set to ${DB_PORT} in ${_pg_conf}"
        fi
    fi

    systemctl enable --now postgresql

    # ── pg_hba.conf — fix BEFORE setting the password so the reload happens
    # before ALTER USER, ensuring scram-sha-256 is active for TCP connections
    local _hba
    _hba=$(sudo -u postgres psql -At -c "SHOW hba_file;" 2>/dev/null)
    if [[ -n "$_hba" && -f "$_hba" ]]; then
        cp -p "$_hba" "${_hba}.bak.$(date +%s)"   # safety backup
        # Replace peer/trust/ident on any host (TCP) line with scram-sha-256
        sed -i -E 's/^(host[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)(peer|trust|ident)[[:space:]]*$/\1scram-sha-256/' "$_hba"
        # Ensure explicit rules for both loopback addresses exist
        if ! grep -qE '^host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32' "$_hba"; then
            echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$_hba"
        fi
        if ! grep -qE '^host[[:space:]]+all[[:space:]]+all[[:space:]]+::1/128' "$_hba"; then
            echo "host    all             all             ::1/128                 scram-sha-256" >> "$_hba"
        fi
        systemctl reload postgresql
        success "pg_hba.conf updated — TCP scram-sha-256 auth enabled."
    else
        warn "Could not locate pg_hba.conf — you may need to set TCP auth manually."
    fi

    # ── Set postgres password via temp SQL file (safe against special chars) ──
    local _pg_sql
    _pg_sql=$(mktemp /tmp/.pg_XXXXXX)
    chmod 600 "$_pg_sql"
    # Escape single quotes in the password by doubling them (SQL standard)
    printf "ALTER USER postgres WITH PASSWORD '%s';\n" \
        "${db_password//\'/\'\'}" > "$_pg_sql"
    if sudo -u postgres psql -U postgres -d postgres -f "$_pg_sql"; then
        success "PostgreSQL password set."
    else
        rm -f "$_pg_sql"
        error "Failed to set PostgreSQL password — check pg_hba.conf and postgres logs."
        exit 1
    fi
    rm -f "$_pg_sql"

    # ── Verify zou can actually connect via TCP with the password ─────────────
    local _pg_conntest
    _pg_conntest=$(PGPASSWORD="${db_password}" psql \
        -h 127.0.0.1 -U postgres -d postgres \
        -At -c "SELECT 1;" 2>&1)
    if [[ "$_pg_conntest" == "1" ]]; then
        success "PostgreSQL TCP connection verified."
    else
        error "PostgreSQL TCP connection test failed: ${_pg_conntest}"
        error "zou will not be able to connect. Fix pg_hba.conf and the postgres password before proceeding."
        exit 1
    fi

    # ── Create database ───────────────────────────────────────────────────────
    if sudo -u postgres psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw zoudb; then
        success "Database 'zoudb' already exists."
    else
        sudo -u postgres psql -c "CREATE DATABASE zoudb;"
        success "Database 'zoudb' created."
    fi

    # ── Redis setup ───────────────────────────────────────────────────────────
    header "Configuring Redis"
    if ! grep -q 'vm.overcommit_memory' /etc/sysctl.conf 2>/dev/null; then
        echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf
        sysctl -p /etc/sysctl.conf &>/dev/null || true
    fi

    # Always ensure redis-server is installed via apt-get (avoids SysV-only scenarios)
    if ! dpkg -s redis-server &>/dev/null 2>&1; then
        info "Installing redis-server via apt-get..."
        apt-get install -y redis-server
        success "redis-server installed."
    else
        success "redis-server already installed."
    fi
    systemctl daemon-reload

    # If the package shipped only a SysV init script (no native unit), create one.
    # This is the root cause of "Unit redis-server.service not found" on older distros.
    if ! systemctl cat redis-server.service &>/dev/null 2>&1; then
        info "No native systemd unit for redis-server — creating one..."
        cat > /etc/systemd/system/redis-server.service <<'REDISUNIT'
[Unit]
Description=Advanced key-value store (Redis)
After=network.target

[Service]
Type=notify
ExecStart=/usr/bin/redis-server /etc/redis/redis.conf --supervised systemd --daemonize no
ExecStop=/usr/bin/redis-cli shutdown
TimeoutStopSec=0
Restart=always
User=redis
Group=redis
RuntimeDirectory=redis
RuntimeDirectoryMode=2755
UMask=007
PrivateTmp=yes
LimitNOFILE=65535
PrivateDevices=yes
ProtectHome=yes
ReadOnlyDirectories=/
ReadWriteDirectories=-/var/lib/redis
ReadWriteDirectories=-/var/log/redis
ReadWriteDirectories=-/var/run/redis

[Install]
WantedBy=multi-user.target
Alias=redis.service
REDISUNIT
        systemctl daemon-reload
        success "Native systemd unit created for redis-server."
    fi

    local _rsvc; _rsvc=$(_redis_service)
    if [[ -z "$_rsvc" ]]; then
        error "No Redis service unit found after install — check your system."
        exit 1
    fi
    info "Redis service: ${_rsvc}"
    _redis_start "$_rsvc"
    info "Waiting for Redis to be ready..."
    local _redis_wait=0
    until redis-cli ping 2>/dev/null | grep -q PONG; do
        sleep 1
        (( _redis_wait++ )) || true
        if (( _redis_wait >= 30 )); then
            error "Redis did not become ready in 30 s — check: journalctl -xeu ${_rsvc}"
            exit 1
        fi
    done
    success "Redis is ready."

    # ── Meilisearch (optional) ────────────────────────────────────────────────
    local meili_key="meilimasterkey"
    if [[ "$enable_search" == "y" ]]; then
        header "Installing Meilisearch"
        _install_meilisearch "$meili_key"
    fi

    # ── Zou user and directories ──────────────────────────────────────────────
    header "Setting Up Zou"
    if ! id zou &>/dev/null 2>&1; then
        useradd --home /opt/zou --no-create-home --shell /usr/sbin/nologin zou
        success "User 'zou' created."
    else
        success "User 'zou' already exists."
    fi

    mkdir -p "${ZOU_DIR}" "${ZOU_DIR}/backups" "${ZOU_DIR}/logs" \
             "${preview_folder}" "${tmp_dir}"
    chown zou: "${ZOU_DIR}/backups"
    chown -R zou:www-data "${ZOU_DIR}/logs" "${preview_folder}" "${tmp_dir}"

    # ── Python virtual environment & Zou ─────────────────────────────────────
    info "Creating Python virtual environment..."
    python3.12 -m venv "${ZOU_ENV}"
    "${ZOU_BIN}/python" -m pip install --upgrade pip -q
    info "Installing Zou (this may take a few minutes)..."
    "${ZOU_BIN}/python" -m pip install zou -q

    if [[ "$enable_jobs" == "y" ]]; then
        info "Installing boto3 for S3 support..."
        "${ZOU_BIN}/python" -m pip install boto3 -q
    fi

    # ── /etc/zou/zou.env ──────────────────────────────────────────────────────
    header "Writing Configuration"
    mkdir -p /etc/zou
    cat > "$ZOU_ENV_FILE" <<EOF
DB_PASSWORD=${db_password}
DB_HOST=localhost
DB_PORT=${DB_PORT}
DB_USERNAME=postgres
DB_DATABASE=zoudb
PREVIEW_FOLDER=${preview_folder}
TMP_DIR=${tmp_dir}
SECRET_KEY=${secret_key}
ENABLE_JOB_QUEUE=False
EOF

    if [[ "$enable_search" == "y" ]]; then
        cat >> "$ZOU_ENV_FILE" <<EOF
INDEXER_KEY=${meili_key}
INDEXER_HOST=localhost
INDEXER_PORT=7700
EOF
    fi

    if [[ -n "$mail_server" ]]; then
        cat >> "$ZOU_ENV_FILE" <<EOF

# Password-recovery email (zou)
MAIL_ENABLED=true
MAIL_SERVER=${mail_server}
MAIL_PORT=${mail_port}
MAIL_USERNAME=${mail_user}
MAIL_PASSWORD=${mail_pass}
MAIL_USE_TLS=${mail_tls}
MAIL_USE_SSL=${mail_ssl}
MAIL_DEFAULT_SENDER=${mail_sender}
DOMAIN_NAME=${domain_name}
EOF
    fi

    cat >> "$ZOU_ENV_FILE" <<'EOF'

# Export all variables
export DB_PASSWORD DB_HOST DB_PORT DB_USERNAME DB_DATABASE \
       PREVIEW_FOLDER TMP_DIR SECRET_KEY ENABLE_JOB_QUEUE
EOF

    chmod 640 "$ZOU_ENV_FILE"
    chown root:zou "$ZOU_ENV_FILE"
    success "Configuration written to ${ZOU_ENV_FILE}"

    # Validate required variables are present in zou.env
    local _missing=()
    for _var in DB_PASSWORD SECRET_KEY PREVIEW_FOLDER TMP_DIR DB_DATABASE; do
        grep -q "^${_var}=" "$ZOU_ENV_FILE" || _missing+=("$_var")
    done
    if [[ ${#_missing[@]} -gt 0 ]]; then
        error "Missing required variables in ${ZOU_ENV_FILE}: ${_missing[*]}"
        exit 1
    fi
    success "All required environment variables are set."

    # ── Gunicorn config files ─────────────────────────────────────────────────
    header "Configuring Gunicorn"

    cat > /etc/zou/gunicorn.py <<'EOF'
accesslog = "/opt/zou/logs/gunicorn_access.log"
errorlog  = "/opt/zou/logs/gunicorn_error.log"
workers   = 3
worker_class = "gevent"
EOF

    cat > /etc/zou/gunicorn-events.py <<'EOF'
accesslog = "/opt/zou/logs/gunicorn_events_access.log"
errorlog  = "/opt/zou/logs/gunicorn_events_error.log"
workers   = 1
worker_class = "geventwebsocket.gunicorn.workers.GeventWebSocketWorker"
EOF

    success "Gunicorn config files written."

    # ── Systemd services ──────────────────────────────────────────────────────
    header "Installing Systemd Services"

    cat > /etc/systemd/system/zou.service <<EOF
[Unit]
Description=Gunicorn instance to serve the Zou API
After=network.target postgresql.service ${_rsvc}.service

[Service]
User=zou
Group=www-data
WorkingDirectory=${ZOU_DIR}
Environment="PATH=${ZOU_BIN}:/usr/bin"
EnvironmentFile=${ZOU_ENV_FILE}
ExecStart=${ZOU_BIN}/gunicorn -c /etc/zou/gunicorn.py -b 127.0.0.1:5000 zou.app:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/zou-events.service <<EOF
[Unit]
Description=Gunicorn instance to serve the Zou Events API
After=network.target postgresql.service ${_rsvc}.service

[Service]
User=zou
Group=www-data
WorkingDirectory=${ZOU_DIR}
Environment="PATH=${ZOU_BIN}"
EnvironmentFile=${ZOU_ENV_FILE}
ExecStart=${ZOU_BIN}/gunicorn -c /etc/zou/gunicorn-events.py -b 127.0.0.1:5001 zou.event_stream:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    if [[ "$enable_jobs" == "y" ]]; then
        cat > /etc/systemd/system/zou-jobs.service <<EOF
[Unit]
Description=RQ Job queue for asynchronous Zou jobs
After=network.target ${_rsvc}.service zou.service

[Service]
User=zou
Group=www-data
WorkingDirectory=${ZOU_DIR}
EnvironmentFile=${ZOU_ENV_FILE}
Environment="PATH=${ZOU_BIN}:/usr/bin"
ExecStart=${ZOU_BIN}/rq worker -c zou.job_settings
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        # Enable job queue in env
        sed -i 's/^ENABLE_JOB_QUEUE=False/ENABLE_JOB_QUEUE=True/' "$ZOU_ENV_FILE"
        # Add export for ENABLE_JOB_QUEUE (already present from template)
    fi

    systemctl daemon-reload
    success "Systemd services installed."

    # ── Database initialisation ───────────────────────────────────────────────
    header "Initialising Database"
    info "Verifying PostgreSQL is ready..."
    local _pg_wait=0
    until sudo -u postgres pg_isready -q 2>/dev/null; do
        sleep 1
        (( _pg_wait++ )) || true
        if (( _pg_wait >= 30 )); then
            error "PostgreSQL did not become ready in 30 s — check: journalctl -xeu postgresql"
            exit 1
        fi
    done
    success "PostgreSQL is ready."

    info "Verifying Redis is ready..."
    local _redis_check=0
    until redis-cli ping 2>/dev/null | grep -q PONG; do
        sleep 1
        (( _redis_check++ )) || true
        if (( _redis_check >= 30 )); then
            error "Redis is not responding — check: journalctl -xeu ${_rsvc}"
            exit 1
        fi
    done
    success "Redis is ready."

    set -a; source "$ZOU_ENV_FILE"; set +a
    "${ZOU_BIN}/zou" init-db
    success "Database tables created."

    # ── Start zou services ────────────────────────────────────────────────────
    header "Starting Zou Services"
    systemctl enable zou zou-events
    systemctl start zou zou-events
    if [[ "$enable_jobs" == "y" ]]; then
        systemctl enable zou-jobs
        systemctl start zou-jobs
    fi
    success "Zou services started."

    # ── Kitsu frontend ────────────────────────────────────────────────────────
    header "Installing Kitsu Frontend"
    mkdir -p "$KITSU_DIST"
    info "Fetching latest Kitsu release..."
    local kitsu_url
    kitsu_url=$(curl -s https://api.github.com/repos/cgwire/kitsu/releases/latest \
        | grep 'browser_download_url.*kitsu-.*.tgz' \
        | cut -d: -f2,3 | tr -d '"' | tr -d ' ')
    if [[ -z "$kitsu_url" ]]; then
        error "Could not retrieve Kitsu download URL. Check your internet connection."
        exit 1
    fi
    curl -L -o /tmp/kitsu.tgz "$kitsu_url"
    tar xzf /tmp/kitsu.tgz -C "$KITSU_DIST/"
    rm -f /tmp/kitsu.tgz
    success "Kitsu frontend installed at ${KITSU_DIST}."

    # ── Nginx ─────────────────────────────────────────────────────────────────
    header "Configuring Nginx"
    KITSU_SERVER_NAME="$server_name"
    KITSU_ADMIN_EMAIL="$admin_email"
    save_kitsu_conf

    cat > "$NGINX_CONF" <<EOF
server {
    listen ${KITSU_HTTP_PORT};
    server_name ${server_name};

    location /api {
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:5000/;
        client_max_body_size 500M;
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        send_timeout 600s;
    }

    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_pass http://127.0.0.1:5001;
    }

    location / {
        autoindex on;
        root  ${KITSU_DIST};
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

    rm -f /etc/nginx/sites-enabled/default
    ln -sf "$NGINX_CONF" "$NGINX_ENABLED"
    nginx -t

    systemctl reset-failed nginx 2>/dev/null || true
    if pgrep -x nginx &>/dev/null; then
        pkill -x nginx 2>/dev/null || true; sleep 1
        pkill -9 -x nginx 2>/dev/null || true; sleep 1
    fi
    for _pid in $(ss -tlnp "sport = :${KITSU_HTTP_PORT}" 2>/dev/null \
            | grep -o 'pid=[0-9]*' | grep -o '[0-9]*' | sort -u); do
        local _comm; _comm=$(cat "/proc/${_pid}/comm" 2>/dev/null || echo "unknown")
        warn "Port ${KITSU_HTTP_PORT} in use by PID ${_pid} (${_comm}) — stopping..."
        kill "$_pid" 2>/dev/null || kill -9 "$_pid" 2>/dev/null || true
    done
    sleep 1

    systemctl enable nginx
    if ! systemctl start nginx; then
        error "Nginx failed to start. Diagnostic output:"
        journalctl -xeu nginx.service --no-pager -n 40 >&2 || true
        nginx -t >&2 || true
        error "Fix the issue above, then run: sudo systemctl start nginx"
        exit 1
    fi
    success "Nginx configured and running."

    # ── Seed data & search index ──────────────────────────────────────────────
    header "Seeding Data"
    set -a; source "$ZOU_ENV_FILE"; set +a
    "${ZOU_BIN}/zou" init-data
    success "Seed data loaded."

    if [[ "$enable_search" == "y" ]]; then
        info "Building search index..."
        "${ZOU_BIN}/zou" reset-search-index
        success "Search index built."
    fi

    # ── Create admin user ─────────────────────────────────────────────────────
    header "Creating Admin User"
    local _out _rc _pass_file
    _pass_file=$(mktemp /tmp/.zou_adm_XXXXXX)
    chmod 600 "$_pass_file"
    while true; do
        printf '%s' "${admin_password}" > "$_pass_file"
        _out=$(
            set -a; source "$ZOU_ENV_FILE"; set +a
            ZOU_ADM_EMAIL="${admin_email}" \
            ZOU_ADM_PASS_FILE="${_pass_file}" \
            "${ZOU_BIN}/python" - 2>&1 <<'PYEOF'
import os, sys
pass_file = os.environ["ZOU_ADM_PASS_FILE"]
with open(pass_file) as f:
    password = f.read()
from zou.app import app
from zou.app.services import persons_service
from zou.app.utils import auth
with app.app_context():
    try:
        persons_service.create_person(
            os.environ["ZOU_ADM_EMAIL"],
            auth.encrypt_password(password),
            "Admin",
            "Admin",
            role="admin",
        )
        print("ok")
    except Exception as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
PYEOF
        ) && _rc=0 || _rc=$?

        if [[ $_rc -eq 0 ]]; then
            rm -f "$_pass_file"
            success "Admin user '${admin_email}' created."
            break
        fi
        warn "Failed to create admin user (exit ${_rc}): ${_out}"
        warn "Password must be at least 8 characters. Symbols are allowed."
        admin_password=$(prompt_secret "Enter a new admin password (min 8 chars)")
        if [[ ${#admin_password} -lt 8 ]]; then
            warn "Password too short — try again."
            continue
        fi
        if [[ -n "$UNATTENDED_CONFIG" ]] && [[ -f "$UNATTENDED_CONFIG" ]]; then
            sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${admin_password}|" "$UNATTENDED_CONFIG"
            info "Updated ADMIN_PASSWORD in ${UNATTENDED_CONFIG}."
        fi
    done
    rm -f "$_pass_file" 2>/dev/null || true

    # ── Log rotation ──────────────────────────────────────────────────────────
    header "Setting Up Log Rotation"
    setup_logrotate

    show_summary "$server_name" "$admin_email"
}

_install_meilisearch() {
    local meili_key="$1"

    if command -v meilisearch &>/dev/null 2>&1; then
        success "Meilisearch already installed."
    else
        info "Adding Meilisearch repository..."
        echo "deb [trusted=yes] https://apt.fury.io/meilisearch/ /" \
            | tee /etc/apt/sources.list.d/fury.list > /dev/null
        apt-get update -qq
        apt-get install -y meilisearch -qq
        success "Meilisearch installed."
    fi

    if ! id meilisearch &>/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin meilisearch
    fi
    mkdir -p /opt/meilisearch
    chown -R meilisearch: /opt/meilisearch

    cat > /etc/systemd/system/meilisearch.service <<EOF
[Unit]
Description=Meilisearch full-text search engine
After=network.target

[Service]
User=meilisearch
Group=meilisearch
WorkingDirectory=/opt/meilisearch
ExecStart=/usr/bin/meilisearch --master-key="${meili_key}"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable meilisearch
    systemctl start meilisearch
    success "Meilisearch service running."
}

# ── Access info (shown on existing install detection) ─────────────────────────
show_access_info() {
    load_kitsu_conf
    local port="${KITSU_HTTP_PORT:-80}"
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local port_suffix=":${port}"
    local admin="${KITSU_ADMIN_EMAIL:-}"

    header "Kitsu — Current Installation"
    echo -e "  ${BOLD}Web UI:${NC}  ${GREEN}http://${ip}${port_suffix}${NC}"
    echo -e "  ${BOLD}API:${NC}     ${GREEN}http://${ip}${port_suffix}/api${NC}"
    [[ -n "$admin" ]] && echo -e "  ${BOLD}Login:${NC}   ${YELLOW}${admin}${NC}"
    echo
    echo -e "  ${CYAN}Services:${NC}"
    for svc in zou zou-events zou-jobs meilisearch nginx; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1 \
                && systemctl list-unit-files "${svc}.service" | grep -q "${svc}.service"; then
            local state; state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            local colour="$GREEN"; [[ "$state" != "active" ]] && colour="$RED"
            echo -e "    ${colour}●${NC} ${svc} (${state})"
        fi
    done
    echo
}

# =============================================================================
# REPAIR
# =============================================================================

repair_kitsu() {
    header "Repair Kitsu Installation"
    load_kitsu_conf
    load_zou_env
    local port="${KITSU_HTTP_PORT:-80}"
    local fixed=0 failed=0

    _repair_check() {
        local label="$1"; shift
        local fix_cmd=("$@")
        info "Checking: ${label}..."
        if ! "${fix_cmd[@]}" 2>/dev/null; then
            warn "  → Fix applied for: ${label}"
            (( fixed++ )) || true
        else
            success "  OK: ${label}"
        fi
    }

    # ── 1. System packages ────────────────────────────────────────────────────
    header "1/7 — System Packages"
    for pkg in postgresql redis-server nginx ffmpeg xmlsec1 curl msmtp; do
        if ! dpkg -s "$pkg" &>/dev/null 2>&1; then
            info "Missing package '${pkg}' — installing..."
            apt-get install -y "$pkg" -qq && success "Installed '${pkg}'." \
                || { error "Failed to install '${pkg}'."; (( failed++ )) || true; }
        else
            success "Package '${pkg}' present."
        fi
    done

    # ── 2. Zou virtualenv & package ───────────────────────────────────────────
    header "2/7 — Zou Python Environment"
    if [[ ! -x "${ZOU_BIN}/zou" ]]; then
        warn "zou binary missing — reinstalling into virtualenv..."
        if ! python3.12 --version &>/dev/null 2>&1; then
            error "Python 3.12 not found. Run a fresh install or fix Python first."
            (( failed++ )) || true
        else
            python3.12 -m venv "${ZOU_ENV}"
            "${ZOU_BIN}/python" -m pip install --upgrade pip zou -q \
                && success "Zou reinstalled." \
                || { error "Zou install failed."; (( failed++ )) || true; }
        fi
    else
        success "Zou binary present ($(${ZOU_BIN}/zou --version 2>/dev/null || echo unknown))."
    fi

    # ── 3. Directories & permissions ─────────────────────────────────────────
    header "3/7 — Directories & Permissions"
    for d in "${ZOU_DIR}" "${ZOU_DIR}/previews" "${ZOU_DIR}/tmp" "${ZOU_DIR}/logs" "${ZOU_DIR}/backups"; do
        if [[ ! -d "$d" ]]; then
            mkdir -p "$d" && info "Created ${d}."
        fi
    done
    chown -R zou:www-data "${ZOU_DIR}/previews" "${ZOU_DIR}/tmp" "${ZOU_DIR}/logs" 2>/dev/null || true
    chown zou: "${ZOU_DIR}/backups" 2>/dev/null || true
    success "Directory permissions OK."

    # ── 4. /etc/zou/zou.env ───────────────────────────────────────────────────
    header "4/7 — Environment File"
    if [[ ! -f "$ZOU_ENV_FILE" ]]; then
        error "Missing ${ZOU_ENV_FILE} — cannot auto-repair. Run a fresh install."
        (( failed++ )) || true
    else
        success "${ZOU_ENV_FILE} present."
        chown root:zou "$ZOU_ENV_FILE" 2>/dev/null || true
        chmod 640 "$ZOU_ENV_FILE" 2>/dev/null || true
    fi

    # ── 5. Systemd services ───────────────────────────────────────────────────
    header "5/7 — Systemd Services"
    for svc in zou zou-events; do
        local unit_file="/etc/systemd/system/${svc}.service"
        if [[ ! -f "$unit_file" ]]; then
            error "Service file missing: ${unit_file}. Re-run fresh install to recreate."
            (( failed++ )) || true
            continue
        fi
        if ! systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl enable "$svc" && info "Enabled ${svc}."
        fi
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            info "Starting ${svc}..."
            systemctl start "$svc" && success "${svc} started." \
                || { error "${svc} failed to start — check: journalctl -xeu ${svc}"; (( failed++ )) || true; }
        else
            success "${svc} is active."
        fi
    done

    if [[ -f "/etc/systemd/system/zou-jobs.service" ]]; then
        if ! systemctl is-active --quiet zou-jobs 2>/dev/null; then
            systemctl start zou-jobs && success "zou-jobs started." \
                || warn "zou-jobs failed to start (non-critical) — check: journalctl -xeu zou-jobs"
        else
            success "zou-jobs is active."
        fi
    fi

    # ── 6. Nginx ──────────────────────────────────────────────────────────────
    header "6/7 — Nginx"

    if [[ ! -f "$NGINX_CONF" ]]; then
        warn "Nginx site config missing — recreating for port ${port}..."
        local sn="${KITSU_SERVER_NAME:-$(hostname -I | awk '{print $1}')}"
        cat > "$NGINX_CONF" <<EOF
server {
    listen ${port};
    server_name ${sn};

    location /api {
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:5000/;
        client_max_body_size 500M;
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        send_timeout 600s;
    }

    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_pass http://127.0.0.1:5001;
    }

    location / {
        autoindex on;
        root  ${KITSU_DIST};
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
        success "Nginx config recreated at ${NGINX_CONF}."
        (( fixed++ )) || true
    fi

    if [[ ! -L "$NGINX_ENABLED" ]]; then
        ln -sf "$NGINX_CONF" "$NGINX_ENABLED"
        info "Nginx site enabled."
    fi

    if [[ -f /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
        info "Removed nginx default site."
    fi

    if ! nginx -t 2>/dev/null; then
        error "Nginx configuration test failed:"
        nginx -t >&2
        (( failed++ )) || true
    else
        success "Nginx config syntax OK."

        systemctl reset-failed nginx 2>/dev/null || true

        if pgrep -x nginx &>/dev/null; then
            info "Stopping existing nginx processes..."
            pkill -x nginx 2>/dev/null || true
            sleep 1
            pkill -9 -x nginx 2>/dev/null || true
            sleep 1
        fi

        for _pid in $(ss -tlnp "sport = :${port}" 2>/dev/null \
                | grep -o 'pid=[0-9]*' | grep -o '[0-9]*' | sort -u); do
            local _comm; _comm=$(cat "/proc/${_pid}/comm" 2>/dev/null || echo "unknown")
            warn "Port ${port} held by PID ${_pid} (${_comm}) — killing..."
            kill "$_pid" 2>/dev/null || kill -9 "$_pid" 2>/dev/null || true
        done
        sleep 1

        if ! systemctl is-enabled --quiet nginx 2>/dev/null; then
            systemctl enable nginx
        fi

        if systemctl start nginx; then
            success "Nginx started."
        else
            error "Nginx still failing. Full diagnostic:"
            journalctl -xeu nginx.service --no-pager -n 40 >&2 || true
            nginx -t >&2 || true
            error "Manual fix required — check the output above."
            (( failed++ )) || true
        fi
    fi

    # ── 7. Database migrations ────────────────────────────────────────────────
    header "7/7 — Database Migrations"
    if [[ -f "$ZOU_ENV_FILE" ]] && [[ -x "${ZOU_BIN}/zou" ]]; then
        set -a; source "$ZOU_ENV_FILE"; set +a
        "${ZOU_BIN}/zou" upgrade-db && success "Database schema up to date." \
            || { error "upgrade-db failed — check DB connectivity."; (( failed++ )) || true; }
    else
        warn "Skipping DB migration (env or zou binary missing)."
    fi

    # ── 8. Admin user ─────────────────────────────────────────────────────────
    header "8/8 — Admin User"
    if [[ -f "$ZOU_ENV_FILE" ]] && [[ -x "${ZOU_BIN}/python" ]]; then
        local _admin_count
        _admin_count=$(
            set -a; source "$ZOU_ENV_FILE"; set +a
            "${ZOU_BIN}/python" - 2>/dev/null <<'PYEOF'
from zou.app import app
from zou.app.services import persons_service
with app.app_context():
    admins = [p for p in persons_service.get_persons() if p.get("role") == "admin"]
    print(len(admins))
PYEOF
        ) || _admin_count=0
        if [[ "${_admin_count:-0}" -gt 0 ]]; then
            success "Admin user(s) present (${_admin_count} found)."
        else
            warn "No admin user found in the database."
            if prompt_yn "Create an admin user now?" "y"; then
                local _adm_email _adm_pass _pass_file _out _rc
                _adm_email=$(prompt_value "Admin email" "admin@example.com")
                _adm_pass=$(prompt_secret "Admin password (min 8 chars)")
                if [[ ${#_adm_pass} -lt 8 ]]; then
                    error "Password too short — skipping admin creation."
                    (( failed++ )) || true
                else
                    _pass_file=$(mktemp /tmp/.zou_rep_XXXXXX)
                    chmod 600 "$_pass_file"
                    printf '%s' "${_adm_pass}" > "$_pass_file"
                    _out=$(
                        set -a; source "$ZOU_ENV_FILE"; set +a
                        ZOU_ADM_EMAIL="${_adm_email}" \
                        ZOU_ADM_PASS_FILE="${_pass_file}" \
                        "${ZOU_BIN}/python" - 2>&1 <<'PYEOF'
import os, sys
with open(os.environ["ZOU_ADM_PASS_FILE"]) as f:
    password = f.read()
from zou.app import app
from zou.app.services import persons_service
from zou.app.utils import auth
with app.app_context():
    try:
        persons_service.create_person(
            os.environ["ZOU_ADM_EMAIL"],
            auth.encrypt_password(password),
            "Admin", "Admin", role="admin",
        )
        print("ok")
    except Exception as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
PYEOF
                    ) && _rc=0 || _rc=$?
                    rm -f "$_pass_file"
                    if [[ $_rc -eq 0 ]]; then
                        success "Admin user '${_adm_email}' created."
                        (( fixed++ )) || true
                    else
                        error "Admin creation failed: ${_out}"
                        (( failed++ )) || true
                    fi
                fi
            else
                warn "Skipping admin creation. Use 'Change User Password' from the menu if needed."
            fi
        fi
    else
        warn "Skipping admin check (env or python binary missing)."
    fi

    echo
    if (( failed == 0 )); then
        success "Repair complete — ${fixed} item(s) fixed, no failures."
    else
        warn "Repair finished — ${fixed} item(s) fixed, ${failed} item(s) could not be repaired automatically."
        warn "Check the errors above and re-run, or perform a fresh install."
    fi
    echo
    show_access_info
}

# =============================================================================
# PURGE INCOMPLETE INSTALL FOOTPRINT
# =============================================================================

purge_footprint() {
    header "Purge Incomplete Kitsu Footprint"

    echo -e "  ${BOLD}This will forcibly remove every trace of a partial Kitsu install:${NC}\n"
    echo -e "  ${YELLOW}•${NC} Systemd services: zou, zou-events, zou-jobs, meilisearch"
    echo -e "  ${YELLOW}•${NC} Directories:      /opt/zou  /opt/kitsu  /opt/meilisearch"
    echo -e "  ${YELLOW}•${NC} Config files:     /etc/zou/  /etc/nginx/sites-*/zou"
    echo -e "  ${YELLOW}•${NC} Log rotation:     /etc/logrotate.d/kitsu"
    echo -e "  ${YELLOW}•${NC} Cron job:         ${BACKUP_CRON_FILE}"
    echo -e "  ${YELLOW}•${NC} Custom redis unit: /etc/systemd/system/redis-server.service (if created by this script)"
    echo -e "  ${YELLOW}•${NC} PostgreSQL DB:    zoudb (if it exists)"
    echo -e "  ${YELLOW}•${NC} System user:      zou"
    echo
    echo -e "  ${BOLD}System packages (postgresql, redis-server, nginx) are NOT removed.${NC}"
    echo

    if ! prompt_yn "Proceed with full purge? This cannot be undone." "n"; then
        info "Purge cancelled — no changes made."
        return
    fi

    echo

    # ── 1. Stop and remove systemd services ──────────────────────────────────
    info "Stopping and removing Kitsu services..."
    for svc in zou zou-events zou-jobs meilisearch; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1 \
                && systemctl list-unit-files "${svc}.service" | grep -q "${svc}.service"; then
            systemctl stop    "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service"
            success "Removed service: ${svc}"
        fi
    done
    # Remove the native redis unit only if it was created by this script
    if [[ -f /etc/systemd/system/redis-server.service ]] \
            && grep -q 'supervised systemd' /etc/systemd/system/redis-server.service 2>/dev/null; then
        local _unit_pkg
        _unit_pkg=$(dpkg -S /etc/systemd/system/redis-server.service 2>/dev/null || true)
        if [[ -z "$_unit_pkg" ]]; then
            rm -f /etc/systemd/system/redis-server.service
            success "Removed script-created redis-server systemd unit."
        fi
    fi
    systemctl daemon-reload
    success "Systemd daemon reloaded."

    # ── 2. PostgreSQL database ────────────────────────────────────────────────
    if systemctl is-active --quiet postgresql 2>/dev/null \
            && sudo -u postgres psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw zoudb; then
        info "Dropping PostgreSQL database 'zoudb'..."
        sudo -u postgres psql \
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='zoudb' AND pid <> pg_backend_pid();" \
            2>/dev/null || true
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS zoudb;" 2>/dev/null \
            && success "Database 'zoudb' dropped." \
            || warn "Could not drop 'zoudb' — drop it manually if needed."
    else
        info "PostgreSQL not running or 'zoudb' not found — skipping."
    fi

    # ── 3. Nginx site config ──────────────────────────────────────────────────
    info "Removing Nginx site config..."
    rm -f "$NGINX_CONF" "$NGINX_ENABLED"
    if [[ -f /etc/nginx/sites-available/default ]] \
            && [[ ! -L /etc/nginx/sites-enabled/default ]]; then
        ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
        info "Re-enabled nginx default site."
    fi
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    fi
    success "Nginx site config removed."

    # ── 4. Directories ────────────────────────────────────────────────────────
    info "Removing Kitsu/Zou directories..."
    rm -rf "$ZOU_DIR" /opt/kitsu /opt/meilisearch
    success "Directories removed."

    # ── 5. Config files ───────────────────────────────────────────────────────
    info "Removing config files..."
    rm -rf /etc/zou
    rm -f /etc/logrotate.d/kitsu "$BACKUP_CRON_FILE" /root/.msmtprc
    success "Config files removed."

    # ── 6. System user ────────────────────────────────────────────────────────
    if id zou &>/dev/null 2>&1; then
        info "Removing system user 'zou'..."
        userdel zou 2>/dev/null && success "User 'zou' removed." \
            || warn "Could not remove user 'zou' — remove manually with: userdel zou"
    fi
    if id meilisearch &>/dev/null 2>&1; then
        info "Removing system user 'meilisearch'..."
        userdel meilisearch 2>/dev/null && success "User 'meilisearch' removed." \
            || warn "Could not remove user 'meilisearch' — remove manually with: userdel meilisearch"
    fi

    echo
    success "Purge complete. The system is clean — you can now run a fresh install."
    echo
}

# =============================================================================
# DELETE
# =============================================================================

delete_kitsu() {
    header "Delete Kitsu Installation"

    echo -e "  ${BOLD}The following Kitsu components were found:${NC}\n"

    local -A components
    local -a order

    _found() { components["$1"]="$2"; order+=("$1"); }

    for svc in zou zou-events zou-jobs meilisearch; do
        if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}.service"; then
            local st; st=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            _found "svc_${svc}" "Systemd service '${svc}' (${st})"
        fi
    done

    # PostgreSQL database
    if sudo -u postgres psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw zoudb; then
        _found "pg_zoudb" "PostgreSQL database 'zoudb'"
    fi

    [[ -f "$NGINX_CONF" ]]    && _found "nginx_conf"   "Nginx site config ${NGINX_CONF}"
    [[ -L "$NGINX_ENABLED" ]] && _found "nginx_link"   "Nginx site symlink ${NGINX_ENABLED}"
    [[ -d "$ZOU_DIR" ]]       && _found "dir_zou"      "Zou install directory ${ZOU_DIR}"
    [[ -d "/opt/kitsu" ]]     && _found "dir_kitsu"    "Kitsu frontend directory /opt/kitsu"
    [[ -d "/opt/meilisearch" ]] && _found "dir_meili"  "Meilisearch data directory /opt/meilisearch"
    [[ -f "$ZOU_ENV_FILE" ]]  && _found "cfg_env"      "Environment file ${ZOU_ENV_FILE}"
    [[ -f "$KITSU_CONF" ]]    && _found "cfg_kitsu"    "Kitsu config ${KITSU_CONF}"
    [[ -f "$BACKUP_CONFIG_FILE" ]] && _found "cfg_backup" "Backup config ${BACKUP_CONFIG_FILE}"

    for pkg in postgresql redis-server redis nginx ffmpeg meilisearch; do
        dpkg -s "$pkg" &>/dev/null 2>&1 && _found "pkg_${pkg}" "System package '${pkg}' (shared — used by other services too)"
    done

    [[ -f /etc/logrotate.d/kitsu ]] && _found "logrotate" "Log rotation config /etc/logrotate.d/kitsu"
    [[ -f "$BACKUP_CRON_FILE" ]]    && _found "cron"       "Backup cron job ${BACKUP_CRON_FILE}"

    if [[ ${#order[@]} -eq 0 ]]; then
        warn "Nothing to remove was found."
        return
    fi

    for key in "${order[@]}"; do
        echo -e "  ${YELLOW}•${NC} ${components[$key]}"
    done
    echo

    warn "Choose which components to remove."
    warn "System packages (postgresql, redis, nginx) are shared — only remove if this is a dedicated server."
    echo

    local -a to_remove=()
    for key in "${order[@]}"; do
        if prompt_yn "  Remove: ${components[$key]}?" "y"; then
            to_remove+=("$key")
        fi
    done

    if [[ ${#to_remove[@]} -eq 0 ]]; then
        info "Nothing selected — no changes made."
        return
    fi

    echo
    warn "About to remove ${#to_remove[@]} component(s). This cannot be undone."
    if ! prompt_yn "Proceed with deletion?" "n"; then
        info "Deletion cancelled."
        return
    fi

    for key in "${to_remove[@]}"; do
        info "Removing: ${components[$key]}..."
        case "$key" in
            svc_*)
                local svc="${key#svc_}"
                systemctl stop    "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                rm -f "/etc/systemd/system/${svc}.service"
                success "Service '${svc}' removed."
                ;;
            pg_zoudb)
                sudo -u postgres psql \
                    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='zoudb' AND pid <> pg_backend_pid();" \
                    2>/dev/null || true
                sudo -u postgres psql -c "DROP DATABASE IF EXISTS zoudb;" \
                    && success "Database 'zoudb' dropped." \
                    || warn "Could not drop database 'zoudb'."
                ;;
            nginx_conf)  rm -f "$NGINX_CONF";  success "Nginx site config removed." ;;
            nginx_link)
                rm -f "$NGINX_ENABLED"
                nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
                success "Nginx site symlink removed."
                ;;
            dir_zou)     rm -rf "$ZOU_DIR";        success "Zou directory removed." ;;
            dir_kitsu)   rm -rf /opt/kitsu;         success "Kitsu frontend directory removed." ;;
            dir_meili)   rm -rf /opt/meilisearch;   success "Meilisearch data directory removed." ;;
            cfg_env)     rm -f "$ZOU_ENV_FILE";     success "Environment file removed." ;;
            cfg_kitsu)   rm -f "$KITSU_CONF";       success "Kitsu config removed." ;;
            cfg_backup)  rm -f "$BACKUP_CONFIG_FILE"; success "Backup config removed." ;;
            pkg_*)
                local pkg="${key#pkg_}"
                apt-get remove -y "$pkg" -qq && success "Package '${pkg}' removed." \
                    || warn "Could not remove package '${pkg}'."
                ;;
            logrotate)   rm -f /etc/logrotate.d/kitsu; success "Log rotation config removed." ;;
            cron)        rm -f "$BACKUP_CRON_FILE";     success "Backup cron job removed." ;;
        esac
    done

    systemctl daemon-reload 2>/dev/null || true

    echo
    success "Deletion complete."
    info "If you removed system packages, run 'apt-get autoremove' to clean up dependencies."
    echo

    if prompt_yn "Run Purge Incomplete Install to remove any leftover traces?" "n"; then
        purge_footprint
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
show_summary() {
    local server_name="${1:-$(hostname -I | awk '{print $1}')}"
    local admin_email="${2:-admin@example.com}"
    load_kitsu_conf
    load_zou_env
    local port="${KITSU_HTTP_PORT:-80}"
    local port_suffix=""; [[ "$port" != "80" ]] && port_suffix=":${port}"

    header "Kitsu is Ready"
    echo -e "  ${BOLD}Web UI:${NC}     ${GREEN}http://${server_name}${port_suffix}${NC}"
    echo -e "  ${BOLD}API:${NC}        ${GREEN}http://${server_name}${port_suffix}/api${NC}"
    echo -e "  ${BOLD}Events:${NC}     ${GREEN}http://${server_name}${port_suffix}/socket.io${NC}"
    echo
    echo -e "  ${BOLD}Login:${NC}      ${YELLOW}${admin_email}${NC}"
    echo -e "  ${YELLOW}Note:${NC} Use the password you set during installation."
    echo
    echo -e "  ${CYAN}Paths:${NC}"
    echo -e "    Zou install    :  ${ZOU_DIR}"
    echo -e "    Virtualenv     :  ${ZOU_ENV}"
    echo -e "    Config file    :  ${ZOU_ENV_FILE}"
    echo -e "    Preview folder :  ${PREVIEW_FOLDER:-${ZOU_DIR}/previews}"
    echo -e "    Temp folder    :  ${TMP_DIR:-${ZOU_DIR}/tmp}"
    echo
    echo -e "  ${CYAN}Useful commands:${NC}"
    echo -e "    View API logs  :  journalctl -fu zou"
    echo -e "    View event logs:  journalctl -fu zou-events"
    echo -e "    Restart all    :  sudo systemctl restart zou zou-events nginx"
    echo -e "    Upgrade DB     :  sudo -u zou ${ZOU_BIN}/zou upgrade-db"
    echo

    local target_user="${SUDO_USER:-$USER}"
    local target_home; target_home=$(eval echo "~$target_user")
    local dest_dir="$target_home/Desktop"
    [[ ! -d "$dest_dir" ]] && dest_dir="$target_home"
    local summary_file="$dest_dir/kitsu_access_info.txt"

    {
        cat <<EOF
Kitsu Installation Summary
==========================
Date:     $(date)
Host:     $(hostname -f 2>/dev/null || hostname)

── Access ──────────────────────────────
Web UI:   http://${server_name}${port_suffix}
API:      http://${server_name}${port_suffix}/api
Events:   http://${server_name}${port_suffix}/socket.io

Login:    ${admin_email}
Note: Use the password you set during installation.

── Paths ───────────────────────────────
Zou install    : ${ZOU_DIR}
Virtualenv     : ${ZOU_ENV}
Config file    : ${ZOU_ENV_FILE}
Preview folder : ${PREVIEW_FOLDER:-${ZOU_DIR}/previews}
Temp folder    : ${TMP_DIR:-${ZOU_DIR}/tmp}

── Environment (${ZOU_ENV_FILE}) ────────
EOF
        # Append zou.env contents, masking secrets
        if [[ -f "$ZOU_ENV_FILE" ]]; then
            sed 's/\(DB_PASSWORD\|SECRET_KEY\|INDEXER_KEY\|FS_S3_SECRET_KEY\)=.*/\1=***/' \
                "$ZOU_ENV_FILE" | grep -v '^#' | grep -v '^$' | grep -v '^export'
        else
            echo "(not found)"
        fi

        cat <<EOF

── Useful commands ──────────────────────
View API logs   : journalctl -fu zou
View event logs : journalctl -fu zou-events
Restart all     : sudo systemctl restart zou zou-events nginx
Upgrade DB      : sudo -u zou ${ZOU_BIN}/zou upgrade-db
EOF
    } > "$summary_file"

    chown "${target_user}:${target_user}" "$summary_file" 2>/dev/null || true

    echo -e "  ${GREEN}Access details saved to:${NC} ${BOLD}${summary_file}${NC}"
    echo

    _send_notify_email "$summary_file" "✅ Kitsu is Ready — $(hostname -f 2>/dev/null || hostname)"
}

_send_notify_email() {
    local summary_file="$1"
    local subject="$2"
    [[ ! -f /root/.msmtprc  ]] && return
    [[ ! -f "$summary_file" ]] && return
    local dest="${REPORT_EMAIL:-}"
    [[ -z "$dest" ]] && return
    local from="${GMAIL_FROM:-}"
    info "Sending summary email to ${dest}..."
    {
        echo "To: ${dest}"
        echo "From: ${from:-kitsu@localhost}"
        echo "Subject: ${subject}"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo ""
        cat "$summary_file"
    } | msmtp "${dest}" \
        && success "Email sent to ${dest}." \
        || warn "Email failed — check /var/log/msmtp.log"
}

# =============================================================================
# UPGRADE
# =============================================================================

upgrade_kitsu() {
    header "Upgrading Kitsu"
    load_zou_env

    # Upgrade Zou
    info "Upgrading Zou Python package..."
    "${ZOU_BIN}/python" -m pip install --upgrade zou -q
    success "Zou package upgraded."

    # Upgrade DB schema
    info "Upgrading database schema..."
    set -a; source "$ZOU_ENV_FILE"; set +a
    "${ZOU_BIN}/zou" upgrade-db
    success "Database schema up to date."

    # Restart zou services
    info "Restarting Zou services..."
    systemctl restart zou zou-events
    systemctl is-active --quiet zou-jobs 2>/dev/null && systemctl restart zou-jobs || true
    success "Zou services restarted."

    # Upgrade Kitsu frontend
    info "Upgrading Kitsu frontend..."
    local kitsu_url
    kitsu_url=$(curl -s https://api.github.com/repos/cgwire/kitsu/releases/latest \
        | grep 'browser_download_url.*kitsu-.*.tgz' \
        | cut -d: -f2,3 | tr -d '"' | tr -d ' ')
    if [[ -z "$kitsu_url" ]]; then
        warn "Could not retrieve Kitsu download URL — frontend not upgraded."
    else
        rm -rf "$KITSU_DIST"
        mkdir -p "$KITSU_DIST"
        curl -L -o /tmp/kitsu.tgz "$kitsu_url"
        tar xzf /tmp/kitsu.tgz -C "$KITSU_DIST/"
        rm -f /tmp/kitsu.tgz
        success "Kitsu frontend upgraded."
    fi

    systemctl reload nginx 2>/dev/null || true
    success "Upgrade complete."
}

# =============================================================================
# S3 STORAGE SETUP
# =============================================================================

setup_s3_storage() {
    header "Setup S3 Preview Storage"

    load_zou_env

    local fs_backend bucket_prefix s3_region s3_endpoint s3_access_key s3_secret_key

    fs_backend="s3"
    bucket_prefix=$(prompt_value "Bucket name prefix (mandatory)" "kitsu")
    s3_region=$(prompt_value "S3 region" "eu-west-3")
    s3_endpoint=$(prompt_value "S3 endpoint URL" "https://s3.${s3_region}.amazonaws.com")
    s3_access_key=$(prompt_value "S3 access key" "")
    s3_secret_key=$(prompt_secret "S3 secret key")

    if [[ -z "$s3_access_key" || -z "$s3_secret_key" || -z "$bucket_prefix" ]]; then
        error "Access key, secret key, and bucket prefix are all required."
        return 1
    fi

    # Install boto3
    info "Installing boto3..."
    "${ZOU_BIN}/python" -m pip install boto3 -q
    success "boto3 installed."

    # Append S3 vars to zou.env (remove old ones first)
    sed -i '/^FS_BACKEND=/d;/^FS_BUCKET_PREFIX=/d;/^FS_S3_REGION=/d' "$ZOU_ENV_FILE"
    sed -i '/^FS_S3_ENDPOINT=/d;/^FS_S3_ACCESS_KEY=/d;/^FS_S3_SECRET_KEY=/d' "$ZOU_ENV_FILE"

    cat >> "$ZOU_ENV_FILE" <<EOF

# S3 storage backend
FS_BACKEND=${fs_backend}
FS_BUCKET_PREFIX=${bucket_prefix}
FS_S3_REGION=${s3_region}
FS_S3_ENDPOINT=${s3_endpoint}
FS_S3_ACCESS_KEY=${s3_access_key}
FS_S3_SECRET_KEY=${s3_secret_key}
EOF

    # Make sure the new vars are exported
    if ! grep -q 'FS_BACKEND' "$ZOU_ENV_FILE" | grep 'export' 2>/dev/null; then
        echo 'export FS_BACKEND FS_BUCKET_PREFIX FS_S3_REGION FS_S3_ENDPOINT FS_S3_ACCESS_KEY FS_S3_SECRET_KEY' \
            >> "$ZOU_ENV_FILE"
    fi

    info "Restarting Zou services..."
    systemctl restart zou zou-events
    systemctl is-active --quiet zou-jobs 2>/dev/null && systemctl restart zou-jobs || true

    success "S3 storage configured. Previews will now be stored in S3."
    echo -e "  ${BOLD}Bucket prefix:${NC} ${YELLOW}${bucket_prefix}${NC}"
    echo -e "  ${BOLD}Region:${NC}        ${YELLOW}${s3_region}${NC}"
    echo -e "  ${BOLD}Endpoint:${NC}      ${YELLOW}${s3_endpoint}${NC}"
    echo
}

# =============================================================================
# BACKUP
# =============================================================================

load_backup_config() {
    if [[ -f "$BACKUP_CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$BACKUP_CONFIG_FILE"
    fi
    BACKUP_DIR="${BACKUP_DIR:-${ZOU_DIR}/backups}"
    KEEP_VERSIONS="${KEEP_VERSIONS:-$DEFAULT_KEEP_VERSIONS}"
}

save_backup_config() {
    mkdir -p "$(dirname "$BACKUP_CONFIG_FILE")"
    cat > "$BACKUP_CONFIG_FILE" <<EOF
BACKUP_DIR="${BACKUP_DIR}"
KEEP_VERSIONS="${KEEP_VERSIONS}"
EOF
    chmod 600 "$BACKUP_CONFIG_FILE"
}

run_backup() {
    load_backup_config
    require_zou_running

    local date_stamp; date_stamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local backup_path="${BACKUP_DIR}/${date_stamp}"
    mkdir -p "$backup_path"

    header "Creating Kitsu Backup — ${date_stamp}"

    load_zou_env

    # Database dump
    info "Dumping PostgreSQL database..."
    (cd "$backup_path" && set -a && source "$ZOU_ENV_FILE" && set +a \
        && "${ZOU_BIN}/zou" dump-database)

    local dump_file
    dump_file=$(ls -t "${backup_path}"/*.sql.gz 2>/dev/null | head -1 || true)
    if [[ -z "$dump_file" ]]; then
        error "No .sql.gz file produced by zou dump-database."
        rm -rf "$backup_path"
        exit 1
    fi
    success "Database → ${dump_file}"

    # Preview files
    info "Archiving preview files..."
    local preview_folder="${PREVIEW_FOLDER:-${ZOU_DIR}/previews}"
    tar czf "${backup_path}/previews.tar.gz" -C "$preview_folder" . 2>/dev/null
    success "Previews  → ${backup_path}/previews.tar.gz"

    # Manifest
    cat > "${backup_path}/manifest.txt" <<EOF
date=${date_stamp}
zou_version=$(${ZOU_BIN}/zou --version 2>/dev/null || echo unknown)
backup_dir=${BACKUP_DIR}
keep_versions=${KEEP_VERSIONS}
EOF
    success "Manifest  → ${backup_path}/manifest.txt"

    rotate_backups
    echo
    success "Backup complete: ${backup_path}"
}

rotate_backups() {
    local -a versions
    mapfile -t versions < <(ls -dt "${BACKUP_DIR}"/[0-9][0-9][0-9][0-9]-* 2>/dev/null || true)
    if (( ${#versions[@]} > KEEP_VERSIONS )); then
        local to_delete=("${versions[@]:$KEEP_VERSIONS}")
        for old in "${to_delete[@]}"; do
            info "Removing old backup: $(basename "$old")"
            rm -rf "$old"
        done
        success "Kept the ${KEEP_VERSIONS} most recent backup(s)."
    fi
}

run_restore() {
    load_backup_config
    require_zou_running

    header "Restore Kitsu from Backup"

    local -a backups
    mapfile -t backups < <(ls -dt "${BACKUP_DIR}"/[0-9][0-9][0-9][0-9]-* 2>/dev/null || true)
    if [[ ${#backups[@]} -eq 0 ]]; then
        error "No backups found in ${BACKUP_DIR}."
        exit 1
    fi

    local -a labels
    for b in "${backups[@]}"; do
        local label size
        label=$(basename "$b")
        size=$(du -sh "$b" 2>/dev/null | cut -f1)
        labels+=("${label}  [${size}]")
    done

    local choice; choice=$(prompt_choice "Select a backup to restore:" "${labels[@]}")
    local chosen_idx=0
    for i in "${!labels[@]}"; do
        [[ "${labels[$i]}" == "$choice" ]] && chosen_idx=$i && break
    done
    local chosen_path="${backups[$chosen_idx]}"

    echo
    warn "WARNING: This will OVERWRITE the current database and preview files."
    warn "Backup: $(basename "$chosen_path")"
    echo
    if ! prompt_yn "Are you sure?" "n"; then
        info "Restore cancelled."
        return
    fi

    header "Restoring — $(basename "$chosen_path")"

    load_zou_env

    # Stop zou to release DB connections
    info "Stopping Zou services..."
    systemctl stop zou zou-events
    systemctl is-active --quiet zou-jobs 2>/dev/null && systemctl stop zou-jobs || true

    # Restore database
    if [[ -n "$(ls "${chosen_path}"/*.sql.gz 2>/dev/null)" ]]; then
        local dump_file; dump_file=$(ls "${chosen_path}"/*.sql.gz | head -1)
        local sql_file="${dump_file%.gz}"
        info "Restoring database from ${dump_file}..."
        gunzip -c "$dump_file" > "$sql_file"

        local pg_host="${DB_HOST:-localhost}"
        local pg_port="${DB_PORT:-5432}"
        local pg_user="${DB_USERNAME:-postgres}"
        local pg_pass="${DB_PASSWORD:?DB_PASSWORD is not set in ${ZOU_ENV_FILE} — cannot restore database}"

        PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='zoudb' AND pid <> pg_backend_pid();" \
            postgres 2>/dev/null || true
        PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
            -c "DROP DATABASE IF EXISTS zoudb;" postgres
        PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
            -c "CREATE DATABASE zoudb;" postgres
        if ! PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
                -v ON_ERROR_STOP=1 -1 -d zoudb -f "$sql_file"; then
            rm -f "$sql_file"
            error "Database restore failed — check the dump file. Restarting services."
            systemctl start zou zou-events
            exit 1
        fi
        rm -f "$sql_file"
        success "Database restored."
    else
        warn "No database dump found — skipping."
    fi

    # Restore previews
    if [[ -f "${chosen_path}/previews.tar.gz" ]]; then
        info "Restoring preview files..."
        local preview_folder="${PREVIEW_FOLDER:-${ZOU_DIR}/previews}"
        rm -rf "${preview_folder:?}"/*
        tar xzf "${chosen_path}/previews.tar.gz" -C "$preview_folder"
        chown -R zou:www-data "$preview_folder"
        success "Preview files restored."
    else
        warn "No previews archive found — skipping."
    fi

    # Restart & migrate
    info "Starting Zou services..."
    systemctl start zou zou-events
    systemctl is-active --quiet zou-jobs 2>/dev/null && systemctl start zou-jobs || true

    info "Running database migrations..."
    sleep 3
    set -a; source "$ZOU_ENV_FILE"; set +a
    "${ZOU_BIN}/zou" upgrade-db && success "Migrations applied." \
        || warn "upgrade-db returned an error — check: journalctl -fu zou"

    success "Restore complete."
}

show_schedule_info() {
    header "Backup Schedule & Status"
    load_backup_config

    if [[ -f "$BACKUP_CRON_FILE" ]]; then
        success "Scheduled backup is ACTIVE"
        local cron_entry schedule_comment
        cron_entry=$(grep -v '^#' "$BACKUP_CRON_FILE" 2>/dev/null | grep -v '^$' | grep -v '^[A-Z]' || true)
        schedule_comment=$(grep '# Schedule:' "$BACKUP_CRON_FILE" 2>/dev/null | sed 's/# Schedule: //' || true)
        echo -e "  ${BOLD}Type:${NC}      ${YELLOW}${schedule_comment:-custom}${NC}"
        echo -e "  ${BOLD}Cron:${NC}      ${YELLOW}$(echo "$cron_entry" | awk '{print $1,$2,$3,$4,$5}')${NC}"
        echo -e "  ${BOLD}Log:${NC}       /var/log/kitsu-backup.log"
    else
        warn "No scheduled backup configured."
    fi

    echo
    echo -e "  ${BOLD}Backup directory:${NC}  ${BACKUP_DIR}"
    echo -e "  ${BOLD}Versions to keep:${NC}  ${KEEP_VERSIONS}"

    local -a existing
    mapfile -t existing < <(ls -dt "${BACKUP_DIR}"/[0-9][0-9][0-9][0-9]-* 2>/dev/null || true)
    echo -e "  ${BOLD}Stored backups:${NC}    ${#existing[@]}"

    if (( ${#existing[@]} > 0 )); then
        echo
        echo -e "  ${BOLD}Available backups:${NC}"
        for b in "${existing[@]}"; do
            local size db_size prev_size
            size=$(du -sh "$b" 2>/dev/null | cut -f1)
            db_size="n/a"; prev_size="n/a"
            local db_file; db_file=$(ls "$b"/*.sql.gz 2>/dev/null | head -1 || true)
            [[ -n "$db_file" ]] && db_size=$(du -sh "$db_file" 2>/dev/null | cut -f1)
            [[ -f "$b/previews.tar.gz" ]] && prev_size=$(du -sh "$b/previews.tar.gz" 2>/dev/null | cut -f1)
            echo -e "    ${CYAN}$(basename "$b")${NC}  total: ${size}  (db: ${db_size}, previews: ${prev_size})"
        done
    fi
    echo
}

configure_schedule() {
    header "Configure Backup Schedule"
    load_backup_config

    BACKUP_DIR=$(prompt_value "Backup directory" "$BACKUP_DIR")
    mkdir -p "$BACKUP_DIR"

    local keep; keep=$(prompt_value "Backup versions to keep" "$KEEP_VERSIONS")
    if [[ "$keep" =~ ^[0-9]+$ ]] && (( keep >= 1 )); then
        KEEP_VERSIONS="$keep"
    else
        KEEP_VERSIONS="$DEFAULT_KEEP_VERSIONS"
    fi

    local sched_type
    sched_type=$(prompt_choice "Backup frequency:" \
        "One time (run now, no recurring schedule)" \
        "Hourly" \
        "Daily" \
        "Weekly (every Sunday)" \
        "Custom interval")

    local backup_hour="2"
    if [[ "$sched_type" == "Daily" || "$sched_type" == "Weekly"* ]]; then
        local raw_hour; raw_hour=$(prompt_value "Hour to run backup (0-23)" "2")
        [[ "$raw_hour" =~ ^[0-9]+$ ]] && (( raw_hour >= 0 && raw_hour <= 23 )) \
            && backup_hour="$raw_hour"
    fi

    local cron_expr="" cron_label=""
    case "$sched_type" in
        "One time"*)
            save_backup_config
            run_backup
            return
            ;;
        "Hourly")
            cron_expr="0 * * * *"; cron_label="Hourly" ;;
        "Daily")
            cron_expr="0 ${backup_hour} * * *"
            cron_label="Daily at $(printf '%02d:00' "$backup_hour")" ;;
        "Weekly"*)
            cron_expr="0 ${backup_hour} * * 0"
            cron_label="Weekly (Sunday at $(printf '%02d:00' "$backup_hour"))" ;;
        "Custom interval")
            local interval_type
            interval_type=$(prompt_choice "Custom interval unit:" \
                "Every X minutes" "Every X hours" "Every X days")
            case "$interval_type" in
                "Every X minutes")
                    local x_min; x_min=$(prompt_value "Every how many minutes?" "30")
                    [[ "$x_min" =~ ^[0-9]+$ ]] && (( x_min >= 1 && x_min <= 59 )) || x_min=30
                    cron_expr="*/${x_min} * * * *"; cron_label="Every ${x_min} minutes" ;;
                "Every X hours")
                    local x_hrs; x_hrs=$(prompt_value "Every how many hours?" "6")
                    [[ "$x_hrs" =~ ^[0-9]+$ ]] && (( x_hrs >= 1 && x_hrs <= 23 )) || x_hrs=6
                    cron_expr="0 */${x_hrs} * * *"; cron_label="Every ${x_hrs} hours" ;;
                "Every X days")
                    local x_days; x_days=$(prompt_value "Every how many days?" "3")
                    [[ "$x_days" =~ ^[0-9]+$ ]] && (( x_days >= 1 )) || x_days=3
                    local raw_h2; raw_h2=$(prompt_value "Hour to run backup (0-23)" "2")
                    [[ "$raw_h2" =~ ^[0-9]+$ ]] && (( raw_h2 >= 0 && raw_h2 <= 23 )) && backup_hour="$raw_h2"
                    cron_expr="0 ${backup_hour} */${x_days} * *"
                    cron_label="Every ${x_days} days at $(printf '%02d:00' "$backup_hour")" ;;
            esac ;;
    esac

    # Install script to stable path for cron
    local script_src; script_src=$(readlink -f "${BASH_SOURCE[0]}")
    if [[ "$script_src" != "$BACKUP_INSTALL_BIN" ]]; then
        cp "$script_src" "$BACKUP_INSTALL_BIN"
        chmod +x "$BACKUP_INSTALL_BIN"
        success "Script installed → ${BACKUP_INSTALL_BIN}"
    fi

    cat > "$BACKUP_CRON_FILE" <<EOF
# Kitsu automated backup
# Schedule: ${cron_label}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${cron_expr} root ${BACKUP_INSTALL_BIN} --backup-run >> /var/log/kitsu-backup.log 2>&1
EOF
    chmod 644 "$BACKUP_CRON_FILE"
    save_backup_config

    echo
    success "Schedule saved: ${cron_label}"
    info  "Cron: ${cron_expr} → ${BACKUP_INSTALL_BIN} --backup-run"
    info  "Log:  /var/log/kitsu-backup.log"
    echo
    if prompt_yn "Run a backup now to verify everything works?" "y"; then
        run_backup
    fi
}

remove_backup_schedule() {
    header "Remove Backup Schedule"
    if [[ -f "$BACKUP_CRON_FILE" ]]; then
        if prompt_yn "Remove the scheduled backup cron job?" "y"; then
            rm -f "$BACKUP_CRON_FILE"
            success "Cron job removed."
        else
            info "No changes made."
        fi
    else
        warn "No scheduled backup found — nothing to remove."
    fi
}

backup_wizard() {
    header "Kitsu Backup Manager"
    local choice
    choice=$(prompt_choice "What would you like to do?" \
        "Create / schedule a backup" \
        "Restore from a backup" \
        "Show backup schedule & info" \
        "Remove backup schedule" \
        "Back")
    case "$choice" in
        "Create / schedule a backup")  configure_schedule ;;
        "Restore from a backup")       run_restore ;;
        "Show backup schedule & info") show_schedule_info ;;
        "Remove backup schedule")      remove_backup_schedule ;;
        "Back") return ;;
    esac
}

# =============================================================================
# DATA MIGRATION
# =============================================================================

data_migration_wizard() {
    header "Data Migration"

    echo -e "  This wizard migrates data from an existing Kitsu instance"
    echo -e "  to this server using the Zou sync CLI.\n"

    local source_url source_login source_password

    source_url=$(prompt_value "Source Kitsu API URL" "http://yourpreviouskitsu.url/api")
    source_login=$(prompt_value "Admin email on source instance" "admin@yourstudio.com")
    source_password=$(prompt_secret "Admin password on source instance")

    echo
    warn "This will clear the local database and replace it with data from ${source_url}."
    if ! prompt_yn "Proceed?" "n"; then
        info "Migration cancelled."
        return
    fi

    load_zou_env
    set -a; source "$ZOU_ENV_FILE"; set +a

    # Step 1 — prepare target database
    header "Step 1/4 — Preparing Target Database"
    "${ZOU_BIN}/zou" clear-db
    "${ZOU_BIN}/zou" reset-migrations
    "${ZOU_BIN}/zou" upgrade-db
    success "Target database ready."

    # Step 2 — sync base data (no projects)
    header "Step 2/4 — Syncing Base Data"
    SYNC_LOGIN="$source_login" SYNC_PASSWORD="$source_password" \
        "${ZOU_BIN}/zou" sync-full \
            --source "$source_url" \
            --no-projects
    success "Base data synced."

    # Step 3 — sync project data
    header "Step 3/4 — Syncing Project Data"
    local sync_mode
    sync_mode=$(prompt_choice "Which projects to sync?" \
        "All projects" \
        "Single project by name")

    if [[ "$sync_mode" == "All projects" ]]; then
        SYNC_LOGIN="$source_login" SYNC_PASSWORD="$source_password" \
            "${ZOU_BIN}/zou" sync-full \
                --source "$source_url" \
                --only-projects
    else
        local project_name
        project_name=$(prompt_value "Project name (case-sensitive)" "AwesomeProject")
        SYNC_LOGIN="$source_login" SYNC_PASSWORD="$source_password" \
            "${ZOU_BIN}/zou" sync-full \
                --source "$source_url" \
                --project "$project_name"
    fi
    success "Project data synced."

    # Step 4 — transfer files
    header "Step 4/4 — Transferring Preview Files"
    if prompt_yn "Transfer preview files from source? (can take a long time)" "y"; then
        SYNC_LOGIN="$source_login" SYNC_PASSWORD="$source_password" \
            "${ZOU_BIN}/zou" sync-full-files \
                --source "$source_url"
        success "Preview files transferred."
    else
        info "File transfer skipped."
    fi

    echo
    success "Data migration complete."
    info "Note: File deletions from the source are not replicated — verify manually."
    echo
}

# =============================================================================
# MAIN MENU
# =============================================================================

# =============================================================================
# MOVE DATABASE
# =============================================================================

move_db_wizard() {
    header "Move PostgreSQL Data Directory"
    load_zou_env

    local current_path
    current_path=$(sudo -u postgres psql -Atc "SHOW data_directory;" 2>/dev/null || true)
    if [[ -z "$current_path" ]]; then
        local pg_conf
        pg_conf=$(find /etc/postgresql -name postgresql.conf 2>/dev/null | head -1)
        if [[ -n "$pg_conf" ]]; then
            current_path=$(grep -E '^data_directory' "$pg_conf" \
                | awk -F"'" '{print $2}' | head -1 || true)
        fi
    fi
    [[ -z "$current_path" ]] && current_path="/var/lib/postgresql"

    echo -e "  ${BOLD}Current PostgreSQL data directory:${NC} ${YELLOW}${current_path}${NC}\n"

    local new_path
    new_path=$(prompt_value "New data directory path" "$current_path")

    if [[ "$new_path" == "$current_path" ]]; then
        info "Path unchanged — nothing to do."
        return
    fi

    if [[ ! "$new_path" = /* ]]; then
        error "Path must be absolute (start with /)."
        return
    fi

    warn "This will:"
    warn "  1. Stop PostgreSQL"
    warn "  2. Copy all data from ${current_path} → ${new_path}"
    warn "  3. Update postgresql.conf to point to the new location"
    warn "  4. Restart PostgreSQL and Zou services"
    echo
    if ! prompt_yn "Proceed?" "n"; then
        info "Cancelled."
        return
    fi

    info "Stopping Zou and PostgreSQL..."
    systemctl stop zou zou-events zou-jobs 2>/dev/null || true
    systemctl stop postgresql

    info "Copying data to ${new_path} (this may take a while)..."
    mkdir -p "$new_path"
    chown postgres:postgres "$new_path"
    chmod 700 "$new_path"
    rsync -a --info=progress2 "${current_path}/" "${new_path}/" \
        || { error "rsync failed — original data is untouched at ${current_path}."; \
             systemctl start postgresql zou zou-events; return 1; }

    local pg_conf
    pg_conf=$(find /etc/postgresql -name postgresql.conf 2>/dev/null | head -1)
    if [[ -z "$pg_conf" ]]; then
        error "Cannot find postgresql.conf — update data_directory manually."
        systemctl start postgresql zou zou-events
        return 1
    fi
    info "Updating ${pg_conf}..."
    sed -i "s|^#*data_directory.*|data_directory = '${new_path}'|" "$pg_conf"
    if ! grep -q "^data_directory" "$pg_conf"; then
        echo "data_directory = '${new_path}'" >> "$pg_conf"
    fi

    info "Starting PostgreSQL with new data directory..."
    systemctl start postgresql
    local _pg_wait=0
    until sudo -u postgres pg_isready -q 2>/dev/null; do
        sleep 1
        (( _pg_wait++ )) || true
        if (( _pg_wait >= 30 )); then
            error "PostgreSQL did not start in 30 s — check: journalctl -xeu postgresql"
            error "Your original data is still intact at: ${current_path}"
            return 1
        fi
    done
    success "PostgreSQL is running from ${new_path}."

    systemctl start zou zou-events 2>/dev/null || true
    [[ -f /etc/systemd/system/zou-jobs.service ]] && systemctl start zou-jobs 2>/dev/null || true

    success "Database moved successfully."
    echo -e "  ${CYAN}Old data still exists at:${NC} ${current_path}"
    echo -e "  ${YELLOW}Once you've confirmed everything works, you can remove it with:${NC}"
    echo -e "    sudo rm -rf ${current_path}"
}

# =============================================================================
# CLEAR TEMP FOLDER
# =============================================================================

clear_tmp_wizard() {
    header "Clear Kitsu Temp Folder"
    load_zou_env
    local tmp="${TMP_DIR:-${ZOU_DIR}/tmp}"

    if [[ ! -d "$tmp" ]]; then
        warn "Temp folder not found: ${tmp}"
        return
    fi

    local size; size=$(du -sh "$tmp" 2>/dev/null | awk '{print $1}')
    echo -e "  ${BOLD}Temp folder:${NC} ${YELLOW}${tmp}${NC}"
    echo -e "  ${BOLD}Current size:${NC} ${YELLOW}${size}${NC}\n"

    if ! prompt_yn "Clear all files in ${tmp}?" "n"; then
        info "Cancelled."
        return
    fi

    # Stop Zou so nothing is writing to tmp during cleanup
    local _zou_was_active=false
    systemctl is-active --quiet zou 2>/dev/null && _zou_was_active=true
    if [[ "$_zou_was_active" == true ]]; then
        info "Stopping Zou services temporarily..."
        systemctl stop zou zou-events zou-jobs 2>/dev/null || true
    fi

    find "$tmp" -mindepth 1 -delete 2>/dev/null || rm -rf "${tmp:?}"/* 2>/dev/null || true
    success "Temp folder cleared."

    if [[ "$_zou_was_active" == true ]]; then
        info "Restarting Zou services..."
        systemctl start zou zou-events 2>/dev/null || true
        [[ -f /etc/systemd/system/zou-jobs.service ]] && systemctl start zou-jobs 2>/dev/null || true
        success "Zou services restarted."
    fi

    local new_size; new_size=$(du -sh "$tmp" 2>/dev/null | awk '{print $1}')
    echo -e "  ${CYAN}Space freed. New size:${NC} ${new_size}"
}

# =============================================================================
# CHANGE USER PASSWORD
# =============================================================================

change_user_wizard() {
    header "Change User Password"
    load_zou_env
    require_zou_running

    # List all users via the Zou API
    info "Fetching user list..."
    local _users_json _rc
    _users_json=$(
        set -a; source "$ZOU_ENV_FILE"; set +a
        "${ZOU_BIN}/python" - 2>&1 <<'PYEOF'
import sys
from zou.app import app
from zou.app.services import persons_service
with app.app_context():
    persons = persons_service.get_persons()
    for p in persons:
        print(f"{p['id']}|{p['email']}|{p.get('full_name', '')}")
PYEOF
    ) && _rc=0 || _rc=$?

    if [[ $_rc -ne 0 || -z "$_users_json" ]]; then
        error "Could not fetch user list: ${_users_json}"
        return 1
    fi

    # Build display list
    local -a ids emails names labels
    while IFS='|' read -r _id _email _name; do
        [[ -z "$_id" ]] && continue
        ids+=("$_id")
        emails+=("$_email")
        names+=("$_name")
        labels+=("${_email} (${_name})")
    done <<< "$_users_json"

    if [[ ${#ids[@]} -eq 0 ]]; then
        warn "No users found."
        return
    fi

    echo -e "\n  ${BOLD}Users:${NC}"
    local i
    for (( i=0; i<${#ids[@]}; i++ )); do
        echo -e "  ${CYAN}$((i+1))${NC}) ${labels[$i]}"
    done
    echo

    local choice_num
    while true; do
        printf "${CYAN}Select user number (1-%d): ${NC}" "${#ids[@]}" >/dev/tty
        read -r choice_num </dev/tty
        if [[ "$choice_num" =~ ^[0-9]+$ ]] \
                && (( choice_num >= 1 )) \
                && (( choice_num <= ${#ids[@]} )); then
            break
        fi
        warn "Invalid choice — enter a number between 1 and ${#ids[@]}."
    done
    local sel=$(( choice_num - 1 ))
    local sel_id="${ids[$sel]}"
    local sel_email="${emails[$sel]}"

    info "Selected: ${sel_email}"

    local new_pass
    new_pass=$(prompt_secret "New password for ${sel_email} (min 8 chars)")
    if [[ ${#new_pass} -lt 8 ]]; then
        error "Password must be at least 8 characters."
        return 1
    fi

    local _pass_file _out _rc2
    _pass_file=$(mktemp /tmp/.zou_chpw_XXXXXX)
    chmod 600 "$_pass_file"
    printf '%s' "${new_pass}" > "$_pass_file"

    _out=$(
        set -a; source "$ZOU_ENV_FILE"; set +a
        ZOU_CHG_ID="${sel_id}" \
        ZOU_CHG_PASS_FILE="${_pass_file}" \
        "${ZOU_BIN}/python" - 2>&1 <<'PYEOF'
import os, sys
pass_file = os.environ["ZOU_CHG_PASS_FILE"]
with open(pass_file) as f:
    password = f.read()
from zou.app import app
from zou.app.services import persons_service
from zou.app.utils import auth
with app.app_context():
    try:
        persons_service.update_person(
            os.environ["ZOU_CHG_ID"],
            {"password": auth.encrypt_password(password)}
        )
        print("ok")
    except Exception as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
PYEOF
    ) && _rc2=0 || _rc2=$?

    rm -f "$_pass_file"

    if [[ $_rc2 -eq 0 ]]; then
        success "Password updated for ${sel_email}."
    else
        error "Failed to update password: ${_out}"
    fi
}

# =============================================================================
# NGINX WIZARD
# =============================================================================

setup_nginx_wizard() {
    header "Configure Nginx"
    load_kitsu_conf
    load_zou_env

    local cur_port="${KITSU_HTTP_PORT:-80}"
    local cur_name="${KITSU_SERVER_NAME:-$(hostname -I | awk '{print $1}')}"

    echo -e "  Current config:"
    echo -e "    Port        : ${YELLOW}${cur_port}${NC}"
    echo -e "    Server name : ${YELLOW}${cur_name}${NC}"
    echo -e "    Nginx conf  : ${NGINX_CONF}"
    echo

    local new_name new_port new_upload use_https cert_path key_path
    new_name=$(prompt_value "Server name or domain" "${cur_name}")
    new_port=$(prompt_value "HTTP listen port" "${cur_port}")
    new_upload=$(prompt_value "Max upload size (e.g. 500M, 2G)" "500M")

    use_https=n
    cert_path=""
    key_path=""

    if prompt_yn "Enable HTTPS / SSL?" "n"; then
        use_https=y
        local https_mode
        https_mode=$(prompt_choice "SSL certificate source?" \
            "Let's Encrypt (certbot — automatic, free)" \
            "Existing certificate files (manual)")

        if [[ "$https_mode" == "Let's Encrypt (certbot — automatic, free)" ]]; then
            local le_email
            le_email=$(prompt_value "Email for Let's Encrypt notifications" "admin@${new_name}")

            if ! command -v certbot &>/dev/null; then
                info "Installing certbot..."
                apt-get install -y certbot -qq \
                    && success "certbot installed." \
                    || { error "certbot install failed."; return 1; }
            fi

            # Stop nginx temporarily so certbot standalone can bind port 80
            info "Stopping nginx briefly to obtain certificate..."
            systemctl stop nginx 2>/dev/null || true

            info "Requesting Let's Encrypt certificate for ${new_name}..."
            if certbot certonly --standalone \
                    -d "${new_name}" \
                    --non-interactive --agree-tos \
                    -m "${le_email}"; then
                cert_path="/etc/letsencrypt/live/${new_name}/fullchain.pem"
                key_path="/etc/letsencrypt/live/${new_name}/privkey.pem"
                success "Certificate obtained: ${cert_path}"

                # Install auto-renewal hook that reloads nginx after renewal
                cat > /etc/letsencrypt/renewal-hooks/deploy/kitsu-nginx.sh <<'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
                chmod +x /etc/letsencrypt/renewal-hooks/deploy/kitsu-nginx.sh
                info "Auto-renewal hook installed — nginx will reload after each renewal."
            else
                error "certbot failed."
                error "Make sure:"
                error "  • ${new_name} resolves to this server's public IP"
                error "  • Port 80 is reachable from the internet"
                systemctl start nginx 2>/dev/null || true
                return 1
            fi
        else
            cert_path=$(prompt_value "Path to certificate file (.crt / .pem)" "")
            key_path=$(prompt_value "Path to private key file (.key)" "")
            if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
                error "Certificate or key file not found."
                return 1
            fi
        fi
    fi

    # ── Write nginx config ────────────────────────────────────────────────────
    if [[ "$use_https" == "y" ]]; then
        cat > "$NGINX_CONF" <<EOF
# HTTP → HTTPS redirect
server {
    listen ${new_port};
    server_name ${new_name};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${new_name};

    ssl_certificate     ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    location /api {
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:5000/;
        client_max_body_size ${new_upload};
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        send_timeout 600s;
    }

    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_pass http://127.0.0.1:5001;
    }

    location / {
        autoindex on;
        root  ${KITSU_DIST};
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    else
        cat > "$NGINX_CONF" <<EOF
server {
    listen ${new_port};
    server_name ${new_name};

    location /api {
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:5000/;
        client_max_body_size ${new_upload};
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        send_timeout 600s;
    }

    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_pass http://127.0.0.1:5001;
    }

    location / {
        autoindex on;
        root  ${KITSU_DIST};
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    fi

    rm -f /etc/nginx/sites-enabled/default
    ln -sf "$NGINX_CONF" "$NGINX_ENABLED"

    if ! nginx -t; then
        error "Nginx config test failed — check ${NGINX_CONF}."
        return 1
    fi

    systemctl start nginx 2>/dev/null || true
    systemctl reload nginx && success "Nginx reloaded." || systemctl restart nginx

    KITSU_SERVER_NAME="$new_name"
    KITSU_HTTP_PORT="$new_port"
    save_kitsu_conf

    success "Nginx configured."
    if [[ "$use_https" == "y" ]]; then
        echo -e "  ${BOLD}URL:${NC} ${GREEN}https://${new_name}${NC}"
        info "HTTP on port ${new_port} redirects to HTTPS."
    else
        local _sfx=""; [[ "$new_port" != "80" ]] && _sfx=":${new_port}"
        echo -e "  ${BOLD}URL:${NC} ${GREEN}http://${new_name}${_sfx}${NC}"
    fi
}

# =============================================================================
# CONFIGURE EMAIL (PASSWORD RECOVERY / NOTIFICATIONS)
# =============================================================================

configure_email_wizard() {
    header "Configure Email (Password Recovery)"

    echo -e "  These settings are written to ${BOLD}${ZOU_ENV_FILE}${NC} and control how"
    echo -e "  Kitsu sends password-reset emails to your users.\n"

    local mail_server mail_port mail_user mail_pass mail_sender mail_tls mail_ssl domain_name

    mail_server=$(prompt_value "SMTP server (e.g. smtp.gmail.com)" "smtp.gmail.com")
    mail_port=$(prompt_value "SMTP port (587=STARTTLS, 465=SSL, 25=plain)" "587")

    if [[ "$mail_port" == "587" ]]; then
        mail_tls="true"; mail_ssl="false"
    elif [[ "$mail_port" == "465" ]]; then
        mail_tls="false"; mail_ssl="true"
    else
        mail_tls="false"; mail_ssl="false"
    fi

    mail_user=$(prompt_value "SMTP username (usually your email address)" "")
    mail_pass=$(prompt_secret "SMTP password / App Password")
    mail_sender=$(prompt_value "From address shown to users" "${mail_user:-no-reply@your-studio.com}")
    load_kitsu_conf
    local _port="${KITSU_HTTP_PORT:-80}"
    local _port_suffix=""; [[ "$_port" != "80" ]] && _port_suffix=":${_port}"
    local _default_domain; _default_domain="$(hostname -I | awk '{print $1}')${_port_suffix}"
    domain_name=$(prompt_value "Your Kitsu domain (used in reset links)" "${_default_domain}")

    if [[ -z "$mail_server" || -z "$mail_user" || -z "$mail_pass" ]]; then
        warn "SMTP server, username and password are required — skipping."
        return 1
    fi

    # Remove old MAIL_* and DOMAIN_NAME entries then append fresh ones
    sed -i '/^MAIL_ENABLED=/d;/^MAIL_SERVER=/d;/^MAIL_PORT=/d' "$ZOU_ENV_FILE"
    sed -i '/^MAIL_USERNAME=/d;/^MAIL_PASSWORD=/d;/^MAIL_USE_TLS=/d' "$ZOU_ENV_FILE"
    sed -i '/^MAIL_USE_SSL=/d;/^MAIL_DEFAULT_SENDER=/d;/^DOMAIN_NAME=/d' "$ZOU_ENV_FILE"

    cat >> "$ZOU_ENV_FILE" <<EOF

# Password-recovery email (zou)
MAIL_ENABLED=true
MAIL_SERVER=${mail_server}
MAIL_PORT=${mail_port}
MAIL_USERNAME=${mail_user}
MAIL_PASSWORD=${mail_pass}
MAIL_USE_TLS=${mail_tls}
MAIL_USE_SSL=${mail_ssl}
MAIL_DEFAULT_SENDER=${mail_sender}
DOMAIN_NAME=${domain_name}
EOF

    info "Restarting Zou to apply new email settings..."
    systemctl restart zou zou-events 2>/dev/null || true

    success "Password-recovery email configured."
    echo -e "  ${BOLD}SMTP:${NC}   ${mail_user}@${mail_server}:${mail_port}"
    echo -e "  ${BOLD}Sender:${NC} ${mail_sender}"
    echo -e "  ${BOLD}Domain:${NC} ${domain_name}"
}

main() {
    # Non-interactive cron mode (no root check needed for --generate-config)
    case "${1:-}" in
        --backup-run)
            require_root
            echo "=== Kitsu backup started at $(date) ==="
            load_backup_config
            run_backup
            echo "=== Kitsu backup finished at $(date) ==="
            exit 0
            ;;
        --generate-config)
            write_config_example "${2:-kitsu_install.conf.example}"
            exit 0
            ;;
        --config)
            if [[ -z "${2:-}" ]]; then
                error "Usage: $0 --config /path/to/kitsu_install.conf"
                exit 1
            fi
            UNATTENDED_CONFIG="$2"
            load_unattended_config "$UNATTENDED_CONFIG"
            require_root
            validate_unattended_config
            install_fresh
            exit 0
            ;;
    esac

    require_root

    header "Kitsu Manager for Debian"

    if detect_existing; then
        show_access_info
        local choice
        choice=$(prompt_choice "What would you like to do?" \
            "Upgrade Kitsu" \
            "Repair Installation" \
            "Change User Password" \
            "Configure Email" \
            "Configure Nginx" \
            "Setup S3 Storage" \
            "Setup Backup" \
            "Data Migration" \
            "Move Database" \
            "Clear Temp Folder" \
            "Delete Kitsu" \
            "Cancel")
        case "$choice" in
            "Upgrade Kitsu")        upgrade_kitsu ;;
            "Repair Installation")  repair_kitsu ;;
            "Change User Password") change_user_wizard ;;
            "Configure Email")      configure_email_wizard ;;
            "Configure Nginx")      setup_nginx_wizard ;;
            "Setup S3 Storage")     setup_s3_storage ;;
            "Setup Backup")         backup_wizard ;;
            "Data Migration")       data_migration_wizard ;;
            "Move Database")        move_db_wizard ;;
            "Clear Temp Folder")    clear_tmp_wizard ;;
            "Delete Kitsu")         delete_kitsu ;;
            "Cancel")               info "No changes made."; exit 0 ;;
        esac
    else
        local choice
        choice=$(prompt_choice "No Kitsu installation found. What would you like to do?" \
            "Install Kitsu" \
            "Purge Incomplete Install" \
            "Cancel")
        case "$choice" in
            "Install Kitsu")          install_fresh ;;
            "Purge Incomplete Install") purge_footprint ;;
            "Cancel") info "Cancelled."; exit 0 ;;
        esac
    fi
}

main "$@"
