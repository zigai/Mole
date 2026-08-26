#!/bin/bash
# Mole - Linux batch uninstall executor.
#
# Consumes the same `selected_apps` global as the macOS flow
# (<epoch>|<path>|<name>|<kind:id>|<size>|<last-used>|<size-kb> rows built by
# bin/uninstall.sh + lib/uninstall/enumerate.sh) and executes removals through
# the platform channels:
#
#   pacman:<pkg>       -> `sudo pacman -Rns --noconfirm <pkg>` (never manual rm)
#   deb:<pkg>          -> `sudo apt-get -y remove <pkg>`
#   rpm:<pkg>          -> `sudo dnf -y remove <pkg>`
#   flatpak:<app-id>   -> `flatpak uninstall --noninteractive <app-id>`;
#                        ~/.var/app/<app-id> is previewed explicitly first and
#                        trashed after a successful uninstall (--delete-data is
#                        never trusted blind, contract §5)
#   desktop:<binary>   -> binary plus its unowned .desktop entries, trashed
#
# Safety rules preserved on Linux:
#   - TOCTOU spirit: identity (package installed / app id listed / binary
#     present) is re-verified immediately before the FIRST destructive side
#     effect of each row.
#   - No launchd/login-items/brew branches exist here: that teardown is macOS
#     only and stays in the macOS path.
#   - Sudo is escalated once, only when a native package row (pacman/deb/rpm)
#     needs it or a leftover outside $HOME would have to be removed;
#     non-package-owned system paths are never deleted manually, so in
#     practice sudo covers package removal only.
#   - Review-tier leftovers are never deleted automatically.

if [[ -n "${MOLE_LINUX_BATCH_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_LINUX_BATCH_LOADED=1

_MOLE_LINUX_BATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_UNINSTALL_LEFTOVERS_LOADED:-}" ]]; then
    # shellcheck source=lib/uninstall/leftovers.sh
    source "$_MOLE_LINUX_BATCH_DIR/leftovers.sh"
fi
if [[ -z "${MOLE_UNINSTALL_ENUMERATE_LOADED:-}" ]]; then
    # shellcheck source=lib/uninstall/enumerate.sh
    source "$_MOLE_LINUX_BATCH_DIR/enumerate.sh"
fi

_linux_batch_is_dry_run() {
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]]
}

# Parse one kind:<id> bundle field into _LINUX_ROW_KIND / _LINUX_ROW_ID.
_linux_batch_parse_identity() {
    local bundle_field="$1"
    _LINUX_ROW_KIND="${bundle_field%%:*}"
    _LINUX_ROW_ID="${bundle_field#*:}"
    [[ -n "$_LINUX_ROW_KIND" && -n "$_LINUX_ROW_ID" && "$_LINUX_ROW_ID" != "$bundle_field" ]]
}

