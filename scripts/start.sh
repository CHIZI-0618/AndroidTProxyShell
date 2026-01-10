#!/system/bin/sh


# ==============================================================================
# Flux Service Manager (start.sh)
# Description: Parallel orchestrator for Core and TProxy services
#              Manages lifecycle with state files and rollback on failure
# ==============================================================================


# ------------------------------------------------------------------------------
# [ Load Dependencies ]
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
. "$SCRIPT_DIR/flux.config"
. "$SCRIPT_DIR/flux.logger"

# Set log component name
export LOG_COMPONENT="Manager"


# ==============================================================================
# [ File Lock Mechanism ]
# ==============================================================================

# Acquire exclusive lock - blocks until lock is available or timeout
acquire_lock() {
    local count=0
    
    # Ensure state directory exists
    [ ! -d "$STATE_DIR" ] && mkdir -p "$STATE_DIR"
    
    # Check if lock exists and is stale (process died)
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # Wait for lock with timeout
    while [ -f "$LOCK_FILE" ]; do
        [ $count -ge $LOCK_TIMEOUT ] && return 1
        sleep 1
        count=$((count + 1))
    done
    
    # Acquire lock
    echo $$ > "$LOCK_FILE"
    trap 'release_lock' EXIT INT TERM
    return 0
}

