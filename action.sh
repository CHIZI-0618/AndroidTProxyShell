#!/system/bin/sh


# ==============================================================================
# Flux Action Handler (action.sh)
# Description: Entry point for user interactions (toggle, update, etc.)
# ==============================================================================

# Load system configuration
. "/data/adb/Flux/scripts/flux.utils" || {
    echo "ERROR: Cannot load utils"
    exit 1
}

export INTERACTIVE=1
export LOG_COMPONENT="Action"
export TPROXY_INTERNAL_TOKEN="valid_entry_2026"


# ==============================================================================
# [ Update Management ]
# ==============================================================================

# Determine if subscription update is required based on timestamp
is_update_due() {
    [ ! -f "$LAST_UPDATE_FILE" ] && return 0
    
    local last_time
    last_time=$(cat "$LAST_UPDATE_FILE" 2>/dev/null)
    [ -z "$last_time" ] && return 0
    
    local current_time
    current_time=$(date +%s)
    
    [ $((current_time - last_time)) -ge "$UPDATE_INTERVAL" ]
}

# Execute update script with timeout monitoring
execute_update() {
    log_info "Updating subscription..."
    
    local update_pid update_result
    
    sh "$UPDATE_SCRIPT" &
    update_pid=$!
    
    local waited=0
    while [ $waited -lt "$UPDATE_TIMEOUT" ]; do
        if ! kill -0 "$update_pid" 2>/dev/null; then
            wait "$update_pid" 2>/dev/null
            update_result=$?
            
            if [ $update_result -eq 0 ]; then
                log_info "Subscription updated"
                date +%s > "$LAST_UPDATE_FILE"
                return 0
            else
                log_warn "Update failed"
                return 1
            fi
        fi
        
        sleep 1
        waited=$((waited + 1))
    done
    
    kill -9 "$update_pid" 2>/dev/null
    log_warn "Update timeout"
    return 1
}

# Check and execute update if due (called before start)
check_and_update() {
    if is_update_due; then
        execute_update || log_warn "Update failed, using cached config"
    else
        log_debug "Update skipped (within interval)"
    fi
}


# ==============================================================================
# [ Action Handlers ]
# ==============================================================================

do_start() {
    # Check for update before starting
    check_and_update
    
    /system/bin/sh "$START_SCRIPT" start
}

do_stop() {
    /system/bin/sh "$START_SCRIPT" stop
}

do_toggle() {
    if is_core_running; then
        do_stop
    else
        do_start
    fi
}


# ==============================================================================
# [ Main Execution Flow ]
# ==============================================================================

main() {
    load_flux_config
    
    [ ! -f "$START_SCRIPT" ] && {
        echo "ERROR: Script not found at $START_SCRIPT"
        exit 1
    }
    
    [ ! -x "$START_SCRIPT" ] && chmod +x "$START_SCRIPT" 2>/dev/null
    
    local action="${1:-toggle}"
    
    case "$action" in

        toggle)
            do_toggle
            ;;
        *)
            echo "Usage: $0 {start|stop|restart|toggle|update}"
            exit 1
            ;;
    esac
}

main "$@"