#!/system/bin/sh

# ==============================================================================
# FLUX Installer (customize.sh)
# Description: Advanced Magisk/KernelSU/APatch installer script
# ==============================================================================

SKIPUNZIP=1

# --- Installation Environment Check ---
if [ "$BOOTMODE" != true ]; then
    ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ui_print "! Please install in Magisk/KernelSU/APatch Manager"
    ui_print "! Install from Recovery is NOT supported"
    abort "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# --- Constants & Paths ---
readonly FLUX_DIR="/data/adb/Flux"
readonly CONF_DIR="$FLUX_DIR/conf"
readonly BIN_DIR="$FLUX_DIR/bin"
readonly SCRIPTS_DIR="$FLUX_DIR/scripts"
readonly RUN_DIR="$FLUX_DIR/run"
readonly TOOLS_DIR="$FLUX_DIR/tools"
readonly MODPROP="$MODPATH/module.prop"

# --- UI Helper Functions ---
# Note: ui_print is provided by Magisk/KernelSU/APatch installer
ui_error() { ui_print "! $1"; }
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
    elif [ -n "$MAGISK_VER" ]; then
        ui_print "  > Magisk: $MAGISK_VER ($MAGISK_VER_CODE)"
    else
        ui_print "  > Unknown Environment"
    fi
}

# --- Universal Volume Key Detection ---
# Optimized: uses temp file + grep for reliable detection
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
        
        # Capture volume key events to temp file
        timeout 1 getevent -lc 1 2>&1 | grep KEY_VOLUME > "$TMPDIR/events"
        
        if [ $((now - start_time)) -gt "$timeout_sec" ]; then
            if [ "$default_action" = "true" ]; then
                ui_print "  > Timeout. Default: [Yes/Keep]"
            else
                ui_print "  > Timeout. Default: [No/Reset]"
            fi
            break
        elif grep -q KEY_VOLUMEUP "$TMPDIR/events"; then
            ui_print "  > Selected: [Yes/Keep]"
            default_action="true"
            break
        elif grep -q KEY_VOLUMEDOWN "$TMPDIR/events"; then
            ui_print "  > Selected: [No/Reset]"
            default_action="false"
            break
        fi
    done
    
    # Clear event buffer after detection
    timeout 1 getevent -cl >/dev/null 2>&1
    
    [ "$default_action" = "true" ] && return 0 || return 1
}

# --- Smart Config Restore (Incremental Update) ---
# Merges old settings into new config: existing keys are replaced, missing keys are appended
migrate_settings() {
    local backup_file="$1"
    local target_file="$2"
    
    [ ! -f "$backup_file" ] && return
    
    ui_print "  > Migrating settings (incremental)..."
    
    # List of keys to migrate (user-customizable settings)
    local keys="SUBSCRIPTION_URL UPDATE_INTERVAL PROXY_MODE DNS_HIJACK_ENABLE"
    keys="$keys PROXY_TCP_PORT PROXY_UDP_PORT DNS_PORT ROUTING_MARK"
    keys="$keys PROXY_MOBILE PROXY_WIFI PROXY_HOTSPOT PROXY_USB PROXY_IPV6"
    keys="$keys APP_PROXY_ENABLE APP_PROXY_MODE PROXY_APPS_LIST BYPASS_APPS_LIST"
    keys="$keys BYPASS_CN_IP MAC_FILTER_ENABLE MAC_PROXY_MODE PROXY_MACS_LIST BYPASS_MACS_LIST"
    
    for key in $keys; do
        # Get the full line from backup
        local value_line
        value_line=$(grep "^${key}=" "$backup_file")
        
        if [ -n "$value_line" ]; then
            # Escape special characters for sed (including | as delimiter)
            local esc_value
            esc_value=$(printf '%s\n' "$value_line" | sed -e 's/[&/\|]/\\&/g')
            
            if grep -q "^${key}=" "$target_file"; then
                # Key exists in new config: replace it
                sed -i "s|^${key}=.*|${esc_value}|" "$target_file"
            else
                # Key missing in new config: append it
                echo "$value_line" >> "$target_file"
            fi
            ui_print "     ↳ $key: restored"
        fi
    done
}

