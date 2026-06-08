#!/usr/bin/env bash
# =============================================================================
# Kitsu Installer & Manager for Debian (bare-metal, no Docker for app services)
# Based on: https://dev.kitsu.cloud/self-hosting/setup.html
# Requires: Debian 12 (Bookworm) or later
# =============================================================================

set -euo pipefail

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

# ── Root check ────────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi
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
        ln -sf /usr/local/bin/python3.12 /usr/local/bin/python3.12
    fi

    # Install venv module (pip is included via --with-ensurepip)
    python3.12 -m ensurepip --upgrade &>/dev/null || true

    success "Python $(python3.12 --version 2>&1) compiled and installed."
}

# =============================================================================
# INSTALLATION
# =============================================================================

_prompt_report_email() {
    echo -e "\n${BOLD}Email notification (Google / Gmail)${NC}"
    echo -e "  The script can send the installation summary to your email."
    echo -e "  You need a Gmail address and a ${CYAN}Google App Password${NC}."
    echo -e "  Generate one at: ${YELLOW}https://myaccount.google.com/apppasswords${NC}\n"

    local gmail_addr gmail_app_pass dest_addr

    printf "${CYAN}Gmail address to send FROM${NC} (leave blank to skip): " >/dev/tty
    read -r gmail_addr </dev/tty

    if [[ -z "$gmail_addr" ]]; then
        REPORT_EMAIL=""
        return
    fi

    gmail_app_pass=$(prompt_secret "Google App Password (16-char, no spaces)")
    if [[ -z "$gmail_app_pass" ]]; then
        warn "No app password entered — email notifications skipped."
        REPORT_EMAIL=""
        return
    fi

    dest_addr=$(prompt_value "Send report TO email address" "$gmail_addr")
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
    header "Fresh Kitsu Installation (Debian, bare-metal)"

    _prompt_report_email
    echo

    # ── Collect configuration ─────────────────────────────────────────────────
    local db_password secret_key admin_email admin_password server_name
    local enable_search enable_jobs

    echo -e "${BOLD}Configure your Kitsu instance${NC} (press Enter to accept defaults)\n"

    server_name=$(prompt_value "Server hostname or IP (for Nginx)" "$(hostname -I | awk '{print $1}')")
    db_password=$(prompt_value "PostgreSQL password" "mysecretpassword")
    secret_key=$(python3 -c "import secrets; print(secrets.token_hex(16))" 2>/dev/null \
        || cat /proc/sys/kernel/random/uuid | tr -d '-')
    admin_email=$(prompt_value "Admin email" "admin@example.com")
    admin_password=$(prompt_secret "Admin password (min 8 chars)")
    enable_search=$(prompt_yn "Enable full-text search (Meilisearch)?" "y" && echo "y" || echo "n")
    enable_jobs=$(prompt_yn "Enable asynchronous job queue (RQ)?" "y" && echo "y" || echo "n")

    echo
    if ! prompt_yn "Proceed with installation?" "y"; then
        info "Installation cancelled."
        exit 0
    fi

    # ── System packages ───────────────────────────────────────────────────────
    header "Installing System Packages"
    apt-get update -qq

    ensure_package "build-essential"
    ensure_package "postgresql"
    ensure_package "postgresql-client"
    ensure_package "postgresql-server-dev-all"
    ensure_package "redis-server"
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
    systemctl enable --now redis-server
    # Performance tuning
    if ! grep -q 'vm.overcommit_memory' /etc/sysctl.conf 2>/dev/null; then
        echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf
        sysctl -p /etc/sysctl.conf &>/dev/null || true
    fi
    success "Redis configured."

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

    mkdir -p "${ZOU_DIR}" "${ZOU_DIR}/backups" "${ZOU_DIR}/previews" \
             "${ZOU_DIR}/tmp" "${ZOU_DIR}/logs"
    chown zou: "${ZOU_DIR}/backups"
    chown -R zou:www-data "${ZOU_DIR}/previews" "${ZOU_DIR}/tmp" "${ZOU_DIR}/logs"

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
DB_PORT=5432
DB_USERNAME=postgres
DB_DATABASE=zoudb
PREVIEW_FOLDER=${ZOU_DIR}/previews
TMP_DIR=${ZOU_DIR}/tmp
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
After=network.target postgresql.service redis-server.service

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
After=network.target postgresql.service redis-server.service

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
After=network.target redis-server.service zou.service

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
    # shellcheck source=/dev/null
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
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
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

    # Free port 80 if something else is already listening there
    local port80_pid
    port80_pid=$(ss -tlnp 'sport = :80' 2>/dev/null \
        | grep -o 'pid=[0-9]*' | grep -o '[0-9]*' | head -1 || true)
    if [[ -n "$port80_pid" ]]; then
        local port80_comm; port80_comm=$(cat "/proc/${port80_pid}/comm" 2>/dev/null || echo "unknown")
        warn "Port 80 is in use by PID ${port80_pid} (${port80_comm}) — stopping it first..."
        local port80_svc
        port80_svc=$(systemctl list-units --type=service --state=running \
            | grep "$port80_comm" | awk '{print $1}' | head -1 || true)
        if [[ -n "$port80_svc" ]]; then
            systemctl stop "$port80_svc" 2>/dev/null || true
        else
            kill "$port80_pid" 2>/dev/null || kill -9 "$port80_pid" 2>/dev/null || true
        fi
        sleep 1
    fi

    systemctl enable nginx
    if ! systemctl start nginx 2>/dev/null; then
        error "nginx failed to start. Diagnostic output:"
        journalctl -xeu nginx.service --no-pager -n 30 >&2 || true
        systemctl status nginx.service --no-pager >&2 || true
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
    "${ZOU_BIN}/zou" create-admin --password "${admin_password}" "${admin_email}"
    success "Admin user '${admin_email}' created."

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

# ── Summary ───────────────────────────────────────────────────────────────────
show_summary() {
    local server_name="${1:-$(hostname -I | awk '{print $1}')}"
    local admin_email="${2:-admin@example.com}"

    header "Kitsu is Ready"
    echo -e "  ${BOLD}Web UI:${NC}     ${GREEN}http://${server_name}${NC}"
    echo -e "  ${BOLD}API:${NC}        ${GREEN}http://${server_name}/api${NC}"
    echo -e "  ${BOLD}Events:${NC}     ${GREEN}http://${server_name}/socket.io${NC}"
    echo
    echo -e "  ${BOLD}Login:${NC}      ${YELLOW}${admin_email}${NC}"
    echo -e "  ${YELLOW}Note:${NC} Use the password you set during installation."
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

    cat > "$summary_file" <<EOF
Kitsu Installation Summary
==========================
Web UI:   http://${server_name}
API:      http://${server_name}/api
Events:   http://${server_name}/socket.io

Login:    ${admin_email}
Note: Use the password you set during installation.

Useful commands:
  View API logs  :  journalctl -fu zou
  View event logs:  journalctl -fu zou-events
  Restart all    :  sudo systemctl restart zou zou-events nginx
  Upgrade DB     :  sudo -u zou ${ZOU_BIN}/zou upgrade-db
EOF
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

main() {
    require_root

    # Non-interactive cron mode
    if [[ "${1:-}" == "--backup-run" ]]; then
        echo "=== Kitsu backup started at $(date) ==="
        load_backup_config
        run_backup
        echo "=== Kitsu backup finished at $(date) ==="
        exit 0
    fi

    header "Kitsu Manager for Debian"

    if detect_existing; then
        local choice
        choice=$(prompt_choice "Existing Kitsu installation detected. What would you like to do?" \
            "Upgrade Kitsu" \
            "Setup S3 Storage" \
            "Setup Backup" \
            "Data Migration" \
            "Cancel")
        case "$choice" in
            "Upgrade Kitsu")    upgrade_kitsu ;;
            "Setup S3 Storage") setup_s3_storage ;;
            "Setup Backup")     backup_wizard ;;
            "Data Migration")   data_migration_wizard ;;
            "Cancel")           info "No changes made."; exit 0 ;;
        esac
    else
        local choice
        choice=$(prompt_choice "No Kitsu installation found. What would you like to do?" \
            "Install Kitsu" \
            "Cancel")
        case "$choice" in
            "Install Kitsu") install_fresh ;;
            "Cancel") info "Cancelled."; exit 0 ;;
        esac
    fi
}

main "$@"
