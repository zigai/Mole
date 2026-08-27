#!/bin/bash
# Mole - Common Functions Library
# Main entry point that loads all core modules

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_COMMON_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_COMMON_LOADED=1

_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load core modules
source "$_MOLE_CORE_DIR/base.sh"
prepare_mole_tmpdir > /dev/null
source "$_MOLE_CORE_DIR/../platform/platform.sh"
source "$_MOLE_CORE_DIR/log.sh"

source "$_MOLE_CORE_DIR/timeout.sh"
source "$_MOLE_CORE_DIR/timeouts.sh"
source "$_MOLE_CORE_DIR/file_ops.sh"
source "$_MOLE_CORE_DIR/help.sh"
source "$_MOLE_CORE_DIR/ui.sh"
source "$_MOLE_CORE_DIR/app_protection.sh"

# Load sudo management if available
if [[ -f "$_MOLE_CORE_DIR/sudo.sh" ]]; then
    source "$_MOLE_CORE_DIR/sudo.sh"
fi

# Normalize a path for comparisons while preserving root.
mole_normalize_path() {
    local path="$1"
    local normalized="${path%/}"
    [[ -n "$normalized" ]] && printf '%s\n' "$normalized" || printf '%s\n' "$path"
}

# Return a stable identity for an existing path. Prefer dev+inode so aliased
# paths on case-insensitive filesystems or symlinks collapse to one identity.
mole_path_identity() {
    local path="$1"
    local normalized
    normalized=$(mole_normalize_path "$path")

    if [[ -e "$normalized" || -L "$normalized" ]]; then
        if command -v stat > /dev/null 2>&1; then
            local fs_id=""
            fs_id=$(stat -L -c '%d:%i' "$normalized" 2> /dev/null || true)
            if [[ "$fs_id" =~ ^[0-9]+:[0-9]+$ ]]; then
                printf 'inode:%s\n' "$fs_id"
                return 0
            fi
        fi
    fi

    printf 'path:%s\n' "$normalized"
}

mole_identity_in_list() {
    local needle="$1"
    shift

    local existing
    for existing in "$@"; do
        [[ "$existing" == "$needle" ]] && return 0
    done
    return 1
}

