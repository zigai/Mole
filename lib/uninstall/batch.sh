#!/bin/bash

set -euo pipefail

# Ensure common.sh is loaded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -z "${MOLE_COMMON_LOADED:-}" ]] && source "$SCRIPT_DIR/lib/core/common.sh"

# Linux batch executor. Owns preview, confirmation, and per-channel execution
# (pacman/deb/rpm/flatpak/desktop) for every selected row.
# shellcheck source=lib/uninstall/linux_batch.sh
source "$SCRIPT_DIR/lib/uninstall/linux_batch.sh"

# Emit a preview path annotated with its on-disk size. Propagates timeout and
# interrupt signals from the size probe so a destructive caller cannot ignore
# Ctrl-C.
format_uninstall_preview_path() {
    local path="$1"
    # Replacement must come from a variable: bash 5.3+ tilde-expands a literal
    # unquoted ~ in the patsub replacement, turning this into a no-op.
    local tilde='~'
    local display_path="${path/#$HOME/$tilde}"
    local size_kb="0"
    local size_rc=0
    size_kb=$(get_path_size_kb "$path" 2> /dev/null) || size_rc=$?
    [[ $size_rc -eq 124 || $size_rc -ge 128 ]] && return "$size_rc"
    [[ $size_rc -eq 0 ]] || size_kb="0"

    if [[ "$size_kb" =~ ^[0-9]+$ && "$size_kb" -gt 0 ]]; then
        printf '%s %s, %s%s' "$display_path" "$GRAY" "$(bytes_to_human "$((size_kb * 1024))")" "$NC"
    else
        printf '%s' "$display_path"
    fi
}

# Batch uninstall with a single confirmation. Delegates to the Linux executor
# and folds its freed-size report into the session total.
batch_uninstall_applications() {
    batch_uninstall_applications_linux
    local _linux_rc=$?
    total_size_cleaned=$((total_size_cleaned + LINUX_BATCH_SIZE_FREED_KB))
    return "$_linux_rc"
}
