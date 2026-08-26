#!/bin/bash
# Mole - rpm (Fedora/RHEL) uninstall enumeration backend (Linux).
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
# Backend selection (contract §5): enabled when `rpm` and `dnf` both exist
# (MOLE_DISTRO_ID fedora/rhel/centos/rocky/alma or capability-probed); callers
# decide via rpm_backend_available. Exactly one native backend is ever active;
# lib/uninstall/enumerate.sh owns that choice.
#
# All queries run under LC_ALL=C so column labels parse identically on every
# locale. Installed sizes are read from a single `rpm -qa` pass (%{SIZE} is
# whole bytes, truncated to KiB by integer division) and reused for the whole
# batch (the per-batch cache required by the apps contract).
#
# This module NEVER deletes anything: removal goes through
# rpm_backend_remove_plan, whose stdout the caller previews and executes.

if [[ -n "${MOLE_UNINSTALL_BACKEND_RPM_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UNINSTALL_BACKEND_RPM_LOADED=1

# Representative binaries live at <bin-root>/<name>. The root is an env
# override for tests (same pattern as MOLE_OS_RELEASE_FILE), defaulting to
# /usr/bin on real systems.
readonly _MOLE_RPM_BIN_ROOT="${MOLE_UNINSTALL_LINUX_BIN_DIR:-/usr/bin}"

rpm_backend_available() {
    command -v rpm > /dev/null 2>&1 &&
        command -v dnf > /dev/null 2>&1
}

# Package names installed by explicit user request rather than as dependency;
# the rpm-family counterpart of `pacman -Qetq`.
rpm_backend_explicit_packages() {
    rpm_backend_available || return 0
    LC_ALL=C dnf -q repoquery --userinstalled --qf '%{name}\n' 2> /dev/null || return 0
}

# True when an absolute path belongs to any installed package; nonzero when
# unowned.
rpm_backend_owns_path() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    rpm_backend_available || return 1
    local owner=""
    owner=$(LC_ALL=C rpm -qf --queryformat '%{NAME}\n' -- "$path" 2> /dev/null) || return 1
    [[ -n "$owner" ]]
}

rpm_backend_package_installed() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 1
    rpm_backend_available || return 1
    LC_ALL=C rpm -q -- "$pkg" > /dev/null 2>&1
}

# Emit "<name>|<size-kb>" for every installed package from one `rpm -qa` pass.
# The single pass is the per-batch cache: callers enumerate rows once. %{SIZE}
# is whole bytes; conversion truncates to whole KiB (integer division).
_rpm_backend_name_size_pairs() {
    rpm_backend_available || return 0

    local dump
    if ! dump=$(LC_ALL=C rpm -qa --qf '%{NAME}|%{SIZE}\n' 2> /dev/null); then
        return 0
    fi

    local line name size_bytes kb
    while IFS= read -r line; do
        case "$line" in
            *"|"*) ;;
            *) continue ;;
        esac
        name="${line%%|*}"
        size_bytes="${line#*|}"
        [[ "$size_bytes" =~ ^[0-9]+$ ]] || size_bytes="0"
        kb=$((size_bytes / 1024))
        if [[ -n "$name" ]]; then
            printf '%s|%s\n' "$name" "$kb"
        fi
    done <<< "$dump"
}

# Emit one row per explicitly installed package that resolves to an existing
# representative binary at <bin-root>/<name>. Library-only packages without
# such a binary are not uninstallable "apps" and stay out of the selector.
rpm_backend_rows() {
    local pairs_file
    pairs_file=$(mktemp "${TMPDIR:-/tmp}/mole.rpm-pairs.XXXXXX") || return 1

    _rpm_backend_name_size_pairs > "$pairs_file"

    local pkg size_kb target
    while IFS= read -r pkg; do
        target="$_MOLE_RPM_BIN_ROOT/$pkg"
        [[ -e "$target" ]] || continue

        size_kb=$(LC_ALL=C awk -F'|' -v pkg="$pkg" '$1 == pkg { print $2; exit }' "$pairs_file")
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb="0"

        printf 'rpm|%s|%s|%s|%s\n' "$pkg" "$pkg" "$size_kb" "$target"
    done < <(rpm_backend_explicit_packages)

    rm -f "$pairs_file"
}

# Plan line for removing a package. The caller previews this exact string and
# executes it through the existing sudo plumbing; nothing runs here.
rpm_backend_remove_plan() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 1
    printf 'sudo dnf -y remove %s\n' "$pkg"
}
