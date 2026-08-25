#!/bin/bash
# Mole - Arch Linux Capability Module
# Implements the distro capability contract from lib/platform/platform.sh:
# query functions echo results and never prompt or mutate; plan functions
# echo one command per line for the caller to preview, confirm, and execute
# through the existing sudo + dry-run plumbing. Commands that require root
# are prefixed exactly with "sudo ".

set -euo pipefail

distro_id() {
    printf 'arch\n'
}

distro_pkg_manager() {
    printf 'pacman\n'
}

# Detect optional tools once into DISTRO_* variables.
distro_init() {
    DISTRO_PKG_CACHE_TOOL=""
    DISTRO_JOURNALCTL=""
    DISTRO_SYSTEMCTL=""
    DISTRO_FLATPAK=""
    DISTRO_AUR_HELPER=""
    if have_cmd paccache; then
        DISTRO_PKG_CACHE_TOOL="paccache"
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
    if have_cmd paru; then
        DISTRO_AUR_HELPER="paru"
    elif have_cmd yay; then
        DISTRO_AUR_HELPER="yay"
    fi
}

distro_pkg_cache_plan() {
    local keep="${1:-3}"
    if [[ "$DISTRO_PKG_CACHE_TOOL" == "paccache" ]]; then
        printf 'sudo paccache -rk%s\n' "$keep"
        printf 'sudo paccache -ruk0\n'
    else
        printf 'sudo pacman -Sc --noconfirm\n'
    fi
}

distro_pkg_cache_summary() {
    local pkg_dir="${MOLE_PKG_CACHE_DIR:-/var/cache/pacman/pkg}"
    if [[ ! -d "$pkg_dir" ]]; then
        return 0
    fi
    local size
    size="$(run_with_timeout "${MOLE_TIMEOUT_DISK_VERIFY_SEC:-15}" \
        du -sh "$pkg_dir" 2> /dev/null | cut -f1)" || return 0
    if [[ -n "$size" ]]; then
        printf 'Pacman package cache: %s\n' "$size"
    fi
}

distro_orphans_list() {
    pacman -Qtdq 2> /dev/null || true
}

distro_orphans_remove_plan() {
    local orphans
    orphans="$(pacman -Qtdq 2> /dev/null | tr '\n' ' ' | sed 's/ *$//')" || return 0
    if [[ -n "$orphans" ]]; then
        printf 'sudo pacman -Rns --noconfirm %s\n' "$orphans"
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
    if have_cmd yay; then
        printf '%s\n' "${HOME}/.cache/yay"
    fi
    if have_cmd paru; then
        printf '%s\n' "${HOME}/.cache/paru"
    fi
}
