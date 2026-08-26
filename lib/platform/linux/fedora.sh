#!/bin/bash
# Mole - Fedora / RHEL-family Capability Module
# Implements the distro capability contract from lib/platform/platform.sh:
# query functions echo results and never prompt or mutate; plan functions
# echo one command per line for the caller to preview, confirm, and execute
# through the existing sudo + dry-run plumbing. Commands that require root
# are prefixed exactly with "sudo ". Selected directly by ID=fedora or via
# the ID_LIKE chain (RHEL, CentOS, Rocky, Alma, ... all declare "fedora"
# in ID_LIKE).

set -euo pipefail

distro_id() {
    printf 'fedora\n'
}

distro_pkg_manager() {
    printf 'dnf\n'
}

# Detect optional tools once into DISTRO_* variables.
distro_init() {
    DISTRO_PKG_CACHE_TOOL=""
    DISTRO_JOURNALCTL=""
    DISTRO_SYSTEMCTL=""
    DISTRO_FLATPAK=""
    if have_cmd dnf; then
        DISTRO_PKG_CACHE_TOOL="dnf"
    fi
    if have_cmd journalctl; then
        DISTRO_JOURNALCTL="journalctl"
    fi
    if have_cmd systemctl; then
        DISTRO_SYSTEMCTL="systemctl"
    fi
    if have_cmd flatpak; then
        DISTRO_FLATPAK="flatpak"
    fi
}

distro_pkg_cache_plan() {
    local keep="${1:-3}"
    # `keep` is version-independent for dnf: `clean packages` drops every
    # cached RPM regardless of age, so unlike paccache there is nothing to
    # size-limit. `clean` never prompts, hence no -y.
    if [[ -n "$DISTRO_PKG_CACHE_TOOL" ]]; then
        printf 'sudo %s clean packages\n' "$DISTRO_PKG_CACHE_TOOL"
    fi
}

distro_pkg_cache_summary() {
    local primary="${MOLE_PKG_CACHE_DIR:-/var/cache/dnf}"
    # Approach: one bounded du -sch over every existing cache root and report
    # its grand total. Summing per-directory human sizes would mean re-parsing
    # units in bash; du -c already does the math. The libdnf5 path is a test
    # seam like MOLE_PKG_CACHE_DIR (production leaves it at the default).
    local extra="${MOLE_LIBDNF5_CACHE_DIR:-/var/cache/libdnf5}"
    local -a cache_dirs=()
    [[ -d "$primary" ]] && cache_dirs+=("$primary")
    [[ -d "$extra" ]] && cache_dirs+=("$extra")
    [[ ${#cache_dirs[@]} -gt 0 ]] || return 0

    local size
    size="$(run_with_timeout "${MOLE_TIMEOUT_DISK_VERIFY_SEC:-15}" \
        du -sch "${cache_dirs[@]}" 2> /dev/null | LC_ALL=C awk '$NF == "total" {print $1}')" || return 0
    if [[ -n "$size" ]]; then
        printf 'DNF package cache: %s\n' "$size"
    fi
}

distro_orphans_list() {
    LC_ALL=C dnf -q repoquery --unneeded --qf '%{name}\n' 2> /dev/null || true
}

distro_orphans_remove_plan() {
    local orphans
    orphans="$(LC_ALL=C dnf -q repoquery --unneeded --qf '%{name}\n' 2> /dev/null |
        tr '\n' ' ' | sed 's/ *$//')" || return 0
    if [[ -n "$orphans" ]]; then
        printf 'sudo dnf -y remove %s\n' "$orphans"
    fi
}

distro_journal_vacuum_plan() {
    if [[ -n "$DISTRO_JOURNALCTL" && -n "$DISTRO_SYSTEMCTL" ]]; then
        printf 'sudo journalctl --vacuum-size=100M --vacuum-time=2weeks\n'
    fi
}

distro_flatpak_unused_plan() {
    if [[ -n "$DISTRO_FLATPAK" ]]; then
        printf 'flatpak uninstall --unused --noninteractive\n'
    fi
}

distro_aur_cache_dirs() {
    return 0
}
