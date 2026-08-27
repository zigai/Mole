#!/bin/bash
# Mole - Uninstall command.
# Interactive app uninstaller.
# Removes app files and leftovers.

set -euo pipefail

# Preserve user's locale for app display name lookup.
readonly MOLE_UNINSTALL_USER_LC_ALL="${LC_ALL:-}"
readonly MOLE_UNINSTALL_USER_LANG="${LANG:-}"

# Fix locale issues on non-English systems.
export LC_ALL=C
export LANG=C

# Load shared helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"

# Clean temp files on exit.
trap cleanup_temp_files EXIT INT TERM
source "$SCRIPT_DIR/../lib/ui/menu_paginated.sh"
source "$SCRIPT_DIR/../lib/ui/app_selector.sh"
# Linux uninstall enumeration and execution (contract §5). Sourced before
# batch.sh, which reassigns the global SCRIPT_DIR.
_MOLE_UNINSTALL_LINUX_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib/uninstall" && pwd)"
source "$_MOLE_UNINSTALL_LINUX_SRC/backends/pacman.sh"
source "$_MOLE_UNINSTALL_LINUX_SRC/backends/flatpak.sh"
source "$_MOLE_UNINSTALL_LINUX_SRC/backends/desktop.sh"
source "$_MOLE_UNINSTALL_LINUX_SRC/leftovers.sh"
source "$_MOLE_UNINSTALL_LINUX_SRC/enumerate.sh"
source "$SCRIPT_DIR/../lib/uninstall/batch.sh"

# State
selected_apps=()
declare -a apps_data=()
declare -a selection_state=()
total_items=0
files_cleaned=0
total_size_cleaned=0

readonly MOLE_UNINSTALL_META_CACHE_DIR="$HOME/.cache/mole"
readonly MOLE_UNINSTALL_META_CACHE_FILE="$MOLE_UNINSTALL_META_CACHE_DIR/uninstall_app_metadata_v2"
readonly MOLE_UNINSTALL_META_CACHE_LOCK="${MOLE_UNINSTALL_META_CACHE_FILE}.lock"
readonly MOLE_UNINSTALL_META_REFRESH_TTL=604800 # 7 days
readonly MOLE_UNINSTALL_EPOCH_FLOOR=978307200

# Linux metadata cache (contract: fingerprint = checksum of package + flatpak
# lists). First line of the file is the fingerprint; the rest is the sorted
# selector index, reused verbatim while the fingerprint matches.
readonly MOLE_UNINSTALL_LINUX_CACHE_FILE="${MOLE_UNINSTALL_META_CACHE_DIR}/uninstall_app_metadata_linux_v1"

uninstall_normalize_size_display() {
    local size="${1:-}"
    local app_path="${2:-}"

    if [[ -z "$size" || "$size" == "0" || "$size" == "Unknown" ]]; then
        echo "N/A"
        return 0
    fi
    echo "$size"
}

uninstall_normalize_last_used_display() {
    local last_used="${1:-}"
    local display
    display=$(format_last_used_summary "$last_used")
    if [[ -z "$display" || "$display" == "Never" ]]; then
        echo "Unknown"
        return 0
    fi
    echo "$display"
}

uninstall_acquire_metadata_lock() {
    local lock_dir="$1"
    local attempts=0

    while ! mkdir "$lock_dir" 2> /dev/null; do
        ((attempts++))
        if [[ $attempts -ge 40 ]]; then
            return 1
        fi

        # Clean stale lock if older than 5 minutes.
        if [[ -d "$lock_dir" ]]; then
            local lock_mtime
            lock_mtime=$(get_file_mtime "$lock_dir")
            # Skip stale detection if mtime lookup failed (returns 0).
            if [[ "$lock_mtime" =~ ^[0-9]+$ && $lock_mtime -gt 0 ]]; then
                local lock_age
                lock_age=$(($(get_epoch_seconds) - lock_mtime))
                if [[ "$lock_age" =~ ^-?[0-9]+$ && $lock_age -gt 300 ]]; then
                    rmdir "$lock_dir" 2> /dev/null || true
                fi
            fi
        fi

        sleep 0.1 2> /dev/null || sleep 1
    done

    return 0
}

uninstall_release_metadata_lock() {
    local lock_dir="$1"
    [[ -d "$lock_dir" ]] && rmdir "$lock_dir" 2> /dev/null || true
}