# Release lock
release_lock() {
    [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
    trap - EXIT INT TERM
}



# ==============================================================================
# [ Environment & Resource Initialization ]
# ==============================================================================

# Initialize runtime environment and rotate logs
init_environment() {
    if [ ! -d "$RUN_DIR" ]; then
        mkdir -p "$RUN_DIR" || {
            log_error "Init: Cannot create run directory"
            return 1
        }
        chmod 0755 "$RUN_DIR"
    fi
    
    rotate_log || log_debug "Log rotation skipped"
    
    log_info "Environment initialized"
    return 0
}

# Check integrity of required files and permissions
check_resource_integrity() {
    local required_files="$SING_BOX_BIN $CONFIG_FILE $SETTINGS_FILE $TPROXY_SCRIPT"
    local missing_files=""
    
    for file in $required_files; do
        if [ ! -f "$file" ]; then
            missing_files="$missing_files $(basename "$file")"
        fi
    done
    
    if [ -n "$missing_files" ]; then
        log_error "Missing:$missing_files"
        return 1
    fi
    
    local executable_files="$SING_BOX_BIN $TPROXY_SCRIPT"
    
    for file in $executable_files; do
        if [ ! -x "$file" ]; then
            chmod +x "$file" 2>/dev/null
            if [ ! -x "$file" ]; then
                log_error "No exec permission: $(basename "$file")"
                return 1
            fi
            log_debug "Fixed permission: $(basename "$file")"
        fi
    done
    
    log_info "Resource check passed"
    return 0
}


# ==============================================================================
# [ State File Management ]
# ==============================================================================

# Clean old state files before starting
clean_state_files() {
    rm -f "$CORE_READY_FILE" "$TPROXY_READY_FILE" 2>/dev/null
    log_debug "State files cleaned"
}

# Create state file to indicate service is ready
create_core_ready() {
    touch "$CORE_READY_FILE"
    log_debug "Core ready state created"
}

create_tproxy_ready() {
    touch "$TPROXY_READY_FILE"
    log_debug "TProxy ready state created"
}

# Check if services are ready
is_tproxy_active() {
    [ -f "$TPROXY_READY_FILE" ]
}


# ==============================================================================
# [ Parallel Start with Rollback ]
# ==============================================================================

start_parallel() {
    log_info "Starting services in parallel..."
    
    local core_result=0
    local tproxy_result=0
    local core_pid tproxy_pid
    
    # Clean old state files first
    clean_state_files
    
    # Start Core in background subshell
    (
        sh "$SCRIPT_DIR/flux.core" start
        exit $?
    ) &
    core_pid=$!
    
    # Start TProxy in background subshell
    (
        sh "$TPROXY_SCRIPT" start
        exit $?
    ) &
    tproxy_pid=$!
    
    # Wait for both to complete
    wait $core_pid
    core_result=$?
    
    wait $tproxy_pid
    tproxy_result=$?
    
    # Evaluate results and handle rollback
    if [ $core_result -ne 0 ] && [ $tproxy_result -ne 0 ]; then
        log_error "All services failed"
        prop_error
        return 1
    elif [ $core_result -ne 0 ]; then
        log_error "Core failed, rolling back TProxy"
        sh "$TPROXY_SCRIPT" stop >/dev/null 2>&1 || true
        prop_error
        return 1
    elif [ $tproxy_result -ne 0 ]; then
        log_error "TProxy failed, rolling back Core"
        sh "$SCRIPT_DIR/flux.core" stop >/dev/null 2>&1 || true
        prop_error
        return 1
    fi
    
    # Both succeeded - create state files
    create_core_ready
    create_tproxy_ready
    
    log_info "Parallel start complete"
    return 0
}


# ==============================================================================
# [ Parallel Stop ]
# ==============================================================================

stop_parallel() {
    log_info "Stopping services in parallel..."
    
    local core_pid tproxy_pid
    
    # Stop Core in background
    (sh "$SCRIPT_DIR/flux.core" stop) &
    core_pid=$!
    
    # Stop TProxy in background
    (sh "$TPROXY_SCRIPT" stop) &
    tproxy_pid=$!
    
    # Wait for both to complete
    wait $core_pid
    wait $tproxy_pid
    
    # Clean state files
    clean_state_files
    
    log_info "Parallel stop complete"
    return 0
}


# ==============================================================================
# [ Force Cleanup ]
# ==============================================================================

force_cleanup() {
    log_debug "Force cleanup..."
    
    (sh "$SCRIPT_DIR/flux.core" stop >/dev/null 2>&1) &
    local core_pid=$!
    
    (sh "$TPROXY_SCRIPT" stop >/dev/null 2>&1) &
    local tproxy_pid=$!
    
    wait $core_pid 2>/dev/null
    wait $tproxy_pid 2>/dev/null
    
    clean_state_files
}


# ==============================================================================
# [ Main Service Operations ]
# ==============================================================================

start_service_sequence() {
    init_environment || return 1
    check_resource_integrity || return 1
    
    # Clean any stale state
    force_cleanup
    
    # Check for subscription updates (interval-based)
    if [ -f "$UPDATE_SCRIPT" ]; then
        log_debug "Checking for subscription updates..."
        sh "$UPDATE_SCRIPT" check || log_debug "Update check completed"
    fi
    
    # Parallel start with rollback
    if ! start_parallel; then
        return 1
    fi
    
    log_info "Service ready"
    prop_run
    return 0
}

stop_service_sequence() {
    stop_parallel
    
    log_info "Service stopped"
    prop_stop
    return 0
}


# ==============================================================================
# [ Entry Point ]
# ==============================================================================

main() {
    local action="${1:-}"
    
    # Validate action first
    case "$action" in
        start|stop) ;;
        *)
            echo "Usage: $0 {start|stop}"
            exit 1
            ;;
    esac
    
    # Acquire lock to prevent concurrent operations
    if ! acquire_lock; then
        log_error "Another operation is in progress, please wait"
        exit 1
    fi
    
    # Load and validate configuration
    load_flux_config
    validate_flux_config || {
        log_error "Configuration validation failed"
        release_lock
        exit 1
    }
    
    trap 'update_description; release_lock' EXIT
    
    local exit_code=0
    
    case "$action" in
        start)
            start_service_sequence || exit_code=1
            ;;
        stop)
            stop_service_sequence || exit_code=1
            ;;
    esac
    
    exit $exit_code
}

main "$@"
