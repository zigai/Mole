#!/bin/bash
# Linux system maintenance for `mo clean` (sudo-gated).
#
# Sourced by bin/clean.sh; only invoked when the user opted into system-level
# cleanup (SYSTEM_CLEAN=true), which is the confirm step for every privileged
# action below. Distro capability functions follow the platform contract:
# they never prompt and echo one command per line, with root-requiring lines
# prefixed exactly "sudo ". This module previews each plan in dry-run mode
# and executes it through sudo in real mode. Orphan packages are strictly
# report-only here; removal belongs to `mo optimize`.
set -euo pipefail

_linux_vartmp_dir() {
    # Env override exists for tests; see tests/linux_clean_system.bats.
    printf '%s\n' "${MOLE_VARTMP_DIR:-/var/tmp}"
}

# Collect plan lines from a distro capability function. Missing capability or
# an empty plan yields no output and success.
_linux_distro_plan_lines() {
    local fn="$1"
    shift
    declare -F "$fn" > /dev/null 2>&1 || return 0
    "$fn" "$@" 2> /dev/null || true
}

# Preview (dry-run) or execute (real mode) a set of plan commands.
# Args: label, then one plan command per argument.
_linux_execute_plan() {
    local label="$1"
    shift

    if [[ "$DRY_RUN" == "true" ]]; then
        local line
        for line in "$@"; do
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $label · would run: $line"
        done
        note_activity
        return 0
    fi

    local line
    local -a argv=()
    local failed=0
    for line in "$@"; do
        argv=()
        # shellcheck disable=SC2206  # Intentional word split of one plan line
        read -r -a argv <<< "$line"
        [[ ${#argv[@]} -gt 0 ]] || continue
        if ! "${argv[@]}"; then
            failed=$((failed + 1))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} $label · $failed command(s) failed"
        note_activity
    fi
    return 0
}

# Remove stale top-level entries from /var/tmp through the audited privileged
# delete helper. Age alone is the criterion on Linux because /var/tmp has no
# per-app staging contract; the window defaults to 7 days.
clean_linux_vartmp_stale() {
    local vartmp_dir
    vartmp_dir=$(_linux_vartmp_dir)
    [[ -d "$vartmp_dir" ]] || return 0

    local age_days="${MOLE_VARTMP_STALE_DAYS:-7}"
    [[ "$age_days" =~ ^[0-9]+$ ]] || age_days=7

    local -a stale_items=()
    local item
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        stale_items+=("$item")
    done < <(command find "$vartmp_dir" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type d \) -mtime "+$age_days" -print 2> /dev/null || true)

    if [[ ${#stale_items[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Stale /var/tmp entries · would remove, ${#stale_items[@]} items older than ${age_days}d"
        note_activity
        return 0
    fi

    safe_sudo_find_delete "$vartmp_dir" "*" "$age_days" f 1 || true
    safe_sudo_find_delete "$vartmp_dir" "*" "$age_days" d 1 || true
    local removed=${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0}
    if [[ "$removed" =~ ^[0-9]+$ && $removed -gt 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Stale /var/tmp entries · removed ${removed} items"
        note_activity
    fi
    return 0
}

# System maintenance section body. Requires an established sudo session;
# callers gate this behind SYSTEM_CLEAN.
clean_linux_system_maintenance() {
    local keep="${MOLE_PKG_CACHE_KEEP:-3}"
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=3

    # Package manager cache.
    local -a pkg_plan=()
    local plan_line
    while IFS= read -r plan_line; do
        [[ -n "$plan_line" ]] && pkg_plan+=("$plan_line")
    done < <(_linux_distro_plan_lines distro_pkg_cache_plan "$keep")

    if [[ ${#pkg_plan[@]} -gt 0 ]]; then
        if declare -F distro_pkg_cache_summary > /dev/null 2>&1; then
            local pkg_summary=""
            pkg_summary=$(distro_pkg_cache_summary 2> /dev/null || true)
            if [[ -n "$pkg_summary" ]]; then
                echo -e "  ${BLUE}${ICON_LIST}${NC} Package cache · $pkg_summary"
            fi
        fi
        _linux_execute_plan "Package cache" "${pkg_plan[@]}"
    fi

    # Journald vacuum.
    local -a journal_plan=()
    while IFS= read -r plan_line; do
        [[ -n "$plan_line" ]] && journal_plan+=("$plan_line")
    done < <(_linux_distro_plan_lines distro_journal_vacuum_plan)
    _linux_execute_plan "Journal logs" "${journal_plan[@]}"

    # Stale /var/tmp entries.
    clean_linux_vartmp_stale

    # Flatpak unused runtimes.
    local -a flatpak_plan=()
    while IFS= read -r plan_line; do
        [[ -n "$plan_line" ]] && flatpak_plan+=("$plan_line")
    done < <(_linux_distro_plan_lines distro_flatpak_unused_plan)
    _linux_execute_plan "Flatpak unused runtimes" "${flatpak_plan[@]}"
}

# REPORT-ONLY: surface orphan packages so the user can act via `mo optimize`
# or their package manager. Never removes anything.
report_linux_orphan_packages() {
    declare -F distro_orphans_list > /dev/null 2>&1 || return 0
    local orphans=""
    orphans=$(distro_orphans_list 2> /dev/null || true)
    local total
    total=$(printf '%s\n' "$orphans" | grep -c . || true)
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    [[ $total -gt 0 ]] || return 0

    local names
    names=$(printf '%s\n' "$orphans" | sed -n '1,5p' | tr '\n' ' ' | sed 's/ $//')
    local suffix=""
    if [[ $(printf '%s\n' "$orphans" | wc -l) -gt 5 ]]; then
        suffix=", …"
    fi

    echo -e "  ${GRAY}${ICON_REVIEW}${NC} Orphan packages · ${total} found: ${names}${suffix}"
    echo -e "      ${GRAY}Review with \`pacman -Qtd\` or run \`mo optimize\` to remove${NC}"
    note_activity
}
