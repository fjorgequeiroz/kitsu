#!/usr/bin/env bash
# =============================================================================
# Kitsu Installer & Backup Manager for Debian
# Based on: https://kitsu.cg-wire.com/installation/
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

# ── Defaults ──────────────────────────────────────────────────────────────────
CONTAINER_NAME="cgwire"
COMPOSE_PROJECT_DIR="/opt/kitsu"
DEFAULT_HTTP_PORT=80
DEFAULT_API_PORT=5000
DEFAULT_WS_PORT=8012
HTTP_PORT=$DEFAULT_HTTP_PORT
API_PORT=$DEFAULT_API_PORT
WS_PORT=$DEFAULT_WS_PORT

# Backup defaults
BACKUP_CONFIG_FILE="/opt/kitsu/backup.conf"
BACKUP_CRON_FILE="/etc/cron.d/kitsu-backup"
BACKUP_INSTALL_BIN="/usr/local/bin/kitsu"
DEFAULT_BACKUP_DIR="/opt/kitsu/backups"
DEFAULT_KEEP_VERSIONS=7
REPORT_EMAIL=""
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
KEEP_VERSIONS="$DEFAULT_KEEP_VERSIONS"

# ── Root check ────────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi
}

# ── Container check ───────────────────────────────────────────────────────────
require_container() {
    if ! docker inspect "$CONTAINER_NAME" &>/dev/null 2>&1; then
        error "Kitsu container '${CONTAINER_NAME}' not found. Is Kitsu running?"
        exit 1
    fi
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
    if [[ "$state" != "running" ]]; then
        error "Kitsu container is '${state}', not 'running'. Start it first."
        exit 1
    fi
}

# ── Detect existing installation ──────────────────────────────────────────────
FOUND_ITEMS=()

