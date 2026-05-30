#!/usr/bin/env bash
# =============================================================================
# Kitsu Backup & Restore Manager
# Supports: cgwire/cgwire all-in-one Docker container
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
CONFIG_FILE="/opt/kitsu/backup.conf"
CRON_FILE="/etc/cron.d/kitsu-backup"
INSTALL_BIN="/usr/local/bin/kitsu-backup"
DEFAULT_BACKUP_DIR="/opt/kitsu/backups"
DEFAULT_KEEP_VERSIONS=7

# These may be overridden by config
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
KEEP_VERSIONS="$DEFAULT_KEEP_VERSIONS"

# ── Config ────────────────────────────────────────────────────────────────────
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
    BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
    KEEP_VERSIONS="${KEEP_VERSIONS:-$DEFAULT_KEEP_VERSIONS}"
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
BACKUP_DIR="${BACKUP_DIR}"
KEEP_VERSIONS="${KEEP_VERSIONS}"
EOF
    chmod 600 "$CONFIG_FILE"
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

# ── Container check ───────────────────────────────────────────────────────────
require_container() {
    if ! docker inspect "$CONTAINER_NAME" &>/dev/null 2>&1; then
        error "Kitsu container '${CONTAINER_NAME}' not found. Is Kitsu installed?"
        exit 1
    fi
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
    if [[ "$state" != "running" ]]; then
        error "Kitsu container is '${state}', not 'running'. Start it first."
        exit 1
    fi
}