# Atomically replace the metadata cache file, healing stale root-owned copies.
# stdin is closed so BSD mv/cp never blocks prompting on a non-writable target.
uninstall_persist_cache_file() {
    local src="$1"
    local dst="$2"

    [[ -s "$src" ]] || {
        rm -f "$src" 2> /dev/null || true
        return 0
    }

    # Heal stale file the user cannot write to (e.g. root-owned from a prior
    # sudo run). The parent dir is user-owned, so rm succeeds regardless.
    if [[ -e "$dst" && ! -w "$dst" ]]; then
        rm -f "$dst" 2> /dev/null || true
    fi

    # shellcheck disable=SC2217 # BSD mv/cp read stdin when prompting; close it to avoid hang.
    mv -f "$src" "$dst" < /dev/null 2> /dev/null || {
        # shellcheck disable=SC2217
        cp -f "$src" "$dst" < /dev/null 2> /dev/null || true
        rm -f "$src" 2> /dev/null || true
    }
}

uninstall_app_inventory_fingerprint() {
    # Fingerprint = checksum of the package + flatpak lists (contract §5).
    enumerate_linux_fingerprint
}

# The in-session app index remains valid when the live inventory only loses
# rows. load_applications rechecks path existence before displaying each row.
# New rows and changed mtimes must rebuild the index so protection and bundle
# metadata are evaluated again.
uninstall_inventory_can_reuse_cached_apps() {
    local cached_inventory="$1"
    local current_inventory="$2"
    local additions=""
    local removals=""

    [[ -n "$cached_inventory" && -n "$current_inventory" ]] || return 1
    additions=$(LC_ALL=C comm -13 \
        <(printf '%s\n' "$cached_inventory") \
        <(printf '%s\n' "$current_inventory")) || return 1
    [[ -z "$additions" ]] || return 1

    removals=$(LC_ALL=C comm -23 \
        <(printf '%s\n' "$cached_inventory") \
        <(printf '%s\n' "$current_inventory")) || return 1
    local removed_row removed_path
    while IFS= read -r removed_row; do
        [[ -n "$removed_row" ]] || continue
        removed_path="${removed_row%|*}"
        removed_path="${removed_path%|*}"
        [[ ! -e "$removed_path" ]] || return 1
    done <<< "$removals"
    return 0
}

scan_applications() {
    # Linux routes through the backend enumeration and reuses the persisted
    # index while the inventory fingerprint matches. Echoes the sorted index
    # file path (registered as a temp file) or returns nonzero when
    # enumeration fails.
    local out_file
    out_file=$(create_temp_file)

    ensure_user_dir "$MOLE_UNINSTALL_META_CACHE_DIR"
    local cache_fingerprint=""
    if [[ -r "$MOLE_UNINSTALL_LINUX_CACHE_FILE" ]]; then
        cache_fingerprint=$(LC_ALL=C head -n 1 "$MOLE_UNINSTALL_LINUX_CACHE_FILE" 2> /dev/null || echo "")
    fi

    local current_fingerprint
    current_fingerprint=$(enumerate_linux_fingerprint)

    if [[ -n "$cache_fingerprint" && "$cache_fingerprint" == "$current_fingerprint" &&
        $(wc -l < "$MOLE_UNINSTALL_LINUX_CACHE_FILE") -gt 1 ]]; then
        LC_ALL=C tail -n +2 "$MOLE_UNINSTALL_LINUX_CACHE_FILE" > "$out_file"
        register_temp_file "$out_file"
        echo "$out_file"
        return 0
    fi

    enumerate_linux_index "$out_file" || {
        rm -f "$out_file"
        return 1
    }

    # Persist fingerprint + index atomically under the shared metadata lock.
    local snapshot_file
    snapshot_file=$(mktemp "${TMPDIR:-/tmp}/mole.linux-scan.XXXXXX")
    {
        printf '%s\n' "$current_fingerprint"
        cat "$out_file"
    } > "$snapshot_file"
    if uninstall_acquire_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"; then
        uninstall_persist_cache_file "$snapshot_file" "$MOLE_UNINSTALL_LINUX_CACHE_FILE"
        uninstall_release_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"
    else
        rm -f "$snapshot_file"
    fi

    register_temp_file "$out_file"
    echo "$out_file"
}

