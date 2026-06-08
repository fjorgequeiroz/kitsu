#!/usr/bin/env bash
# =============================================================================
# Kitsu Installer & Manager for Ubuntu (bare-metal, no Docker for app services)
# Based on: https://dev.kitsu.cloud/self-hosting/setup.html
#
# Unattended install:
#   sudo ./install_kitsu.sh --config /path/to/kitsu_install.conf
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
        # Strip comments and blank lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key="${key// /}"
        val="${val%%#*}"          # strip inline comments
        val="${val#"${val%%[![:space:]]*}"}"  # ltrim
        val="${val%"${val##*[![:space:]]}"}"  # rtrim
        _CONF["$key"]="$val"
    done < "$cfg"
}

# Return value from config file, or prompt interactively if not set
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
# Usage: sudo ./install_kitsu.sh --config kitsu_install.conf
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

# ── Email notifications (Gmail / App Password) ────────────────────────────────
# Leave GMAIL_FROM blank to skip email setup entirely.
GMAIL_FROM=
GMAIL_APP_PASSWORD=
REPORT_EMAIL=
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

# ── Redis service name (varies: redis-server on Ubuntu, redis on Debian/others)
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
        # Package installed but unit not yet visible — trust the package name
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

# ── Load / save env helpers ───────────────────────────────────────────────────
load_zou_env() {
    if [[ -f "$ZOU_ENV_FILE" ]]; then
        # shellcheck source=/dev/null
        set -a; source "$ZOU_ENV_FILE"; set +a
    fi
}

# =============================================================================
# PYTHON 3.12 INSTALL (apt main → deadsnakes PPA → compile from source)
# =============================================================================

