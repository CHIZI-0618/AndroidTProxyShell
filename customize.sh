#!/system/bin/sh

# ==============================================================================
# FLUX Installer (customize.sh)
# Description: Advanced Magisk/KernelSU/APatch installer script
# ==============================================================================

SKIPUNZIP=1

# --- Constants & Paths ---
readonly FLUX_DIR="/data/adb/Flux"
readonly CONF_DIR="$FLUX_DIR/conf"
readonly BIN_DIR="$FLUX_DIR/bin"
readonly SCRIPTS_DIR="$FLUX_DIR/scripts"
readonly RUN_DIR="$FLUX_DIR/run"
readonly TOOLS_DIR="$FLUX_DIR/tools"
readonly MODPROP="$MODPATH/module.prop"

# --- UI Functions ---
ui_print() { echo "$1"; }
ui_error() { ui_print "!!! $1"; }
ui_success() { ui_print "√ $1"; }

# --- Environment Detection ---
detect_env() {
    ui_print "- Detecting environment..."
    
    if [ "$KSU" = "true" ]; then
        ui_print "  > KernelSU: $KSU_KERNEL_VER_CODE (kernel) + $KSU_VER_CODE (manager)"
        sed -i "s/^name=.*/& (KernelSU)/" "$MODPROP" 2>/dev/null
    elif [ "$APATCH" = "true" ]; then
        ui_print "  > APatch: $APATCH_VER_CODE"
        sed -i "s/^name=.*/& (APatch)/" "$MODPROP" 2>/dev/null
    elif [ -z "$MAGISK_VER" ]; then
        ui_print "  > Magisk: $MAGISK_VER ($MAGISK_VER_CODE)"
    else
        ui_print "  > Unknown Environment"
    fi
}

# --- Universal Volume Key Detection ---
# Captures input from any event device to detect Vol+ / Vol-
check_key_event() {
    local key_event="$1"
    case "$key_event" in
        *0073*) return 1 ;; # KEY_VOLUMEUP
        *0072*) return 2 ;; # KEY_VOLUMEDOWN
    esac
    return 0
}

choose_action() {
    local title="$1"
    local default_action="$2" # true = Yes/Keep, false = No/Reset
    local timeout_sec=10
    
    ui_print " "
    ui_print "● $title"
    ui_print "  Vol [+] : Yes / Keep"
    ui_print "  Vol [-] : No / Reset"
    ui_print "  (Timeout: ${timeout_sec}s)"

    local start_time
    start_time=$(date +%s)
    
    while true; do
        local now
        now=$(date +%s)
        if [ $((now - start_time)) -ge "$timeout_sec" ]; then
            if [ "$default_action" = "true" ]; then
                ui_print "  > Timeout. Default: [Yes/Keep]"
                return 0
            else
                ui_print "  > Timeout. Default: [No/Reset]"
                return 1
            fi
        fi

        # Capture hex output from all input devices
        local events
        events=$(timeout 0.1 getevent -luc 1 2>&1)
        
        if echo "$events" | grep -q "0073"; then
            ui_print "  > Selected: [Yes/Keep]"
            return 0
        elif echo "$events" | grep -q "0072"; then
            ui_print "  > Selected: [No/Reset]"
            return 1
        fi
    done
}

# --- Smart Config Restore ---
# $1: Source (Backup), $2: Destination (New Default)
restore_value() {
    local key="$1"
    local source="$2"
    local dest="$3"
    
    local val
    val=$(grep "^${key}=" "$source" | cut -d= -f2-)
    
    if [ -n "$val" ]; then
        # Escape special characters for sed
        # We need to escape /, &, and newlines eventually, but basic config usually simple
        val_escaped=$(echo "$val" | sed 's/[\/&]/\\&/g')
        sed -i "s|^${key}=.*|${key}=${val_escaped}|" "$dest"
    fi
}

migrate_settings() {
    local backup_file="$1"
    local new_file="$2"
    
    [ ! -f "$backup_file" ] && return
    
    ui_print "  > Migrating settings..."
    
    # List of keys to migrate
    local keys="SUBSCRIPTION_URL PROXY_MODE APP_PROXY_MODE PROXY_APPS_LIST BYPASS_CN_IP UPDATE_INTERVAL PROXY_TCP_PORT PROXY_UDP_PORT"
    
    for key in $keys; do
        restore_value "$key" "$backup_file" "$new_file"
    done
}

# --- Main Installation Logic ---

main() {
    detect_env
    
    # 1. Prepare Temporary Backup
    local TMP_BACKUP
    TMP_BACKUP=$(mktemp -d)
    local HAS_BACKUP=false
    
    if [ -d "$FLUX_DIR" ]; then
        ui_print "- Backing up current version..."
        if [ -f "$CONF_DIR/settings.ini" ]; then
            cp -f "$CONF_DIR/settings.ini" "$TMP_BACKUP/settings.ini"
            HAS_BACKUP=true
        fi
        # Backup other custom files if needed
        [ -f "$CONF_DIR/config.json" ] && cp -f "$CONF_DIR/config.json" "$TMP_BACKUP/"
    fi
    
    # 2. Extract New Files
    ui_print "- Extracting new module..."
    unzip -o "$ZIPFILE" -x 'META-INF/*' -x 'bin/*' -x 'conf/*' -x 'scripts/*' -x 'tools/*' -d "$MODPATH" >&2
    
    # Create structure
    mkdir -p "$FLUX_DIR" "$CONF_DIR" "$RUN_DIR" "$BIN_DIR" "$SCRIPTS_DIR" "$TOOLS_DIR"
    
    # Extract Core Files
    unzip -o "$ZIPFILE" "bin/*" "scripts/*" "conf/*" "tools/*" -d "$FLUX_DIR" >&2
    
    # 3. Handle Configuration
    local KEEP_CONFIG=true
    
    if [ "$HAS_BACKUP" = "true" ]; then
        if choose_action "Migrate old configuration?" "true"; then
            KEEP_CONFIG=true
        else
            KEEP_CONFIG=false
        fi
        
        if [ "$KEEP_CONFIG" = "true" ]; then
            migrate_settings "$TMP_BACKUP/settings.ini" "$CONF_DIR/settings.ini"
            # Optional: Start with old config.json or fresh one? Usually fresh is safer unless we migrate it too.
            # Here we only migrate settings.ini as requested for "Smart Restore"
            ui_print "  > Settings migrated."
        else
            ui_print "  > Using default configuration."
        fi
    else
        ui_print "- No previous configuration found. Using defaults."
    fi
    
    # 4. Set Permissions
    ui_print "- Setting permissions..."
    set_perm_recursive "$MODPATH" 0 0 0755 0644
    set_perm_recursive "$FLUX_DIR" 0 0 0755 0644
    set_perm_recursive "$BIN_DIR" 0 0 0755 0755
    set_perm_recursive "$SCRIPTS_DIR" 0 0 0755 0755
    
    chmod +x "$TOOLS_DIR/jq" 2>/dev/null
    chmod +x "$TOOLS_DIR/subconverter" 2>/dev/null
    chmod 0777 "$RUN_DIR"
    
    # 5. Cleanup
    rm -rf "$TMP_BACKUP"
    rm -rf "$FLUX_DIR/tmp" 2>/dev/null
    
    ui_success "Installation Complete!"
}

main

