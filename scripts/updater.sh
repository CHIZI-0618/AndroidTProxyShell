#!/system/bin/sh


# ==============================================================================
# TProxyShell Subscription Updater (updater.sh)
# Description: Downloads, converts, and generates sing-box configuration
# ==============================================================================

# ------------------------------------------------------------------------------
# [ Load Dependencies ]
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
. "$SCRIPT_DIR/flux.config"
. "$SCRIPT_DIR/flux.logger"

# Set log component name
export LOG_COMPONENT="Update"


# ==============================================================================
# [ Country Mapping ]
# ==============================================================================
# Mapping country codes to regex patterns for node filtering
readonly COUNTRY_REGEX_MAP='
{
  "HK": "港|hk|hongkong|🇭🇰",
  "TW": "台|tw|taiwan|🇹🇼",
  "JP": "日本|jp|japan|🇯🇵",
  "SG": "新|sg|singapore|🇸🇬",
  "US": "美|us|united states|🇺🇸",
  "KR": "韩|kr|korea|🇰🇷",
  "UK": "英|uk|united kingdom|🇬🇧",
  "DE": "德|de|germany|🇩🇪",
  "FR": "法|fr|france|🇫🇷",
  "CA": "加|ca|canada|🇨🇦",
  "AU": "澳|au|australia|🇦🇺",
  "RU": "俄|ru|russia|🇷🇺",
  "NL": "荷|nl|netherlands|🇳🇱",
  "IN": "印|in|india|🇮🇳",
  "TR": "土|tr|turkey|🇹🇷",
  "IT": "意|it|italy|🇮🇹",
  "CH": "瑞|ch|switzerland|🇨🇭",
  "SE": "瑞典|se|sweden|🇸🇪",
  "BR": "巴西|br|brazil|🇧🇷",
  "AR": "阿根廷|ar|argentina|🇦🇷",
  "VN": "越|vn|vietnam|🇻🇳",
  "TH": "泰|th|thailand|🇹🇭",
  "PH": "菲|ph|philippines|🇵🇭",
  "MY": "马|my|malaysia|🇲🇾",
  "ID": "印尼|id|indonesia|🇮🇩"
}'


# ==============================================================================
# [ JQ Scripts Logic ]
# ==============================================================================

# 1. Build Filter Regex
readonly JQ_SCRIPT_BUILD_REGEX='
    [ (.outbounds[]? | select(.type=="selector").tag) ] as $template_tags |
    ($map | to_entries | map(select(.key as $country_code | $template_tags | index($country_code))) | map(.value))
    | join("|")
'

