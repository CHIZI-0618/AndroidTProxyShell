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
readonly STATE_DIR="$FLUX_DIR/state"
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
# Supports multi-line values (package lists with newlines inside quotes)
migrate_settings() {
    local backup_file="$1"
    local target_file="$2"
    
    [ ! -f "$backup_file" ] && return
    
    ui_print "  > Migrating settings (incremental)..."
    
    # List of keys to migrate (all user-customizable settings)
    # Subscription
    local keys="SUBSCRIPTION_URL"
    # Logging
    keys="$keys LOG_ENABLE LOG_LEVEL LOG_MAX_SIZE"
    # Timeouts
    keys="$keys CORE_TIMEOUT UPDATE_TIMEOUT RETRY_COUNT UPDATE_INTERVAL"
    # Routing
    keys="$keys ROUTING_MARK"
    # Ports
    keys="$keys PROXY_TCP_PORT PROXY_UDP_PORT DNS_PORT"
    # Proxy Mode
    keys="$keys PROXY_MODE DNS_HIJACK_ENABLE"
    # Network Interfaces
    keys="$keys MOBILE_INTERFACE WIFI_INTERFACE HOTSPOT_INTERFACE USB_INTERFACE"
    # Proxy Scope
    keys="$keys PROXY_MOBILE PROXY_WIFI PROXY_HOTSPOT PROXY_USB PROXY_TCP PROXY_UDP PROXY_IPV6"
    # Per-App Proxy
    keys="$keys APP_PROXY_ENABLE APP_PROXY_MODE PROXY_APPS_LIST BYPASS_APPS_LIST"
    # CN IP Bypass
    keys="$keys BYPASS_CN_IP CN_IP_URL CN_IPV6_URL"
    # MAC Filter
    keys="$keys MAC_FILTER_ENABLE MAC_PROXY_MODE PROXY_MACS_LIST BYPASS_MACS_LIST"
    # Advanced
    keys="$keys SKIP_CHECK_FEATURE"
    
    for key in $keys; do
        # Use awk to extract value (handles multi-line quoted values)
        local value
        value=$(awk -v key="$key" '
            BEGIN { found=0; in_quotes=0; value="" }
            $0 ~ "^"key"=" {
                found=1
                # Get everything after KEY=
                sub("^"key"=", "")
                value = $0
                # Count quotes to detect multi-line
                n = gsub(/"/, "\"", value)
                if (n == 1) {
                    # Opening quote but no closing - multi-line value
                    in_quotes=1
                } else {
                    # Single line value - print and exit
                    print value
                    exit
                }
                next
            }
            found && in_quotes {
                value = value "\n" $0
                # Check for closing quote
                if (/"/) {
                    in_quotes=0
                    print value
                    exit
                }
            }
        ' "$backup_file")
        
        if [ -n "$value" ]; then
            # Create temp file for the replacement
            local tmp_file
            tmp_file=$(mktemp)
            
            # Use awk to replace or append the key in target file
            awk -v key="$key" -v newval="$value" '
                BEGIN { found=0; skip=0 }
                $0 ~ "^"key"=" {
                    found=1
                    print key"="newval
                    # Check if value continues on next lines
                    n = gsub(/"/, "\"", $0)
                    if (n == 1) skip=1
                    next
                }
                skip {
                    if (/"/) skip=0
                    next
                }
                { print }
                END {
                    if (!found) print key"="newval
                }
            ' "$target_file" > "$tmp_file"
            
            mv -f "$tmp_file" "$target_file"
            ui_print "     ↳ $key: restored"
        fi
    done
}

# --- Main Installation Logic ---

main() {
    detect_env
    
    # 1. Backup config files before overwriting
    local TMP_BACKUP
    TMP_BACKUP=$(mktemp -d)
    
    local has_settings=false
    local has_config=false
    local has_pref=false
    local has_singbox=false
    local has_timestamp=false
    
    if [ -d "$FLUX_DIR" ]; then
        ui_print "- Backing up configuration files..."
        
        # Backup settings.ini (will auto-migrate)
        if [ -f "$CONF_DIR/settings.ini" ]; then
            cp -f "$CONF_DIR/settings.ini" "$TMP_BACKUP/settings.ini"
            has_settings=true
        fi
        # Backup config.json (user choice) - with update_timestamp
        if [ -f "$CONF_DIR/config.json" ]; then
            cp -f "$CONF_DIR/config.json" "$TMP_BACKUP/config.json"
            has_config=true
            # Also backup update_timestamp if exists (synced with config.json)
            if [ -f "$STATE_DIR/.last_update" ]; then
                cp -f "$STATE_DIR/.last_update" "$TMP_BACKUP/.last_update"
                has_timestamp=true
            fi
        fi
        # Backup pref.toml (user choice)
        if [ -f "$TOOLS_DIR/pref.toml" ]; then
            cp -f "$TOOLS_DIR/pref.toml" "$TMP_BACKUP/pref.toml"
            has_pref=true
        fi
        # Backup singbox.json template (user choice)
        if [ -f "$TOOLS_DIR/base/singbox.json" ]; then
            cp -f "$TOOLS_DIR/base/singbox.json" "$TMP_BACKUP/singbox.json"
            has_singbox=true
        fi
    fi
    
    # 2. Extract module files to MODPATH (for Magisk)
    # Note: META-INF is handled automatically by Magisk installer, do not extract manually
    ui_print "- Extracting module files..."
    unzip -o "$ZIPFILE" 'module.prop' 'service.sh' 'webroot/*' -d "$MODPATH" >&2
    
    # 3. Clear and recreate FLUX_DIR structure (ensures clean install)
    ui_print "- Installing Flux core files..."
    
    # Remove old directories that will be fully replaced
    rm -rf "$BIN_DIR" "$SCRIPTS_DIR" "$TOOLS_DIR" 2>/dev/null
    
    # Create fresh directory structure
    mkdir -p "$FLUX_DIR" "$CONF_DIR" "$BIN_DIR" "$SCRIPTS_DIR" "$TOOLS_DIR" "$STATE_DIR"
    [ ! -d "$RUN_DIR" ] && mkdir -p "$RUN_DIR"
    
    # Extract core files (bin, scripts, conf, tools) - full overwrite
    unzip -o "$ZIPFILE" 'bin/*' 'scripts/*' 'conf/*' 'tools/*' -d "$FLUX_DIR" >&2
    
    # 4. Handle configuration restoration
    ui_print " "
    ui_print "=== Configuration ==="
    
    # 4.1 settings.ini - Auto migrate (no user confirmation needed)
    if [ "$has_settings" = "true" ]; then
        ui_print "- Migrating settings.ini..."
        migrate_settings "$TMP_BACKUP/settings.ini" "$CONF_DIR/settings.ini"
    else
        ui_print "- Using default settings.ini"
    fi
    
    # 4.2 config.json + .last_update - User choice (synced together)
    if [ "$has_config" = "true" ]; then
        if choose_action "Keep [config.json]?" "true"; then
            cp -f "$TMP_BACKUP/config.json" "$CONF_DIR/config.json"
            # Restore .last_update if it was backed up
            if [ "$has_timestamp" = "true" ]; then
                cp -f "$TMP_BACKUP/.last_update" "$STATE_DIR/.last_update"
            fi
            ui_print "  > config.json: restored"
        else
            # Reset config.json means also delete .last_update
            rm -f "$STATE_DIR/.last_update" 2>/dev/null
            ui_print "  > config.json: reset to default"
        fi
    fi
    
    # 4.3 pref.toml - User choice
    if [ "$has_pref" = "true" ]; then
        if choose_action "Keep [pref.toml]?" "true"; then
            cp -f "$TMP_BACKUP/pref.toml" "$TOOLS_DIR/pref.toml"
            ui_print "  > pref.toml: restored"
        else
            ui_print "  > pref.toml: reset to default"
        fi
    fi
    
    # 4.4 singbox.json - User choice
    if [ "$has_singbox" = "true" ]; then
        if choose_action "Keep [singbox.json]?" "true"; then
            mkdir -p "$TOOLS_DIR/base"
            cp -f "$TMP_BACKUP/singbox.json" "$TOOLS_DIR/base/singbox.json"
            ui_print "  > singbox.json: restored"
        else
            ui_print "  > singbox.json: reset to default"
        fi
    fi
    
    # 5. Set Permissions
    ui_print "- Setting permissions..."
    set_perm_recursive "$MODPATH" 0 0 0755 0644
    set_perm_recursive "$FLUX_DIR" 0 0 0755 0644
    
    # Executables
    set_perm_recursive "$BIN_DIR" 0 0 0755 0755
    set_perm_recursive "$SCRIPTS_DIR" 0 0 0755 0755
    chmod +x "$TOOLS_DIR/jq" 2>/dev/null
    chmod +x "$TOOLS_DIR/subconverter" 2>/dev/null
    
    # RUN_DIR needs write access for runtime files
    chmod 0755 "$RUN_DIR"
    
    # 6. Cleanup
    rm -rf "$TMP_BACKUP"
    rm -rf "$FLUX_DIR/tmp" 2>/dev/null
    
    ui_success "Installation Complete!"
}

main