# ── BACKUP ────────────────────────────────────────────────────────────────────
run_backup() {
    load_config
    require_container

    local date_stamp
    date_stamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local backup_path="${BACKUP_DIR}/${date_stamp}"
    mkdir -p "$backup_path"

    header "Creating Kitsu Backup — ${date_stamp}"

    # 1. Database dump
    # zou lives at /opt/zou/env/bin/zou inside the cgwire/cgwire container.
    # Fall back to pg_dump directly if zou is unavailable.
    info "Dumping PostgreSQL database..."
    local dump_dir="/tmp/kitsu-backup-$$"
    local dump_file="${dump_dir}/$(date '+%Y-%m-%d')-zou-db-backup.sql.gz"
    local zou_bin="/opt/zou/env/bin/zou"

    docker exec "$CONTAINER_NAME" sh -c "mkdir -p ${dump_dir}"

    if docker exec "$CONTAINER_NAME" sh -c "test -x ${zou_bin}"; then
        # Primary: zou dump-database
        if ! docker exec "$CONTAINER_NAME" sh -c "cd ${dump_dir} && ${zou_bin} dump-database"; then
            error "zou dump-database failed — check: docker logs ${CONTAINER_NAME}"
            docker exec "$CONTAINER_NAME" sh -c "rm -rf ${dump_dir}" 2>/dev/null || true
            rm -rf "$backup_path"
            exit 1
        fi
    else
        # Fallback: pg_dump directly
        warn "zou not found at ${zou_bin} — falling back to pg_dump."
        if ! docker exec "$CONTAINER_NAME" sh -c \
            "pg_dump -h localhost -U postgres zoudb | gzip > ${dump_file}"; then
            error "pg_dump fallback also failed — check: docker logs ${CONTAINER_NAME}"
            docker exec "$CONTAINER_NAME" sh -c "rm -rf ${dump_dir}" 2>/dev/null || true
            rm -rf "$backup_path"
            exit 1
        fi
    fi

    # Grab the dump file from inside the container
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

    # 2. Preview files (read the named volume via a temporary alpine container)
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

    # 4. Rotate old backups
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

# ── RESTORE ───────────────────────────────────────────────────────────────────
run_restore() {
    load_config
    require_container

    header "Restore Kitsu from Backup"

    # Collect available backups
    local -a backups
    mapfile -t backups < <(ls -dt "${BACKUP_DIR}"/[0-9][0-9][0-9][0-9]-* 2>/dev/null || true)
    if [[ ${#backups[@]} -eq 0 ]]; then
        error "No backups found in ${BACKUP_DIR}."
        exit 1
    fi

    # Build display labels
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

    # Find which index was chosen
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

    # 1. Restore database
    if [[ -f "${chosen_path}/database.sql.gz" ]]; then
        info "Restoring database..."
        docker cp "${chosen_path}/database.sql.gz" "${CONTAINER_NAME}:/tmp/kitsu_restore.sql.gz"
        docker exec "$CONTAINER_NAME" sh -c "
            set -e
            gunzip -f /tmp/kitsu_restore.sql.gz

            # Terminate active connections to zoudb
            psql -h localhost -U postgres -c \
                \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
                  WHERE datname = 'zoudb' AND pid <> pg_backend_pid();\" \
                2>/dev/null || true

            # Drop and recreate clean database
            psql -h localhost -U postgres -c 'DROP DATABASE IF EXISTS zoudb;' 2>/dev/null
            psql -h localhost -U postgres -c 'CREATE DATABASE zoudb;' 2>/dev/null

            # Restore
            psql -h localhost -U postgres -1 -d zoudb -f /tmp/kitsu_restore.sql

            rm -f /tmp/kitsu_restore.sql
        "
        success "Database restored."
    else
        warn "No database dump found in this backup — skipping database restore."
    fi

    # 2. Restore preview files
    if [[ -f "${chosen_path}/previews.tar.gz" ]]; then
        info "Restoring preview files..."
        docker run --rm \
            -v zou-previews:/previews \
            -v "${chosen_path}:/backup:ro" \
            alpine sh -c "rm -rf /previews/* && tar xzf /backup/previews.tar.gz -C /previews"
        success "Preview files restored."
    else
        warn "No previews archive found in this backup — skipping preview restore."
    fi

    # 3. Restart container so Zou reconnects to the restored database
    info "Restarting Kitsu container..."
    docker restart "$CONTAINER_NAME"

    # 4. Wait for service and run migrations
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
    success "Restore complete. Refresh Kitsu in your browser."
    if ! prompt_yn "Open a private/incognito window to avoid stale session issues?" "y"; then
        true
    fi
}

# ── SCHEDULE INFO ─────────────────────────────────────────────────────────────
show_schedule_info() {
    header "Backup Schedule & Status"
    load_config

    # Cron status
    if [[ -f "$CRON_FILE" ]]; then
        success "Scheduled backup is ACTIVE"
        echo
        local cron_entry
        cron_entry=$(grep -v '^#' "$CRON_FILE" 2>/dev/null | grep -v '^$' | grep -v '^[A-Z]' || true)
        local schedule_comment
        schedule_comment=$(grep '# Schedule:' "$CRON_FILE" 2>/dev/null | sed 's/# Schedule: //' || true)
        echo -e "  ${BOLD}Type:${NC}       ${YELLOW}${schedule_comment:-custom}${NC}"
        echo -e "  ${BOLD}Cron expr:${NC}  ${YELLOW}$(echo "$cron_entry" | awk '{print $1,$2,$3,$4,$5}')${NC}"
        echo -e "  ${BOLD}Cron file:${NC}  $CRON_FILE"
        echo -e "  ${BOLD}Log file:${NC}   /var/log/kitsu-backup.log"
    else
        warn "No scheduled backup configured."
    fi

    echo
    echo -e "  ${BOLD}Backup directory:${NC}  ${BACKUP_DIR}"
    echo -e "  ${BOLD}Versions to keep:${NC}  ${KEEP_VERSIONS}"

    # List existing backups
    local -a existing
    mapfile -t existing < <(ls -dt "${BACKUP_DIR}"/[0-9][0-9][0-9][0-9]-* 2>/dev/null || true)
    echo -e "  ${BOLD}Stored backups:${NC}    ${#existing[@]}"

    if (( ${#existing[@]} > 0 )); then
        echo
        echo -e "  ${BOLD}Available backups:${NC}"
        for b in "${existing[@]}"; do
            local size db_size prev_size
            size=$(du -sh "$b" 2>/dev/null | cut -f1)
            db_size="n/a"
            prev_size="n/a"
            [[ -f "$b/database.sql.gz" ]]  && db_size=$(du -sh "$b/database.sql.gz" 2>/dev/null | cut -f1)
            [[ -f "$b/previews.tar.gz" ]]  && prev_size=$(du -sh "$b/previews.tar.gz" 2>/dev/null | cut -f1)
            echo -e "    ${CYAN}$(basename "$b")${NC}  total: ${size}  (db: ${db_size}, previews: ${prev_size})"
        done
    fi
    echo
}

# ── SCHEDULE SETUP ────────────────────────────────────────────────────────────
configure_schedule() {
    header "Configure Backup Schedule"
    load_config

    # Backup directory
    BACKUP_DIR=$(prompt_value "Backup directory" "$BACKUP_DIR")
    mkdir -p "$BACKUP_DIR"

    # Versions to keep
    local keep
    keep=$(prompt_value "How many backup versions to keep" "$KEEP_VERSIONS")
    if [[ "$keep" =~ ^[0-9]+$ ]] && (( keep >= 1 )); then
        KEEP_VERSIONS="$keep"
    else
        warn "Invalid number — using ${DEFAULT_KEEP_VERSIONS}."
        KEEP_VERSIONS="$DEFAULT_KEEP_VERSIONS"
    fi

    # Schedule type
    local sched_type
    sched_type=$(prompt_choice "Backup frequency:" \
        "One time (run now, no recurring schedule)" \
        "Hourly" \
        "Daily" \
        "Weekly (every Sunday)" \
        "Every X days (custom interval)")

    # Hour prompt (not needed for one-time or hourly)
    local backup_hour="2"
    if [[ "$sched_type" != "One time"* && "$sched_type" != "Hourly" ]]; then
        local raw_hour
        raw_hour=$(prompt_value "Hour to run backup (0-23)" "2")
        if [[ "$raw_hour" =~ ^[0-9]+$ ]] && (( raw_hour >= 0 && raw_hour <= 23 )); then
            backup_hour="$raw_hour"
        else
            warn "Invalid hour — defaulting to 02:00."
        fi
    fi

    local cron_expr=""
    case "$sched_type" in
        "One time"*)
            save_config
            info "Running one-time backup..."
            run_backup
            return
            ;;
        "Hourly")
            cron_expr="0 * * * *"
            ;;
        "Daily")
            cron_expr="0 ${backup_hour} * * *"
            ;;
        "Weekly"*)
            cron_expr="0 ${backup_hour} * * 0"
            ;;
        "Every X days"*)
            local x_days
            x_days=$(prompt_value "Run every how many days?" "3")
            if ! [[ "$x_days" =~ ^[0-9]+$ ]] || (( x_days < 1 )); then
                warn "Invalid interval — defaulting to 3 days."
                x_days=3
            fi
            cron_expr="0 ${backup_hour} */${x_days} * *"
            ;;
    esac

    # Install script to a stable path so the cron entry survives moves
    local script_src
    script_src=$(readlink -f "$0")
    if [[ "$script_src" != "$INSTALL_BIN" ]]; then
        info "Installing script to ${INSTALL_BIN} for stable cron reference..."
        cp "$script_src" "$INSTALL_BIN"
        chmod +x "$INSTALL_BIN"
        success "Installed → ${INSTALL_BIN}"
    fi

    # Write cron file
    cat > "$CRON_FILE" <<EOF
# Kitsu automated backup — managed by kitsu_backup.sh
# Schedule: ${sched_type}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${cron_expr} root ${INSTALL_BIN} --run >> /var/log/kitsu-backup.log 2>&1
EOF
    chmod 644 "$CRON_FILE"
    save_config

    echo
    success "Schedule saved: ${sched_type}"
    info  "Cron:    ${cron_expr} → ${INSTALL_BIN} --run"
    info  "Config:  ${CONFIG_FILE}"
    info  "Log:     /var/log/kitsu-backup.log"
    echo
    if prompt_yn "Run a backup now to verify everything works?" "y"; then
        run_backup
    fi
}

# ── REMOVE SCHEDULE ───────────────────────────────────────────────────────────
remove_schedule() {
    header "Remove Backup Schedule"
    if [[ -f "$CRON_FILE" ]]; then
        if prompt_yn "Remove the scheduled backup cron job?" "y"; then
            rm -f "$CRON_FILE"
            success "Cron job removed."
            info "Existing backups in ${BACKUP_DIR} are untouched."
        else
            info "No changes made."
        fi
    else
        warn "No scheduled backup found — nothing to remove."
    fi
}

# ── ROOT CHECK ────────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    require_root

    # Non-interactive mode invoked by cron
    if [[ "${1:-}" == "--run" ]]; then
        echo "=== Kitsu backup started at $(date) ==="
        load_config
        run_backup
        echo "=== Kitsu backup finished at $(date) ==="
        exit 0
    fi

    header "Kitsu Backup Manager"

    local choice
    choice=$(prompt_choice "What would you like to do?" \
        "Create / schedule a backup" \
        "Restore from a backup" \
        "Show backup schedule & info" \
        "Remove backup schedule" \
        "Exit")

    case "$choice" in
        "Create / schedule a backup")  configure_schedule ;;
        "Restore from a backup")       run_restore ;;
        "Show backup schedule & info") show_schedule_info ;;
        "Remove backup schedule")      remove_schedule ;;
        "Exit")                        info "Bye."; exit 0 ;;
    esac
}

main "$@"
