#!/system/bin/sh


# ==============================================================================
# TProxyShell Service Manager (start.sh)
# Description: Manages sing-box core lifecycle and TProxy firewall rules
# ==============================================================================

# ------------------------------------------------------------------------------
# [ Load Dependencies ]
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
. "$SCRIPT_DIR/flux.config"
. "$SCRIPT_DIR/flux.logger"
. "$SCRIPT_DIR/flux.core"

# Set log component name for logging function
export LOG_COMPONENT="Manager"


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
    local required_files="$SING_BOX_BIN $CONFIG_FILE $SETTINGS_FILE $TPROXY_SCRIPT $UPDATE_SCRIPT"
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
    
    local executable_files="$SING_BOX_BIN $TPROXY_SCRIPT $UPDATE_SCRIPT"
    
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
# [ TProxy Execution ]
# ==============================================================================

execute_tproxy() {
    local action="$1"
    
    log_debug "TProxy: $action"
    
    [ ! -f "$TPROXY_SCRIPT" ] && {
        log_error "TProxy script missing"
        return 1
    }
    
    sh "$TPROXY_SCRIPT" "$action"
    local ret=$?
    
    if [ $ret -eq 0 ]; then
        log_info "TProxy $action done"
        return 0
    else
        log_error "TProxy $action failed"
        return 1
    fi
}


# ==============================================================================
# [ Concurrent Start/Stop with Rollback ]
# ==============================================================================

start_parallel() {
    log_info "Starting services..."
    
    local core_result=0
    local tproxy_result=0
    local core_pid tproxy_pid
    
    (start_core; exit $?) &
    core_pid=$!
    
    (execute_tproxy "start"; exit $?) &
    tproxy_pid=$!
    
    wait $core_pid
    core_result=$?
    
    wait $tproxy_pid
    tproxy_result=$?
    
    if [ $core_result -ne 0 ] && [ $tproxy_result -ne 0 ]; then
        log_error "All services failed"
        return 1
    elif [ $core_result -ne 0 ]; then
        log_error "Core failed, rollback TProxy"
        execute_tproxy "stop" >/dev/null 2>&1 || true
        return 1
    elif [ $tproxy_result -ne 0 ]; then
        log_error "TProxy failed, rollback Core"
        stop_core >/dev/null 2>&1 || true
        return 1
    fi
    
    log_info "All services started"
    return 0
}

stop_parallel() {
    log_info "Stopping services..."
    
    local core_pid tproxy_pid
    
    (stop_core) &
    core_pid=$!
    
    (execute_tproxy "stop") &
    tproxy_pid=$!
    
    wait $core_pid
    wait $tproxy_pid
    
    log_info "All services stopped"
    return 0
}

force_cleanup() {
    log_debug "Force cleanup..."
    
    (stop_core >/dev/null 2>&1) &
    local core_pid=$!
    
    (execute_tproxy "stop" >/dev/null 2>&1) &
    local tproxy_pid=$!
    
    wait $core_pid 2>/dev/null
    wait $tproxy_pid 2>/dev/null
}


# ==============================================================================
# [ Main Service Operations ]
# ==============================================================================

start_service_sequence() {
    init_environment || return 1
    check_resource_integrity || return 1
    
    
    # Clean any stale state
    force_cleanup
    
    # Validate config (fatal if fails)
    if ! validate_singbox_config; then
        log_error "Config invalid"
        return 1
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
    load_flux_config
    validate_flux_config
    
    trap 'update_description' EXIT
    
    local action="${1:-}"
    local exit_code=0
    
    case "$action" in
        start)
            start_service_sequence || exit_code=1
            ;;
        stop)
            stop_service_sequence || exit_code=1
            ;;
        *)
            echo "Usage: $0 {start|stop}"
            exit_code=1
            ;;
    esac
    
    exit $exit_code
}

main "$@"