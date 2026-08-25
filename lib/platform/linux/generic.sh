#!/bin/bash
# Mole - Generic Linux Distro Module
# Safe subset for distributions without a dedicated capability module:
# no package-manager knowledge means package and journal plans stay empty;
# flatpak cleanup is still offered when flatpak exists. Queries echo empty
# results, plans echo nothing, both return 0.

set -euo pipefail

distro_id() {
    printf 'generic\n'
}

distro_pkg_manager() {
    return 0
}

distro_pkg_cache_plan() {
    return 0
}

distro_pkg_cache_summary() {
    return 0
}

distro_orphans_list() {
    return 0
}

distro_orphans_remove_plan() {
    return 0
}

distro_journal_vacuum_plan() {
    return 0
}

distro_flatpak_unused_plan() {
    if have_cmd flatpak; then
        printf 'flatpak uninstall --unused --noninteractive\n'
    fi
    return 0
}

distro_aur_cache_dirs() {
    return 0
}
