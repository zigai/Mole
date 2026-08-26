#!/bin/bash
# Mole - Debian/Ubuntu Capability Module
# Implements the distro capability contract from lib/platform/platform.sh:
# query functions echo results and never prompt or mutate; plan functions
# echo one command per line for the caller to preview, confirm, and execute
# through the existing sudo + dry-run plumbing. Commands that require root
# are prefixed exactly with "sudo ". Ubuntu derivatives resolve here through
# the loader's ID_LIKE walk (ID=ubuntu, ID_LIKE=debian).

set -euo pipefail

distro_id() {
    printf 'debian\n'
}

distro_pkg_manager() {
    printf 'apt\n'
}

# Detect optional tools once into DISTRO_* variables.
distro_init() {
    DISTRO_PKG_CACHE_TOOL=""
    DISTRO_JOURNALCTL=""
    DISTRO_SYSTEMCTL=""
    DISTRO_FLATPAK=""
    if have_cmd apt-get; then
        DISTRO_PKG_CACHE_TOOL="apt"
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
    # keep is accepted for contract symmetry with arch's paccache -rk<keep>
    # and deliberately ignored: /var/cache/apt/archives holds only the
    # current downloads (no per-version history to retain).
    local keep="${1:-}"
    if [[ -n "$DISTRO_PKG_CACHE_TOOL" ]]; then
        printf 'sudo apt-get clean\n'
    fi
}

distro_pkg_cache_summary() {
    local pkg_dir="${MOLE_PKG_CACHE_DIR:-/var/cache/apt/archives}"
    if [[ ! -d "$pkg_dir" ]]; then
        return 0
    fi
    local size
    size="$(run_with_timeout "${MOLE_TIMEOUT_DISK_VERIFY_SEC:-15}" \
        du -sh "$pkg_dir" 2> /dev/null | cut -f1)" || return 0
    if [[ -n "$size" ]]; then
        printf 'APT package cache: %s\n' "$size"
    fi
}

distro_orphans_list() {
    command -v apt-get > /dev/null 2>&1 || return 0
    # autoremove prints exactly one "Remv <name> ..." line per removed
    # package, so no dedupe is needed.
    LC_ALL=C apt-get autoremove --simulate 2> /dev/null \
        | sed -n 's/^Remv //p' | cut -d' ' -f1 || true
}

distro_orphans_remove_plan() {
    command -v apt-get > /dev/null 2>&1 || return 0
    local names
    names="$(LC_ALL=C apt-get autoremove --simulate 2> /dev/null \
        | sed -n 's/^Remv //p' | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ *$//')" || return 0
    if [[ -n "$names" ]]; then
        # remove, NOT purge: leftover package configs survive, matching Mole's
        # conservatism elsewhere (pacman -Rns keeps nothing, but apt users
        # expect dpkg conffiles to persist until explicitly purged).
        printf 'sudo apt-get -y remove %s\n' "$names"
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