# --- Main Installation Logic ---

main() {
    detect_env
    
    # 1. Prepare Temporary Backup (4 config files)
    local TMP_BACKUP
    TMP_BACKUP=$(mktemp -d)
    
    local has_settings=false
    local has_config=false
    local has_pref=false
    local has_singbox=false
    
    if [ -d "$FLUX_DIR" ]; then
        ui_print "- Backing up current configuration..."
        
        if [ -f "$CONF_DIR/settings.ini" ]; then
            cp -f "$CONF_DIR/settings.ini" "$TMP_BACKUP/settings.ini"
            has_settings=true
        fi
        if [ -f "$CONF_DIR/config.json" ]; then
            cp -f "$CONF_DIR/config.json" "$TMP_BACKUP/config.json"
            has_config=true
        fi
        if [ -f "$TOOLS_DIR/pref.toml" ]; then
            cp -f "$TOOLS_DIR/pref.toml" "$TMP_BACKUP/pref.toml"
            has_pref=true
        fi
        if [ -f "$TOOLS_DIR/base/singbox.json" ]; then
            cp -f "$TOOLS_DIR/base/singbox.json" "$TMP_BACKUP/singbox.json"
            has_singbox=true
        fi
    fi
    
    # 2. Extract New Files
    ui_print "- Extracting new module..."
    unzip -o "$ZIPFILE" -x 'META-INF/*' -x 'bin/*' -x 'conf/*' -x 'scripts/*' -x 'tools/*' -d "$MODPATH" >&2
    
    # Create structure (keep run directory as-is)
    mkdir -p "$FLUX_DIR" "$CONF_DIR" "$BIN_DIR" "$SCRIPTS_DIR" "$TOOLS_DIR"
    [ ! -d "$RUN_DIR" ] && mkdir -p "$RUN_DIR"
    
    # Extract Core Files
    unzip -o "$ZIPFILE" "bin/*" "scripts/*" "conf/*" "tools/*" -d "$FLUX_DIR" >&2
    
    # 3. Handle Configuration (each file independently)
    ui_print " "
    ui_print "=== Configuration Restore ==="
    
    # 3.1 settings.ini
    if [ "$has_settings" = "true" ]; then
        if choose_action "Keep [settings.ini]?" "true"; then
            migrate_settings "$TMP_BACKUP/settings.ini" "$CONF_DIR/settings.ini"
            ui_print "  > settings.ini: migrated"
        else
            ui_print "  > settings.ini: reset to default"
        fi
    fi
    
    # 3.2 config.json
    if [ "$has_config" = "true" ]; then
        if choose_action "Keep [config.json]?" "true"; then
            cp -f "$TMP_BACKUP/config.json" "$CONF_DIR/config.json"
            ui_print "  > config.json: restored"
        else
            ui_print "  > config.json: reset to default"
        fi
    fi
    
    # 3.3 pref.toml
    if [ "$has_pref" = "true" ]; then
        if choose_action "Keep [pref.toml]?" "true"; then
            cp -f "$TMP_BACKUP/pref.toml" "$TOOLS_DIR/pref.toml"
            ui_print "  > pref.toml: restored"
        else
            ui_print "  > pref.toml: reset to default"
        fi
    fi
    
    # 3.4 singbox.json
    if [ "$has_singbox" = "true" ]; then
        if choose_action "Keep [singbox.json]?" "true"; then
            mkdir -p "$TOOLS_DIR/base"
            cp -f "$TMP_BACKUP/singbox.json" "$TOOLS_DIR/base/singbox.json"
            ui_print "  > singbox.json: restored"
        else
            ui_print "  > singbox.json: reset to default"
        fi
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