detect_existing() {
    FOUND_ITEMS=()

    if command -v docker &>/dev/null; then
        for cname in cgwire kitsu zou zou-app zou-event; do
            if docker inspect "$cname" &>/dev/null 2>&1; then
                local state
                state=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null)
                FOUND_ITEMS+=("Docker container '$cname' ($state)")
            fi
        done

        local extra
        extra=$(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null \
            | grep -Ei 'cgwire|kitsu|/zou' || true)
        if [[ -n "$extra" ]]; then
            while IFS=$'\t' read -r en ei es; do
                local dup=false
                for item in "${FOUND_ITEMS[@]:-}"; do
                    [[ "$item" == *"'$en'"* ]] && dup=true && break
                done
                $dup || FOUND_ITEMS+=("Docker container '$en' (image: $ei, $es)")
            done <<< "$extra"
        fi
    fi

    for dir in /opt/kitsu /opt/cgwire "$HOME/kitsu" "$HOME/cgwire"; do
        if [[ -f "$dir/docker-compose.yml" ]] || [[ -f "$dir/docker-compose.yaml" ]]; then
            FOUND_ITEMS+=("Docker Compose project at $dir")
        fi
    done

    if command -v systemctl &>/dev/null; then
        for svc in zou zou-app zou-event kitsu cgwire; do
            if systemctl list-unit-files "$svc.service" &>/dev/null 2>&1 \
                    | grep -q "$svc.service"; then
                local state
                state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
                FOUND_ITEMS+=("Systemd service '$svc' ($state)")
            fi
        done
    fi

    for dir in /opt/zou /opt/kitsu /var/www/kitsu; do
        if [[ -d "$dir" ]]; then
            FOUND_ITEMS+=("Installation directory $dir")
        fi
    done

    for pip_bin in pip3 /opt/zou/env/bin/pip /opt/kitsu/env/bin/pip; do
        if command -v "$pip_bin" &>/dev/null 2>&1; then
            local ver
            ver=$("$pip_bin" show zou 2>/dev/null | grep -i '^Version' | awk '{print $2}')
            if [[ -n "$ver" ]]; then
                FOUND_ITEMS+=("Python package 'zou' v${ver} ($pip_bin)")
            fi
        fi
    done

    if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ':5000 '; then
        local proc
        proc=$(ss -tlnp 2>/dev/null | awk '/:5000 /{print $NF}' | head -1)
        FOUND_ITEMS+=("Port 5000 in use — Zou API likely running ($proc)")
    fi

    [[ ${#FOUND_ITEMS[@]} -gt 0 ]]
}

# ── Package presence check & install ──────────────────────────────────────────
ensure_package() {
    local pkg="$1"
    if dpkg -s "$pkg" &>/dev/null; then
        success "Package '$pkg' is already installed."
    else
        info "Installing '$pkg'..."
        apt-get install -y "$pkg" -qq
        success "Package '$pkg' installed."
    fi
}

install_docker() {
    if command -v docker &>/dev/null; then
        success "Docker is already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))."
        return
    fi
    info "Docker not found — installing via official script..."
    ensure_package "ca-certificates"
    ensure_package "curl"
    ensure_package "gnupg"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin -qq
    systemctl enable --now docker
    success "Docker installed."
}

# ── Prompt helpers ────────────────────────────────────────────────────────────
# All prompts write to /dev/tty and read from /dev/tty so they work inside $().
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

# ── Comprehensive removal ─────────────────────────────────────────────────────
_KNOWN_CONTAINER_NAMES=(cgwire kitsu zou zou-app zou-event)
_KNOWN_COMPOSE_DIRS=(/opt/kitsu /opt/cgwire "$HOME/kitsu" "$HOME/cgwire")
_KNOWN_INSTALL_DIRS=(/opt/zou /opt/kitsu /opt/cgwire /var/www/kitsu)
_KNOWN_SYSTEMD_SVCS=(zou zou-app zou-event kitsu cgwire)
_KNOWN_VOLUMES=(zou-db zou-previews)

release_kitsu_ports() {
    local http_port="${HTTP_PORT:-}"
    local api_port="${API_PORT:-}"
    local ws_port="${WS_PORT:-}"

    for env_file in "$COMPOSE_PROJECT_DIR/.env" /opt/kitsu/.env /opt/zou/.env; do
        if [[ -f "$env_file" ]]; then
            [[ -z "$http_port" ]] && http_port=$(grep '^HTTP_PORT=' "$env_file" 2>/dev/null | cut -d'=' -f2 || true)
            [[ -z "$api_port" ]]  && api_port=$(grep '^API_PORT='  "$env_file" 2>/dev/null | cut -d'=' -f2 || true)
            [[ -z "$ws_port" ]]   && ws_port=$(grep '^WS_PORT='   "$env_file" 2>/dev/null | cut -d'=' -f2 || true)
        fi
    done

    local -A seen=()
    local ports=()
    for p in 5000 5001 8012 "$http_port" "$api_port" "$ws_port"; do
        [[ -z "$p" ]] && continue
        [[ -n "${seen[$p]:-}" ]] && continue
        seen[$p]=1
        ports+=("$p")
    done

    for port in "${ports[@]}"; do
        local raw
        raw=$(ss -tlnp 2>/dev/null | grep ":${port} " || true)
        [[ -z "$raw" ]] && continue

        local pids
        pids=$(echo "$raw" | grep -o 'pid=[0-9]*' | grep -o '[0-9]*' | sort -u || true)
        [[ -z "$pids" ]] && continue

        info "Releasing port ${port}..."
        while IFS= read -r pid; do
            local comm
            comm=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "unknown")
            info "  Stopping PID ${pid} (${comm})"
            kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
        done <<< "$pids"
        success "Port ${port} released."
    done
}

# Prompt about backup cleanup before removal; call before remove_all_kitsu.
prompt_backup_cleanup() {
    if [[ ! -f "$BACKUP_CRON_FILE" ]]; then
        return
    fi

    echo
    warn "A Kitsu backup schedule is active (${BACKUP_CRON_FILE})."
    if prompt_yn "Remove the backup schedule too?" "y"; then
        rm -f "$BACKUP_CRON_FILE"
        success "Backup schedule removed."

        load_backup_config
        if [[ -d "$BACKUP_DIR" ]]; then
            local count
            count=$(ls -d "${BACKUP_DIR}"/[0-9][0-9][0-9][0-9]-* 2>/dev/null | wc -l || true)
            if (( count > 0 )); then
                warn "${count} backup file(s) found in ${BACKUP_DIR}."
                if prompt_yn "Also delete all backup files?" "n"; then
                    rm -rf "$BACKUP_DIR"
                    success "Backup files deleted."
                else
                    info "Backup files kept in ${BACKUP_DIR}."
                fi
            fi
        fi
    else
        info "Backup schedule kept."
    fi
}

remove_all_kitsu() {
    local remove_data="${1:-false}"

    set +o pipefail

    release_kitsu_ports

    # 1. Bring down any docker-compose stacks
    for dir in "${_KNOWN_COMPOSE_DIRS[@]}"; do
        for yml in "$dir/docker-compose.yml" "$dir/docker-compose.yaml"; do
            if [[ -f "$yml" ]]; then
                info "Bringing down Compose stack in $dir ..."
                docker compose -f "$yml" down --remove-orphans 2>/dev/null || true
            fi
        done
    done

    # 2. Force-remove containers by well-known names
    for cname in "${_KNOWN_CONTAINER_NAMES[@]}"; do
        if docker inspect "$cname" &>/dev/null 2>&1; then
            info "Removing container '$cname' ..."
            docker rm -f "$cname" 2>/dev/null || true
        fi
    done

    # 3. Force-remove any remaining container whose IMAGE is from cgwire/kitsu/zou
    local all_containers
    all_containers=$(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null || true)
    if [[ -n "$all_containers" ]]; then
        while IFS=$'\t' read -r cname cimage; do
            if echo "$cimage" | grep -qEi 'cgwire|/kitsu|/zou' 2>/dev/null; then
                if docker inspect "$cname" &>/dev/null 2>&1; then
                    info "Removing container '$cname' (image: $cimage) ..."
                    docker rm -f "$cname" 2>/dev/null || true
                fi
            fi
        done <<< "$all_containers"
    fi

    # 4. Remove data volumes (only when explicitly requested)
    if [[ "$remove_data" == "true" ]]; then
        info "Removing data volumes..."
        sleep 2
        local all_gone=true
        for vol in "${_KNOWN_VOLUMES[@]}"; do
            if ! docker volume inspect "$vol" &>/dev/null 2>&1; then
                info "  Volume '$vol' does not exist — skipping."
                continue
            fi
            local removed=false
            local attempt
            for attempt in 1 2 3; do
                if docker volume rm "$vol" 2>/dev/null; then
                    success "  Volume '$vol' removed."
                    removed=true
                    break
                fi
                warn "  Volume '$vol' still referenced, retrying (${attempt}/3)..."
                sleep 3
            done
            if [[ "$removed" == false ]]; then
                error "  Volume '$vol' could not be removed."
                warn "  Run manually: docker volume rm $vol"
                all_gone=false
            fi
        done
        [[ "$all_gone" == true ]] && success "All data volumes removed."
    fi

    # 5. Remove installation directories
    for dir in "${_KNOWN_INSTALL_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            info "Removing directory $dir ..."
            rm -rf "$dir"
        fi
    done

    # 6. Disable and remove systemd services (bare-metal install)
    if command -v systemctl &>/dev/null; then
        for svc in "${_KNOWN_SYSTEMD_SVCS[@]}"; do
            if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}.service"; then
                info "Removing systemd service '$svc' ..."
                systemctl stop    "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                rm -f "/etc/systemd/system/${svc}.service" \
                      "/lib/systemd/system/${svc}.service"
            fi
        done
        systemctl daemon-reload 2>/dev/null || true
    fi

    # 7. Remove nginx configuration files (bare-metal / host nginx)
    if command -v nginx &>/dev/null; then
        local nginx_cfg_files=(
            /etc/nginx/sites-enabled/kitsu       /etc/nginx/sites-enabled/kitsu.conf
            /etc/nginx/sites-enabled/cgwire      /etc/nginx/sites-enabled/cgwire.conf
            /etc/nginx/sites-enabled/zou         /etc/nginx/sites-enabled/zou.conf
            /etc/nginx/sites-available/kitsu     /etc/nginx/sites-available/kitsu.conf
            /etc/nginx/sites-available/cgwire    /etc/nginx/sites-available/cgwire.conf
            /etc/nginx/sites-available/zou       /etc/nginx/sites-available/zou.conf
            /etc/nginx/conf.d/kitsu.conf         /etc/nginx/conf.d/cgwire.conf
            /etc/nginx/conf.d/zou.conf
        )
        local nginx_changed=false
        for cfg in "${nginx_cfg_files[@]}"; do
            if [[ -f "$cfg" ]]; then
                info "Removing nginx config: $cfg"
                rm -f "$cfg"
                nginx_changed=true
            fi
        done
        if [[ "$nginx_changed" == true ]]; then
            if nginx -t &>/dev/null 2>&1; then
                systemctl reload nginx 2>/dev/null || true
                success "nginx configuration removed and service reloaded."
            else
                warn "nginx config test failed after removal — reload skipped. Check: sudo nginx -t"
            fi
        fi
    fi

    success "All Kitsu artifacts removed."
    set -o pipefail
}

