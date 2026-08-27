#!/bin/bash
# Canonical optimization task metadata and handler ownership.

set -euo pipefail

if [[ -n "${MOLE_OPTIMIZE_CATALOG_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_OPTIMIZE_CATALOG_LOADED=1

# The catalog uses aligned arrays instead of serialized records. This keeps
# field boundaries explicit on Bash 3.2 and lets each consumer read only the
# projection it owns. Every registered task is safe for automatic execution.
MOLE_OPTIMIZE_ACTIONS=()
MOLE_OPTIMIZE_HANDLERS=()
MOLE_OPTIMIZE_HEALTH_NAMES=()
MOLE_OPTIMIZE_WHITELIST_NAMES=()
MOLE_OPTIMIZE_DESCRIPTIONS=()
MOLE_OPTIMIZE_SAFE_VALUES=()

_optimize_catalog_register() {
    local index=${#MOLE_OPTIMIZE_ACTIONS[@]}
    MOLE_OPTIMIZE_ACTIONS[index]="$1"
    MOLE_OPTIMIZE_HANDLERS[index]="$2"
    MOLE_OPTIMIZE_HEALTH_NAMES[index]="$3"
    MOLE_OPTIMIZE_WHITELIST_NAMES[index]="$4"
    MOLE_OPTIMIZE_DESCRIPTIONS[index]="$5"
    MOLE_OPTIMIZE_SAFE_VALUES[index]="$6"
}

# Linux actions back onto the distro capability contract (lib/platform/linux/*).
# Queries answer immediately; plans are previewed and executed by the
# handlers in tasks.sh through the shared dry-run + sudo plumbing.
_optimize_catalog_register pkg_cache_trim opt_pkg_cache_trim \
    "Package Cache Trim" "Package Cache Trim" \
    "Trim package manager cache, keeping recent versions" true
_optimize_catalog_register journal_vacuum opt_journal_vacuum \
    "Journal Vacuum" "Journal Vacuum" \
    "Shrink the systemd journal to 100M / 2 weeks" true
_optimize_catalog_register orphan_packages opt_orphan_packages \
    "Orphaned Packages" "Orphaned Packages" \
    "Report packages orphaned by upgrades and offer their removal" true
_optimize_catalog_register flatpak_unused opt_flatpak_unused \
    "Flatpak Cleanup" "Flatpak Cleanup" \
    "Uninstall unused Flatpak runtimes and extensions" true
_optimize_catalog_register ssd_trim opt_ssd_trim \
    "SSD TRIM" "SSD TRIM" \
    "Discard unused blocks on SSDs via fstrim -av" true
_optimize_catalog_register failed_units_report opt_failed_units_report \
    "Failed Units Report" "Failed Units Report" \
    "List failed systemd units (read-only)" true
_optimize_catalog_register dns_cache_flush opt_dns_cache_flush \
    "DNS Cache Flush" "DNS Cache Flush" \
    "Flush the systemd-resolved DNS cache" true

optimize_catalog_index_for() {
    local requested_action="$1"
    local index
    for ((index = 0; index < ${#MOLE_OPTIMIZE_ACTIONS[@]}; index++)); do
        if [[ "${MOLE_OPTIMIZE_ACTIONS[$index]}" == "$requested_action" ]]; then
            printf '%s\n' "$index"
            return 0
        fi
    done
    return 1
}

optimize_catalog_handler_for() {
    local index
    index=$(optimize_catalog_index_for "$1") || return 1
    printf '%s\n' "${MOLE_OPTIMIZE_HANDLERS[$index]}"
}

optimize_catalog_health_name_for() {
    local index
    index=$(optimize_catalog_index_for "$1") || return 1
    printf '%s\n' "${MOLE_OPTIMIZE_HEALTH_NAMES[$index]}"
}

optimize_catalog_validate() {
    local count=${#MOLE_OPTIMIZE_ACTIONS[@]}
    if [[ $count -eq 0 ]]; then
        echo "Optimize task catalog is empty" >&2
        return 1
    fi
    if [[ ${#MOLE_OPTIMIZE_HANDLERS[@]} -ne $count ||
        ${#MOLE_OPTIMIZE_HEALTH_NAMES[@]} -ne $count ||
        ${#MOLE_OPTIMIZE_WHITELIST_NAMES[@]} -ne $count ||
        ${#MOLE_OPTIMIZE_DESCRIPTIONS[@]} -ne $count ||
        ${#MOLE_OPTIMIZE_SAFE_VALUES[@]} -ne $count ]]; then
        echo "Optimize task catalog fields are misaligned" >&2
        return 1
    fi

    local seen_actions="|"
    local seen_handlers="|"
    local index action handler
    for ((index = 0; index < count; index++)); do
        action=${MOLE_OPTIMIZE_ACTIONS[$index]}
        handler=${MOLE_OPTIMIZE_HANDLERS[$index]}
        if [[ ! "$action" =~ ^[a-z0-9_]+$ || ! "$handler" =~ ^opt_[a-z0-9_]+$ ]]; then
            echo "Invalid optimize task identity: $action|$handler" >&2
            return 1
        fi
        if [[ -z "${MOLE_OPTIMIZE_HEALTH_NAMES[$index]}" ||
            -z "${MOLE_OPTIMIZE_WHITELIST_NAMES[$index]}" ||
            -z "${MOLE_OPTIMIZE_DESCRIPTIONS[$index]}" ]]; then
            echo "Optimize task metadata is incomplete: $action" >&2
            return 1
        fi
        if [[ "${MOLE_OPTIMIZE_SAFE_VALUES[$index]}" != "true" ]]; then
            echo "Optimize task is not safe for automatic execution: $action" >&2
            return 1
        fi
        if [[ "$seen_actions" == *"|$action|"* ]]; then
            echo "Duplicate optimize task action: $action" >&2
            return 1
        fi
        if [[ "$seen_handlers" == *"|$handler|"* ]]; then
            echo "Duplicate optimize task handler: $handler" >&2
            return 1
        fi
        seen_actions+="$action|"
        seen_handlers+="$handler|"
    done
}

optimize_catalog_validate
readonly -a MOLE_OPTIMIZE_ACTIONS
readonly -a MOLE_OPTIMIZE_HANDLERS
readonly -a MOLE_OPTIMIZE_HEALTH_NAMES
readonly -a MOLE_OPTIMIZE_WHITELIST_NAMES
readonly -a MOLE_OPTIMIZE_DESCRIPTIONS
readonly -a MOLE_OPTIMIZE_SAFE_VALUES
unset -f _optimize_catalog_register
