#!/bin/bash
# Optimization Tasks

set -euo pipefail

if [[ -n "${MOLE_OPTIMIZE_TASKS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_OPTIMIZE_TASKS_LOADED=1

_MOLE_OPTIMIZE_TASKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _MOLE_OPTIMIZE_TASKS_DIR
source "$_MOLE_OPTIMIZE_TASKS_DIR/catalog.sh"
source "$_MOLE_OPTIMIZE_TASKS_DIR/outcomes.sh"

# Dry-run aware output.
opt_msg() {
    local message="$1"
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $message"
    else
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $message"
    fi
}

# Whether the current optimize run can use sudo without re-prompting.
# Set by bin/optimize.sh after the upfront ensure_sudo_session call.
# Test-mode env vars hard-deny so ad-hoc task calls under MOLE_TEST_NO_AUTH=1
# (e.g. ./scripts/test.sh, manual repro) cannot reach a real sudo invocation
# even when this helper is invoked outside the optimize entrypoint.
optimize_sudo_available() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi
    [[ "${MOLE_OPTIMIZE_SUDO_AVAILABLE:-true}" == "true" ]]
}

###############################################################################
# Linux maintenance actions.
#
# Handlers consume the distro capability contract from lib/platform/linux/*:
# queries echo results freely, plans ECHO one command per line (root commands
# prefixed exactly `sudo `). Plans are previewed and executed here through the
# shared dry-run + sudo plumbing; modules themselves never prompt or execute.
###############################################################################

readonly MOLE_OPTIMIZE_LINUX_CMD_TIMEOUT="${MOLE_OPTIMIZE_LINUX_CMD_TIMEOUT:-300}"

_OPT_PLAN_APPLIED=0
_OPT_PLAN_SKIPPED=0
_OPT_PLAN_FAILED=0

# Execute a distro plan (one command per line). Dry-run only previews; sudo
# lines go through the shared sudo-availability gate, which also hard-denies
# under MOLE_TEST_MODE / MOLE_TEST_NO_AUTH.
_opt_linux_execute_plan() {
    local plan="$1"
    _OPT_PLAN_APPLIED=0
    _OPT_PLAN_SKIPPED=0
    _OPT_PLAN_FAILED=0

    local cmd rc
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
            opt_msg "Would run: $cmd"
            _OPT_PLAN_APPLIED=$((_OPT_PLAN_APPLIED + 1))
            continue
        fi
        if [[ "$cmd" == sudo\ * ]] && ! optimize_sudo_available; then
            echo -e "  ${GRAY}${ICON_EMPTY}${NC} Skipped (admin access required): $cmd"
            _OPT_PLAN_SKIPPED=$((_OPT_PLAN_SKIPPED + 1))
            continue
        fi

        # Plan lines come from our own distro modules (contract output), never
        # user input; split without glob expansion before executing.
        local -a argv=()
        read -r -a argv <<< "$cmd"
        rc=0
        if [[ "${argv[0]:-}" == "sudo" ]]; then
            argv=("${argv[@]:1}")
            run_with_timeout "$MOLE_OPTIMIZE_LINUX_CMD_TIMEOUT" \
                sudo "${argv[@]}" 2> /dev/null || rc=$?
        else
            run_with_timeout "$MOLE_OPTIMIZE_LINUX_CMD_TIMEOUT" \
                "${argv[@]}" 2> /dev/null || rc=$?
        fi
        if [[ $rc -eq 124 || $rc -ge 128 ]]; then
            return "$rc"
        elif [[ $rc -ne 0 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed (exit=$rc): $cmd"
            _OPT_PLAN_FAILED=$((_OPT_PLAN_FAILED + 1))
        else
            opt_msg "Ran: $cmd"
            _OPT_PLAN_APPLIED=$((_OPT_PLAN_APPLIED + 1))
        fi
    done <<< "$plan"
}

# Map executor counts onto one canonical task outcome.
_opt_linux_plan_outcome() {
    if [[ $_OPT_PLAN_FAILED -gt 0 ]]; then
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
    elif [[ $_OPT_PLAN_APPLIED -gt 0 ]]; then
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
    elif [[ $_OPT_PLAN_SKIPPED -gt 0 ]]; then
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
    else
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
    fi
}

_opt_distro_fn_defined() {
    declare -F "$1" > /dev/null 2>&1
}

# Package cache trim via distro_pkg_cache_plan(keep); keeps one version of
# each installed package plus uninstalled leftovers, per the Arch convention.
opt_pkg_cache_trim() {
    if ! _opt_distro_fn_defined distro_pkg_cache_plan; then
        opt_msg "Package cache trim unavailable (no distro module)"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    local summary=""
    summary=$(distro_pkg_cache_summary 2> /dev/null || true)
    if [[ -n "$summary" ]]; then
        echo -e "  ${GRAY}${ICON_INFO}${NC} $summary"
    fi

    local plan=""
    plan=$(distro_pkg_cache_plan 1 2> /dev/null || true)
    if [[ -z "$plan" ]]; then
        opt_msg "No supported package cache to trim"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    _opt_linux_execute_plan "$plan"
    _opt_linux_plan_outcome
}

# Shrink the systemd journal via distro_journal_vacuum_plan.
opt_journal_vacuum() {
    if ! _opt_distro_fn_defined distro_journal_vacuum_plan; then
        opt_msg "Journal vacuum unavailable (no distro module)"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    local plan=""
    plan=$(distro_journal_vacuum_plan 2> /dev/null || true)
    if [[ -z "$plan" ]]; then
        opt_msg "Journal vacuum unavailable (systemd not present)"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    _opt_linux_execute_plan "$plan"
    _opt_linux_plan_outcome
}

# Report orphaned packages and offer their removal behind an explicit confirm.
# Non-interactive runs stay read-only and surface ATTENTION instead.
opt_orphan_packages() {
    if ! _opt_distro_fn_defined distro_orphans_list; then
        opt_msg "Orphaned package scan unavailable (no distro module)"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    local orphan_output=""
    orphan_output=$(distro_orphans_list 2> /dev/null || true)
    local -a names=()
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done <<< "$orphan_output"

    if [[ ${#names[@]} -eq 0 ]]; then
        opt_msg "No orphaned packages found"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    echo -e "  ${GRAY}${ICON_INFO}${NC} Orphaned packages (${#names[@]}):"
    local shown_limit=10
    local shown=0
    for name in "${names[@]}"; do
        if [[ $shown -ge $shown_limit ]]; then
            echo -e "  ${GRAY}${ICON_SUBLIST}${NC} ... and $(( ${#names[@]} - shown )) more"
            break
        fi
        echo -e "  ${GRAY}${ICON_SUBLIST}${NC} $name"
        shown=$((shown + 1))
    done

    local plan=""
    if _opt_distro_fn_defined distro_orphans_remove_plan; then
        plan=$(distro_orphans_remove_plan 2> /dev/null || true)
    fi
    if [[ -z "$plan" ]]; then
        echo -e "  ${YELLOW}${ICON_REVIEW}${NC} No removal plan available for these orphans"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_ATTENTION"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        opt_msg "Would run: $plan"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
        return 0
    fi

    # Interactive confirmation mirrors the installer delete prompt. Without a
    # TTY on stdin there is no safe way to consent, so stay read-only.
    if ! [[ -t 0 ]] || [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        echo -e "  ${YELLOW}${ICON_REVIEW}${NC} Review and rerun interactively to remove: $plan"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_ATTENTION"
        return 0
    fi

    echo -ne "  ${PURPLE}${ICON_ARROW}${NC} Remove ${#names[@]} orphaned packages? ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} skip: "
    local key=""
    IFS= read -r -s -n1 key || key=""
    if declare -F drain_pending_input > /dev/null 2>&1; then
        drain_pending_input
    fi
    case "$key" in
        "" | $'\n' | $'\r') ;;
        *)
            printf "\r\033[K"
            opt_msg "Skipped by user"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
            return 0
            ;;
    esac
    printf "\r\033[K"

    _opt_linux_execute_plan "$plan"
    _opt_linux_plan_outcome
}

# Uninstall unused Flatpak runtimes/extensions via distro_flatpak_unused_plan.
opt_flatpak_unused() {
    if ! _opt_distro_fn_defined distro_flatpak_unused_plan; then
        opt_msg "Flatpak cleanup unavailable (no distro module)"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    local plan=""
    plan=$(distro_flatpak_unused_plan 2> /dev/null || true)
    if [[ -z "$plan" ]]; then
        opt_msg "Flatpak not present, nothing to clean"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    _opt_linux_execute_plan "$plan"
    _opt_linux_plan_outcome
}

# True when at least one block device reports rotational=0. The root is a
# parameter so tests can point at a fixture tree; production uses sysfs.
_linux_has_ssd_device() {
    local sys_block_root="${1:-/sys/block}"
    local rotational_file value
    for rotational_file in "$sys_block_root"/*/queue/rotational; do
        [[ -r "$rotational_file" ]] || continue
        value=""
        read -r value < "$rotational_file" || value=""
        if [[ "$value" == "0" ]]; then
            return 0
        fi
    done
    return 1
}

# SSD TRIM via fstrim -av, gated on at least one non-rotational device.
opt_ssd_trim() {
    if ! command -v fstrim > /dev/null 2>&1; then
        opt_msg "SSD TRIM unavailable (fstrim not found)"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    if ! _linux_has_ssd_device; then
        opt_msg "SSD TRIM skipped (no non-rotational devices)"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    _opt_linux_execute_plan "sudo fstrim -av"
    _opt_linux_plan_outcome
}

# Read-only report of failed systemd units.
opt_failed_units_report() {
    if ! command -v systemctl > /dev/null 2>&1; then
        opt_msg "Failed units report unavailable (systemctl not found)"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    local units_output=""
    units_output=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" \
        systemctl --failed --no-legend --plain 2> /dev/null || true)
    local -a units=()
    local unit_line
    while IFS= read -r unit_line; do
        [[ -n "$unit_line" ]] && units+=("$unit_line")
    done <<< "$units_output"

    if [[ ${#units[@]} -eq 0 ]]; then
        opt_msg "No failed systemd units"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed systemd units (${#units[@]}):"
    local shown_limit=10
    local shown=0
    for unit_line in "${units[@]}"; do
        if [[ $shown -ge $shown_limit ]]; then
            echo -e "  ${GRAY}${ICON_SUBLIST}${NC} ... and $(( ${#units[@]} - shown )) more"
            break
        fi
        echo -e "  ${GRAY}${ICON_SUBLIST}${NC} $unit_line"
        shown=$((shown + 1))
    done
    echo -e "  ${GRAY}${ICON_INFO}${NC} Inspect with: systemctl --failed"
    optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_ATTENTION"
}

# Flush the systemd-resolved DNS cache when resolvectl is present.
opt_dns_cache_flush() {
    if ! command -v resolvectl > /dev/null 2>&1; then
        opt_msg "DNS cache flush unavailable (resolvectl not found)"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    _opt_linux_execute_plan "resolvectl flush-caches"
    _opt_linux_plan_outcome
}

# Dispatch optimization by action name.
execute_optimization() {
    local action="$1"

    local handler health_name
    if ! handler=$(optimize_catalog_handler_for "$action"); then
        echo -e "${YELLOW}${ICON_ERROR}${NC} Unknown action: $action"
        return 1
    fi
    health_name=$(optimize_catalog_health_name_for "$action")
    if ! declare -F "$handler" > /dev/null; then
        echo -e "${YELLOW}${ICON_ERROR}${NC} Missing optimization handler: $handler"
        return 1
    fi

    if command -v is_whitelisted > /dev/null && is_whitelisted "$action"; then
        optimize_task_start
        opt_msg "Skipped (whitelisted): $health_name"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
        optimize_task_finish "$action"
        return 0
    fi

    optimize_task_start
    "$handler"
    optimize_task_finish "$action"
}
