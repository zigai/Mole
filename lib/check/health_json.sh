#!/bin/bash
# System Health Check - JSON Generator
# Extracted from tasks.sh

set -euo pipefail

if [[ -n "${MOLE_HEALTH_JSON_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_HEALTH_JSON_LOADED=1

# Ensure dependencies are loaded (only if running standalone)
if [[ -z "${MOLE_FILE_OPS_LOADED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    source "$SCRIPT_DIR/lib/core/file_ops.sh"
fi

_MOLE_HEALTH_JSON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _MOLE_HEALTH_JSON_DIR
source "$_MOLE_HEALTH_JSON_DIR/../optimize/catalog.sh"

# Get memory info in GB from /proc/meminfo. Used memory is total minus
# available (free + reclaimable caches), matching what `free -g` reports.
get_memory_info() {
    local mem_total_kb mem_available_kb used_gb total_gb

    mem_total_kb=$(LC_ALL=C awk '/^MemTotal:/ {print $2}' /proc/meminfo 2> /dev/null || echo "0")
    mem_available_kb=$(LC_ALL=C awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2> /dev/null || echo "0")
    [[ "$mem_total_kb" =~ ^[0-9]+$ ]] || mem_total_kb=0
    [[ "$mem_available_kb" =~ ^[0-9]+$ ]] || mem_available_kb=0
    ((mem_available_kb > mem_total_kb)) && mem_available_kb=$mem_total_kb

    total_gb=$(LC_ALL=C awk "BEGIN {printf \"%.2f\", $mem_total_kb / (1024*1024)}" 2> /dev/null || echo "0")
    used_gb=$(LC_ALL=C awk "BEGIN {printf \"%.2f\", ($mem_total_kb - $mem_available_kb) / (1024*1024)}" 2> /dev/null || echo "0")
    [[ -z "$total_gb" || "$total_gb" == "" ]] && total_gb="0"
    [[ -z "$used_gb" || "$used_gb" == "" ]] && used_gb="0"

    echo "$used_gb $total_gb"
}

# Get disk info
get_disk_info() {
    local home="${HOME:-/}"
    local df_output total_gb used_gb used_percent

    df_output=$(command df -P -k "$home" 2> /dev/null | tail -1)

    local total_kb used_kb
    total_kb=$(echo "$df_output" | LC_ALL=C awk 'NR==1{print $2}' 2> /dev/null)
    used_kb=$(echo "$df_output" | LC_ALL=C awk 'NR==1{print $3}' 2> /dev/null)

    total_kb=${total_kb:-0}
    used_kb=${used_kb:-0}
    [[ "$total_kb" == "0" ]] && total_kb=1 # Avoid division by zero

    total_gb=$(LC_ALL=C awk "BEGIN {printf \"%.2f\", $total_kb / (1024*1024)}" 2> /dev/null || echo "0")
    used_gb=$(LC_ALL=C awk "BEGIN {printf \"%.2f\", $used_kb / (1024*1024)}" 2> /dev/null || echo "0")
    used_percent=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", ($used_kb / $total_kb) * 100}" 2> /dev/null || echo "0")

    [[ -z "$total_gb" || "$total_gb" == "" ]] && total_gb="0"
    [[ -z "$used_gb" || "$used_gb" == "" ]] && used_gb="0"
    [[ -z "$used_percent" || "$used_percent" == "" ]] && used_percent="0"

    echo "$used_gb $total_gb $used_percent"
}

# Get uptime in days from /proc/uptime.
get_uptime_days() {
    local uptime_sec uptime_days
    uptime_sec=$(LC_ALL=C cut -d' ' -f1 /proc/uptime 2> /dev/null || echo "")
    uptime_sec=${uptime_sec%%.*}

    if [[ -n "$uptime_sec" && "$uptime_sec" =~ ^[0-9]+$ ]]; then
        uptime_days=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", $uptime_sec / 86400}" 2> /dev/null || echo "0")
    else
        uptime_days="0"
    fi

    [[ -z "$uptime_days" || "$uptime_days" == "" ]] && uptime_days="0"
    echo "$uptime_days"
}

# JSON escape helper
json_escape() {
    # Escape backslash, double quote, tab, and newline
    local escaped
    escaped=$(echo -n "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr '\n' ' ')
    echo -n "${escaped% }"
}

# Generate JSON output
generate_health_json() {
    # System info
    read -r mem_used mem_total <<< "$(get_memory_info)"
    read -r disk_used disk_total disk_percent <<< "$(get_disk_info)"
    local uptime=$(get_uptime_days)

    # Ensure all values are valid numbers (fallback to 0)
    mem_used=${mem_used:-0}
    mem_total=${mem_total:-0}
    disk_used=${disk_used:-0}
    disk_total=${disk_total:-0}
    disk_percent=${disk_percent:-0}
    uptime=${uptime:-0}

    # Start JSON
    cat << EOF
{
  "memory_used_gb": $mem_used,
  "memory_total_gb": $mem_total,
  "disk_used_gb": $disk_used,
  "disk_total_gb": $disk_total,
  "disk_used_percent": $disk_percent,
  "uptime_days": $uptime,
  "optimizations": [
EOF

    local first=true
    local index action health_name desc safe
    for ((index = 0; index < ${#MOLE_OPTIMIZE_ACTIONS[@]}; index++)); do
        action=${MOLE_OPTIMIZE_ACTIONS[$index]}
        health_name=${MOLE_OPTIMIZE_HEALTH_NAMES[$index]}
        desc=${MOLE_OPTIMIZE_DESCRIPTIONS[$index]}
        safe=${MOLE_OPTIMIZE_SAFE_VALUES[$index]}

        # Escape strings
        action=$(json_escape "$action")
        health_name=$(json_escape "$health_name")
        desc=$(json_escape "$desc")

        [[ "$first" == "true" ]] && first=false || echo ","

        cat << EOF
    {
      "category": "system",
      "name": "$health_name",
      "description": "$desc",
      "action": "$action",
      "safe": $safe
    }
EOF
    done

    # Close JSON
    cat << 'EOF'
  ]
}
EOF
}

# Main execution (for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    generate_health_json
fi
