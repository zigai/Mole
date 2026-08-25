#!/bin/bash
# Linux user-level cleanup for `mo clean`.
#
# Sourced by bin/clean.sh after the core stack. Every deletion goes through
# the shared funnel (safe_clean / safe_remove), so whitelist rules, protected
# paths, dry-run ledger records, and operation logs behave exactly like the
# macOS flow. Distro capability functions (distro_*) come from
# lib/platform/linux/<distro>.sh via the platform contract; when they are not
# available the corresponding step stays silent instead of failing.
set -euo pipefail

# Browser cache roots under $XDG_CACHE_HOME handled by their own labeled step.
# The generic user-cache sweep skips them so items are never counted twice.
# shellcheck disable=SC2199  # Fixed whitelist, expanded once at use sites.
_LINUX_BROWSER_CACHE_PATTERNS=(
    "google-chrome*"
    "chromium*"
    "firefox*"
    "brave*"
    "microsoft-edge*"
    "edge*"
    "opera*"
    "vivaldi*"
)

_linux_cache_home() {
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}"
}

_linux_trash_dir() {
    # Env override exists for tests; see tests/linux_clean_*.bats.
    printf '%s\n' "${MOLE_LINUX_TRASH_DIR:-$HOME/.local/share/Trash}"
}

# True when the candidate is Mole's own state or cache directory. Sweeps must
# never remove Mole's ledger, logs, or preview files out from under a run.
_linux_path_is_mole_owned() {
    local candidate="$1"
    local owned=""
    if declare -F mole_state_dir > /dev/null 2>&1; then
        owned=$(mole_state_dir 2> /dev/null || true)
        case "$candidate" in
            "$owned" | "$owned"/*) return 0 ;;
        esac
    fi
    if declare -F mole_cache_dir > /dev/null 2>&1; then
        owned=$(mole_cache_dir 2> /dev/null || true)
        case "$candidate" in
            "$owned" | "$owned"/*) return 0 ;;
        esac
    fi
    return 1
}

# True when the basename matches one of the browser cache patterns above.
_linux_is_browser_cache_name() {
    local name="$1"
    local pattern
    for pattern in "${_LINUX_BROWSER_CACHE_PATTERNS[@]}"; do
        # shellcheck disable=SC2254  # pattern comes from a fixed whitelist
        case "$name" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

# Sweep rebuildable caches under ~/.cache, excluding Mole's own directories
# and the browser roots that clean_linux_browser_caches reports separately.
clean_linux_user_cache_sweep() {
    local cache_home
    cache_home=$(_linux_cache_home)
    [[ -d "$cache_home" ]] || return 0

    start_section_spinner "Scanning user caches..."
    local -a targets=()
    local entry name matched
    for entry in "$cache_home"/* "$cache_home"/.[!.]*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        if _linux_path_is_mole_owned "$entry"; then
            continue
        fi
        name="${entry##*/}"
        if _linux_is_browser_cache_name "$name"; then
            continue
        fi
        targets+=("$entry")
    done

    if [[ ${#targets[@]} -gt 0 ]]; then
        safe_clean "${targets[@]}" "User cache"
    fi
    stop_section_spinner
}

# Empty the XDG Trash (~/.local/share/Trash/files plus its .trashinfo
# metadata) through the existing delete layer. gio routing itself belongs to
# file_ops.sh; this step only enumerates and hands over top-level entries.
clean_linux_trash() {
    local trash_dir
    trash_dir=$(_linux_trash_dir)
    [[ -d "$trash_dir" ]] || return 0
    if is_path_whitelisted "$trash_dir"; then
        return 0
    fi
    stop_section_spinner

    local -a data_items=()
    local -a info_items=()
    local sub item
    for sub in files info; do
        [[ -d "$trash_dir/$sub" ]] || continue
        while IFS= read -r -d '' item; do
            [[ -n "$item" ]] || continue
            if [[ "$sub" == "files" ]]; then
                data_items+=("$item")
            else
                info_items+=("$item")
            fi
        done < <(command find "$trash_dir/$sub" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
    done

    if [[ ${#data_items[@]} -eq 0 && ${#info_items[@]} -eq 0 ]]; then
        debug_log "Trash already empty"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        local preview_count=0
        local item_kb
        local size_rc=0
        for item in "${data_items[@]}"; do
            if should_protect_path "$item" 2> /dev/null ||
                is_path_whitelisted "$item" 2> /dev/null; then
                continue
            fi
            item_kb=0
            size_rc=0
            item_kb=$(get_path_size_kb "$item" 2> /dev/null) || size_rc=$?
            [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
            [[ $size_rc -eq 0 ]] || return "$size_rc"
            [[ "$item_kb" =~ ^[0-9]+$ ]] || item_kb=0
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$item" "$item_kb" 1 true || continue
            fi
            preview_count=$((preview_count + 1))
        done
        if [[ $preview_count -gt 0 ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Trash · would empty, $preview_count items"
            note_activity
        fi
        return 0
    fi

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Emptying trash..."
    fi

    local cleaned_count=0
    for item in "${data_items[@]}"; do
        if safe_remove "$item" true; then
            cleaned_count=$((cleaned_count + 1))
        fi
    done
    for item in "${info_items[@]}"; do
        safe_remove "$item" true > /dev/null 2>&1 || true
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ $cleaned_count -gt 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Trash · emptied, $cleaned_count items"
        note_activity
    fi
}

# Sweep browser cache roots (Chromium-family, Firefox) one level down so each
# profile cache directory is removed but the profile root stays in place.
clean_linux_browser_caches() {
    local cache_home
    cache_home=$(_linux_cache_home)
    [[ -d "$cache_home" ]] || return 0

    local -a roots=()
    local entry name
    for entry in "$cache_home"/*; do
        [[ -d "$entry" ]] || continue
        name="${entry##*/}"
        if _linux_is_browser_cache_name "$name"; then
            roots+=("$entry")
        fi
    done
    [[ ${#roots[@]} -gt 0 ]] || return 0

    start_section_spinner "Scanning browser caches..."
    local -a targets=()
    local root child
    for root in "${roots[@]}"; do
        for child in "$root"/* "$root"/.[!.]*; do
            [[ -e "$child" || -L "$child" ]] || continue
            targets+=("$child")
        done
    done

    if [[ ${#targets[@]} -gt 0 ]]; then
        safe_clean "${targets[@]}" "Browser cache"
    fi
    stop_section_spinner
}

# Sweep AUR helper download caches reported by the distro module
# (for example ~/.cache/yay and ~/.cache/paru on Arch).
clean_linux_aur_caches() {
    declare -F distro_aur_cache_dirs > /dev/null 2>&1 || return 0
    local dirs_raw=""
    dirs_raw=$(distro_aur_cache_dirs 2> /dev/null || true)
    [[ -n "$dirs_raw" ]] || return 0

    local -a targets=()
    local dir child
    while IFS= read -r dir; do
        [[ -n "$dir" && -d "$dir" ]] || continue
        for child in "$dir"/* "$dir"/.[!.]*; do
            [[ -e "$child" || -L "$child" ]] || continue
            if _linux_path_is_mole_owned "$child"; then
                continue
            fi
            targets+=("$child")
        done
    done <<< "$dirs_raw"

    [[ ${#targets[@]} -gt 0 ]] || return 0
    safe_clean "${targets[@]}" "AUR helper cache"
}
