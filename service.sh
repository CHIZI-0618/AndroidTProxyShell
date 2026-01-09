#!/system/bin/sh


# ==============================================================================
# ENVIRONMENT SETUP
# ==============================================================================

# Load system configuration
. "/data/adb/Flux/scripts/flux.config"
. "/data/adb/Flux/scripts/flux.logger"

export LOG_COMPONENT="Service"

# ==============================================================================
# BOOT DETECTION UTILITY
# ==============================================================================

# Wait for the Android system to signal boot completion via getprop
wait_for_boot() {
    local boot_wait_count=0
    local MAX_BOOT_WAIT=60
    
    while [ "$boot_wait_count" -lt "$MAX_BOOT_WAIT" ]; do
        # Check property to verify if boot process is finished
        if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
            log_info "System boot completed (waited ${boot_wait_count}s)"
            return 0
        fi
        
        sleep 1
        boot_wait_count=$((boot_wait_count + 1))
    done
    
    log_error "Timeout waiting for boot completion after ${MAX_BOOT_WAIT}s"
    return 1
}

# ==============================================================================
# MAIN EXECUTION FLOW
# ==============================================================================

main() {
    wait_for_boot
   
    sleep 5
    
    [ ! -f "$START_SCRIPT" ] && exit 1
    [ ! -x "$START_SCRIPT" ] && chmod +x "$START_SCRIPT" 2>/dev/null
    
    /system/bin/sh "$START_SCRIPT" start >/dev/null 2>&1 &
}

main