# 2. Extract Nodes
readonly JQ_SCRIPT_EXTRACT_NODES='
    (.outbounds // []) |
    map(select(
        .type != "selector" and
        .type != "urltest" and
        .type != "direct" and
        .type != "block" and
        .type != "dns"
    )) |
    map(del(.network)) as $clean_nodes |
    
    if ($pattern | length) > 0 then
        ($clean_nodes | map(select(.tag | test($pattern; "i")))) as $filtered |
        if ($filtered | length) > 0 then $filtered else $clean_nodes end
    else
        $clean_nodes
    end
'

# 3. Generate Config
readonly JQ_SCRIPT_MERGE_CONFIG='
    ($nodes[0] // []) as $valid_nodes |
    
    (.outbounds // []) |= map(
        if (.type == "selector") and ($COUNTRY_REGEX_MAP[.tag] != null) then
            .tag as $group_tag |
            .outbounds = (
                $valid_nodes
                | map(select(.tag | test($COUNTRY_REGEX_MAP[$group_tag]; "i")))
                | map(.tag)
            )
        elif (.tag == "PROXY" or .tag == "GLOBAL" or .tag == "AUTO") and ((.outbounds | length) == 0) then
            .outbounds = ($valid_nodes | map(.tag))
        else
            .
        end
    ) |
    
    .outbounds += $valid_nodes
'


# ==============================================================================
# [ CN IP List Management ]
# ==============================================================================

# Download China IP lists if bypass is enabled and file is outdated
download_cn_ip_list() {
    if [ "$BYPASS_CN_IP" -ne 1 ]; then
        log_debug "CN IP bypass disabled, skipping download"
        return 0
    fi

    log_info "Updating CN IP list..."

    # Download IPv4 list
    if [ ! -f "$CN_IP_FILE" ] || [ "$(find "$CN_IP_FILE" -mtime +7 2> /dev/null)" ]; then
        log_info "Fetching CN IPv4 list..."
        if curl -fsSL --connect-timeout 10 --retry 3 \
            "$CN_IP_URL" \
            -o "$CN_IP_FILE.tmp" 2>/dev/null; then
            mv "$CN_IP_FILE.tmp" "$CN_IP_FILE"
            log_info "CN IPv4 list updated"
        else
            log_warn "CN IPv4 download failed"
            rm -f "$CN_IP_FILE.tmp"
        fi
    else
        log_debug "CN IPv4 list is up to date"
    fi

    # Download IPv6 list if enabled
    if [ "$PROXY_IPV6" -eq 1 ]; then
        if [ ! -f "$CN_IPV6_FILE" ] || [ "$(find "$CN_IPV6_FILE" -mtime +7 2> /dev/null)" ]; then
            log_info "Fetching CN IPv6 list..."
            if curl -fsSL --connect-timeout 10 --retry 3 \
                "$CN_IPV6_URL" \
                -o "$CN_IPV6_FILE.tmp" 2>/dev/null; then
                mv "$CN_IPV6_FILE.tmp" "$CN_IPV6_FILE"
                log_info "CN IPv6 list updated"
            else
                log_warn "CN IPv6 download failed"
                rm -f "$CN_IPV6_FILE.tmp"
            fi
        else
            log_debug "CN IPv6 list is up to date"
        fi
    fi
    
    return 0
}


# ==============================================================================
# [ Cleanup & Utilities ]
# ==============================================================================

# Remove temporary files
cleanup_temp_files() {
    local files="$TMP_SUB_CONVERTED $TMP_NODES_EXTRACTED $GENERATE_FILE"
    for file in $files; do
        [ -f "$file" ] && rm -f "$file" 2>/dev/null
    done
    
    log_debug "Temporary files cleaned up"
}


# ==============================================================================
# [ Validation Functions ]
# ==============================================================================

# Validate required executables and directories
validate_environment() {
    log_info "Validating environment..."
    
    [ ! -d "$TOOLS_DIR" ] && fatal "Tools directory not found: $TOOLS_DIR"
    
    cd "$TOOLS_DIR" || fatal "Cannot change to directory: $TOOLS_DIR"
    
    [ ! -x "./subconverter" ] && [ ! -f "./subconverter" ] && fatal "subconverter executable not found"
    [ ! -x "./jq" ] && [ ! -f "./jq" ] && fatal "jq executable not found"
    [ ! -f "$TEMPLATE_FILE" ] && fatal "Template file not found: $TEMPLATE_FILE"
    
    # Ensure executables have correct permissions
    chmod +x "./subconverter" "./jq" 2>/dev/null || true
    
    # Create run directory if missing
    [ ! -d "$RUN_DIR" ] && mkdir -p "$RUN_DIR"
    
    log_info "Environment validation passed"
}

# Exit with error message and perform cleanup
fatal() {
    log_error "$1"
    cleanup_temp_files
    exit 1
}

# Check if a file exists and is not empty
validate_file() {
    local file="$1"
    local description="$2"
    
    [ ! -f "$file" ] && return 1
    [ ! -s "$file" ] && return 1
    
    return 0
}


# ==============================================================================
# [ Conversion Phase ]
# ==============================================================================

# Convert subscription content to sing-box format using subconverter
download_and_convert_subscription() {
    log_info "Download and converting subscription to sing-box format..."
    
    if [ -z "$SUBSCRIPTION_URL" ]; then
        fatal "SUBSCRIPTION_URL is not set. Please configure it in settings.ini"
    fi
    
    # Create configuration file for subconverter
    cat > "$GENERATE_FILE" <<EOF
[singbox_conversion]
target=singbox
url=$SUBSCRIPTION_URL
path=$TMP_SUB_CONVERTED
EOF
    
    local attempt=0
    local success=0
    
    while [ $attempt -le $RETRY_COUNT ]; do
        if [ $attempt -gt 0 ]; then
            log_warn "Retry attempt $attempt of $RETRY_COUNT..."
            sleep 1
        fi

        if ./subconverter -g >/dev/null 2>&1; then
            success=1
            break
        fi

        attempt=$((attempt + 1))
    done
    
    if [ $success -eq 0 ]; then
        log_error "All attempts failed. Running once more for error output:"
        ./subconverter -g
        rm -f "$GENERATE_FILE"
        fatal "Subconverter failed to download or convert the subscription."
    fi
    
    # Validate conversion result
    if ! validate_file "$TMP_SUB_CONVERTED" "converted JSON"; then
        rm -f "$GENERATE_FILE"
        fatal "Conversion produced empty or invalid output"
    fi
    
    log_info "Conversion successful"
    
    rm -f "$GENERATE_FILE"
}


# ==============================================================================
# [ Node Processing Phase ]
# ==============================================================================

# Build dynamic filter regex based on available template groups
build_filter_regex() {
    ./jq -r --argjson map "$COUNTRY_REGEX_MAP" \
        "$JQ_SCRIPT_BUILD_REGEX" \
        "$TEMPLATE_FILE"
}

# Extract relevant nodes and apply filtering
filter_and_extract_proxies() {
    log_info "Extracting and filtering nodes..."
    
    local filter_regex
    filter_regex=$(build_filter_regex)
    
    if [ -z "$filter_regex" ]; then
        log_info "No country groups detected, retaining all nodes"
    else
        log_info "Applying filter rules: $filter_regex"
    fi
    
    ./jq --arg pattern "$filter_regex" \
        "$JQ_SCRIPT_EXTRACT_NODES" \
        "$TMP_SUB_CONVERTED" > "$TMP_NODES_EXTRACTED"
    
    if ! validate_file "$TMP_NODES_EXTRACTED" "nodes"; then
        fatal "Node extraction produced empty result"
    fi
    
    local count
    count=$(./jq 'length' "$TMP_NODES_EXTRACTED" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && fatal "No valid nodes extracted"
    
    log_info "Successfully extracted and filtered nodes: $count"
}


# ==============================================================================
# [ Configuration Generation Phase ]
# ==============================================================================

# Merge extracted nodes into the template to create final config
merge_nodes_into_template() {
    log_info "Generating final configuration..."
    
    [ -f "$CONFIG_FILE" ] && cp -f "$CONFIG_FILE" "$CONFIG_BACKUP" 2>/dev/null
    
    ./jq --slurpfile nodes "$TMP_NODES_EXTRACTED" \
         --argjson COUNTRY_REGEX_MAP "$COUNTRY_REGEX_MAP" \
         "$JQ_SCRIPT_MERGE_CONFIG" \
         "$TEMPLATE_FILE" > "$CONFIG_FILE"
    
    if [ $? -ne 0 ] || ! validate_file "$CONFIG_FILE" "final config"; then
        if [ -f "$CONFIG_BACKUP" ]; then
            log_warn "Restoring backup configuration..."
            mv -f "$CONFIG_BACKUP" "$CONFIG_FILE"
        fi
        fatal "Configuration generation failed"
    fi
}


# ==============================================================================
# [ Final Verification ]
# ==============================================================================

# Verify the final JSON file is valid and contains nodes
validate_and_report() {
    log_info "Validating configuration..."
    
    local size nodes_count
    size=$(wc -c < "$CONFIG_FILE" 2>/dev/null || echo 0)
    
    [ "$size" -eq 0 ] && fatal "Generated configuration is empty"
    
    # Count nodes in final configuration
    nodes_count=$(./jq '
        [.outbounds[] |
            select(
                .type != "selector" and
                .type != "urltest" and
                .type != "direct" and
                .type != "block" and
                .type != "dns"
            )
        ] | length
    ' "$CONFIG_FILE" 2>/dev/null || echo 0)
    
    [ "$nodes_count" -eq 0 ] && fatal "No nodes found in final configuration"
}


# ==============================================================================
# [ Update Interval Check ]
# ==============================================================================

# Check if enough time has passed since last update
should_update() {
    # If no timestamp file exists, should update
    [ ! -f "$LAST_UPDATE_FILE" ] && return 0
    
    local last_update current_time elapsed
    last_update=$(cat "$LAST_UPDATE_FILE" 2>/dev/null || echo 0)
    current_time=$(date +%s)
    elapsed=$((current_time - last_update))
    
    if [ "$elapsed" -ge "$UPDATE_INTERVAL" ]; then
        log_debug "Update interval exceeded (${elapsed}s >= ${UPDATE_INTERVAL}s)"
        return 0
    else
        local remaining=$((UPDATE_INTERVAL - elapsed))
        log_debug "Update not needed yet (${remaining}s remaining)"
        return 1
    fi
}


# ==============================================================================
# [ Update Execution ]
# ==============================================================================

# Execute the full update pipeline
do_update() {
    log_info "Starting configuration update..."
    
    # Ensure cleanup on exit
    trap cleanup_temp_files EXIT
    
    # Execute update pipeline
    validate_environment

    download_and_convert_subscription
    filter_and_extract_proxies
    merge_nodes_into_template
    validate_and_report
    
    # Download CN IP list if enabled in config
    download_cn_ip_list
    
    # Update timestamp
    date +%s > "$LAST_UPDATE_FILE"
    
    # Cleanup
    cleanup_temp_files
    
    log_info "Update completed"
}


# ==============================================================================
# [ Entry Point ]
# ==============================================================================

main() {
    load_flux_config
    
    local action="${1:-update}"
    
    case "$action" in
        check)
            # Called by start.sh - only update if interval exceeded
            if should_update; then
                log_info "Update interval exceeded, starting update..."
                do_update
            else
                log_info "Skipping update (interval not reached)"
            fi
            ;;
        update|*)
            # Direct execution - force immediate update
            log_info "Forcing immediate update..."
            do_update
            ;;
    esac
    
    exit 0
}

main "$@"