_install_python312() {
    if python3.12 --version &>/dev/null 2>&1; then
        success "Python 3.12 already installed ($(python3.12 --version 2>&1))."
        return
    fi

    # 1. Try standard repo first (Ubuntu 24.04+ has it)
    apt-get update -qq
    if apt-cache show python3.12 &>/dev/null 2>&1; then
        info "Installing Python 3.12 from standard repo..."
        apt-get install -y python3.12 python3.12-venv python3.12-dev -qq
        success "Python 3.12 installed from apt."
        return
    fi

    # 2. Try deadsnakes PPA (Ubuntu 20.04 / 22.04)
    info "python3.12 not in standard repo — trying deadsnakes PPA..."
    apt-get install -y software-properties-common -qq
    add-apt-repository ppa:deadsnakes/ppa -y
    apt-get update -qq
    if apt-cache show python3.12 &>/dev/null 2>&1; then
        apt-get install -y python3.12 python3.12-venv python3.12-dev -qq
        success "Python 3.12 installed from deadsnakes PPA."
        return
    fi

    # 3. Compile from source as last resort
    warn "python3.12 not available in apt — compiling from source (this takes ~5 min)..."
    local py_ver="3.12.7"
    local py_src="/tmp/Python-${py_ver}"
    local py_tar="/tmp/Python-${py_ver}.tgz"

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

    if ! command -v python3.12 &>/dev/null; then
        ln -sf /usr/local/bin/python3.12 /usr/bin/python3.12
    fi

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

# Returns 0 if port is free, 1 if in use
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

    # Write /root/.msmtprc
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
    header "Fresh Kitsu Installation (bare-metal)"

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
            fi
        fi
    fi

    _prompt_report_email
    echo

    # ── Collect configuration ─────────────────────────────────────────────────
    local db_password secret_key admin_email admin_password server_name db_port
    local preview_folder tmp_dir
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
    preview_folder=$(conf_value "PREVIEW_FOLDER" "Preview files folder" "${ZOU_DIR}/previews")
    tmp_dir=$(conf_value "TMP_DIR" "Temporary files folder" "${ZOU_DIR}/tmp")
    enable_search=$(conf_yn "ENABLE_SEARCH" "Enable full-text search (Meilisearch)?" "y")
    enable_jobs=$(conf_yn "ENABLE_JOBS" "Enable asynchronous job queue (RQ)?" "y")

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

    # Python 3.12 — try apt first (standard repo → deadsnakes PPA), compile as last resort
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

    # Set postgres password
    sudo -u postgres psql -U postgres -d postgres \
        -c "ALTER USER postgres WITH PASSWORD '${db_password}';" 2>/dev/null || true

    # Create database
    if sudo -u postgres psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw zoudb; then
        success "Database 'zoudb' already exists."
    else
        sudo -u postgres psql -c "CREATE DATABASE zoudb;" 2>/dev/null
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
    # Verify both PostgreSQL and Redis are reachable before calling zou init-db
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

    # Clear any stale failed state, then kill all nginx processes and port
    # occupants before starting fresh — prevents "already in use" failures
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
    while true; do
        local _out
        _out=$("${ZOU_BIN}/zou" create-admin --password "${admin_password}" "${admin_email}" 2>&1)
        if [[ $? -eq 0 ]]; then
            success "Admin user '${admin_email}' created."
            break
        fi
        warn "Failed to create admin user: ${_out}"
        warn "The password may be too short (Kitsu requires at least 8 characters)."
        admin_password=$(prompt_secret "Enter a new admin password (min 8 chars)")
        if [[ ${#admin_password} -lt 8 ]]; then
            warn "Password must be at least 8 characters — try again."
            continue
        fi
        if [[ -n "$UNATTENDED_CONFIG" ]] && [[ -f "$UNATTENDED_CONFIG" ]]; then
            sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${admin_password}|" "$UNATTENDED_CONFIG"
            info "Updated ADMIN_PASSWORD in ${UNATTENDED_CONFIG}."
        fi
    done

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
    # Always show port explicitly so there is no ambiguity
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
        # Ensure zou can read it
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

    # zou-jobs (optional)
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

    # Ensure our site config exists and is enabled
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

    # Ensure symlink exists
    if [[ ! -L "$NGINX_ENABLED" ]]; then
        ln -sf "$NGINX_CONF" "$NGINX_ENABLED"
        info "Nginx site enabled."
    fi

    # Remove default site if it conflicts
    if [[ -f /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
        info "Removed nginx default site."
    fi

    # Test config
    if ! nginx -t 2>/dev/null; then
        error "Nginx configuration test failed:"
        nginx -t >&2
        (( failed++ )) || true
    else
        success "Nginx config syntax OK."

        # Clear any failed systemd state so restart isn't blocked
        systemctl reset-failed nginx 2>/dev/null || true

        # Kill every running nginx process (master + workers) so the port is
        # guaranteed free — catches stray processes that ss/lsof can miss
        if pgrep -x nginx &>/dev/null; then
            info "Stopping existing nginx processes..."
            pkill -x nginx 2>/dev/null || true
            sleep 1
            # Force-kill if still alive
            pkill -9 -x nginx 2>/dev/null || true
            sleep 1
        fi

        # Also free the port via ss in case something else grabbed it
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

    # ── Result ────────────────────────────────────────────────────────────────
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
    # (identified by the REDISUNIT marker comment we embed)
    if [[ -f /etc/systemd/system/redis-server.service ]] \
            && grep -q 'supervised systemd' /etc/systemd/system/redis-server.service 2>/dev/null; then
        local _unit_pkg
        _unit_pkg=$(dpkg -S /etc/systemd/system/redis-server.service 2>/dev/null || true)
        if [[ -z "$_unit_pkg" ]]; then
            # Not owned by any package — we created it, safe to remove
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
    # Restore default site if it was removed and nginx is installed
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

    # ── Inventory what is installed ───────────────────────────────────────────
    echo -e "  ${BOLD}The following Kitsu components were found:${NC}\n"

    local -A components   # component_key -> description
    local -a order        # keep insertion order

    _found() { components["$1"]="$2"; order+=("$1"); }

    # Services / unit files
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

    # Nginx site config
    [[ -f "$NGINX_CONF" ]]    && _found "nginx_conf"   "Nginx site config ${NGINX_CONF}"
    [[ -L "$NGINX_ENABLED" ]] && _found "nginx_link"   "Nginx site symlink ${NGINX_ENABLED}"

    # Directories
    [[ -d "$ZOU_DIR" ]]       && _found "dir_zou"      "Zou install directory ${ZOU_DIR}"
    [[ -d "/opt/kitsu" ]]     && _found "dir_kitsu"    "Kitsu frontend directory /opt/kitsu"
    [[ -d "/opt/meilisearch" ]] && _found "dir_meili"  "Meilisearch data directory /opt/meilisearch"

    # Config files
    [[ -f "$ZOU_ENV_FILE" ]]  && _found "cfg_env"      "Environment file ${ZOU_ENV_FILE}"
    [[ -f "$KITSU_CONF" ]]    && _found "cfg_kitsu"    "Kitsu config ${KITSU_CONF}"
    [[ -f "$BACKUP_CONFIG_FILE" ]] && _found "cfg_backup" "Backup config ${BACKUP_CONFIG_FILE}"

    # System packages (mark as optional/shared)
    for pkg in postgresql redis-server redis nginx ffmpeg meilisearch; do
        dpkg -s "$pkg" &>/dev/null 2>&1 && _found "pkg_${pkg}" "System package '${pkg}' (shared — used by other services too)"
    done

    # Logrotate
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

    # ── Ask per-component ─────────────────────────────────────────────────────
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

    # ── Remove selected components ────────────────────────────────────────────
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
            nginx_conf)
                rm -f "$NGINX_CONF"
                success "Nginx site config removed."
                ;;
            nginx_link)
                rm -f "$NGINX_ENABLED"
                nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
                success "Nginx site symlink removed."
                ;;
            dir_zou)
                rm -rf "$ZOU_DIR"
                success "Zou directory removed."
                ;;
            dir_kitsu)
                rm -rf /opt/kitsu
                success "Kitsu frontend directory removed."
                ;;
            dir_meili)
                rm -rf /opt/meilisearch
                success "Meilisearch data directory removed."
                ;;
            cfg_env)
                rm -f "$ZOU_ENV_FILE"
                success "Environment file removed."
                ;;
            cfg_kitsu)
                rm -f "$KITSU_CONF"
                success "Kitsu config removed."
                ;;
            cfg_backup)
                rm -f "$BACKUP_CONFIG_FILE"
                success "Backup config removed."
                ;;
            pkg_*)
                local pkg="${key#pkg_}"
                apt-get remove -y "$pkg" -qq && success "Package '${pkg}' removed." \
                    || warn "Could not remove package '${pkg}'."
                ;;
            logrotate)
                rm -f /etc/logrotate.d/kitsu
                success "Log rotation config removed."
                ;;
            cron)
                rm -f "$BACKUP_CRON_FILE"
                success "Backup cron job removed."
                ;;
        esac
    done

    systemctl daemon-reload 2>/dev/null || true

    echo
    success "Deletion complete."
    info "If you removed system packages, run 'apt-get autoremove' to clean up dependencies."
    echo
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
        local pg_pass="${DB_PASSWORD:-mysecretpassword}"

        PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='zoudb' AND pid <> pg_backend_pid();" \
            postgres 2>/dev/null || true
        PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
            -c "DROP DATABASE IF EXISTS zoudb;" postgres
        PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
            -c "CREATE DATABASE zoudb;" postgres
        PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
            -1 -d zoudb -f "$sql_file"
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

    # Resolve current data directory from PostgreSQL itself
    local current_path
    current_path=$(sudo -u postgres psql -Atc "SHOW data_directory;" 2>/dev/null || true)
    if [[ -z "$current_path" ]]; then
        # Fallback: read from postgresql.conf
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

    # Stop services that depend on the DB
    info "Stopping Zou and PostgreSQL..."
    systemctl stop zou zou-events zou-jobs 2>/dev/null || true
    systemctl stop postgresql

    # Create new directory and copy data
    info "Copying data to ${new_path} (this may take a while)..."
    mkdir -p "$new_path"
    chown postgres:postgres "$new_path"
    chmod 700 "$new_path"
    rsync -a --info=progress2 "${current_path}/" "${new_path}/" \
        || { error "rsync failed — original data is untouched at ${current_path}."; \
             systemctl start postgresql zou zou-events; return 1; }

    # Update data_directory in postgresql.conf
    local pg_conf
    pg_conf=$(find /etc/postgresql -name postgresql.conf 2>/dev/null | head -1)
    if [[ -z "$pg_conf" ]]; then
        error "Cannot find postgresql.conf — update data_directory manually."
        systemctl start postgresql zou zou-events
        return 1
    fi
    info "Updating ${pg_conf}..."
    # Remove existing data_directory line (commented or not) and append new one
    sed -i "s|^#*data_directory.*|data_directory = '${new_path}'|" "$pg_conf"
    if ! grep -q "^data_directory" "$pg_conf"; then
        echo "data_directory = '${new_path}'" >> "$pg_conf"
    fi

    # Restart and verify
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
            install_fresh
            exit 0
            ;;
    esac

    require_root

    header "Kitsu Manager for Ubuntu"

    if detect_existing; then
        show_access_info
        local choice
        choice=$(prompt_choice "What would you like to do?" \
            "Upgrade Kitsu" \
            "Repair Installation" \
            "Setup S3 Storage" \
            "Setup Backup" \
            "Data Migration" \
            "Move Database" \
            "Clear Temp Folder" \
            "Delete Kitsu" \
            "Purge Incomplete Install" \
            "Cancel")
        case "$choice" in
            "Upgrade Kitsu")           upgrade_kitsu ;;
            "Repair Installation")     repair_kitsu ;;
            "Setup S3 Storage")        setup_s3_storage ;;
            "Setup Backup")            backup_wizard ;;
            "Data Migration")          data_migration_wizard ;;
            "Move Database")           move_db_wizard ;;
            "Clear Temp Folder")       clear_tmp_wizard ;;
            "Delete Kitsu")            delete_kitsu ;;
            "Purge Incomplete Install") purge_footprint ;;
            "Cancel")                  info "No changes made."; exit 0 ;;
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
