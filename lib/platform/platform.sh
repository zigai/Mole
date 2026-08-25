#!/bin/bash
# Mole - Platform Detection and Path Resolvers
# Detects the operating system, loads the matching platform module, and
# exposes per-platform path resolvers used across Mole.
#
# Sourcing order contract: lib/core/common.sh sources this file AFTER
# base.sh and BEFORE log.sh, because log.sh resolves its readonly log paths
# through mole_state_dir() at source time. This file is also safe to source
# standalone.

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_PLATFORM_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_PLATFORM_LOADED=1

# Resolve this file's directory with parameter expansion only: platform.sh
# can be sourced into minimal-PATH environments during tests.
if [[ "${BASH_SOURCE[0]}" == */* ]]; then
    _MOLE_PLATFORM_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
else
    _MOLE_PLATFORM_DIR="$PWD"
fi

# Resolve the operating system into MOLE_PLATFORM ("darwin" or "linux") and
# load the matching platform module. Anything else is refused loudly.
mole_detect_platform() {
    # Honor an explicitly pinned MOLE_PLATFORM (test seam); detect otherwise.
    local kernel="${MOLE_PLATFORM:-}"
    if [[ -z "$kernel" ]]; then
        kernel="$(uname -s)"
    fi
    case "$kernel" in
        Darwin|darwin)
            export MOLE_PLATFORM="darwin"
            # shellcheck source=platform/darwin.sh
            source "$_MOLE_PLATFORM_DIR/darwin.sh"
            ;;
        Linux|linux)
            export MOLE_PLATFORM="linux"
            # shellcheck source=platform/linux/common.sh
            source "$_MOLE_PLATFORM_DIR/linux/common.sh"
            mole_detect_distro
            ;;
        *)
            echo "mole: unsupported platform" >&2
            exit 1
            ;;
    esac
}

# Parse /etc/os-release (override with MOLE_OS_RELEASE_FILE for tests) into
# MOLE_DISTRO_ID, then load the first matching distro capability module:
# linux/<ID>.sh first, then each word of ID_LIKE in order, else generic.sh.
# Calls distro_init() afterwards when the loaded module defines it.
mole_detect_distro() {
    local os_release="${MOLE_OS_RELEASE_FILE:-/etc/os-release}"
    local distro_id="" id_like=""

    if [[ -r "$os_release" ]]; then
        local line key value
        while IFS= read -r line || [[ -n "$line" ]]; do
            key="${line%%=*}"
            value="${line#*=}"
            # Strip one pair of surrounding double quotes if present.
            if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            case "$key" in
                ID) distro_id="$value" ;;
                ID_LIKE) id_like="$value" ;;
            esac
        done < "$os_release"
    fi
    export MOLE_DISTRO_ID="$distro_id"

    local linux_dir="$_MOLE_PLATFORM_DIR/linux"

    # Distro IDs end up in a file path; only accept sane identifier shapes.
    if [[ -n "$distro_id" && "$distro_id" =~ ^[A-Za-z0-9._-]+$ && -f "$linux_dir/${distro_id}.sh" ]]; then
        # shellcheck source=platform/linux/arch.sh
        source "$linux_dir/${distro_id}.sh"
    else
        local candidate
        for candidate in $id_like; do
            [[ "$candidate" =~ ^[A-Za-z0-9._-]+$ ]] || continue
            if [[ -f "$linux_dir/${candidate}.sh" ]]; then
                # shellcheck source=platform/linux/arch.sh
                source "$linux_dir/${candidate}.sh"
                break
            fi
        done
    fi

    # No capability module matched: fall back to the inert generic subset so
    # unknown distributions still get safe, tool-driven behavior.
    if ! declare -F distro_id > /dev/null 2>&1; then
        if [[ -f "$linux_dir/generic.sh" ]]; then
            # shellcheck source=platform/linux/generic.sh
            source "$linux_dir/generic.sh"
        else
            echo "mole: unsupported Linux distribution '${distro_id:-unknown}'" >&2
            exit 1
        fi
    fi

    if declare -F distro_init > /dev/null 2>&1; then
        distro_init
    fi
}

# Shared roots; identical on darwin and linux. XDG variables are honored on
# both platforms (they are simply usually unset on macOS).
mole_cache_dir() {
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/mole"
}

mole_config_dir() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/mole"
}

mole_detect_platform
