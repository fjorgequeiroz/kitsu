#!/usr/bin/env bash
# =============================================================================
# Kitsu Installation Script for Ubuntu
# Based on: https://kitsu.cg-wire.com/installation/
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
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

# ── Defaults ─────────────────────────────────────────────────────────────────
CONTAINER_NAME="cgwire"
COMPOSE_PROJECT_DIR="/opt/kitsu"
DEFAULT_HTTP_PORT=80
HTTP_PORT=$DEFAULT_HTTP_PORT

# ── Root check ───────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi
}

# ── Detect existing installation ─────────────────────────────────────────────
FOUND_ITEMS=()

detect_existing() {
    FOUND_ITEMS=()

    # Docker containers by well-known names
    if command -v docker &>/dev/null; then
        for cname in cgwire kitsu zou zou-app zou-event; do
            if docker inspect "$cname" &>/dev/null 2>&1; then
                local state
                state=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null)
                FOUND_ITEMS+=("Docker container '$cname' ($state)")
            fi
        done

        # Any container whose image references cgwire/kitsu/zou (catches renamed containers)
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

    # Docker Compose project directories
    for dir in /opt/kitsu /opt/cgwire "$HOME/kitsu" "$HOME/cgwire"; do
        if [[ -f "$dir/docker-compose.yml" ]] || [[ -f "$dir/docker-compose.yaml" ]]; then
            FOUND_ITEMS+=("Docker Compose project at $dir")
        fi
    done

    # Systemd services (bare-metal install)
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

    # Bare-metal installation directories
    for dir in /opt/zou /opt/kitsu /var/www/kitsu; do
        if [[ -d "$dir" ]]; then
            FOUND_ITEMS+=("Installation directory $dir")
        fi
    done

    # Python package 'zou' in common virtualenvs and system pip
    for pip_bin in pip3 /opt/zou/env/bin/pip /opt/kitsu/env/bin/pip; do
        if command -v "$pip_bin" &>/dev/null 2>&1; then
            local ver
            ver=$("$pip_bin" show zou 2>/dev/null | grep -i '^Version' | awk '{print $2}')
            if [[ -n "$ver" ]]; then
                FOUND_ITEMS+=("Python package 'zou' v${ver} ($pip_bin)")
            fi
        fi
    done

    # Port 5000 listener (Zou API — bare-metal)
    if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ':5000 '; then
        local proc
        proc=$(ss -tlnp 2>/dev/null | awk '/:5000 /{print $NF}' | head -1)
        FOUND_ITEMS+=("Port 5000 in use — Zou API likely running ($proc)")
    fi

    [[ ${#FOUND_ITEMS[@]} -gt 0 ]]
}

# ── Package presence check & install ─────────────────────────────────────────
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
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin -qq
    systemctl enable --now docker
    success "Docker installed."
}

# ── Prompt helpers ────────────────────────────────────────────────────────────
# All prompts write labels to /dev/tty and read from /dev/tty so they work
# correctly when the function is called inside $() which captures stdout.
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
    if [[ -z "$http_port" ]]; then
        for env_file in "$COMPOSE_PROJECT_DIR/.env" /opt/kitsu/.env /opt/zou/.env; do
            if [[ -f "$env_file" ]]; then
                http_port=$(grep '^HTTP_PORT=' "$env_file" 2>/dev/null | cut -d'=' -f2 || true)
                [[ -n "$http_port" ]] && break
            fi
        done
    fi

    local ports=(5000 5001)
    [[ -n "$http_port" && "$http_port" != "5000" && "$http_port" != "5001" ]] \
        && ports+=("$http_port")

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
            /etc/nginx/sites-enabled/kitsu
            /etc/nginx/sites-enabled/kitsu.conf
            /etc/nginx/sites-enabled/cgwire
            /etc/nginx/sites-enabled/cgwire.conf
            /etc/nginx/sites-enabled/zou
            /etc/nginx/sites-enabled/zou.conf
            /etc/nginx/sites-available/kitsu
            /etc/nginx/sites-available/kitsu.conf
            /etc/nginx/sites-available/cgwire
            /etc/nginx/sites-available/cgwire.conf
            /etc/nginx/sites-available/zou
            /etc/nginx/sites-available/zou.conf
            /etc/nginx/conf.d/kitsu.conf
            /etc/nginx/conf.d/cgwire.conf
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

# ── Update (pull latest image, restart) ──────────────────────────────────────
update_kitsu() {
    header "Updating Kitsu"
    info "Pulling latest cgwire/cgwire image..."
    docker pull cgwire/cgwire
    info "Restarting container with new image..."
    remove_all_kitsu "false"
    if [[ -f "$COMPOSE_PROJECT_DIR/.env" ]]; then
        # shellcheck source=/dev/null
        source "$COMPOSE_PROJECT_DIR/.env"
        HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"
    else
        HTTP_PORT="$DEFAULT_HTTP_PORT"
    fi
    start_container
    success "Kitsu updated and restarted."
    show_summary
}

# ── Repair existing installation ─────────────────────────────────────────────
repair_kitsu() {
    header "Repairing Kitsu"

    # Load the saved HTTP port; fall back to default if env file is missing
    if [[ -f "$COMPOSE_PROJECT_DIR/.env" ]]; then
        # shellcheck source=/dev/null
        source "$COMPOSE_PROJECT_DIR/.env"
    fi
    HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"

    local needs_recreate=false

    if ! docker inspect "$CONTAINER_NAME" &>/dev/null 2>&1; then
        warn "Container '$CONTAINER_NAME' not found — will recreate it (volumes are kept)."
        needs_recreate=true
    else
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
        info "Container state: ${state}"

        # Check required port mappings
        local port_bindings
        port_bindings=$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER_NAME" 2>/dev/null)
        local missing_ports=()
        # Port 8012 (event stream) is only exposed as a separate host port when the
        # HTTP port is different; when HTTP_PORT=8012 nginx handles it on the same port.
        if [[ "${HTTP_PORT}" != "8012" ]]; then
            echo "$port_bindings" | grep -q '"8012/tcp"' || missing_ports+=("8012")
        fi

        if [[ ${#missing_ports[@]} -gt 0 ]]; then
            warn "Container is missing port mapping(s): ${missing_ports[*]} — recreating."
            needs_recreate=true
        elif [[ "$state" == "running" ]]; then
            info "Container is running and port mappings look correct."
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
        # Container is already running; just run DB migrations and verify
        info "Running database upgrade..."
        docker exec "$CONTAINER_NAME" sh -c "zou upgrade-db" 2>/dev/null \
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

# ── Write env file ────────────────────────────────────────────────────────────
write_env_file() {
    mkdir -p "$COMPOSE_PROJECT_DIR"
    cat > "$COMPOSE_PROJECT_DIR/.env" <<EOF
HTTP_PORT=${HTTP_PORT}
EOF
    chmod 600 "$COMPOSE_PROJECT_DIR/.env"
}

# ── Port availability ─────────────────────────────────────────────────────────
prompt_port() {
    local port="$DEFAULT_HTTP_PORT"
    while true; do
        port=$(prompt_value "HTTP port" "$port")
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            warn "Invalid port number — please enter a value between 1 and 65535." >/dev/tty
            continue
        fi
        if [[ "$port" == "8012" ]]; then
            warn "Port 8012 is reserved for the Kitsu event stream (Socket.IO)." >/dev/tty
            warn "Please choose a different port." >/dev/tty
            continue
        fi
        local occupied
        occupied=$(ss -tlnp 2>/dev/null | awk -v p=":${port} " '$0 ~ p {print; exit}')
        if [[ -n "$occupied" ]]; then
            warn "Port ${port} is already in use: ${occupied}" >/dev/tty
            warn "Please choose a different port." >/dev/tty
        else
            break
        fi
    done
    printf '%s' "$port"
}

# ── Start container ───────────────────────────────────────────────────────────
start_container() {
    local occupied
    occupied=$(ss -tlnp 2>/dev/null | awk -v p=":${HTTP_PORT} " '$0 ~ p {print; exit}')
    if [[ -n "$occupied" ]]; then
        error "Port ${HTTP_PORT} is already in use and cannot be bound:"
        error "  ${occupied}"
        error "Stop the service using that port, or re-run the script and choose a different port."
        exit 1
    fi

    for vol in zou-db zou-previews; do
        if docker volume inspect "$vol" &>/dev/null 2>&1; then
            warn "Volume '$vol' still exists and will be reused (old data preserved)."
            warn "To start completely fresh, run: docker volume rm $vol"
        fi
    done

    info "Starting Kitsu container on port ${HTTP_PORT}..."
    # Port 8012 is the internal event stream (Socket.IO).
    # Only expose it separately when the main HTTP port is different;
    # if HTTP_PORT is already 8012, nginx handles the same port and
    # adding a duplicate host-port mapping would make Docker refuse to start.
    local event_port_arg=""
    [[ "$HTTP_PORT" != "8012" ]] && event_port_arg="-p 8012:8012"

    # shellcheck disable=SC2086
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart always \
        -p "${HTTP_PORT}:80" \
        ${event_port_arg} \
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
install_fresh() {
    header "Fresh Kitsu Installation"

    echo -e "${BOLD}Configure your Kitsu instance${NC} (press Enter to accept default)\n"

    HTTP_PORT=$(prompt_port)

    echo
    info "Port: ${YELLOW}${HTTP_PORT}${NC}"
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

    local port_suffix=""
    if [[ "$HTTP_PORT" != "80" ]]; then
        port_suffix=":${HTTP_PORT}"
    fi

    header "Kitsu is Ready"
    echo -e "  ${BOLD}URL:${NC}      ${GREEN}http://${ip}${port_suffix}${NC}"
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
    echo -e "    Upgrade DB:  docker exec -ti ${CONTAINER_NAME} sh -c \"zou upgrade-db\""
    echo
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    require_root

    header "Kitsu Installer for Ubuntu"

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

            "Delete and reinstall from scratch")
                warn "This will DESTROY all existing data (database, previews)."
                if prompt_yn "Are you sure you want to delete all data?" "n"; then
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
