#!/bin/bash
# Mole - deb (Debian/Ubuntu) uninstall enumeration backend (Linux).
#
# Row format (INTERNAL to lib/uninstall/backends/*, documented here because the
# merge glue in lib/uninstall/enumerate.sh consumes it verbatim):
#
#     <backend>|<id>|<display-name>|<size-kb>|<target-path>
#
#   backend      : "pacman" | "deb" | "rpm" | "flatpak" | "desktop"
#   id           : package name / flatpak app id / desktop-entry id
#   display-name : human name shown in the selector
#   size-kb      : installed size in KiB, "0" when unknown
#   target-path  : existing representative path on disk
#
# Backend selection (contract §5): enabled when `dpkg-query` and `apt-mark`
# both exist (MOLE_DISTRO_ID debian/ubuntu/mint/pop or capability-probed);
# callers decide via deb_backend_available. Exactly one native backend is ever
# active; lib/uninstall/enumerate.sh owns that choice.
#
# All queries run under LC_ALL=C so column labels parse identically on every
# locale. Installed sizes are read from a single `dpkg-query -W` pass
# (Installed-Size is already whole KiB) and reused for the whole batch (the
# per-batch cache required by the apps contract).
#
# This module NEVER deletes anything: removal goes through
# deb_backend_remove_plan, whose stdout the caller previews and executes.

if [[ -n "${MOLE_UNINSTALL_BACKEND_DEB_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UNINSTALL_BACKEND_DEB_LOADED=1

# Representative binaries live at <bin-root>/<name>. The root is an env
# override for tests (same pattern as MOLE_OS_RELEASE_FILE), defaulting to
# /usr/bin on real systems.
readonly _MOLE_DEB_BIN_ROOT="${MOLE_UNINSTALL_LINUX_BIN_DIR:-/usr/bin}"

deb_backend_available() {
    command -v dpkg-query > /dev/null 2>&1 &&
        command -v apt-mark > /dev/null 2>&1
}

# Package names that were explicitly requested (apt-mark's manual list); the
# deb counterpart of `pacman -Qetq`.
deb_backend_explicit_packages() {
    deb_backend_available || return 0
    LC_ALL=C apt-mark showmanual 2> /dev/null || return 0
}

# True when an absolute path belongs to any installed package; nonzero when
# unowned. dpkg-query -S reads the same database as `dpkg -S` without taking
# the dpkg lock.
deb_backend_owns_path() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    deb_backend_available || return 1
    local owners=""
    owners=$(LC_ALL=C dpkg-query -S -- "$path" 2> /dev/null) || return 1
    [[ -n "$owners" ]]
}

# True when the package is installed right now (Status ends in "installed";
# residual config-files states do not count).
deb_backend_package_installed() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 1
    deb_backend_available || return 1
    local status=""
    status=$(LC_ALL=C dpkg-query -W -f='${Status}' -- "$pkg" 2> /dev/null) || return 1
    [[ "$status" == *"installed" ]]
}

# Emit "<name>|<size-kb>" for every installed package from one `dpkg-query -W`
# pass. The single pass is the per-batch cache: callers enumerate rows once.
# Multi-arch qualified names (libc6:amd64) collapse onto the bare package name
# so apt-mark's manual list matches.
_deb_backend_name_size_pairs() {
    deb_backend_available || return 0

    local dump
    if ! dump=$(LC_ALL=C dpkg-query -W -f='${binary:Package}|${Installed-Size}\n' 2> /dev/null); then
        return 0
    fi

    local line name kb
    while IFS= read -r line; do
        case "$line" in
            *"|"*) ;;
            *) continue ;;
        esac
        name="${line%%|*}"
        kb="${line#*|}"
        name="${name%%:*}"
        [[ "$kb" =~ ^[0-9]+$ ]] || kb="0"
        if [[ -n "$name" ]]; then
            printf '%s|%s\n' "$name" "$kb"
        fi
    done <<< "$dump"
}

# Emit one row per manually installed package that resolves to an existing
# representative binary at <bin-root>/<name>. Library-only packages without
# such a binary are not uninstallable "apps" and stay out of the selector.
deb_backend_rows() {
    local pairs_file
    pairs_file=$(mktemp "${TMPDIR:-/tmp}/mole.deb-pairs.XXXXXX") || return 1

    _deb_backend_name_size_pairs > "$pairs_file"

    local pkg size_kb target
    while IFS= read -r pkg; do
        target="$_MOLE_DEB_BIN_ROOT/$pkg"
        [[ -e "$target" ]] || continue

        size_kb=$(LC_ALL=C awk -F'|' -v pkg="$pkg" '$1 == pkg { print $2; exit }' "$pairs_file")
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb="0"

        printf 'deb|%s|%s|%s|%s\n' "$pkg" "$pkg" "$size_kb" "$target"
    done < <(deb_backend_explicit_packages)

    rm -f "$pairs_file"
}

# Plan line for removing a package. The caller previews this exact string and
# executes it through the existing sudo plumbing; nothing runs here.
deb_backend_remove_plan() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 1
    printf 'sudo apt-get -y remove %s\n' "$pkg"
}