# ── Update (pull latest image, restart) ───────────────────────────────────────
update_kitsu() {
    header "Updating Kitsu"
    info "Pulling latest cgwire/cgwire image..."
    docker pull cgwire/cgwire
    info "Restarting container with new image..."
    remove_all_kitsu "false"
    if [[ -f "$COMPOSE_PROJECT_DIR/.env" ]]; then
        # shellcheck source=/dev/null
        source "$COMPOSE_PROJECT_DIR/.env"
    fi
    HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"
    API_PORT="${API_PORT:-$DEFAULT_API_PORT}"
    WS_PORT="${WS_PORT:-$DEFAULT_WS_PORT}"
    start_container
    success "Kitsu updated and restarted."
    show_summary
}

# ── Repair existing installation ──────────────────────────────────────────────
repair_kitsu() {
    header "Repairing Kitsu"

    if [[ -f "$COMPOSE_PROJECT_DIR/.env" ]]; then
        # shellcheck source=/dev/null
        source "$COMPOSE_PROJECT_DIR/.env"
    fi
    HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"
    API_PORT="${API_PORT:-$DEFAULT_API_PORT}"
    WS_PORT="${WS_PORT:-$DEFAULT_WS_PORT}"

    local needs_recreate=false

    if ! docker inspect "$CONTAINER_NAME" &>/dev/null 2>&1; then
        warn "Container '$CONTAINER_NAME' not found — will recreate it (volumes are kept)."
        needs_recreate=true
    else
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
        info "Container state: ${state}"

        local port_bindings
        port_bindings=$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER_NAME" 2>/dev/null)
        local missing_ports=()
        echo "$port_bindings" | grep -q '"80/tcp"'   || missing_ports+=("web (80)")
        echo "$port_bindings" | grep -q '"5000/tcp"' || missing_ports+=("api (5000)")
        echo "$port_bindings" | grep -q '"8012/tcp"' || missing_ports+=("ws (8012)")

        if [[ ${#missing_ports[@]} -gt 0 ]]; then
            warn "Container is missing port mapping(s): ${missing_ports[*]} — recreating."
            needs_recreate=true
        elif [[ "$state" == "running" ]]; then
            info "Container is running and all port mappings look correct."
        elif [[ "$state" == "exited" || "$state" == "created" || "$state" == "stopped" ]]; then
            info "Container is stopped — starting it."
            docker start "$CONTAINER_NAME"
        else
            warn "Container is in unexpected state '$state' — recreating."
            needs_recreate=true
        fi
    fi

    if [[ "$needs_recreate" == true ]]; then
        info "Recreating container (data volumes are preserved)..."
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
        start_container
    else
        info "Running database upgrade..."
        docker exec "$CONTAINER_NAME" sh -c "/opt/zou/env/bin/zou upgrade-db" 2>/dev/null \
            && success "Database upgraded." \
            || warn "zou upgrade-db returned an error — check logs."

        info "Verifying service health..."
        local elapsed=0
        until docker exec "$CONTAINER_NAME" sh -c \
            "curl -sf -X POST http://localhost/api/auth/login \
             -H 'Content-Type: application/json' \
             -d '{\"email\":\"admin@example.com\",\"password\":\"mysecretpassword\"}' \
             -o /dev/null" 2>/dev/null; do
            sleep 3
            elapsed=$((elapsed + 3))
            printf '.' >/dev/tty
            if (( elapsed >= 60 )); then
                echo >/dev/tty
                warn "Service did not respond in 60 s — check: docker logs ${CONTAINER_NAME}"
                show_summary
                return
            fi
        done
        echo >/dev/tty
        success "Service is healthy."
    fi

    show_summary
}

# ── Change Super Admin Password ───────────────────────────────────────────────
change_admin_password() {
    header "Change Super Admin Password"
    require_container

    local email
    email=$(prompt_value "User email" "admin@example.com")

    local new_pwd
    printf "${CYAN}Enter new password: ${NC}" >/dev/tty
    read -rs new_pwd </dev/tty
    echo >/dev/tty

    if [[ -z "$new_pwd" ]]; then
        error "Password cannot be empty."
        return
    fi

    local new_pwd2
    printf "${CYAN}Confirm new password: ${NC}" >/dev/tty
    read -rs new_pwd2 </dev/tty
    echo >/dev/tty

    if [[ "$new_pwd" != "$new_pwd2" ]]; then
        error "Passwords do not match."
        return
    fi

    info "Updating password for ${email}..."
    
    # Execute the backend 'zou' CLI command inside the container to force a password change
    if docker exec "$CONTAINER_NAME" sh -c "/opt/zou/env/bin/zou change-password '${email}' --password '${new_pwd}'"; then
        success "Password updated successfully."
    else
        error "Failed to update password. Ensure the email is correct and the user exists."
    fi
    
    echo
}

# ── Write env file ────────────────────────────────────────────────────────────
write_env_file() {
    mkdir -p "$COMPOSE_PROJECT_DIR"
    cat > "$COMPOSE_PROJECT_DIR/.env" <<EOF
HTTP_PORT=${HTTP_PORT}
API_PORT=${API_PORT}
WS_PORT=${WS_PORT}
EOF
    chmod 600 "$COMPOSE_PROJECT_DIR/.env"
}

# ── Port prompt ───────────────────────────────────────────────────────────────
# Usage: prompt_port <label> <default> [already-taken-port ...]
prompt_port() {
    local label="$1"
    local default_port="$2"
    shift 2
    local taken=("$@")

    local port="$default_port"
    while true; do
        port=$(prompt_value "$label" "$port")
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            warn "Invalid port — enter a number between 1 and 65535." >/dev/tty
            continue
        fi
        local conflict=false
        for t in "${taken[@]:-}"; do
            if [[ "$port" == "$t" ]]; then
                warn "Port ${port} is already assigned to another Kitsu service." >/dev/tty
                conflict=true
                break
            fi
        done
        $conflict && continue
        local occupied
        occupied=$(ss -tlnp 2>/dev/null | awk -v p=":${port} " '$0 ~ p {print; exit}')
        if [[ -n "$occupied" ]]; then
            warn "Port ${port} is already in use: ${occupied}" >/dev/tty
            warn "Please choose a different port." >/dev/tty
            continue
        fi
        break
    done
    printf '%s' "$port"
}

# ── Start container ───────────────────────────────────────────────────────────
start_container() {
    local port_map=(
        "${HTTP_PORT}:web (→ nginx :80)"
        "${API_PORT}:api (→ zou :5000)"
        "${WS_PORT}:ws (→ event stream :8012)"
    )
    for entry in "${port_map[@]}"; do
        local port="${entry%%:*}"
        local role="${entry#*:}"
        local occupied
        occupied=$(ss -tlnp 2>/dev/null | awk -v p=":${port} " '$0 ~ p {print; exit}')
        if [[ -n "$occupied" ]]; then
            error "Port ${port} (${role}) is already in use: ${occupied}"
            error "Stop the conflicting service or re-run and choose different ports."
            exit 1
        fi
    done

    for vol in zou-db zou-previews; do
        if docker volume inspect "$vol" &>/dev/null 2>&1; then
            warn "Volume '$vol' still exists and will be reused (old data preserved)."
            warn "To start completely fresh, run: docker volume rm $vol"
        fi
    done

    info "Starting Kitsu container  web:${HTTP_PORT}  api:${API_PORT}  ws:${WS_PORT}"
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart always \
        -p "${HTTP_PORT}:80" \
        -p "${API_PORT}:5000" \
        -p "${WS_PORT}:8012" \
        -v zou-db:/var/lib/postgresql \
        -v zou-previews:/opt/zou/previews \
        cgwire/cgwire
    success "Container started."

    info "Waiting for Kitsu to be ready..."
    local elapsed=0
    until docker exec "$CONTAINER_NAME" sh -c \
        "curl -sf -X POST http://localhost/api/auth/login \
         -H 'Content-Type: application/json' \
         -d '{\"email\":\"admin@example.com\",\"password\":\"mysecretpassword\"}' \
         -o /dev/null" 2>/dev/null; do
        sleep 5
        elapsed=$((elapsed + 5))
        printf '.' >/dev/tty
        if (( elapsed >= 180 )); then
            echo >/dev/tty
            warn "Kitsu did not become ready in 180 s — it may still be initializing."
            return
        fi
    done
    echo >/dev/tty
    success "Kitsu is ready."
}

# ── Install fresh ─────────────────────────────────────────────────────────────
_prompt_report_email() {
    local stored_dest=""
    if [[ -f /etc/server-notify.conf ]]; then
        # shellcheck source=/dev/null
        source /etc/server-notify.conf
        stored_dest="${EMAIL_DEST:-}"
    fi

    if [[ -n "$stored_dest" ]]; then
        printf "${CYAN}Send installation report to:${NC} [${YELLOW}%s${NC}] (Enter to confirm, new address to change, 'n' to skip): " "$stored_dest" >/dev/tty
    else
        printf "${CYAN}Send installation report to email${NC} (leave blank to skip): " >/dev/tty
    fi
    local answer=""
    read -r answer </dev/tty

    if [[ "${answer,,}" == "n" ]]; then
        REPORT_EMAIL=""
    elif [[ -z "$answer" ]]; then
        REPORT_EMAIL="$stored_dest"
    else
        REPORT_EMAIL="$answer"
    fi

    if [[ -n "$REPORT_EMAIL" && ! -f /root/.msmtprc ]]; then
        warn "msmtp is not configured — email will be skipped." >/dev/tty
        warn "Run install_gateway.sh first to set up email notifications." >/dev/tty
        REPORT_EMAIL=""
    fi
}

install_fresh() {
    header "Fresh Kitsu Installation"

    _prompt_report_email
    echo
    echo -e "${BOLD}Configure your Kitsu instance${NC} (press Enter to accept defaults)\n"

    HTTP_PORT=$(prompt_port "Web UI port  (HTTP / nginx)"   "$DEFAULT_HTTP_PORT")
    API_PORT=$(prompt_port  "API port     (Zou REST API)"   "$DEFAULT_API_PORT"  "$HTTP_PORT")
    WS_PORT=$(prompt_port   "WebSocket port (event stream)" "$DEFAULT_WS_PORT"   "$HTTP_PORT" "$API_PORT")

    echo
    info "Web UI  : ${YELLOW}${HTTP_PORT}${NC}"
    info "API     : ${YELLOW}${API_PORT}${NC}"
    info "WS      : ${YELLOW}${WS_PORT}${NC}"
    echo
    if ! prompt_yn "Proceed with installation?" "y"; then
        info "Installation cancelled."
        exit 0
    fi

    header "Installing System Packages"
    apt-get update -qq
    ensure_package "curl"
    ensure_package "ca-certificates"
    ensure_package "gnupg"
    install_docker

    header "Pulling Kitsu Image"
    info "Pulling cgwire/cgwire from Docker Hub..."
    docker pull cgwire/cgwire
    success "Image ready."

    write_env_file
    start_container
    show_summary
}

# ── Summary ───────────────────────────────────────────────────────────────────
show_summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<your-server-ip>"

    local web_port_suffix=""
    [[ "$HTTP_PORT" != "80" ]] && web_port_suffix=":${HTTP_PORT}"

    header "Kitsu is Ready"
    echo -e "  ${BOLD}Web UI:${NC}     ${GREEN}http://${ip}${web_port_suffix}${NC}"
    echo -e "  ${BOLD}API:${NC}        ${GREEN}http://${ip}:${API_PORT}/api${NC}"
    echo -e "  ${BOLD}WebSocket:${NC}  ${GREEN}ws://${ip}:${WS_PORT}/socket.io/${NC}"
    echo
    echo -e "  ${BOLD}Login:${NC}    ${YELLOW}admin@example.com${NC}"
    echo -e "  ${BOLD}Password:${NC} ${YELLOW}mysecretpassword${NC}"
    echo
    echo -e "  ${YELLOW}Note:${NC} Change the default password in ${BOLD}Settings → Profile${NC} after first login."
    echo -e "  If your browser opens a previous session, use a ${BOLD}private/incognito window${NC}."
    echo
    echo -e "  ${CYAN}Manage container:${NC}"
    echo -e "    View logs :  docker logs -f ${CONTAINER_NAME}"
    echo -e "    Stop      :  docker stop ${CONTAINER_NAME}"
    echo -e "    Start     :  docker start ${CONTAINER_NAME}"
    echo -e "    Upgrade DB:  docker exec -ti ${CONTAINER_NAME} sh -c \"/opt/zou/env/bin/zou upgrade-db\""
    echo

    # ---- Create the .txt file with the summary data ----
    local target_user="${SUDO_USER:-$USER}"
    local target_home
    target_home=$(eval echo "~$target_user")
    
    local dest_dir="$target_home/Desktop"
    # Fallback to home directory if a Desktop directory does not exist (like on headless servers)
    if [[ ! -d "$dest_dir" ]]; then
        dest_dir="$target_home"
    fi
    
    local summary_file="$dest_dir/kitsu_access_info.txt"
    
    cat <<EOF > "$summary_file"
Kitsu Installation Summary
==========================
Web UI:     http://${ip}${web_port_suffix}
API:        http://${ip}:${API_PORT}/api
WebSocket:  ws://${ip}:${WS_PORT}/socket.io/

Login:      admin@example.com
Password:   mysecretpassword

Note: Change the default password in Settings → Profile after first login.
If your browser opens a previous session, use a private/incognito window.

Manage container:
  View logs :  docker logs -f ${CONTAINER_NAME}
  Stop      :  docker stop ${CONTAINER_NAME}
  Start     :  docker start ${CONTAINER_NAME}
  Upgrade DB:  docker exec -ti ${CONTAINER_NAME} sh -c "/opt/zou/env/bin/zou upgrade-db"
EOF
    
    # Change ownership of the file to the user who invoked sudo so they can access/delete it easily
    chown "$target_user:$target_user" "$summary_file" 2>/dev/null || true

    echo -e "  ${GREEN}A copy of these access details has been saved to:${NC}"
    echo -e "  ${BOLD}${summary_file}${NC}"
    echo

    _send_notify_email "$summary_file" "✅ Kitsu is Ready — $(hostname -f 2>/dev/null || hostname)"
}

# ── Email notification (reuses gateway msmtp config if present) ───────────────
_send_notify_email() {
    local summary_file="$1"
    local subject="$2"

    [[ ! -f /root/.msmtprc  ]] && return
    [[ ! -f "$summary_file" ]] && return

    # Use address from prompt; fall back to stored gateway config
    local dest="${REPORT_EMAIL:-}"
    local from=""
    if [[ -f /etc/server-notify.conf ]]; then
        local _stored_dest="" _stored_from=""
        # shellcheck source=/dev/null
        source /etc/server-notify.conf
        [[ -z "$dest" ]] && dest="${EMAIL_DEST:-}"
        from="${EMAIL_FROM:-}"
    fi
    [[ -z "$dest" ]] && return

    info "Sending summary email to ${dest}..."
    {
        echo "To: ${dest}"
        echo "From: ${from:-noreply@localhost}"
        echo "Subject: ${subject}"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo ""
        cat "$summary_file"
    } | msmtp "${dest}" \
        && success "Email sent to ${dest}" \
        || warn "Email failed — check /var/log/msmtp.log"
}

# =============================================================================
# BACKUP & RESTORE
# =============================================================================

load_backup_config() {
    if [[ -f "$BACKUP_CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$BACKUP_CONFIG_FILE"
    fi
    BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
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

# ── Run backup ────────────────────────────────────────────────────────────────
run_backup() {
    load_backup_config
    require_container

    local date_stamp
    date_stamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local backup_path="${BACKUP_DIR}/${date_stamp}"
    mkdir -p "$backup_path"

    header "Creating Kitsu Backup — ${date_stamp}"

    # 1. Database dump
    info "Dumping PostgreSQL database..."
    local dump_dir="/tmp/kitsu-backup-$$"
    local dump_file="${dump_dir}/$(date '+%Y-%m-%d')-zou-db-backup.sql.gz"
    local zou_bin="/opt/zou/env/bin/zou"

    docker exec "$CONTAINER_NAME" sh -c "mkdir -p ${dump_dir}"

    if docker exec "$CONTAINER_NAME" sh -c "test -x ${zou_bin}"; then
        if ! docker exec "$CONTAINER_NAME" sh -c "cd ${dump_dir} && ${zou_bin} dump-database"; then
            error "zou dump-database failed — check: docker logs ${CONTAINER_NAME}"
            docker exec "$CONTAINER_NAME" sh -c "rm -rf ${dump_dir}" 2>/dev/null || true
            rm -rf "$backup_path"
            exit 1
        fi
    else
        warn "zou not found at ${zou_bin} — falling back to pg_dump."
        if ! docker exec "$CONTAINER_NAME" sh -c \
            "pg_dump -h localhost -U postgres zoudb | gzip > ${dump_file}"; then
            error "pg_dump fallback also failed — check: docker logs ${CONTAINER_NAME}"
            docker exec "$CONTAINER_NAME" sh -c "rm -rf ${dump_dir}" 2>/dev/null || true
            rm -rf "$backup_path"
            exit 1
        fi
    fi

    local remote_dump
    remote_dump=$(docker exec "$CONTAINER_NAME" sh -c \
        "ls -t ${dump_dir}/*.sql.gz 2>/dev/null | head -1" || true)
    if [[ -z "$remote_dump" ]]; then
        error "No .sql.gz file found inside container after dump."
        docker exec "$CONTAINER_NAME" sh -c "rm -rf ${dump_dir}" 2>/dev/null || true
        rm -rf "$backup_path"
        exit 1
    fi
    docker cp "${CONTAINER_NAME}:${remote_dump}" "${backup_path}/database.sql.gz"
    docker exec "$CONTAINER_NAME" sh -c "rm -rf ${dump_dir}" 2>/dev/null || true
    success "Database → ${backup_path}/database.sql.gz"

    # 2. Preview files
    info "Archiving preview files..."
    docker run --rm \
        -v zou-previews:/previews:ro \
        -v "${backup_path}:/backup" \
        alpine tar czf /backup/previews.tar.gz -C /previews . 2>/dev/null
    success "Previews  → ${backup_path}/previews.tar.gz"

    # 3. Manifest
    local image
    image=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
    cat > "${backup_path}/manifest.txt" <<EOF
date=${date_stamp}
container=${CONTAINER_NAME}
image=${image}
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

# ── Restore ───────────────────────────────────────────────────────────────────
run_restore() {
    load_backup_config
    require_container

    header "Restore Kitsu from Backup"

    local -a backups
    mapfile -t backups < <(ls -dt "${BACKUP_DIR}"/[0-9][0-9][0-9][0-9]-* 2>/dev/null || true)
    if [[ ${#backups[@]} -eq 0 ]]; then
        error "No backups found in ${BACKUP_DIR}."
        exit 1
    fi

    local -a labels
    for b in "${backups[@]}"; do
        local label size image_tag
        label=$(basename "$b")
        size=$(du -sh "$b" 2>/dev/null | cut -f1)
        image_tag=""
        [[ -f "$b/manifest.txt" ]] && image_tag=$(grep '^image=' "$b/manifest.txt" 2>/dev/null | cut -d= -f2 || true)
        label+="  [${size}]"
        [[ -n "$image_tag" ]] && label+="  (${image_tag})"
        labels+=("$label")
    done

    local choice
    choice=$(prompt_choice "Select a backup to restore:" "${labels[@]}")

    local chosen_idx=0
    for i in "${!labels[@]}"; do
        [[ "${labels[$i]}" == "$choice" ]] && chosen_idx=$i && break
    done
    local chosen_path="${backups[$chosen_idx]}"

    echo
    warn "WARNING: This will OVERWRITE the current Kitsu database and preview files."
    warn "Backup selected: $(basename "$chosen_path")"
    echo
    if ! prompt_yn "Are you sure you want to restore?" "n"; then
        info "Restore cancelled."
        return
    fi

    header "Restoring — $(basename "$chosen_path")"

    # 1. Stop Zou so it releases all DB connections before we drop the database
    info "Stopping Kitsu application (keeping postgres running)..."
    docker exec "$CONTAINER_NAME" sh -c "supervisorctl stop zou zou-event 2>/dev/null || true"
    sleep 2

    # 2. Database
    if [[ -f "${chosen_path}/database.sql.gz" ]]; then
        info "Restoring database..."
        docker cp "${chosen_path}/database.sql.gz" "${CONTAINER_NAME}:/tmp/kitsu_restore.sql.gz"
        docker exec "$CONTAINER_NAME" sh -c "
            set -e
            gunzip -f /tmp/kitsu_restore.sql.gz
            # Terminate any remaining connections (belt-and-suspenders after supervisorctl stop)
            psql -h localhost -U postgres -c \
                \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
                  WHERE datname = 'zoudb' AND pid <> pg_backend_pid();\" \
                2>/dev/null || true
            psql -h localhost -U postgres -c 'DROP DATABASE IF EXISTS zoudb;'
            psql -h localhost -U postgres -c 'CREATE DATABASE zoudb;'
            psql -h localhost -U postgres -1 -d zoudb -f /tmp/kitsu_restore.sql
            rm -f /tmp/kitsu_restore.sql
        "
        success "Database restored."
    else
        warn "No database dump found in this backup — skipping database restore."
    fi

    # 2. Previews
    if [[ -f "${chosen_path}/previews.tar.gz" ]]; then
        info "Restoring preview files..."
        docker run --rm \
            -v zou-previews:/previews \
            -v "${chosen_path}:/backup:ro" \
            alpine sh -c "rm -rf /previews/* && tar xzf /backup/previews.tar.gz -C /previews"
        success "Preview files restored."
    else
        warn "No previews archive found — skipping preview restore."
    fi

    # 3. Restart and verify
    info "Restarting Kitsu container..."
    docker restart "$CONTAINER_NAME"

    info "Waiting for Kitsu to come back online..."
    local elapsed=0
    until docker exec "$CONTAINER_NAME" sh -c \
        "curl -sf -X POST http://localhost/api/auth/login \
         -H 'Content-Type: application/json' \
         -d '{\"email\":\"admin@example.com\",\"password\":\"mysecretpassword\"}' \
         -o /dev/null" 2>/dev/null; do
        sleep 5
        elapsed=$((elapsed + 5))
        printf '.' >/dev/tty
        if (( elapsed >= 120 )); then
            echo >/dev/tty
            warn "Service did not respond in 120 s — check: docker logs ${CONTAINER_NAME}"
            break
        fi
    done
    echo >/dev/tty

    info "Running database migrations..."
    docker exec "$CONTAINER_NAME" sh -c "/opt/zou/env/bin/zou upgrade-db" 2>/dev/null \
        && success "Database migrations applied." \
        || warn "zou upgrade-db returned an error — check: docker logs ${CONTAINER_NAME}"

    echo
    success "Restore complete. Refresh Kitsu in your browser (use a private window if needed)."
}

# ── Schedule info ─────────────────────────────────────────────────────────────
show_schedule_info() {
    header "Backup Schedule & Status"
    load_backup_config

    if [[ -f "$BACKUP_CRON_FILE" ]]; then
        success "Scheduled backup is ACTIVE"
        echo
        local cron_entry schedule_comment
        cron_entry=$(grep -v '^#' "$BACKUP_CRON_FILE" 2>/dev/null | grep -v '^$' | grep -v '^[A-Z]' || true)
        schedule_comment=$(grep '# Schedule:' "$BACKUP_CRON_FILE" 2>/dev/null | sed 's/# Schedule: //' || true)
        echo -e "  ${BOLD}Type:${NC}       ${YELLOW}${schedule_comment:-custom}${NC}"
        echo -e "  ${BOLD}Cron expr:${NC}  ${YELLOW}$(echo "$cron_entry" | awk '{print $1,$2,$3,$4,$5}')${NC}"
        echo -e "  ${BOLD}Cron file:${NC}  $BACKUP_CRON_FILE"
        echo -e "  ${BOLD}Log file:${NC}   /var/log/kitsu-backup.log"
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
            db_size="n/a";   prev_size="n/a"
            [[ -f "$b/database.sql.gz" ]] && db_size=$(du -sh "$b/database.sql.gz"  2>/dev/null | cut -f1)
            [[ -f "$b/previews.tar.gz" ]] && prev_size=$(du -sh "$b/previews.tar.gz" 2>/dev/null | cut -f1)
            echo -e "    ${CYAN}$(basename "$b")${NC}  total: ${size}  (db: ${db_size}, previews: ${prev_size})"
        done
    fi
    echo
}

# ── Schedule setup ────────────────────────────────────────────────────────────
configure_schedule() {
    header "Configure Backup Schedule"
    load_backup_config

    BACKUP_DIR=$(prompt_value "Backup directory" "$BACKUP_DIR")
    mkdir -p "$BACKUP_DIR"

    local keep
    keep=$(prompt_value "How many backup versions to keep" "$KEEP_VERSIONS")
    if [[ "$keep" =~ ^[0-9]+$ ]] && (( keep >= 1 )); then
        KEEP_VERSIONS="$keep"
    else
        warn "Invalid number — using ${DEFAULT_KEEP_VERSIONS}."
        KEEP_VERSIONS="$DEFAULT_KEEP_VERSIONS"
    fi

    local sched_type
    sched_type=$(prompt_choice "Backup frequency:" \
        "One time (run now, no recurring schedule)" \
        "Hourly" \
        "Daily" \
        "Weekly (every Sunday)" \
        "Custom interval")

    # Hour prompt — only relevant for time-of-day schedules
    local backup_hour="2"
    if [[ "$sched_type" == "Daily" || "$sched_type" == "Weekly"* ]]; then
        local raw_hour
        raw_hour=$(prompt_value "Hour to run backup (0-23)" "2")
        if [[ "$raw_hour" =~ ^[0-9]+$ ]] && (( raw_hour >= 0 && raw_hour <= 23 )); then
            backup_hour="$raw_hour"
        else
            warn "Invalid hour — defaulting to 02:00."
        fi
    fi

    local cron_expr="" cron_label=""
    case "$sched_type" in
        "One time"*)
            save_backup_config
            info "Running one-time backup now..."
            run_backup
            return
            ;;
        "Hourly")
            cron_expr="0 * * * *"
            cron_label="Hourly"
            ;;
        "Daily")
            cron_expr="0 ${backup_hour} * * *"
            cron_label="Daily at $(printf '%02d:00' "$backup_hour")"
            ;;
        "Weekly"*)
            cron_expr="0 ${backup_hour} * * 0"
            cron_label="Weekly (Sunday at $(printf '%02d:00' "$backup_hour"))"
            ;;
        "Custom interval")
            local interval_type
            interval_type=$(prompt_choice "Custom interval unit:" \
                "Every X minutes" \
                "Every X hours" \
                "Every X days")

            case "$interval_type" in
                "Every X minutes")
                    local x_min
                    x_min=$(prompt_value "Run every how many minutes?" "30")
                    if ! [[ "$x_min" =~ ^[0-9]+$ ]] || (( x_min < 1 || x_min > 59 )); then
                        warn "Invalid — defaulting to 30 minutes."
                        x_min=30
                    fi
                    cron_expr="*/${x_min} * * * *"
                    cron_label="Every ${x_min} minutes"
                    ;;
                "Every X hours")
                    local x_hrs
                    x_hrs=$(prompt_value "Run every how many hours?" "6")
                    if ! [[ "$x_hrs" =~ ^[0-9]+$ ]] || (( x_hrs < 1 || x_hrs > 23 )); then
                        warn "Invalid — defaulting to 6 hours."
                        x_hrs=6
                    fi
                    cron_expr="0 */${x_hrs} * * *"
                    cron_label="Every ${x_hrs} hours"
                    ;;
                "Every X days")
                    local x_days raw_hour2
                    x_days=$(prompt_value "Run every how many days?" "3")
                    if ! [[ "$x_days" =~ ^[0-9]+$ ]] || (( x_days < 1 )); then
                        warn "Invalid — defaulting to 3 days."
                        x_days=3
                    fi
                    raw_hour2=$(prompt_value "Hour to run backup (0-23)" "2")
                    if [[ "$raw_hour2" =~ ^[0-9]+$ ]] && (( raw_hour2 >= 0 && raw_hour2 <= 23 )); then
                        backup_hour="$raw_hour2"
                    fi
                    cron_expr="0 ${backup_hour} */${x_days} * *"
                    cron_label="Every ${x_days} days at $(printf '%02d:00' "$backup_hour")"
                    ;;
            esac
            ;;
    esac

    # Install this script to a stable path for cron.
    # BASH_SOURCE[0] is always the file the shell opened, regardless of invocation style.
    local script_src
    script_src=$(readlink -f "${BASH_SOURCE[0]}")
    if [[ "$script_src" != "$BACKUP_INSTALL_BIN" ]]; then
        info "Installing script to ${BACKUP_INSTALL_BIN} for stable cron reference..."
        cp "$script_src" "$BACKUP_INSTALL_BIN"
        chmod +x "$BACKUP_INSTALL_BIN"
        success "Installed → ${BACKUP_INSTALL_BIN}"
    fi

    cat > "$BACKUP_CRON_FILE" <<EOF
# Kitsu automated backup — managed by install_kitsu.sh
# Schedule: ${cron_label}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${cron_expr} root ${BACKUP_INSTALL_BIN} --backup-run >> /var/log/kitsu-backup.log 2>&1
EOF
    chmod 644 "$BACKUP_CRON_FILE"
    save_backup_config

    echo
    success "Schedule saved: ${cron_label}"
    info  "Cron:    ${cron_expr} → ${BACKUP_INSTALL_BIN} --backup-run"
    info  "Config:  ${BACKUP_CONFIG_FILE}"
    info  "Log:     /var/log/kitsu-backup.log"
    echo
    if prompt_yn "Run a backup now to verify everything works?" "y"; then
        run_backup
    fi
}

# ── Remove schedule ───────────────────────────────────────────────────────────
remove_backup_schedule() {
    header "Remove Backup Schedule"
    if [[ -f "$BACKUP_CRON_FILE" ]]; then
        if prompt_yn "Remove the scheduled backup cron job?" "y"; then
            rm -f "$BACKUP_CRON_FILE"
            success "Cron job removed."
            load_backup_config
            info "Existing backups in ${BACKUP_DIR} are untouched."
        else
            info "No changes made."
        fi
    else
        warn "No scheduled backup found — nothing to remove."
    fi
}

# ── Backup wizard (sub-menu) ──────────────────────────────────────────────────
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
        "Back")                        return ;;
    esac
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    require_root

    # Non-interactive mode invoked by cron
    if [[ "${1:-}" == "--backup-run" ]]; then
        echo "=== Kitsu backup started at $(date) ==="
        load_backup_config
        run_backup
        echo "=== Kitsu backup finished at $(date) ==="
        exit 0
    fi

    header "Kitsu Installer & Backup Manager for Debian"

    if detect_existing; then
        warn "Existing Kitsu installation(s) detected:"
        for item in "${FOUND_ITEMS[@]}"; do
            echo -e "  ${YELLOW}•${NC} $item"
        done
        echo

        local choice
        choice=$(prompt_choice \
            "What would you like to do?" \
            "Update to the latest version" \
            "Repair installation" \
            "Change Super Admin password" \
            "Backup wizard" \
            "Delete and reinstall from scratch" \
            "Delete only (no reinstall)" \
            "Cancel")

        case "$choice" in
            "Update to the latest version")
                update_kitsu
                ;;

            "Repair installation")
                repair_kitsu
                ;;

            "Change Super Admin password")
                change_admin_password
                ;;

            "Backup wizard")
                backup_wizard
                ;;

            "Delete and reinstall from scratch")
                warn "This will DESTROY all existing data (database, previews)."
                if prompt_yn "Are you sure you want to delete all data?" "n"; then
                    prompt_backup_cleanup
                    remove_all_kitsu "true"
                    install_fresh
                else
                    info "Aborted."
                    exit 0
                fi
                ;;

            "Delete only (no reinstall)")
                warn "This will remove all Kitsu containers, services, and directories."
                if prompt_yn "Are you sure?" "n"; then
                    local wipe_data="true"
                    if ! prompt_yn "Also delete database and preview data?" "y"; then
                        wipe_data="false"
                        info "Data volumes will be kept."
                    fi
                    prompt_backup_cleanup
                    remove_all_kitsu "$wipe_data"
                    success "Kitsu has been completely removed."
                else
                    info "Aborted."
                    exit 0
                fi
                ;;

            "Cancel")
                info "No changes made."
                exit 0
                ;;
        esac
    else
        install_fresh
    fi
}

main "$@"