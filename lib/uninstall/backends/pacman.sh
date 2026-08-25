#!/bin/bash
# Mole - pacman uninstall enumeration backend (Linux).
#
# Row format (INTERNAL to lib/uninstall/backends/*, documented here because the
# merge glue in lib/uninstall/enumerate.sh consumes it verbatim):
#
#     <backend>|<id>|<display-name>|<size-kb>|<target-path>
#
#   backend      : "pacman" | "flatpak" | "desktop"
#   id           : package name / flatpak app id / desktop-entry id
#   display-name : human name shown in the selector
#   size-kb      : installed size in KiB, "0" when unknown
#   target-path  : existing representative path on disk
#
# Backend selection (contract §5): enabled when `pacman` exists (MOLE_DISTRO_ID
# arch or arch-like); callers decide via pacman_backend_available.
#
# All queries run under LC_ALL=C so column labels parse identically on every
# locale. Installed sizes are read from a single `pacman -Qi` pass and reused
# for the whole batch (the per-batch cache required by the apps contract).
#
# This module NEVER deletes anything: removal goes through
# pacman_backend_remove_plan, whose stdout the caller previews and executes.

if [[ -n "${MOLE_UNINSTALL_BACKEND_PACMAN_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UNINSTALL_BACKEND_PACMAN_LOADED=1

# Representative binaries live at <bin-root>/<name>. The root is an env
# override for tests (same pattern as MOLE_OS_RELEASE_FILE), defaulting to
# /usr/bin on real systems.
readonly _MOLE_PACMAN_BIN_ROOT="${MOLE_UNINSTALL_LINUX_BIN_DIR:-/usr/bin}"

pacman_backend_available() {
    command -v pacman > /dev/null 2>&1
}

# Package names that are explicitly installed and not required by others.
pacman_backend_explicit_packages() {
    pacman_backend_available || return 0
    LC_ALL=C pacman -Qetq 2> /dev/null || return 0
}

# Every installed package name (explicit or dependency).
pacman_backend_all_packages() {
    pacman_backend_available || return 0
    LC_ALL=C pacman -Qq 2> /dev/null || return 0
}

# Echo the owning package names for an absolute path; nonzero when unowned.
pacman_backend_owns_path() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    pacman_backend_available || return 1
    local owners=""
    owners=$(LC_ALL=C pacman -Qoq -- "$path" 2> /dev/null) || return 1
    [[ -n "$owners" ]]
}

pacman_backend_package_installed() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 1
    pacman_backend_available || return 1
    LC_ALL=C pacman -Qq -- "$pkg" > /dev/null 2>&1
}

# Convert a human "Installed Size" token pair into whole KiB.
# Args: <value> <unit>; unit in {B, KiB, MiB, GiB}.
_pacman_backend_size_to_kb() {
    local value="$1"
    local unit="$2"
    case "$unit" in
        B) LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", v / 1024 }' ;;
        KiB | KB) LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", v }' ;;
        MiB | MB) LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", v * 1024 }' ;;
        GiB | GB) LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", v * 1048576 }' ;;
        *) echo "0" ;;
    esac
}

# Emit "<name>|<size-kb>" for every installed package from one `pacman -Qi`
# pass. The single pass is the per-batch cache: callers enumerate rows once.
_pacman_backend_name_size_pairs() {
    pacman_backend_available || return 0

    local dump
    if ! dump=$(LC_ALL=C pacman -Qi 2> /dev/null); then
        return 0
    fi

    local line name="" value="" unit="" kb
    while IFS= read -r line; do
        case "$line" in
            Name*:*)
                name="${line#Name*:*}"
                name="${name#"${name%%[![:space:]]*}"}"
                name="${name%"${name##*[![:space:]]}"}"
                ;;
            *"Installed Size"*:*)
                value="${line#*:}"
                # shellcheck disable=SC2086  # split value/unit deliberately
                set -- $value
                value="${1:-}"
                unit="${2:-}"
                kb="0"
                if [[ -n "$value" ]]; then
                    kb=$(_pacman_backend_size_to_kb "$value" "$unit")
                fi
                if [[ -n "$name" ]]; then
                    printf '%s|%s\n' "$name" "${kb:-0}"
                fi
                name=""
                ;;
        esac
    done <<< "$dump"
}

# Emit one row per explicitly installed, non-dependency package that resolves
# to an existing representative binary at /usr/bin/<name>. Library-only
# packages without such a binary are not uninstallable "apps" and stay out of
# the selector.
pacman_backend_rows() {
    local pairs_file
    pairs_file=$(mktemp "${TMPDIR:-/tmp}/mole.pacman-pairs.XXXXXX") || return 1

    _pacman_backend_name_size_pairs > "$pairs_file"

    local pkg size_kb target
    while IFS= read -r pkg; do
        target="$_MOLE_PACMAN_BIN_ROOT/$pkg"
        [[ -e "$target" ]] || continue

        size_kb=$(LC_ALL=C awk -F'|' -v pkg="$pkg" '$1 == pkg { print $2; exit }' "$pairs_file")
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb="0"

        printf 'pacman|%s|%s|%s|%s\n' "$pkg" "$pkg" "$size_kb" "$target"
    done < <(pacman_backend_explicit_packages)

    rm -f "$pairs_file"
}

# Plan line for removing a package. The caller previews this exact string and
# executes it through the existing sudo plumbing; nothing runs here.
pacman_backend_remove_plan() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 1
    printf 'sudo pacman -Rns --noconfirm %s\n' "$pkg"
}