load_applications() {
    local apps_file="$1"

    if [[ ! -f "$apps_file" || ! -s "$apps_file" ]]; then
        log_warning "No applications found for uninstallation"
        return 1
    fi

    apps_data=()
    selection_state=()

    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
        # Flatpak rows target ~/.var/app/<id> which may not exist yet;
        # identity is re-verified before any destructive side effect.
        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
        selection_state+=(false)
    done < "$apps_file"


    if [[ ${#apps_data[@]} -eq 0 ]]; then
        log_warning "No applications available for uninstallation"
        return 1
    fi

    return 0
}

# Keep the scan and selector on one alternate screen so restoring the terminal
# also restores the primary-screen cursor to the command's original row.
start_uninstall_interactive_screen() {
    if [[ -t 1 && -t 2 && "${MOLE_ALT_SCREEN_ACTIVE:-}" != "1" ]]; then
        enter_alt_screen
        export MOLE_ALT_SCREEN_ACTIVE=1
        export MOLE_MANAGED_ALT_SCREEN=1
        printf '\033[2J\033[H' >&2
    fi
}

stop_uninstall_interactive_screen() {
    if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
        leave_alt_screen
    fi
    unset MOLE_ALT_SCREEN_ACTIVE MOLE_MANAGED_ALT_SCREEN
}

# Surface an abort during scan/load/selection instead of returning to the
# prompt as if the run had succeeded. Interactive mode renders on an alternate
# screen, so the reason has to be printed after the screen is restored (#1339).
uninstall_abort() {
    local reason="$1"
    stop_uninstall_interactive_screen
    show_cursor
    log_error "Uninstall aborted: $reason"
}

# Cleanup: restore cursor and kill keepalive.
cleanup() {
    local exit_code="${1:-$?}"
    stop_uninstall_interactive_screen
    if [[ -n "${sudo_keepalive_pid:-}" ]]; then
        kill "$sudo_keepalive_pid" 2> /dev/null || true
        wait "$sudo_keepalive_pid" 2> /dev/null || true
        sudo_keepalive_pid=""
    fi
    # Log session end
    log_operation_session_end "uninstall" "${files_cleaned:-0}" "${total_size_cleaned:-0}"
    show_cursor
    exit "$exit_code"
}

trap cleanup EXIT INT TERM

# Match app names from scan data against user-provided search terms.
# Performs case-insensitive substring matching on app display names.
# Returns matched entries from apps_data in selected_apps.
match_apps_by_name() {
    local -a search_terms=("$@")
    selected_apps=()
    local -a matched_indices=()

    # `mo uninstall Tor Browser` arrives as two words. Matching each word
    # alone sent "Tor" into a substring hit on WebSTORm while the app the
    # user actually named sat in the list (#1365). When the words joined
    # with spaces exactly match an installed app's display or directory
    # name, that is the query, UNLESS every word already exactly names its
    # own installed app: with Foo.app, Bar.app, and "Foo Bar.app" all
    # present, `mo uninstall Foo Bar` keeps its original two-app meaning
    # rather than silently collapsing into the third.
    if [[ ${#search_terms[@]} -gt 1 ]]; then
        local every_word_exact=true
        local word word_lower word_app word_hit
        for word in "${search_terms[@]}"; do
            word_lower=$(echo "$word" | tr '[:upper:]' '[:lower:]')
            word_hit=false
            for word_app in "${apps_data[@]}"; do
                IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$word_app"
                local word_name_lower word_dir_lower
                word_name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
                word_dir_lower=$(basename "$app_path" .app | tr '[:upper:]' '[:lower:]')
                if [[ "$word_name_lower" == "$word_lower" || "$word_dir_lower" == "$word_lower" ]]; then
                    word_hit=true
                    break
                fi
            done
            if [[ "$word_hit" == "false" ]]; then
                every_word_exact=false
                break
            fi
        done
        if [[ "$every_word_exact" == "false" ]]; then
            local joined_lower
            joined_lower=$(echo "$*" | tr '[:upper:]' '[:lower:]')
            local joined_app
            for joined_app in "${apps_data[@]}"; do
                IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$joined_app"
                local joined_name_lower joined_dir_lower
                joined_name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
                joined_dir_lower=$(basename "$app_path" .app | tr '[:upper:]' '[:lower:]')
                if [[ "$joined_name_lower" == "$joined_lower" || "$joined_dir_lower" == "$joined_lower" ]]; then
                    selected_apps=("$joined_app")
                    return 0
                fi
            done
        fi
    fi

    for search_term in "${search_terms[@]}"; do
        local search_lower
        search_lower=$(echo "$search_term" | tr '[:upper:]' '[:lower:]')
        # Escape glob characters to prevent pattern injection
        search_lower=${search_lower//\\/\\\\}
        search_lower=${search_lower//\*/\\*}
        search_lower=${search_lower//\?/\\?}
        search_lower=${search_lower//\[/\\[}
        local found=false
        local idx=0
        for app_data in "${apps_data[@]}"; do
            IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$app_data"
            local name_lower
            name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
            # Also try matching against the .app directory base name
            local dir_name
            dir_name=$(basename "$app_path" .app)
            local dir_lower
            dir_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')

            if [[ "$name_lower" == "$search_lower" || "$dir_lower" == "$search_lower" ]]; then
                # Exact match - prefer this
                local already=false
                local mi
                for mi in "${matched_indices[@]+"${matched_indices[@]}"}"; do
                    [[ -z "$mi" ]] && continue
                    [[ "$mi" == "$idx" ]] && already=true && break
                done
                if [[ "$already" == "false" ]]; then
                    selected_apps+=("$app_data")
                    matched_indices+=("$idx")
                fi
                found=true
                break
            fi
            idx=$((idx + 1))
        done

        # If no exact match, try substring match
        if [[ "$found" == "false" ]]; then
            idx=0
            for app_data in "${apps_data[@]}"; do
                IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$app_data"
                local name_lower
                name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
                local dir_name
                dir_name=$(basename "$app_path" .app)
                local dir_lower
                dir_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')

                if [[ "$name_lower" == *"$search_lower"* || "$dir_lower" == *"$search_lower"* ]]; then
                    local already=false
                    local mi
                    for mi in "${matched_indices[@]+"${matched_indices[@]}"}"; do
                        [[ -z "$mi" ]] && continue
                        [[ "$mi" == "$idx" ]] && already=true && break
                    done
                    if [[ "$already" == "false" ]]; then
                        selected_apps+=("$app_data")
                        matched_indices+=("$idx")
                    fi
                    found=true
                fi
                idx=$((idx + 1))
            done
        fi

        if [[ "$found" == "false" ]]; then
            echo -e "${YELLOW}Warning:${NC} No application found matching '$search_term'"
        fi
    done
}

# Escape a value for embedding in a single-line JSON string. Only handles
# the chars that would break a one-line value: backslash, quote, and C0
# whitespace. Bundle IDs / display names never contain control bytes worth
# preserving in this output.
uninstall_list_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\n'/ }"
    printf '%s' "$s"
}

# Read-only listing: surface each installed app's display name, bundle id,
# the exact name `mo uninstall` accepts, and human-readable size. Reuses the
# existing scanner so the output stays in lockstep with what the destructive
# path sees.
uninstall_list_apps() {
    local apps_file=""
    if ! apps_file=$(scan_applications); then
        uninstall_abort "could not complete the application scan"
        return 1
    fi
    if [[ ! -f "$apps_file" ]]; then
        uninstall_abort "application scan produced no list"
        return 1
    fi
    if ! load_applications "$apps_file"; then
        rm -f "$apps_file"
        uninstall_abort "no applications available for uninstallation"
        return 1
    fi
    rm -f "$apps_file"

    # Auto-switch to JSON when stdout is piped, matching `mo status`.
    local format="text"
    if [[ ! -t 1 ]]; then
        format="json"
    fi

    if [[ "$format" == "json" ]]; then
        printf '['
        local first=1
        local app_data
        for app_data in "${apps_data[@]+"${apps_data[@]}"}"; do
            IFS='|' read -r _ app_path app_name bundle_id size _ _ <<< "$app_data"
            local uninstall_name="$app_name"
            local source_label="App"
            local size_display
            size_display=$(uninstall_normalize_size_display "$size" "$app_path")
            if [[ $first -eq 1 ]]; then
                first=0
                printf '\n'
            else
                printf ',\n'
            fi
            printf '  {"name": "%s", "bundle_id": "%s", "source": "%s", "uninstall_name": "%s", "path": "%s", "size": "%s"}' \
                "$(uninstall_list_json_escape "$app_name")" \
                "$(uninstall_list_json_escape "$bundle_id")" \
                "$source_label" \
                "$(uninstall_list_json_escape "$uninstall_name")" \
                "$(uninstall_list_json_escape "$app_path")" \
                "$(uninstall_list_json_escape "$size_display")"
        done
        if [[ $first -eq 0 ]]; then
            printf '\n'
        fi
        printf ']\n'
        return 0
    fi

    local total=${#apps_data[@]}
    if [[ $total -eq 0 ]]; then
        echo "No applications found."
        return 0
    fi

    printf '\n'
    printf '%-36s %-30s %-30s %8s\n' 'NAME' 'BUNDLE ID' 'UNINSTALL NAME' 'SIZE'
    printf -- '-%.0s' $(seq 1 108)
    printf '\n'

    local app_data
    for app_data in "${apps_data[@]+"${apps_data[@]}"}"; do
        IFS='|' read -r _ app_path app_name bundle_id size _ _ <<< "$app_data"
        local uninstall_name="$app_name"
        local size_display
        size_display=$(uninstall_normalize_size_display "$size" "$app_path")

        # Truncate by display columns, then adjust printf width for CJK.
        # printf counts bytes (LC_ALL=C), but CJK chars are 3 bytes yet only
        # 2 display columns wide, so we pad with the extra bytes to land on
        # the correct visual column.
        local name_trunc name_display_w name_byte_count name_printf_w
        name_trunc=$(truncate_by_display_width "$app_name" 34)
        name_display_w=$(get_display_width "$name_trunc")

        # Get byte count in C locale for printf
        local old_lc="${LC_ALL:-}"
        export LC_ALL=C
        name_byte_count=${#name_trunc}
        if [[ -n "$old_lc" ]]; then
            export LC_ALL="$old_lc"
        else
            unset LC_ALL
        fi

        name_printf_w=$((36 + name_byte_count - name_display_w))

        printf "%-*s %-30s %-30s %8s\n" \
            "$name_printf_w" "$name_trunc" \
            "${bundle_id:0:28}" \
            "${uninstall_name:0:28}" \
            "$size_display"
    done

    printf '\n%d application(s)  |  Remove with: mo uninstall <UNINSTALL NAME>\n\n' "$total"
    return 0
}

main() {
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="uninstall"
    log_operation_session_start "uninstall"

    # Default to Trash routing so an accidental uninstall is recoverable.
    # The caller can opt back into rm -rf with --permanent. See #723.
    export MOLE_DELETE_MODE="${MOLE_DELETE_MODE:-trash}"

    # Parse flags and collect app name arguments
    local -a app_name_args=()
    local list_mode=0
    for arg in "$@"; do
        case "$arg" in
            "--help" | "-h")
                show_uninstall_help
                exit 0
                ;;
            "--debug")
                export MO_DEBUG=1
                ;;
            "--dry-run" | "-n")
                export MOLE_DRY_RUN=1
                ;;
            "--permanent")
                export MOLE_DELETE_MODE="permanent"
                ;;
            "--list")
                list_mode=1
                ;;
            "--whitelist")
                echo "Unknown uninstall option: $arg"
                echo "Whitelist management is currently supported by: mo clean --whitelist / mo optimize --whitelist"
                echo "Use 'mo uninstall --help' for supported options."
                exit 1
                ;;
            -*)
                echo "Unknown uninstall option: $arg"
                echo "Use 'mo uninstall --help' for supported options."
                exit 1
                ;;
            *)
                app_name_args+=("$arg")
                ;;
        esac
    done

    # --list short-circuits before any destructive code. Read-only path:
    # scan, resolve uninstall names, print table or JSON, exit 0.
    if [[ $list_mode -eq 1 ]]; then
        uninstall_list_apps
        return $?
    fi

    hide_cursor
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, No app files or settings will be modified"
        printf '\n'
    fi

    # Direct uninstall by app name
    if [[ ${#app_name_args[@]} -gt 0 ]]; then
        local apps_file=""
        if ! apps_file=$(scan_applications); then
            uninstall_abort "could not complete the application scan"
            return 1
        fi
        if [[ ! -f "$apps_file" ]]; then
            uninstall_abort "application scan produced no list"
            return 1
        fi
        if ! load_applications "$apps_file"; then
            rm -f "$apps_file"
            uninstall_abort "no applications available for uninstallation"
            return 1
        fi

        match_apps_by_name "${app_name_args[@]}"
        rm -f "$apps_file"

        if [[ ${#selected_apps[@]} -eq 0 ]]; then
            show_cursor
            echo "No matching applications found."
            return 1
        fi

        show_cursor
        clear_screen
        local selection_count=${#selected_apps[@]}
        echo -e "${BLUE}${ICON_CONFIRM}${NC} Matched ${selection_count} app(s):"
        local index=1
        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r _ app_path app_name _ size last_used _ <<< "$selected_app"
            local size_display
            size_display=$(uninstall_normalize_size_display "$size" "$app_path")
            local last_display
            last_display=$(uninstall_normalize_last_used_display "$last_used")
            printf "%d. %s  %s  |  Last: %s\n" "$index" "$app_name" "$size_display" "$last_display"
            ((index++))
        done

        printf '\n'
        printf "Proceed with uninstallation? [y/N] "
        local confirm
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Aborted."
            return 0
        fi

        batch_uninstall_applications
        return 0
    fi

    local first_scan=true
    local cached_apps_file=""
    local cached_inventory_fingerprint=""
    unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN MOLE_ALT_SCREEN_ACTIVE
    while true; do
        unset MOLE_INLINE_LOADING

        # Keep scanning and selection on one alternate screen. Entering the
        # selector only after the scan leaves the primary-screen cursor below
        # the scan progress; restoring it on cancel then creates a large blank
        # gap before the next shell prompt (#1194).
        start_uninstall_interactive_screen

        if [[ $first_scan == false ]]; then
            echo -e "${GRAY}Checking application list...${NC}" >&2
        fi
        first_scan=false

        local apps_file=""
        local reused_app_cache=false
        if [[ -n "$cached_apps_file" && -f "$cached_apps_file" && -n "$cached_inventory_fingerprint" ]]; then
            local current_inventory_fingerprint
            current_inventory_fingerprint=$(uninstall_app_inventory_fingerprint 2> /dev/null || echo "")
            if uninstall_inventory_can_reuse_cached_apps "$cached_inventory_fingerprint" "$current_inventory_fingerprint"; then
                apps_file="$cached_apps_file"
                reused_app_cache=true
                cached_inventory_fingerprint="$current_inventory_fingerprint"
            fi
        fi

        if [[ "$reused_app_cache" != "true" ]]; then
            if [[ -n "$cached_apps_file" && -f "$cached_apps_file" ]]; then
                rm -f "$cached_apps_file" 2> /dev/null || true
            fi

            local scan_abort_reason=""
            if ! apps_file=$(scan_applications); then
                scan_abort_reason="could not complete the application scan"
            elif [[ ! -f "$apps_file" ]]; then
                scan_abort_reason="application scan produced no list"
            fi
            if [[ -n "$scan_abort_reason" ]]; then
                uninstall_abort "$scan_abort_reason"
                rm -f "$apps_file"
                [[ "$apps_file" == "$cached_apps_file" ]] && cached_apps_file=""
                return 1
            fi

            cached_apps_file="$apps_file"
            cached_inventory_fingerprint=$(uninstall_app_inventory_fingerprint 2> /dev/null || echo "")
        fi

        if ! load_applications "$apps_file"; then
            rm -f "$apps_file"
            [[ "$apps_file" == "$cached_apps_file" ]] && cached_apps_file=""
            uninstall_abort "no applications available for uninstallation"
            return 1
        fi

        # Keystrokes typed during the scan/load phase must not leak into the
        # selector. A queued Enter would confirm whichever app is highlighted
        # first and drop the user straight into the destructive path. See #726.
        drain_pending_input 0.2

        set +e
        select_apps_for_uninstall
        local exit_code=$?
        set -e

        if [[ $exit_code -ne 0 ]]; then
            rm -f "$apps_file"
            [[ "$apps_file" == "$cached_apps_file" ]] && cached_apps_file=""
            if [[ "${_MOLE_MENU_USER_QUIT:-0}" == "1" ]]; then
                # A deliberate q is a cancel, not a failure: leave quietly
                # with success, matching mole's other cancel flows. Only a
                # selector that broke gets the visible abort below.
                stop_uninstall_interactive_screen
                show_cursor
                return 0
            fi
            uninstall_abort "application selection did not complete"
            return 1
        fi

        stop_uninstall_interactive_screen
        show_cursor
        clear_screen
        printf '\033[2J\033[H' >&2
        local selection_count=${#selected_apps[@]}
        if [[ $selection_count -eq 0 ]]; then
            echo "No apps selected"
            continue
        fi
        echo -e "${BLUE}${ICON_CONFIRM}${NC} Selected ${selection_count} apps:"
        local -a summary_rows=()
        local max_name_display_width=0
        local max_size_width=0
        local max_last_width=0
        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r _ app_path app_name _ size last_used _ <<< "$selected_app"
            local name_width=$(get_display_width "$app_name")
            [[ $name_width -gt $max_name_display_width ]] && max_name_display_width=$name_width
            local size_display
            size_display=$(uninstall_normalize_size_display "$size" "$app_path")
            [[ ${#size_display} -gt $max_size_width ]] && max_size_width=${#size_display}
            local last_display
            last_display=$(uninstall_normalize_last_used_display "$last_used")
            [[ ${#last_display} -gt $max_last_width ]] && max_last_width=${#last_display}
        done
        ((max_size_width < 5)) && max_size_width=5
        ((max_last_width < 5)) && max_last_width=5
        ((max_name_display_width < 16)) && max_name_display_width=16

        local term_width=$(tput cols 2> /dev/null || echo 100)
        local available_for_name=$((term_width - 17 - max_size_width - max_last_width))

        local min_name_width=24
        if [[ $term_width -ge 120 ]]; then
            min_name_width=50
        elif [[ $term_width -ge 100 ]]; then
            min_name_width=42
        elif [[ $term_width -ge 80 ]]; then
            min_name_width=30
        fi

        local name_trunc_limit=$max_name_display_width
        [[ $name_trunc_limit -lt $min_name_width ]] && name_trunc_limit=$min_name_width
        [[ $name_trunc_limit -gt $available_for_name ]] && name_trunc_limit=$available_for_name
        [[ $name_trunc_limit -gt 60 ]] && name_trunc_limit=60

        max_name_display_width=0

        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$selected_app"

            local display_name
            display_name=$(truncate_by_display_width "$app_name" "$name_trunc_limit")

            local current_width
            current_width=$(get_display_width "$display_name")
            [[ $current_width -gt $max_name_display_width ]] && max_name_display_width=$current_width

            local size_display
            size_display=$(uninstall_normalize_size_display "$size" "$app_path")

            local last_display
            last_display=$(uninstall_normalize_last_used_display "$last_used")

            summary_rows+=("$display_name|$size_display|$last_display")
        done

        ((max_name_display_width < 16)) && max_name_display_width=16

        local index=1
        for row in "${summary_rows[@]}"; do
            IFS='|' read -r name_cell size_cell last_cell <<< "$row"
            local name_display_width
            name_display_width=$(get_display_width "$name_cell")

            # Get byte count for printf width calculation
            local old_lc="${LC_ALL:-}"
            export LC_ALL=C
            local name_byte_count=${#name_cell}
            if [[ -n "$old_lc" ]]; then
                export LC_ALL="$old_lc"
            else
                unset LC_ALL
            fi

            local padding_needed=$((max_name_display_width - name_display_width))
            local printf_name_width=$((name_byte_count + padding_needed))

            printf "%d. %-*s  %*s  |  Last: %s\n" "$index" "$printf_name_width" "$name_cell" "$max_size_width" "$size_cell" "$last_cell"
            ((index++))
        done

        batch_uninstall_applications

        # A nested command may have returned the controlling terminal to the
        # parent shell. Reading while Mole is no longer the foreground process
        # group would suspend the completed uninstall with SIGTTIN. The removal
        # is already finished, so exit cleanly instead of touching terminal input.
        if ! mole_tty_is_foreground; then
            show_cursor
            return 0
        fi

        local _countdown=5
        local _key=""
        local _pressed=false
        while [[ $_countdown -gt 0 ]]; do
            printf "\r${GRAY}Press Enter to return to the app list, press q to exit (%d)${NC} " "$_countdown"
            if IFS= read -r -s -n1 -t 1 _key; then
                _pressed=true
                break
            fi
            ((_countdown--))
        done
        printf "\n"
        drain_pending_input

        if [[ "$_pressed" == "true" && -z "$_key" ]]; then
            :
        else
            show_cursor
            return 0
        fi

    done
}

# Run only when executed; sourcing loads definitions for tests. Kept on one
# line because test harnesses slice this file with sed/awk anchored on the
# `main "$@"` sentinel, and a multi-line guard leaves them an unclosed `if`.
[[ "${BASH_SOURCE[0]}" != "$0" ]] || main "$@"