# Re-verify the row still identifies an installed payload right before the
# first destructive side effect (TOCTOU guard).
_linux_batch_identity_still_valid() {
    case "$_LINUX_ROW_KIND" in
        pacman)
            pacman_backend_package_installed "$_LINUX_ROW_ID"
            ;;
        deb)
            deb_backend_package_installed "$_LINUX_ROW_ID"
            ;;
        rpm)
            rpm_backend_package_installed "$_LINUX_ROW_ID"
            ;;
        flatpak)
            flatpak_backend_app_installed "$_LINUX_ROW_ID"
            ;;
        desktop)
            [[ -e "$_LINUX_ROW_ID" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# Collect the .desktop launcher files whose Exec/TryExec resolves to the
# given binary and which the active native package backend does not own.
_linux_batch_desktop_entries_for_binary() {
    local binary="$1"
    local root desktop_file exec_value try_exec token resolved dir_name
    while IFS= read -r root; do
        [[ -d "$root" ]] || continue
        while IFS= read -r -d '' desktop_file; do
            dir_name="${desktop_file%/*}"
            [[ "$dir_name" == "$root" ]] || continue
            exec_value=$(LC_ALL=C sed -n 's/^Exec=//p' "$desktop_file" 2> /dev/null | LC_ALL=C sed 's/[[:space:]].*$//')
            try_exec=$(LC_ALL=C sed -n 's/^TryExec=//p' "$desktop_file" 2> /dev/null)
            if [[ -n "$try_exec" ]]; then
                resolved=$(command -v -- "$try_exec" 2> /dev/null || true)
            fi
            if [[ -z "${resolved:-}" && -n "$exec_value" ]]; then
                token="${exec_value%%[[:space:]]*}"
                if [[ "$token" == /* ]]; then
                    [[ -x "$token" ]] && resolved="$token"
                else
                    resolved=$(command -v -- "$token" 2> /dev/null || true)
                fi
            fi
            [[ "${resolved:-}" == "$binary" ]] || continue
            native_backend_owns_path "$desktop_file" && continue
            printf '%s\n' "$desktop_file"
        done < <(command find "$root" -maxdepth 1 -name '*.desktop' -print0 2> /dev/null)
    done < <(desktop_backend_roots)
}

# Emit preview lines for one selected row: channel plan, safe leftovers,
# review-only leftovers, running warning.
_linux_batch_preview_row() {
    local row="$1"
    local _ path name bundle_field size last_used size_kb
    IFS='|' read -r _ path name bundle_field size last_used size_kb <<< "$row"

    _linux_batch_parse_identity "$bundle_field" || return 0

    local preview_path
    echo -e "${BLUE}${ICON_CONFIRM}${NC} ${name} ${GRAY}[${_LINUX_ROW_KIND}]${NC}, ${size}"

    case "$_LINUX_ROW_KIND" in
        pacman)
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${GRAY}Plan:${NC} $(pacman_backend_remove_plan "$_LINUX_ROW_ID")"
            ;;
        deb)
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${GRAY}Plan:${NC} $(deb_backend_remove_plan "$_LINUX_ROW_ID")"
            ;;
        rpm)
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${GRAY}Plan:${NC} $(rpm_backend_remove_plan "$_LINUX_ROW_ID")"
            ;;
        flatpak)
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${GRAY}Plan:${NC} $(flatpak_backend_uninstall_plan "$_LINUX_ROW_ID")"
            local data_dir
            data_dir=$(leftovers_flatpak_data_dir "$_LINUX_ROW_ID")
            if [[ -e "$data_dir" ]]; then
                local child
                while IFS= read -r child; do
                    preview_path=$(format_uninstall_preview_path "$child") || return $?
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} App data: $preview_path"
                done < <(command find "$data_dir" -mindepth 1 -maxdepth 1 2> /dev/null)
            fi
            ;;
        desktop)
            if [[ -e "$path" ]]; then
                preview_path=$(format_uninstall_preview_path "$path") || return $?
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $preview_path"
            fi
            while IFS= read -r desktop_file; do
                preview_path=$(format_uninstall_preview_path "$desktop_file") || return $?
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $preview_path"
            done < <(_linux_batch_desktop_entries_for_binary "$_LINUX_ROW_ID")
            ;;
    esac

    # Safe tier: exact-id leftovers eligible for removal.
    local candidate verdict shown_any=0
    while IFS= read -r candidate; do
        verdict=$(leftovers_classify_path "$candidate" "id")
        [[ "$verdict" == "safe" ]] || continue
        preview_path=$(format_uninstall_preview_path "$candidate") || return $?
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $preview_path"
        shown_any=1
    done < <(leftovers_exact_paths "$_LINUX_ROW_ID")

    # Review tier: display-name-derived leftovers surfaced but never removed.
    while IFS= read -r candidate; do
        verdict=$(leftovers_classify_path "$candidate" "name")
        [[ "$verdict" == "review" ]] || continue
        preview_path=$(format_uninstall_preview_path "$candidate") || return $?
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Review only: $preview_path"
        shown_any=1
    done < <(leftovers_review_paths "$name")

    if [[ "$shown_any" == "0" ]]; then
        echo -e "  ${GRAY}${ICON_EMPTY}${NC} No known leftovers under XDG roots${NC}"
    fi

    local run_state
    run_state=$(leftovers_running_state "$_LINUX_ROW_ID" "$name")
    if [[ "$run_state" == "running" ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Running: ${name} is currently active"
    elif [[ "$run_state" == "unknown" ]]; then
        echo -e "  ${GRAY}${ICON_INFO}${NC} Could not check whether ${name} is running"
    fi

    echo ""
}

# Preview every row and ask for one confirmation. Returns 0 = confirmed,
# 2 = cancelled, 1 = otherwise aborted.
_linux_batch_preview_and_confirm() {
    # shellcheck disable=SC2154  # selected_apps is assigned by bin/uninstall.sh.
    local total_rows=${#selected_apps[@]}
    echo -e "\n${PURPLE_BOLD}The following will be removed:${NC}"
    echo ""

    local row
    for row in "${selected_apps[@]}"; do
        _linux_batch_preview_row "$row"
    done

    local app_text="app"
    [[ $total_rows -gt 1 ]] && app_text="apps"
    echo ""
    echo -ne "${PURPLE}${ICON_ARROW}${NC} Remove ${total_rows} ${app_text}?  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "

    drain_pending_input
    local key=""
    IFS= read -r -s -n1 key || key=""
    drain_pending_input
    case "$key" in
        $'\e' | q | Q)
            echo ""
            return 2
            ;;
        "" | $'\n' | $'\r' | y | Y)
            echo ""
            ;;
        *)
            echo ""
            return 2
            ;;
    esac

    # Uninstall mode relaxes data-protected checks for the explicitly chosen
    # apps; system-critical protection stays active.
    export MOLE_UNINSTALL_MODE=1

    return 0
}

# Execute one confirmed row. Echoes "success", "skipped", or "failed".
_linux_batch_execute_row() {
    local row="$1"
    local _ path name bundle_field size last_used size_kb
    IFS='|' read -r _ path name bundle_field size last_used size_kb <<< "$row"

    _linux_batch_parse_identity "$bundle_field" || {
        log_error "Unrecognized uninstall target: ${bundle_field}" >&2
        echo "failed"
        return 0
    }

    if _linux_batch_is_dry_run; then
        case "$_LINUX_ROW_KIND" in
            pacman)
                log_info "[DRY RUN] Would run: $(pacman_backend_remove_plan "$_LINUX_ROW_ID")" >&2
                ;;
            deb)
                log_info "[DRY RUN] Would run: $(deb_backend_remove_plan "$_LINUX_ROW_ID")" >&2
                ;;
            rpm)
                log_info "[DRY RUN] Would run: $(rpm_backend_remove_plan "$_LINUX_ROW_ID")" >&2
                ;;
            flatpak)
                log_info "[DRY RUN] Would run: $(flatpak_backend_uninstall_plan "$_LINUX_ROW_ID")" >&2
                ;;
        esac
        echo "success"
        return 0
    fi

    # TOCTOU guard: re-verify identity immediately before the first
    # destructive side effect.
    if ! _linux_batch_identity_still_valid; then
        log_warning "Skipped ${name}: it is no longer installed in the expected form" >&2
        echo "skipped"
        return 0
    fi

    local failed=0
    case "$_LINUX_ROW_KIND" in
        pacman)
            sudo pacman -Rns --noconfirm -- "$_LINUX_ROW_ID" > /dev/null 2>&1 || failed=1
            ;;
        deb)
            sudo apt-get -y remove -- "$_LINUX_ROW_ID" > /dev/null 2>&1 || failed=1
            ;;
        rpm)
            sudo dnf -y remove -- "$_LINUX_ROW_ID" > /dev/null 2>&1 || failed=1
            ;;
        flatpak)
            flatpak uninstall --noninteractive -- "$_LINUX_ROW_ID" > /dev/null 2>&1 || failed=1
            if [[ $failed -eq 0 ]]; then
                local data_dir
                data_dir=$(leftovers_flatpak_data_dir "$_LINUX_ROW_ID")
                if [[ -e "$data_dir" ]] && ! should_protect_path "$data_dir"; then
                    mole_delete "$data_dir" > /dev/null 2>&1 || true
                fi
            fi
            ;;
        desktop)
            if ! should_protect_path "$_LINUX_ROW_ID"; then
                mole_delete "$_LINUX_ROW_ID" > /dev/null 2>&1 || failed=1
            else
                failed=1
            fi
            local desktop_file
            while IFS= read -r desktop_file; do
                if ! should_protect_path "$desktop_file"; then
                    mole_delete "$desktop_file" > /dev/null 2>&1 || true
                fi
            done < <(_linux_batch_desktop_entries_for_binary "$_LINUX_ROW_ID")
            ;;
    esac

    if [[ $failed -ne 0 ]]; then
        echo "failed"
        return 0
    fi

    # Exact-id leftovers classified safe are trashed; anything else is left
    # for review.
    local candidate verdict
    while IFS= read -r candidate; do
        verdict=$(leftovers_classify_path "$candidate" "id") || verdict="skip"
        [[ "$verdict" == "safe" ]] || continue
        should_protect_path "$candidate" && continue
        mole_delete "$candidate" > /dev/null 2>&1 || true
    done < <(leftovers_exact_paths "$_LINUX_ROW_ID")

    echo "success"
}

# Linux entry point dispatched from batch_uninstall_applications.
# Reads:  selected_apps
# Writes: LINUX_BATCH_SUCCESS/LINUX_BATCH_FAILED/LINUX_BATCH_SKIPPED names,
#         LINUX_BATCH_SIZE_FREED_KB
batch_uninstall_applications_linux() {
    LINUX_BATCH_SUCCESS=()
    LINUX_BATCH_FAILED=()
    LINUX_BATCH_SKIPPED=()
    LINUX_BATCH_SIZE_FREED_KB=0
    # shellcheck disable=SC2154  # selected_apps is assigned by bin/uninstall.sh.
    if [[ ${#selected_apps[@]} -eq 0 ]]; then
        log_warning "No applications selected for uninstallation"
        return 0
    fi

    local _confirm_rc=0
    _linux_batch_preview_and_confirm || _confirm_rc=$?
    if [[ $_confirm_rc -eq 2 ]]; then
        echo "Cancelled."
        unset MOLE_UNINSTALL_MODE
        return 0
    elif [[ $_confirm_rc -ne 0 ]]; then
        unset MOLE_UNINSTALL_MODE
        return 1
    fi

    # Sudo escalation: required only for native package removals
    # (pacman/deb/rpm). Non-package-owned system paths are never deleted
    # manually, so no other source of root is reachable from this flow.
    if ! _linux_batch_is_dry_run; then
        local row kind id
        local needs_sudo=0
        for row in "${selected_apps[@]}"; do
            IFS='|' read -r _ _ _ bundle_field _ <<< "$row"
            kind="${bundle_field%%:*}"
            id="${bundle_field#*:}"
            case "$kind" in
                pacman | deb | rpm)
                    needs_sudo=1
                    break
                    ;;
            esac
        done
        if [[ $needs_sudo -eq 1 ]]; then
            if declare -f ensure_sudo_session > /dev/null 2>&1; then
                if ! ensure_sudo_session "Admin access is required to remove packages"; then
                    log_error "Admin access denied"
                    unset MOLE_UNINSTALL_MODE
                    return 1
                fi
            fi
        fi
    fi

    local row verdict name size_kb
    for row in "${selected_apps[@]}"; do
        IFS='|' read -r _ _ name _ _ _ size_kb <<< "$row"
        verdict=$(_linux_batch_execute_row "$row")
        case "$verdict" in
            success)
                LINUX_BATCH_SUCCESS+=("$name")
                if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
                    LINUX_BATCH_SIZE_FREED_KB=$((LINUX_BATCH_SIZE_FREED_KB + size_kb))
                fi
                ;;
            skipped)
                LINUX_BATCH_SKIPPED+=("$name")
                ;;
            *)
                LINUX_BATCH_FAILED+=("$name")
                ;;
        esac
    done

    unset MOLE_UNINSTALL_MODE

    # Summary
    echo ""
    if [[ ${#LINUX_BATCH_SUCCESS[@]} -gt 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed ${#LINUX_BATCH_SUCCESS[@]} application(s)"
    fi
    if [[ ${#LINUX_BATCH_SKIPPED[@]} -gt 0 ]]; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped (changed during run): ${LINUX_BATCH_SKIPPED[*]}"
    fi
    if [[ ${#LINUX_BATCH_FAILED[@]} -gt 0 ]]; then
        echo -e "${RED}${ICON_ERROR}${NC} Failed: ${LINUX_BATCH_FAILED[*]}"
    fi
    if [[ ${#LINUX_BATCH_SUCCESS[@]} -gt 0 && $LINUX_BATCH_SIZE_FREED_KB -gt 0 ]]; then
        echo -e "${GRAY}Freed approximately $(bytes_to_human $((LINUX_BATCH_SIZE_FREED_KB * 1024)))${NC}"
    fi

    return 0
}
