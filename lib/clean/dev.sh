#!/bin/bash
# Developer Tools Cleanup Module
set -euo pipefail

# Tool cache helper (respects DRY_RUN and whitelist).
# Args:
#   $1 = description (display name)
#   $2 = cache path to check against whitelist (empty string to skip check)
#   $3+ = command to run
clean_tool_cache() {
    local description="$1"
    local cache_path="$2"
    shift 2

    if [[ -n "$cache_path" ]] && is_path_whitelisted "$cache_path"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $description · would skip (whitelist)"
            note_activity
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $description · skipped (whitelist)"
            note_activity
        fi
        return 0
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        local command_succeeded=false
        if [[ -t 1 ]]; then
            start_section_spinner "Cleaning $description..."
        fi
        if "$@" > /dev/null 2>&1; then
            command_succeeded=true
        fi
        if [[ -t 1 ]]; then
            stop_section_spinner
        fi
        if [[ "$command_succeeded" == "true" ]]; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $description"
            note_activity
        fi
    else
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $description · would clean"
        note_activity
    fi
    return 0
}

clean_corepack_cache() {
    local corepack_home="${COREPACK_HOME:-$HOME/.cache/node/corepack}"
    [[ -n "$corepack_home" && "$corepack_home" == /* ]] || return 0
    case "$corepack_home" in
        / | "$HOME" | "$HOME/")
            debug_log "Skipping unsafe Corepack cache path: $corepack_home"
            return 0
            ;;
    esac
    # COREPACK_ENABLE_DOWNLOAD_PROMPT=0 mirrors the pnpm path above: without it
    # corepack can stop on an interactive "download? [Y/n]" prompt. Because the
    # call is wrapped with stdout/stderr to /dev/null, that prompt is invisible
    # and the command looks frozen until the timeout fires (seen on a Node setup
    # where corepack is installed; machines without corepack take the else
    # branch and never hit this).
    if command -v corepack > /dev/null 2>&1 && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" corepack --version > /dev/null 2>&1; then
        COREPACK_ENABLE_DOWNLOAD_PROMPT=0 clean_tool_cache "Corepack cache" "$corepack_home" run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" corepack cache clean
    else
        safe_clean "$corepack_home"/* "Corepack cache"
    fi
}

clean_uv_cache() {
    local uv_cache_path="$HOME/.cache/uv"
    if command -v uv > /dev/null 2>&1 && run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" uv --version > /dev/null 2>&1; then
        local detected_cache
        detected_cache=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" uv cache dir 2> /dev/null || true)
        if [[ -n "$detected_cache" && "$detected_cache" == /* ]]; then
            uv_cache_path="$detected_cache"
        fi
        clean_tool_cache "uv cache" "$uv_cache_path" run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" uv cache prune
    else
        safe_clean "$uv_cache_path"/* "uv cache"
    fi
}

github_cli_process_state() {
    mole_pgrep_any -x gh
}

_run_github_cli_clear_cache_bound() {
    local cache_path="$1"
    local expected_parent="$2"
    local expected_parent_id="$3"
    local expected_target_id="$4"

    _MOLE_GITHUB_CLI_CLEAR_REASON=""
    local process_state=0
    github_cli_process_state || process_state=$?
    if [[ $process_state -eq 0 ]]; then
        _MOLE_GITHUB_CLI_CLEAR_REASON="owner active"
        return 1
    fi
    if [[ $process_state -ne 1 ]]; then
        _MOLE_GITHUB_CLI_CLEAR_REASON="process state unknown"
        return 1
    fi

    if ! _mole_path_matches_identity \
        "$cache_path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
        _MOLE_GITHUB_CLI_CLEAR_REASON="cache path changed"
        return 1
    fi

    local command_status=0
    run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" \
        env XDG_CACHE_HOME="$expected_parent" gh config clear-cache || command_status=$?
    if [[ $command_status -ne 0 && $command_status -ne 124 && $command_status -lt 128 ]]; then
        _MOLE_GITHUB_CLI_CLEAR_REASON="owner cleanup failed"
    fi
    return "$command_status"
}

clean_github_cli_cache() {
    local cache_root
    if ! cache_root=$(mole_github_cli_cache_root); then
        debug_log "Skipping GitHub CLI cache for unsafe XDG_CACHE_HOME: ${XDG_CACHE_HOME:-<unset>}"
        return 0
    fi

    local cache_path="$cache_root/gh"
    [[ -e "$cache_path" || -L "$cache_path" ]] || return 0
    if [[ ! -d "$cache_path" || -L "$cache_path" ]]; then
        debug_log "Skipping GitHub CLI cache because its cache leaf is not a real directory: $cache_path"
        return 0
    fi

    local cache_parent="${cache_path%/*}"
    local physical_parent
    if [[ ! -d "$cache_parent" ]] ||
        ! physical_parent=$(cd "$cache_parent" 2> /dev/null && pwd -P) ||
        [[ -z "$physical_parent" || "$physical_parent" != /* ]]; then
        debug_log "Skipping GitHub CLI cache because its physical parent could not be verified: $cache_path"
        return 0
    fi
    case "$physical_parent" in
        / | "$HOME")
            debug_log "Skipping GitHub CLI cache because its physical parent is unsafe: $physical_parent"
            return 0
            ;;
    esac
    local physical_cache_path="${physical_parent%/}/${cache_path##*/}"

    if ! _mole_snapshot_path_identity "$physical_cache_path" ||
        [[ "$_MOLE_PATH_SNAPSHOT_PARENT" != "$physical_parent" ]]; then
        debug_log "Skipping GitHub CLI cache because its identity could not be verified: $cache_path"
        return 0
    fi
    local expected_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local expected_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local expected_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"

    if ! validate_path_for_deletion "$cache_path" > /dev/null 2>&1 ||
        ! validate_path_for_deletion "$physical_cache_path" > /dev/null 2>&1; then
        debug_log "Skipping GitHub CLI cache because its path failed deletion policy: $cache_path"
        return 0
    fi

    local whitelist_path=""
    if is_path_whitelisted "$cache_path"; then
        whitelist_path="$cache_path"
    elif is_path_whitelisted "$physical_cache_path"; then
        whitelist_path="$physical_cache_path"
    fi
    if [[ -n "$whitelist_path" ]]; then
        clean_tool_cache "GitHub CLI cache" "$whitelist_path" :
        return 0
    fi
    if should_protect_path "$cache_path" 2> /dev/null || should_protect_path "$physical_cache_path" 2> /dev/null; then
        debug_log "Skipping protected GitHub CLI cache path: $cache_path"
        return 0
    fi

    command -v gh > /dev/null 2>&1 || return 0
    local _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard github_cli_process_state "GitHub CLI started"; then
        mole_report_guard_stop "GitHub CLI cache" mole_defer_cleanup_family "GitHub CLI"
        return 0
    fi
    local probe_status=0
    run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        env XDG_CACHE_HOME="$physical_parent" gh config clear-cache --help > /dev/null 2>&1 || probe_status=$?
    if [[ $probe_status -eq 124 || $probe_status -ge 128 ]]; then
        return "$probe_status"
    fi
    if [[ $probe_status -ne 0 ]]; then
        debug_log "Skipping GitHub CLI cache because gh config clear-cache is unavailable"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} GitHub CLI cache · would clean"
        note_activity
        return 0
    fi

    local _MOLE_GITHUB_CLI_CLEAR_REASON=""
    local clear_status=0
    if [[ -t 1 ]]; then
        start_section_spinner "Cleaning GitHub CLI cache..."
    fi
    _run_github_cli_clear_cache_bound "$physical_cache_path" \
        "$expected_parent" "$expected_parent_id" "$expected_target_id" \
        > /dev/null 2>&1 || clear_status=$?
    if [[ -t 1 ]]; then
        stop_section_spinner
    fi

    if [[ $clear_status -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} GitHub CLI cache"
        note_activity
        return 0
    fi
    if [[ $clear_status -eq 124 || $clear_status -ge 128 ]]; then
        return "$clear_status"
    fi

    case "$_MOLE_GITHUB_CLI_CLEAR_REASON" in
        "owner active")
            mole_defer_cleanup_family "GitHub CLI"
            ;;
        "process state unknown" | "cache path changed" | "owner cleanup failed")
            echo -e "  ${GRAY}${ICON_WARNING}${NC} GitHub CLI cache · stopped (${_MOLE_GITHUB_CLI_CLEAR_REASON})"
            note_activity
            ;;
        *)
            echo -e "  ${GRAY}${ICON_WARNING}${NC} GitHub CLI cache · stopped (owner cleanup failed)"
            note_activity
            ;;
    esac
    return 0
}

conda_cache_whitelisted() {
    local root
    for root in "$@"; do
        [[ -n "$root" ]] || continue
        if is_path_whitelisted "$root" 2> /dev/null || is_path_whitelisted "$root/.mole-cache-guard" 2> /dev/null; then
            return 0
        fi
    done
    return 1
}

clean_conda_metadata_caches() {
    local -a conda_pkg_roots=(
        "$HOME/.conda/pkgs"
        "$HOME/anaconda3/pkgs"
        "$HOME/miniconda3/pkgs"
        "$HOME/miniforge3/pkgs"
        "$HOME/mambaforge/pkgs"
    )
    if conda_cache_whitelisted "${conda_pkg_roots[@]}"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} conda index/tarball/log caches · would skip (whitelist)"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} conda index/tarball/log caches · skipped (whitelist)"
            note_activity
        fi
        return 0
    fi

    local conda_cache_hint="$HOME/.conda/pkgs"
    if command -v conda > /dev/null 2>&1 && run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" conda --version > /dev/null 2>&1; then
        clean_tool_cache "conda index/tarball/log caches" "$conda_cache_hint" \
            run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" conda clean --yes --index-cache --tarballs --logfiles
        note_activity
        return 0
    fi

    local root
    for root in "${conda_pkg_roots[@]}"; do
        [[ -d "$root" ]] || continue
        debug_log "Conda package cache present but conda is unavailable, leaving for manual review: $root"
    done
}

gradle_daemon_running() {
    mole_pgrep_any \
        -f "org.gradle.launcher.daemon" \
        -f "GradleDaemon"
}

# True when a pnpm process is running, or when process state cannot be
# determined (fail closed: skip prune rather than race a live install).
# shellcheck disable=SC2329
pnpm_process_blocks_prune() {
    if ! command -v pgrep > /dev/null 2>&1; then
        return 0
    fi
    # `-x pnpm` only sees the standalone binary. Corepack and npm-installed
    # pnpm run as `node .../pnpm.cjs`, so the guard it was written to be
    # (fail closed while an install is live) never fired for them. Match the
    # invoked program instead, delimited so `pnpm-lock.yaml` in some other
    # process's argv cannot block the prune forever.
    #
    # Capture pgrep's own status: after a failed `if pgrep; then`, $? is the
    # if-statement status (0), not pgrep's 1, which would false-positive block.
    local pgrep_rc=0
    pgrep -f '(^|/)pnpm(\.cjs)?([[:space:]]|$)' > /dev/null 2>&1 || pgrep_rc=$?
    # 0 = running (block), 1 = no match (allow), other = unknown (block).
    [[ $pgrep_rc -ne 1 ]]
}

# Absolute store path without ".." / control characters only.
# shellcheck disable=SC2329
is_safe_pnpm_store_path() {
    local path="${1:-}"
    [[ -n "$path" && "$path" == /* ]] || return 1
    case "$path" in
        *'/../'* | */.. | .. | *$'\n'* | *$'\r'*)
            return 1
            ;;
    esac
    return 0
}

# Emit candidate pnpm binaries already installed locally. Never downloads.
# Order: PATH pnpm first, then mise versioned installs. Callers dedupe by
# resolved store path (issue #1370).
# shellcheck disable=SC2329
list_installed_pnpm_binaries() {
    local bin=""
    if command -v pnpm > /dev/null 2>&1; then
        # type -P resolves only real files; shell-function stubs (tests) fall
        # back to the bare "pnpm" name still reachable on PATH.
        bin=$(type -P pnpm 2> /dev/null || true)
        if [[ -n "$bin" && -x "$bin" ]]; then
            printf '%s\n' "$bin"
        else
            printf '%s\n' "pnpm"
        fi
    fi

    local mise_root="$HOME/.local/share/mise/installs/pnpm"
    if [[ -d "$mise_root" ]]; then
        local version_dir
        for version_dir in "$mise_root"/*; do
            [[ -d "$version_dir" ]] || continue
            if [[ -x "$version_dir/pnpm" ]]; then
                printf '%s\n' "$version_dir/pnpm"
            fi
        done
    fi
}

# Prune every distinct pnpm store generation reachable through an already
# installed matching pnpm binary. Owner command only (plain `store prune`,
# no --force, no raw directory delete). Dedupes by store path so two
# binaries that resolve to the same generation run once (issue #1370).
# shellcheck disable=SC2329
clean_pnpm_stores() {
    if pnpm_process_blocks_prune; then
        debug_log "pnpm process running or process state unknown, skipping store prune"
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} pnpm cache · would skip (pnpm busy)"
            note_activity
        fi
        return 0
    fi

    local -a pnpm_bins=()
    local bin_line
    while IFS= read -r bin_line; do
        [[ -n "$bin_line" ]] || continue
        pnpm_bins+=("$bin_line")
    done < <(list_installed_pnpm_binaries)

    if [[ ${#pnpm_bins[@]} -eq 0 ]]; then
        debug_log "pnpm is unavailable, leaving global pnpm store for manual review"
        return 0
    fi

    local -a seen_stores=()
    local pruned_any=false
    local pnpm_bin store_path store_seen store_entry
    for pnpm_bin in "${pnpm_bins[@]}"; do
        # Usable binary only; never prompt Corepack to download another major.
        if ! COREPACK_ENABLE_DOWNLOAD_PROMPT=0 run_with_timeout \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$pnpm_bin" --version > /dev/null 2>&1; then
            debug_log "Skipping unusable pnpm binary: $pnpm_bin"
            continue
        fi

        start_section_spinner "Checking pnpm store path..."
        store_path=$(COREPACK_ENABLE_DOWNLOAD_PROMPT=0 run_with_timeout \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$pnpm_bin" store path 2> /dev/null) || store_path=""
        stop_section_spinner

        if ! is_safe_pnpm_store_path "$store_path"; then
            debug_log "Rejecting unsafe or empty pnpm store path from $pnpm_bin: ${store_path:-<empty>}"
            continue
        fi
        store_path="${store_path%/}"

        store_seen=false
        for store_entry in "${seen_stores[@]+"${seen_stores[@]}"}"; do
            if [[ "$store_entry" == "$store_path" ]]; then
                store_seen=true
                break
            fi
        done
        if [[ "$store_seen" == "true" ]]; then
            debug_log "pnpm store already scheduled: $store_path"
            continue
        fi
        seen_stores+=("$store_path")

        COREPACK_ENABLE_DOWNLOAD_PROMPT=0 clean_tool_cache "pnpm cache" "$store_path" \
            run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" \
            env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 "$pnpm_bin" store prune
        pruned_any=true
    done

    if [[ "$pruned_any" != "true" ]]; then
        debug_log "No pruneable pnpm store resolved from installed binaries"
    fi
}

# npm/pnpm/yarn/bun caches.
clean_dev_npm() {
    local npm_default_cache="$HOME/.npm"
    local npm_cache_path="$npm_default_cache"

    if command -v npm > /dev/null 2>&1; then
        start_section_spinner "Checking npm cache path..."
        npm_cache_path=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" npm config get cache 2> /dev/null) || npm_cache_path=""
        stop_section_spinner

        if [[ -z "$npm_cache_path" || "$npm_cache_path" != /* ]]; then
            npm_cache_path="$npm_default_cache"
        fi

        clean_tool_cache "npm cache" "$npm_cache_path" npm cache clean --force
        note_activity
    fi

    # These residual directories are not removed by `npm cache clean --force`
    local -a npm_residual_dirs=("_cacache" "_npx" "_logs" "_prebuilds")
    local -a npm_descriptions=("npm cache directory" "npm npx cache" "npm logs" "npm prebuilds")

    # Clean default npm cache path
    local i
    for i in "${!npm_residual_dirs[@]}"; do
        safe_clean "$npm_default_cache/${npm_residual_dirs[$i]}"/* "${npm_descriptions[$i]}"
    done

    # Normalize paths for comparison (remove trailing slash + resolve symlinked dirs)
    local npm_cache_path_normalized="${npm_cache_path%/}"
    local npm_default_cache_normalized="${npm_default_cache%/}"
    if [[ -d "$npm_cache_path_normalized" ]]; then
        npm_cache_path_normalized=$(cd "$npm_cache_path_normalized" 2> /dev/null && pwd -P) || npm_cache_path_normalized="${npm_cache_path%/}"
    fi
    if [[ -d "$npm_default_cache_normalized" ]]; then
        npm_default_cache_normalized=$(cd "$npm_default_cache_normalized" 2> /dev/null && pwd -P) || npm_default_cache_normalized="${npm_default_cache%/}"
    fi

    # Clean custom npm cache path (if different from default)
    if [[ "$npm_cache_path_normalized" != "$npm_default_cache_normalized" ]]; then
        for i in "${!npm_residual_dirs[@]}"; do
            safe_clean "$npm_cache_path/${npm_residual_dirs[$i]}"/* "${npm_descriptions[$i]} (custom path)"
        done
    fi

    clean_pnpm_stores
    clean_corepack_cache
    local bun_default_cache="$HOME/.bun/install/cache"
    local bun_cache_path="$bun_default_cache"
    local bun_cache_cleaned=false
    local bun_dry_run="${DRY_RUN:-false}"
    if command -v bun > /dev/null 2>&1 && bun --version > /dev/null 2>&1; then
        if [[ -t 1 ]]; then start_section_spinner "Checking bun cache path..."; fi
        bun_cache_path=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" bun pm cache 2> /dev/null) || bun_cache_path=""
        if [[ -t 1 ]]; then stop_section_spinner; fi

        if [[ -z "$bun_cache_path" || "$bun_cache_path" != /* ]]; then
            bun_cache_path="$bun_default_cache"
        fi

        local bun_protected=false
        is_path_whitelisted "$bun_cache_path" && bun_protected=true

        if [[ "$bun_protected" == "true" ]]; then
            if [[ "$bun_dry_run" == "true" ]]; then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} bun cache · would skip (whitelist)"
            else
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} bun cache · skipped (whitelist)"
                note_activity
            fi
            bun_cache_cleaned=true
        elif [[ "$bun_dry_run" != "true" ]]; then
            if [[ -t 1 ]]; then
                start_section_spinner "Cleaning bun cache..."
            fi
            if run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" bun pm cache rm > /dev/null 2>&1; then
                bun_cache_cleaned=true
            fi
            if [[ -t 1 ]]; then
                stop_section_spinner
            fi
            if [[ "$bun_cache_cleaned" == "true" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} bun cache"
                note_activity
            fi
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} bun cache · would clean"
            note_activity
            bun_cache_cleaned=true
        fi

        local bun_cache_path_normalized="${bun_cache_path%/}"
        local bun_default_cache_normalized="${bun_default_cache%/}"
        if [[ -d "$bun_cache_path_normalized" ]]; then
            bun_cache_path_normalized=$(cd "$bun_cache_path_normalized" 2> /dev/null && pwd -P) || bun_cache_path_normalized="${bun_cache_path%/}"
        fi
        if [[ -d "$bun_default_cache_normalized" ]]; then
            bun_default_cache_normalized=$(cd "$bun_default_cache_normalized" 2> /dev/null && pwd -P) || bun_default_cache_normalized="${bun_default_cache%/}"
        fi

        if [[ "$bun_cache_path_normalized" != "$bun_default_cache_normalized" ]]; then
            safe_clean "$bun_default_cache"/* "Orphaned bun cache"
        fi

        # If bun pm cache rm fails, fall back to filesystem cleanup to avoid no-op.
        if [[ "$bun_cache_cleaned" != "true" ]]; then
            safe_clean "$bun_cache_path"/* "Bun cache"
        fi
    else
        safe_clean "$bun_default_cache"/* "Bun cache"
    fi

    note_activity
    safe_clean ~/.tnpm/_cacache/* "tnpm cache directory"
    safe_clean ~/.tnpm/_logs/* "tnpm logs"
    safe_clean ~/.yarn/cache/* "Yarn cache"
}
# Resolve a cache root to its physical location and prove that it remains a
# descendant of its owner container. Both directories must be ordinary,
# invoking-user-owned directories; user-managed redirect symlinks are kept.
guarded_dev_cache_root_physical_path() {
    local container_root="${1%/}"
    local cache_root="${2%/}"

    [[ "$container_root" == /* && "$cache_root" == /* ]] || return 1
    [[ ! "$container_root" =~ [[:cntrl:]] && ! "$cache_root" =~ [[:cntrl:]] ]] || return 1
    case "$container_root" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac
    case "$cache_root" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac
    [[ -d "$container_root" && ! -L "$container_root" ]] || return 1
    [[ -d "$cache_root" && ! -L "$cache_root" ]] || return 1

    local physical_container physical_root invoking_uid container_uid root_uid
    physical_container=$(cd -P "$container_root" 2> /dev/null && pwd -P) || return 1
    physical_root=$(cd -P "$cache_root" 2> /dev/null && pwd -P) || return 1
    [[ "$physical_container" != "/" ]] || return 1
    case "$physical_root" in
        "$physical_container"/*) ;;
        *) return 1 ;;
    esac

    invoking_uid=$(get_invoking_uid 2> /dev/null) || return 1
    [[ "$invoking_uid" =~ ^[0-9]+$ ]] || return 1
    container_uid=$($STAT_BSD "${_MOLE_STAT_UID_FLAG}" "$physical_container" 2> /dev/null) || return 1
    root_uid=$($STAT_BSD "${_MOLE_STAT_UID_FLAG}" "$physical_root" 2> /dev/null) || return 1
    [[ "$container_uid" == "$invoking_uid" && "$root_uid" == "$invoking_uid" ]] || return 1
    should_protect_path "$cache_root" && return 1
    should_protect_path "$physical_root" && return 1

    printf '%s\n' "$physical_root"
}

# Compound sink-time guard for rebuildable developer caches. It rechecks both
# process ownership and the container/root/leaf identities immediately before
# safe_remove, so a path swap after discovery cannot redirect deletion.
guarded_dev_cache_cleanup_state() {
    local process_state=0
    "$_MOLE_DEV_CACHE_PROCESS_PROBE" || process_state=$?
    [[ $process_state -eq 1 ]] || return "$process_state"

    local physical_now=""
    physical_now=$(guarded_dev_cache_root_physical_path \
        "$_MOLE_DEV_CACHE_CONTAINER" "$_MOLE_DEV_CACHE_ROOT") || return 2
    [[ "$physical_now" == "$_MOLE_DEV_CACHE_PHYSICAL" ]] || return 2
    _mole_path_matches_identity \
        "$_MOLE_DEV_CACHE_CONTAINER" \
        "$_MOLE_DEV_CACHE_CONTAINER_PARENT" \
        "$_MOLE_DEV_CACHE_CONTAINER_PARENT_ID" \
        "$_MOLE_DEV_CACHE_CONTAINER_TARGET_ID" || return 2
    _mole_path_matches_identity \
        "$_MOLE_DEV_CACHE_ROOT" \
        "$_MOLE_DEV_CACHE_ROOT_PARENT" \
        "$_MOLE_DEV_CACHE_ROOT_PARENT_ID" \
        "$_MOLE_DEV_CACHE_ROOT_TARGET_ID" || return 2

    local guarded_path="${_MOLE_DEV_GUARDED_PATH:-}"
    if [[ -n "$guarded_path" ]]; then
        [[ ! -L "$guarded_path" ]] || return 2
        _mole_snapshot_path_identity "$guarded_path" || return 2
        [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "$physical_now" ]] || return 2

        local leaf_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
        local leaf_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        local leaf_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
        physical_now=$(guarded_dev_cache_root_physical_path \
            "$_MOLE_DEV_CACHE_CONTAINER" "$_MOLE_DEV_CACHE_ROOT") || return 2
        [[ "$physical_now" == "$_MOLE_DEV_CACHE_PHYSICAL" ]] || return 2
        _mole_path_matches_identity \
            "$_MOLE_DEV_CACHE_ROOT" \
            "$_MOLE_DEV_CACHE_ROOT_PARENT" \
            "$_MOLE_DEV_CACHE_ROOT_PARENT_ID" \
            "$_MOLE_DEV_CACHE_ROOT_TARGET_ID" || return 2

        _MOLE_SAFE_CLEAN_BOUND_PATH="$guarded_path"
        _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$leaf_parent"
        _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$leaf_parent_id"
        _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$leaf_target_id"
    fi
    return 1
}

clean_guarded_dev_cache_root() {
    local container_root="${1%/}"
    local cache_root="${2%/}"
    local process_probe="$3"
    local family="$4"
    local display_name="$5"
    shift 5
    [[ $# -gt 0 ]] || return 0
    mole_cleanup_targets_exist "$@" || return 0

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard "$process_probe" "$family started"; then
        mole_report_guard_stop "$display_name" mole_defer_cleanup_family "$family"
        return 0
    fi

    local physical_root=""
    if ! physical_root=$(guarded_dev_cache_root_physical_path "$container_root" "$cache_root"); then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi

    if ! _mole_snapshot_path_identity "$container_root"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi
    local container_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local container_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local container_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    if ! _mole_snapshot_path_identity "$cache_root"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi
    local root_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local root_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local root_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"

    local _MOLE_DEV_CACHE_CONTAINER="$container_root"
    local _MOLE_DEV_CACHE_ROOT="$cache_root"
    local _MOLE_DEV_CACHE_PHYSICAL="$physical_root"
    local _MOLE_DEV_CACHE_CONTAINER_PARENT="$container_parent"
    local _MOLE_DEV_CACHE_CONTAINER_PARENT_ID="$container_parent_id"
    local _MOLE_DEV_CACHE_CONTAINER_TARGET_ID="$container_target_id"
    local _MOLE_DEV_CACHE_ROOT_PARENT="$root_parent"
    local _MOLE_DEV_CACHE_ROOT_PARENT_ID="$root_parent_id"
    local _MOLE_DEV_CACHE_ROOT_TARGET_ID="$root_target_id"
    local _MOLE_DEV_CACHE_PROCESS_PROBE="$process_probe"
    local _MOLE_DEV_PROCESS_GUARD_UNKNOWN_REASON="process or cache path state unknown"
    local clean_rc=0
    _dev_safe_clean_process_guarded \
        guarded_dev_cache_cleanup_state \
        "$family" \
        "$display_name" \
        "$@" \
        "$display_name" || clean_rc=$?
    [[ $clean_rc -eq 1 ]] && return 0
    return "$clean_rc"
}

# Python/pip ecosystem caches.
clean_dev_python() {
    # Check pip3 is functional before trusting its cache-dir output.
    if command -v pip3 > /dev/null 2>&1 && pip3 --version > /dev/null 2>&1; then
        local pip_cache_path
        pip_cache_path=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" pip3 cache dir 2> /dev/null) || pip_cache_path=""
        if [[ -n "$pip_cache_path" && "$pip_cache_path" == /* ]]; then
            clean_tool_cache "pip cache" "$pip_cache_path" bash -c 'pip3 cache purge > /dev/null 2>&1 || true'
            note_activity
        fi
    fi
    safe_clean ~/.pyenv/cache/* "pyenv cache"
    safe_clean ~/.cache/poetry/* "Poetry cache"
    clean_uv_cache
    safe_clean ~/.cache/ruff/* "Ruff cache"
    safe_clean ~/.cache/mypy/* "MyPy cache"
    safe_clean ~/.pytest_cache/* "Pytest cache"
    safe_clean ~/.jupyter/runtime/* "Jupyter runtime cache"
    # Hugging Face, PyTorch, TensorFlow and Weights & Biases keep downloaded
    # model weights, datasets and run artifacts here. Their roots are not
    # blanket caches: Hugging Face's own prune warns that interruption can
    # corrupt its cache, while the other roots mix reusable payloads with run
    # state. Keep all four off the automatic delete path.
    clean_conda_metadata_caches
}

go_cache_process_state() {
    local cache_kind="${1:-GOMODCACHE}"
    # Go documents GOCACHE as safe for multiple local processes. The module
    # cache's whole-root RemoveAll has no equivalent operation-wide lock, so
    # only that root needs the active owner-process gate.
    [[ "$cache_kind" == "GOCACHE" ]] && return 1
    mole_pgrep_any -x go -x gopls
}

# Resolve an owner-reported Go cache root to a stable physical directory. A
# custom Go root is allowed, but broad home/cache parents, protected paths, and
# directories not owned by the invoking user fail closed. A leaf symlink is
# accepted only because the owner command receives the resolved physical root
# and both identities are rebound immediately before it runs.
go_cache_root_physical_path() {
    local cache_root="${1%/}"
    [[ -d "$cache_root" ]] || return 1

    local physical_root=""
    physical_root=$(cd -P "$cache_root" 2> /dev/null && pwd -P) || return 1
    case "$physical_root" in
        / | "$HOME" | "$HOME/.cache" | "$HOME/go")
            return 1
            ;;
    esac

    validate_path_for_deletion "$cache_root" > /dev/null 2>&1 || return 1
    validate_path_for_deletion "$physical_root" > /dev/null 2>&1 || return 1
    should_protect_path "$cache_root" 2> /dev/null && return 1
    should_protect_path "$physical_root" 2> /dev/null && return 1

    local invoking_uid=""
    local root_uid=""
    invoking_uid=$(get_invoking_uid 2> /dev/null) || return 1
    root_uid=$($STAT_BSD "${_MOLE_STAT_UID_FLAG}" "$physical_root" 2> /dev/null) || return 1
    [[ "$invoking_uid" =~ ^[0-9]+$ && "$root_uid" == "$invoking_uid" ]] || return 1

    printf '%s\n' "$physical_root"
}

_run_go_cache_clean_bound() {
    local cache_root="$1"
    local physical_root="$2"
    local lexical_parent="$3"
    local lexical_parent_id="$4"
    local lexical_target_id="$5"
    local physical_parent="$6"
    local physical_parent_id="$7"
    local physical_target_id="$8"
    local cache_kind="$9"
    local clean_flag="${10}"
    local owner_dry_run="${11}"

    _MOLE_GO_CACHE_BOUND_REASON=""

    # The entry check only proves the root was not a symlink when the caller
    # looked. A directory swapped for a link afterwards survives the identity
    # comparison below, and `go clean -modcache` would then remove whatever the
    # link resolves to instead of the module root. Re-read the link bit here,
    # at the last hop before the owner command runs.
    if [[ "$cache_kind" == "GOMODCACHE" && -L "$cache_root" ]]; then
        _MOLE_GO_CACHE_BOUND_REASON="symlinked module root"
        return 1
    fi

    local process_state=0
    go_cache_process_state "$cache_kind" || process_state=$?
    if [[ $process_state -eq 0 ]]; then
        _MOLE_GO_CACHE_BOUND_REASON="Go started"
        return 1
    elif [[ $process_state -ne 1 ]]; then
        _MOLE_GO_CACHE_BOUND_REASON="process state unknown"
        return 1
    fi

    if ! _mole_path_matches_identity \
        "$cache_root" "$lexical_parent" "$lexical_parent_id" "$lexical_target_id" ||
        ! _mole_path_matches_identity \
            "$physical_root" "$physical_parent" "$physical_parent_id" "$physical_target_id"; then
        _MOLE_GO_CACHE_BOUND_REASON="cache path state unknown"
        return 1
    fi

    local -a command_args=(env "$cache_kind=$physical_root" go clean)
    if [[ "$owner_dry_run" == "true" ]]; then
        command_args+=(-n)
    fi
    command_args+=("$clean_flag")
    run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" "${command_args[@]}" > /dev/null 2>&1
}

clean_go_cache_root() {
    local cache_root="$1"
    local cache_kind="$2"
    local clean_flag="$3"
    local display_name="$4"
    [[ -e "$cache_root" || -L "$cache_root" ]] || return 0

    # `go clean -modcache` removes the module root itself, not just its
    # contents, so handing it the resolved physical path of a symlinked
    # GOMODCACHE deletes the target directory and leaves the owner's own root a
    # dangling link that the next build cannot use. GOCACHE is safe here
    # because `go clean -cache` empties the cache subdirectories and leaves the
    # root in place.
    if [[ "$cache_kind" == "GOMODCACHE" && -L "$cache_root" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (symlinked module root)"
        note_activity
        return 0
    fi

    local physical_root=""
    if ! physical_root=$(go_cache_root_physical_path "$cache_root"); then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi

    local whitelist_path=""
    if is_path_whitelisted "$cache_root"; then
        whitelist_path="$cache_root"
    elif is_path_whitelisted "$physical_root"; then
        whitelist_path="$physical_root"
    fi
    if [[ -n "$whitelist_path" ]]; then
        clean_tool_cache "$display_name" "$whitelist_path" :
        return 0
    fi

    local process_state=0
    go_cache_process_state "$cache_kind" || process_state=$?
    if [[ $process_state -eq 0 ]]; then
        mole_defer_cleanup_family "Go"
        return 0
    elif [[ $process_state -ne 1 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (process state unknown)"
        note_activity
        return 0
    fi

    if ! _mole_snapshot_path_identity "$cache_root"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi
    local lexical_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local lexical_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local lexical_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    if ! _mole_snapshot_path_identity "$physical_root"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi
    local physical_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local physical_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local physical_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"

    local _MOLE_GO_CACHE_BOUND_REASON=""
    local command_status=0
    if [[ "$DRY_RUN" != "true" && -t 1 ]]; then
        start_section_spinner "Cleaning $display_name..."
    fi
    _run_go_cache_clean_bound \
        "$cache_root" "$physical_root" \
        "$lexical_parent" "$lexical_parent_id" "$lexical_target_id" \
        "$physical_parent" "$physical_parent_id" "$physical_target_id" \
        "$cache_kind" "$clean_flag" "$DRY_RUN" || command_status=$?
    if [[ "$DRY_RUN" != "true" && -t 1 ]]; then
        stop_section_spinner
    fi

    if [[ $command_status -eq 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $display_name · would clean"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $display_name"
        fi
        note_activity
        return 0
    fi
    if [[ $command_status -eq 124 || $command_status -ge 128 ]]; then
        return "$command_status"
    fi

    if [[ "$_MOLE_GO_CACHE_BOUND_REASON" == "Go started" ]]; then
        mole_defer_cleanup_family "Go"
    elif [[ -n "$_MOLE_GO_CACHE_BOUND_REASON" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${_MOLE_GO_CACHE_BOUND_REASON})"
        note_activity
    else
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (owner cleanup failed)"
        note_activity
    fi
    return 0
}

# Go explicitly documents both roots as caches and provides the removal
# command. Re-download cost is an acceptable clean tradeoff; the effective
# roots remain independently whitelistable and are rebound at the command
# boundary before the owner command runs.
clean_dev_go() {
    command -v go > /dev/null 2>&1 || return 0

    local go_mod_cache=""
    local go_build_cache=""
    local resolver_rc=0
    go_mod_cache=$(mole_go_cache_root GOMODCACHE) || resolver_rc=$?
    if [[ $resolver_rc -eq 124 || $resolver_rc -ge 128 ]]; then
        return "$resolver_rc"
    fi
    resolver_rc=0
    go_build_cache=$(mole_go_cache_root GOCACHE) || resolver_rc=$?
    if [[ $resolver_rc -eq 124 || $resolver_rc -ge 128 ]]; then
        return "$resolver_rc"
    fi

    if [[ -n "$go_mod_cache" ]]; then
        clean_go_cache_root \
            "$go_mod_cache" GOMODCACHE -modcache "Go module cache" || return $?
    fi
    if [[ -n "$go_build_cache" ]]; then
        clean_go_cache_root \
            "$go_build_cache" GOCACHE -cache "Go build cache" || return $?
    fi
}

get_mise_cache_path() {
    if [[ -n "${MISE_CACHE_DIR:-}" && "${MISE_CACHE_DIR}" == /* ]]; then
        echo "$MISE_CACHE_DIR"
        return 0
    fi

    if command -v mise > /dev/null 2>&1; then
        local mise_cache_path
        mise_cache_path=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" mise cache path 2> /dev/null || echo "")
        if [[ -n "$mise_cache_path" && "$mise_cache_path" == /* ]]; then
            echo "$mise_cache_path"
            return 0
        fi
    fi

}

clean_dev_mise() {
    local mise_cache_path
    mise_cache_path=$(get_mise_cache_path)
    [[ -n "$mise_cache_path" ]] || return 0

    if command -v mise > /dev/null 2>&1; then
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            clean_tool_cache "mise cache" "$mise_cache_path" bash -c 'mise cache clear > /dev/null 2>&1 || true'
            note_activity
        elif is_path_whitelisted "$mise_cache_path"; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} mise cache · would skip (whitelist)"
            note_activity
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} mise cache · would clean"
            note_activity
        fi
    fi

    safe_clean "$mise_cache_path"/* "mise cache"
}
# Resolve a tool home from an optional env value plus default.
# Only absolute paths without ".." / control characters are accepted from
# env; anything else falls back to the default so a poisoned CARGO_HOME
# cannot redirect cleanup (issue #1378, mise-relocated cargo/rustup).
# shellcheck disable=SC2329
resolve_tool_home() {
    local env_value="${1:-}"
    local default_home="$2"

    if [[ -n "$env_value" && "$env_value" == /* ]]; then
        case "$env_value" in
            *'/../'* | */.. | .. | *$'\n'* | *$'\r'*)
                ;;
            *)
                printf '%s\n' "${env_value%/}"
                return 0
                ;;
        esac
    fi
    printf '%s\n' "${default_home%/}"
}

# Cargo and rustc read registry sources throughout builds. Returns the shared
# process tri-state: 0 active, 1 idle, 2 unknown.
rust_build_process_state() {
    mole_pgrep_any \
        -x cargo \
        -x rustc \
        -x rustdoc \
        -x clippy-driver \
        -x cargo-nextest
}

# Resolve a Cargo cache root and prove it remains physically contained by the
# selected CARGO_HOME. The home itself may be symlinked by a version manager,
# but a nested cache root must not escape it.
rust_cache_root_physical_path() {
    local cargo_home="$1"
    local cache_root="$2"
    [[ -d "$cargo_home" && -d "$cache_root" ]] || return 1

    local physical_home physical_root
    physical_home=$(cd -P "$cargo_home" 2> /dev/null && pwd -P) || return 1
    physical_root=$(cd -P "$cache_root" 2> /dev/null && pwd -P) || return 1
    [[ "$physical_home" != "/" ]] || return 1
    case "$physical_root" in
        "$physical_home"/*)
            printf '%s\n' "$physical_root"
            return 0
            ;;
    esac
    return 1
}

# Combine the process state with the physical root identity for the final
# safe_clean_guarded boundary. Returns 0 active, 1 idle/safe, 2 unknown/changed.
rust_cache_cleanup_state() {
    local process_state=0
    rust_build_process_state || process_state=$?
    [[ $process_state -eq 1 ]] || return "$process_state"

    local physical_now
    physical_now=$(rust_cache_root_physical_path \
        "$_MOLE_RUST_CARGO_HOME" "$_MOLE_RUST_CACHE_ROOT") || return 2
    [[ "$physical_now" == "$_MOLE_RUST_CACHE_PHYSICAL" ]] || return 2

    # Production safe_clean_guarded supplies the exact leaf it is about to
    # remove. Bind that object and its physical parent to safe_remove's final
    # identity check so replacing registry/src (or another Cargo cache root)
    # after this guard cannot redirect the pathname outside CARGO_HOME.
    local guarded_path="${_MOLE_DEV_GUARDED_PATH:-}"
    if [[ -n "$guarded_path" ]]; then
        _mole_snapshot_path_identity "$guarded_path" || return 2
        [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "$physical_now" ]] || return 2

        local physical_after
        physical_after=$(rust_cache_root_physical_path \
            "$_MOLE_RUST_CARGO_HOME" "$_MOLE_RUST_CACHE_ROOT") || return 2
        [[ "$physical_after" == "$physical_now" ]] || return 2

        _MOLE_SAFE_CLEAN_BOUND_PATH="$guarded_path"
        _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
        _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    fi
    return 1
}

clean_rust_dependency_cache_root() {
    local cargo_home="$1"
    local cache_root="$2"
    local display_name="$3"
    [[ -d "$cache_root" ]] || return 0

    local physical_root
    if ! physical_root=$(rust_cache_root_physical_path "$cargo_home" "$cache_root"); then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path leaves CARGO_HOME)"
        note_activity
        return 0
    fi

    local _MOLE_RUST_CARGO_HOME="$cargo_home"
    local _MOLE_RUST_CACHE_ROOT="$cache_root"
    local _MOLE_RUST_CACHE_PHYSICAL="$physical_root"
    local _MOLE_DEV_PROCESS_GUARD_UNKNOWN_REASON="process or cache path state unknown"
    _dev_safe_clean_process_guarded \
        rust_cache_cleanup_state \
        "Rust" \
        "$display_name" \
        "$cache_root"/* \
        "$display_name"
}

# Rust/cargo caches. Honor CARGO_HOME / RUSTUP_HOME when they point at a
# validated absolute path (mise and other version managers relocate these).
# Scope stays redundant download copies only: registry/cache and rustup
# downloads. Keep bin, toolchains, registry/src, registry/index, and git.
#
# registry/src is deliberately excluded. It holds the extracted crate sources
# cargo builds against, so with it present a project still builds after
# registry/cache is emptied; removing both turns every previously working
# offline build into a crates.io round trip. rust-analyzer also reads it
# continuously and is not part of rust_build_process_state, so a deletion
# would break IDE navigation for an editor Mole cannot see. Cargo 1.88+ owns
# age-aware garbage collection for registry sources and git dependencies, so
# Mole does not race that store with a second whole-tree policy.
clean_dev_rust() {
    local cargo_home rustup_home
    cargo_home=$(resolve_tool_home "${CARGO_HOME:-}" "${HOME}/.cargo")
    rustup_home=$(resolve_tool_home "${RUSTUP_HOME:-}" "${HOME}/.rustup")

    if mole_cleanup_targets_exist \
        "${cargo_home}/registry/cache"/*; then
        local rust_state=0
        rust_build_process_state || rust_state=$?
        if [[ $rust_state -eq 0 ]]; then
            mole_defer_cleanup_family "Rust"
        elif [[ $rust_state -eq 1 ]]; then
            clean_rust_dependency_cache_root \
                "$cargo_home" \
                "${cargo_home}/registry/cache" \
                "Rust cargo cache" || return 0
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Rust dependency cache · stopped (process state unknown)"
            note_activity
        fi
    fi
    safe_clean "${rustup_home}/downloads"/* "Rustup downloads cache"
}
# Ruby/gem ecosystem caches (not installed versions).
clean_dev_ruby() {
    safe_clean ~/.rbenv/cache/* "rbenv download cache"
    safe_clean ~/.gem/specs/* "gem spec cache"
    safe_clean ~/.gem/ruby/*/cache/*.gem "gem package cache"
    safe_clean ~/.bundle/cache/* "Ruby Bundler cache"
}
# Perl ecosystem caches (not installed modules).
clean_dev_perl() {
    # ~/.cpan/sources is the distribution store CPAN installs from and reuses
    # across installs, so it stays. Only the throwaway build tree goes.
    safe_clean ~/.cpan/build/* "CPAN build artifacts"
}

# Helper: Check for multiple versions in a directory.
# Args: $1=directory, $2=tool_name, $3=list_command, $4=remove_command
check_multiple_versions() {
    local dir="$1"
    local tool_name="$2"
    local list_cmd="${3:-}"
    local remove_cmd="${4:-}"

    if [[ ! -d "$dir" ]]; then
        return 0
    fi

    local count
    count=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l | tr -d ' ')

    if [[ "$count" -gt 1 ]]; then
        note_activity
        local hint=""
        if [[ -n "$list_cmd" ]]; then
            hint=" ${GRAY}(${list_cmd})${NC}"
        fi
        echo -e "  ${YELLOW}${ICON_REVIEW}${NC} ${tool_name} · ${count} found${hint}"
    fi
}

# Check for multiple Rust toolchains.
check_rust_toolchains() {
    command -v rustup > /dev/null 2>&1 || return 0

    local rustup_home
    rustup_home=$(resolve_tool_home "${RUSTUP_HOME:-}" "${HOME}/.rustup")

    check_multiple_versions \
        "${rustup_home}/toolchains" \
        "Rust toolchains" \
        "rustup toolchain list"
}
# Docker caches (guarded by daemon check).

clean_dev_docker() {
    if command -v docker > /dev/null 2>&1; then
        note_activity
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} Docker unused data · review with docker system df"
        debug_log "Docker daemon-managed cleanup skipped by default"
    fi

    if command -v orb > /dev/null 2>&1 || command -v orbctl > /dev/null 2>&1 || [[ -d "$HOME/.orbstack" ]]; then
        note_activity
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} OrbStack container data · review with docker system df"
        debug_log "OrbStack daemon-managed data left for manual prune"
    fi
    safe_clean ~/.docker/buildx/cache/* "Docker BuildX cache"
}
# Nix garbage collection.
clean_dev_nix() {
    if command -v nix-collect-garbage > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            clean_tool_cache "Nix garbage collection" "/nix/store" nix-collect-garbage --delete-older-than 30d
        elif is_path_whitelisted "/nix/store"; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Nix garbage collection · would skip (whitelist)"
            note_activity
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Nix garbage collection · would clean"
        fi
        note_activity
    fi
}
# Cloud CLI caches.
clean_dev_cloud() {
    clean_github_cli_cache || return $?
    safe_clean ~/.kube/cache/* "Kubernetes cache"
    safe_clean ~/.local/share/containers/storage/tmp/* "Container storage temp"
    safe_clean ~/.aws/cli/cache/* "AWS CLI cache"
    safe_clean ~/.config/gcloud/logs/* "Google Cloud logs"
    safe_clean ~/.azure/logs/* "Azure CLI logs"
}
# Frontend build caches.
clean_dev_frontend() {
    safe_clean ~/.cache/typescript/* "TypeScript cache"
    safe_clean ~/.cache/electron/* "Electron cache"
    safe_clean ~/.cache/node-gyp/* "node-gyp cache"
    safe_clean ~/.node-gyp/* "node-gyp build cache"
    safe_clean ~/.turbo/cache/* "Turbo cache"
    safe_clean ~/.vite/cache/* "Vite cache"
    safe_clean ~/.cache/vite/* "Vite global cache"
    safe_clean ~/.cache/webpack/* "Webpack cache"
    safe_clean ~/.parcel-cache/* "Parcel cache"
    safe_clean ~/.cache/eslint/* "ESLint cache"
    safe_clean ~/.cache/prettier/* "Prettier cache"
}
_dev_process_delete_guard_allows() {
    # safe_clean_guarded passes the leaf currently at its deletion boundary.
    # Keep it in dynamic scope so compound probes such as the Cargo root guard
    # can bind that exact object without changing ordinary process probes.
    local _MOLE_DEV_GUARDED_PATH="${1:-}"
    mole_clean_process_guard \
        "$_MOLE_DEV_PROCESS_GUARD_PROBE" \
        "$_MOLE_DEV_PROCESS_GUARD_FAMILY started" \
        "${_MOLE_DEV_PROCESS_GUARD_UNKNOWN_REASON:-process state unknown}"
}

_dev_report_process_guard_stop() {
    local display_name="$1"
    local family="$2"
    local reason="$3"

    if [[ "$reason" == "process state unknown" || "$reason" == "process or cache path state unknown" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${reason})"
        note_activity
    else
        mole_defer_cleanup_family "$family"
    fi
}

# Bind a tri-state process probe to safe_clean's post-size boundary. The local
# guard state is intentionally dynamic so Bash 3.2 callbacks can read it.
_dev_safe_clean_process_guarded() {
    local probe="$1"
    local family="$2"
    local display_name="$3"
    shift 3
    local _MOLE_DEV_PROCESS_GUARD_PROBE="$probe"
    local _MOLE_DEV_PROCESS_GUARD_FAMILY="$family"
    local _MOLE_CLEAN_GUARD_REASON="${family} started"

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        if ! _dev_process_delete_guard_allows; then
            _dev_report_process_guard_stop "$display_name" "$family" "$_MOLE_CLEAN_GUARD_REASON"
            return 1
        fi
        safe_clean "$@"
        return $?
    fi

    local guarded_rc=0
    safe_clean_guarded _dev_process_delete_guard_allows "$@" || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        _dev_report_process_guard_stop "$display_name" "$family" "$_MOLE_CLEAN_GUARD_REASON"
        return 1
    fi
    return "$guarded_rc"
}

_dev_clean_service_worker_process_guarded() {
    local probe="$1"
    local family="$2"
    local display_name="$3"
    local browser_name="$4"
    local cache_path="$5"
    local _MOLE_DEV_PROCESS_GUARD_PROBE="$probe"
    local _MOLE_DEV_PROCESS_GUARD_FAMILY="$family"
    local _MOLE_CLEAN_GUARD_REASON="${family} started"
    local guarded_rc=0

    clean_service_worker_cache \
        "$browser_name" \
        "$cache_path" \
        _dev_process_delete_guard_allows || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        _dev_report_process_guard_stop "$display_name" "$family" "$_MOLE_CLEAN_GUARD_REASON"
        return 1
    fi
    return "$guarded_rc"
}

# JVM ecosystem caches.
# Gradle: Respects whitelist, cleaned when not protected via: mo clean --whitelist
clean_dev_jvm() {
    # Excluded on purpose, all for the same reason: ~/.m2/repository and
    # ~/.ivy2/cache are the stores Maven, sbt and Ivy resolve dependencies
    # from, and ~/.sbt/boot with ~/.sbt/launchers hold the Scala compiler and
    # sbt launcher jars themselves. clean_large_files reports them for review.
    # Maven used to be cleaned here and relied on DEFAULT_WHITELIST_PATTERNS to
    # stay safe, which stops applying as soon as a user saves any whitelist
    # entry of their own, so the delete path is gone rather than guarded.
    if mole_cleanup_targets_exist \
        "$HOME/.gradle/caches/build-cache-"*/* \
        "$HOME/.gradle/notifications"/* \
        "$HOME/.gradle/daemon"/* \
        "$HOME/.gradle/workers"/*; then
        local gradle_state=0
        gradle_daemon_running || gradle_state=$?
        if [[ $gradle_state -eq 0 ]]; then
            mole_defer_cleanup_family "Gradle"
        elif [[ $gradle_state -eq 1 ]]; then
            # Each group rechecks the probe at its deletion boundary; any
            # refusal stops the remaining Gradle cleanup.
            _dev_safe_clean_process_guarded \
                gradle_daemon_running \
                "Gradle" \
                "Gradle build cache" \
                "$HOME/.gradle/caches/build-cache-"*/* \
                "Gradle build cache" || return 0
            _dev_safe_clean_process_guarded \
                gradle_daemon_running \
                "Gradle" \
                "Gradle notifications cache" \
                "$HOME/.gradle/notifications"/* \
                "Gradle notifications cache" || return 0
            _dev_safe_clean_process_guarded \
                gradle_daemon_running \
                "Gradle" \
                "Gradle daemon/workers" \
                "$HOME/.gradle/daemon"/* \
                "$HOME/.gradle/workers"/* \
                "Gradle daemon/workers" || return 0
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Gradle targets · skipped (process state unknown)"
            note_activity
        fi
    fi
}
# AI coding agents (Claude Code, Cursor Agent, etc.) auto-update but never
# remove previous versions, so ~/.local/share/<agent>/versions accumulates
# hundreds of MB per release. Keep the most recently modified N entries
# plus the version pointed at by the active CLI symlink (mtime alone is
# unreliable: Claude Code pre-downloads the next version before flipping
# the symlink, so newest mtime is not always the active version).
_MOLE_VERSIONED_AGENT_CLEANUP_TARGETS=()
_MOLE_VERSIONED_AGENT_RETENTION_TARGETS=()
_MOLE_VERSIONED_AGENT_ACTIVE_PATH=""

_versioned_agent_scan_deadline() {
    local timeout_seconds="${1:-$MOLE_TIMEOUT_DISK_VERIFY_SEC}"
    [[ "$timeout_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]] || timeout_seconds="$MOLE_TIMEOUT_DISK_VERIFY_SEC"
    local timeout_whole="${timeout_seconds%%.*}"
    local timeout_budget=$((10#$timeout_whole))
    if [[ "$timeout_seconds" == *.* && "${timeout_seconds#*.}" =~ [1-9] ]]; then
        timeout_budget=$((timeout_budget + 1))
    fi
    [[ $timeout_budget -gt 0 ]] || timeout_budget=1
    printf '%s\n' "$((SECONDS + timeout_budget))"
}

_materialize_versioned_agent_entries() {
    local versions_root="$1"
    local output_file="$2"
    local timeout_seconds="${3:-$MOLE_TIMEOUT_DISK_VERIFY_SEC}"
    : > "$output_file" || return 1

    local scan_rc=0
    run_with_timeout "$timeout_seconds" find "$versions_root" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type d \) -print0 \
        < /dev/null > "$output_file" 2> /dev/null || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        : > "$output_file" || true
        return "$scan_rc"
    fi
    return 0
}

_versioned_agent_entry_mtime() {
    local entry="$1"
    local timeout_seconds="$2"
    run_with_timeout "$timeout_seconds" stat \
        "${_MOLE_STAT_MTIME_FLAG}" "$entry" < /dev/null 2> /dev/null
}

_plan_versioned_agent_cleanup_targets() {
    local versions_root="$1"
    local keep_previous="$2"
    local active_path="${3:-}"

    _MOLE_VERSIONED_AGENT_CLEANUP_TARGETS=()
    _MOLE_VERSIONED_AGENT_RETENTION_TARGETS=()

    [[ -d "$versions_root" ]] || return 0

    local -a entries=()
    local -a entry_mtimes=()
    local scan_deadline=""
    scan_deadline=$(_versioned_agent_scan_deadline)
    local scan_timeout=""
    local deadline_rc=0
    scan_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$scan_deadline") || deadline_rc=$?
    [[ $deadline_rc -eq 0 ]] || return "$deadline_rc"
    local scan_file=""
    scan_file=$(create_temp_file) || return 1
    local scan_rc=0
    _materialize_versioned_agent_entries \
        "$versions_root" "$scan_file" "$scan_timeout" || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$scan_rc"
    fi

    local entry
    local inventory_rc=0
    while IFS= read -r -d '' entry; do
        local name
        name=$(basename "$entry")
        [[ "$name" == .* ]] && continue
        [[ ! "$name" =~ ^[0-9] ]] && continue
        entries+=("$entry")
        local mtime=""
        local stat_rc=0
        local stat_timeout=""
        stat_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$scan_deadline") || stat_rc=$?
        if [[ $stat_rc -eq 0 ]]; then
            mtime=$(_versioned_agent_entry_mtime \
                "$entry" "$stat_timeout") || stat_rc=$?
        fi
        if [[ $stat_rc -ne 0 || ! "$mtime" =~ ^[0-9]+$ ]]; then
            inventory_rc=$stat_rc
            [[ $inventory_rc -ne 0 ]] || inventory_rc=1
            break
        fi
        entry_mtimes+=("$mtime")
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    if [[ $inventory_rc -ne 0 ]]; then
        _MOLE_VERSIONED_AGENT_CLEANUP_TARGETS=()
        _MOLE_VERSIONED_AGENT_RETENTION_TARGETS=()
        return "$inventory_rc"
    fi

    [[ ${#entries[@]} -le "$keep_previous" ]] && return 0

    # Sort the parallel arrays by mtime without serializing pathnames through
    # newline-delimited text. Version directories can legally contain newlines.
    local i j key_mtime key_path
    for ((i = 1; i < ${#entries[@]}; i++)); do
        key_path="${entries[$i]}"
        key_mtime="${entry_mtimes[$i]}"
        j=$((i - 1))
        while [[ $j -ge 0 && ${entry_mtimes[$j]} -lt $key_mtime ]]; do
            entries[j + 1]="${entries[$j]}"
            entry_mtimes[j + 1]="${entry_mtimes[$j]}"
            j=$((j - 1))
        done
        entries[j + 1]="$key_path"
        entry_mtimes[j + 1]="$key_mtime"
    done

    local idx=0
    local target
    for target in "${entries[@]}"; do
        if [[ -n "$active_path" && "$target" == "$active_path" ]]; then
            continue
        fi
        if [[ $idx -lt $keep_previous ]]; then
            idx=$((idx + 1))
            continue
        fi
        _MOLE_VERSIONED_AGENT_RETENTION_TARGETS+=("$target")
        if mole_cleanup_targets_exist "$target"; then
            _MOLE_VERSIONED_AGENT_CLEANUP_TARGETS+=("$target")
        fi
        idx=$((idx + 1))
    done
}

_resolve_versioned_agent_active_path() {
    local versions_root="$1"
    local active_symlink="$2"
    _MOLE_VERSIONED_AGENT_ACTIVE_PATH=""

    [[ -L "$active_symlink" ]] || return 1
    [[ -e "$active_symlink" ]] || return 2

    local target
    target=$(readlink "$active_symlink" 2> /dev/null || true)
    [[ -n "$target" ]] || return 2
    case "$target" in
        /*) ;;
        *) target="$(dirname "$active_symlink")/$target" ;;
    esac

    # Resolve dot segments and symlinked parent directories before comparing.
    # Launchers commonly use ../../relative targets, and a lexical comparison
    # would fail to pin the active version.
    local target_parent target_name
    target_parent=$(dirname "$target")
    target_name=$(basename "$target")
    target_parent=$(cd "$target_parent" 2> /dev/null && pwd -P) || return 2
    target="$target_parent/$target_name"

    local scan_deadline=""
    scan_deadline=$(_versioned_agent_scan_deadline)
    local scan_timeout=""
    local deadline_rc=0
    scan_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$scan_deadline") || deadline_rc=$?
    [[ $deadline_rc -eq 0 ]] || return "$deadline_rc"
    local scan_file=""
    scan_file=$(create_temp_file) || return 2
    local scan_rc=0
    _materialize_versioned_agent_entries \
        "$versions_root" "$scan_file" "$scan_timeout" || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$scan_rc"
    fi

    local entry entry_resolved entry_parent entry_name
    local found_active=false
    while IFS= read -r -d '' entry; do
        if [[ -d "$entry" ]]; then
            entry_resolved=$(cd "$entry" 2> /dev/null && pwd -P) || continue
        else
            entry_parent=$(dirname "$entry")
            entry_name=$(basename "$entry")
            entry_parent=$(cd "$entry_parent" 2> /dev/null && pwd -P) || continue
            entry_resolved="$entry_parent/$entry_name"
        fi
        case "$target/" in
            "$entry_resolved"/*)
                _MOLE_VERSIONED_AGENT_ACTIVE_PATH="$entry"
                found_active=true
                break
                ;;
        esac
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    [[ "$found_active" == "true" ]] && return 0
    return 2
}

_MOLE_VERSIONED_AGENT_GUARD_ROOT=""
_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK=""
_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED=false
_MOLE_VERSIONED_AGENT_GUARD_KEEP=1
_MOLE_CLEAN_GUARD_REASON=""

_versioned_agent_delete_guard_allows() {
    local target="${1:-}"
    local active_path=""
    local active_status=0

    if [[ -n "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK" ]]; then
        _resolve_versioned_agent_active_path \
            "$_MOLE_VERSIONED_AGENT_GUARD_ROOT" \
            "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK" || active_status=$?
        if [[ $active_status -eq 124 || $active_status -ge 128 ]]; then
            _MOLE_CLEAN_GUARD_REASON="inventory interrupted"
            return "$active_status"
        fi
        if [[ $active_status -eq 0 ]]; then
            active_path="$_MOLE_VERSIONED_AGENT_ACTIVE_PATH"
        elif [[ $active_status -eq 1 && "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED" != "true" ]]; then
            : # This agent currently has no active launcher symlink to preserve.
        elif [[ $active_status -eq 1 ]]; then
            _MOLE_CLEAN_GUARD_REASON="active version changed"
            return 1
        else
            _MOLE_CLEAN_GUARD_REASON="active version unknown"
            return "$active_status"
        fi
    fi

    # An updater can switch the launcher or install a newer version while size
    # is being measured. Re-plan and authorize this exact target at the delete
    # boundary so neither the active version nor the new retention set is lost.
    local plan_rc=0
    _plan_versioned_agent_cleanup_targets \
        "$_MOLE_VERSIONED_AGENT_GUARD_ROOT" \
        "$_MOLE_VERSIONED_AGENT_GUARD_KEEP" \
        "$active_path" || plan_rc=$?
    if [[ $plan_rc -ne 0 ]]; then
        _MOLE_CLEAN_GUARD_REASON="inventory unknown"
        [[ $plan_rc -eq 124 || $plan_rc -ge 128 ]] && return "$plan_rc"
        return 1
    fi

    if [[ -n "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK" ]]; then
        local verified_active_path=""
        local verified_active_status=0
        _resolve_versioned_agent_active_path \
            "$_MOLE_VERSIONED_AGENT_GUARD_ROOT" \
            "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK" || verified_active_status=$?
        if [[ $verified_active_status -eq 124 || $verified_active_status -ge 128 ]]; then
            _MOLE_CLEAN_GUARD_REASON="inventory interrupted"
            return "$verified_active_status"
        fi
        [[ $verified_active_status -ne 0 ]] || verified_active_path="$_MOLE_VERSIONED_AGENT_ACTIVE_PATH"
        if [[ $verified_active_status -ne 0 && $verified_active_status -ne 1 ]]; then
            _MOLE_CLEAN_GUARD_REASON="active version unknown"
            return "$verified_active_status"
        fi
        if [[ $verified_active_status -eq 1 && "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED" == "true" ]]; then
            _MOLE_CLEAN_GUARD_REASON="active version changed"
            return 1
        fi
        if [[ $verified_active_status -ne $active_status || "$verified_active_path" != "$active_path" ]]; then
            _MOLE_CLEAN_GUARD_REASON="active version changed"
            return 1
        fi
    fi

    local planned_target
    if [[ ${#_MOLE_VERSIONED_AGENT_CLEANUP_TARGETS[@]} -gt 0 ]]; then
        for planned_target in "${_MOLE_VERSIONED_AGENT_CLEANUP_TARGETS[@]}"; do
            [[ "$planned_target" == "$target" ]] && return 0
        done
    fi

    _MOLE_CLEAN_GUARD_REASON="retention changed"
    return 1
}

_report_versioned_agent_guard_stop() {
    local label="$1"
    echo -e "  ${GRAY}${ICON_WARNING}${NC} ${label} · stopped (${_MOLE_CLEAN_GUARD_REASON})"
    note_activity
}

clean_versioned_agent_root() {
    local versions_root="$1"
    local label="$2"
    local keep_previous="$3"
    local active_path="${4:-}"
    local active_symlink="${5:-}"

    local plan_rc=0
    _plan_versioned_agent_cleanup_targets \
        "$versions_root" "$keep_previous" "$active_path" || plan_rc=$?
    if [[ $plan_rc -ne 0 ]]; then
        _MOLE_CLEAN_GUARD_REASON="inventory unknown"
        [[ $plan_rc -eq 124 || $plan_rc -ge 128 ]] && return "$plan_rc"
        _report_versioned_agent_guard_stop "$label"
        return "$plan_rc"
    fi
    [[ ${#_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]} -gt 0 ]] || return 0

    _MOLE_VERSIONED_AGENT_GUARD_ROOT="$versions_root"
    _MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK="$active_symlink"
    _MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED=false
    [[ -n "$active_path" ]] && _MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED=true
    _MOLE_VERSIONED_AGENT_GUARD_KEEP="$keep_previous"
    _MOLE_CLEAN_GUARD_REASON="retention changed"

    if declare -f safe_clean_guarded > /dev/null 2>&1; then
        local guarded_rc=0
        safe_clean_guarded \
            _versioned_agent_delete_guard_allows \
            "${_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]}" \
            "$label" || guarded_rc=$?
        if [[ $guarded_rc -eq 75 ]]; then
            _report_versioned_agent_guard_stop "$label"
            return 0
        fi
        return "$guarded_rc"
    fi

    local target
    for target in "${_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]}"; do
        local guard_rc=0
        _versioned_agent_delete_guard_allows "$target" || guard_rc=$?
        if [[ $guard_rc -ne 0 ]]; then
            [[ $guard_rc -eq 124 || $guard_rc -ge 128 ]] && return "$guard_rc"
            _report_versioned_agent_guard_stop "$label"
            return 0
        fi
        safe_clean "$target" "$label"
        note_activity
    done
}

count_versioned_agent_entries() {
    local versions_root="$1"
    local count=0
    local entry

    [[ -d "$versions_root" ]] || {
        echo 0
        return 0
    }

    local scan_timeout="$MOLE_TIMEOUT_DISK_VERIFY_SEC"
    local scan_file=""
    scan_file=$(create_temp_file) || return 1
    local scan_rc=0
    _materialize_versioned_agent_entries \
        "$versions_root" "$scan_file" "$scan_timeout" || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$scan_rc"
    fi

    while IFS= read -r -d '' entry; do
        local name
        name=$(basename "$entry")
        [[ "$name" == .* ]] && continue
        [[ ! "$name" =~ ^[0-9] ]] && continue
        count=$((count + 1))
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    echo "$count"
}
clean_dev_ai_agents() {
    local keep_previous="${MOLE_AI_AGENTS_KEEP:-1}"
    [[ "$keep_previous" =~ ^[0-9]+$ ]] || keep_previous=1

    local -a agent_specs=(
        "$HOME/.local/share/claude/versions|Claude Code old version|$HOME/.local/bin/claude"
        "$HOME/.local/share/cursor-agent/versions|Cursor Agent old version|$HOME/.local/bin/cursor-agent"
        "$HOME/.copilot/pkg/universal|GitHub Copilot CLI old version|$HOME/.local/bin/copilot"
    )

    local spec
    for spec in "${agent_specs[@]}"; do
        local versions_root="${spec%%|*}"
        local rest="${spec#*|}"
        local label="${rest%%|*}"
        local active_symlink="${rest#*|}"
        [[ "$active_symlink" == "$rest" ]] && active_symlink=""
        [[ -d "$versions_root" ]] || continue

        local active_path=""
        if [[ -n "$active_symlink" && -L "$active_symlink" ]]; then
            local active_status=0
            _resolve_versioned_agent_active_path "$versions_root" "$active_symlink" || active_status=$?
            if [[ $active_status -ne 0 ]]; then
                [[ $active_status -eq 124 || $active_status -ge 128 ]] && return "$active_status"
                if [[ ! -e "$active_symlink" ]]; then
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} $label · skipped (active symlink broken)"
                else
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} $label · skipped (active version unknown)"
                fi
                note_activity
                continue
            fi
            active_path="$_MOLE_VERSIONED_AGENT_ACTIVE_PATH"
            if [[ -z "$active_path" ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} $label · skipped (active symlink broken)"
                note_activity
                continue
            fi
        fi

        clean_versioned_agent_root \
            "$versions_root" "$label" "$keep_previous" "$active_path" "$active_symlink" || return $?
    done
}

# Other language tool caches.
clean_dev_other_langs() {
    safe_clean ~/.composer/cache/* "PHP Composer cache (legacy)"
    # ~/.nuget/packages is NuGet's global packages folder, the restore target
    # itself rather than an HTTP cache, so it is the .NET equivalent of
    # ~/.m2/repository: emptying it forces a full re-download on the next
    # build. Both stay off the delete path and are surfaced by
    # `clean_large_files` for review instead.
    # safe_clean ~/.pub-cache/* "Dart Pub cache"
    safe_clean ~/.cache/bazel/* "Bazel cache"
    safe_clean ~/.cache/zig/* "Zig cache"
    # DENO_DIR mixes remote imports with origin storage and downloaded runtime
    # payloads. The owner clean command resets the whole root, so Mole keeps it
    # review-only and the generic user-cache sweep excludes it as well.
    debug_log "DENO_DIR left intact by default: ${DENO_DIR:-$HOME/.deno}"
}
# CI/CD and DevOps caches.
clean_dev_cicd() {
    safe_clean ~/.cache/terraform/* "Terraform cache"
    safe_clean ~/.grafana/cache/* "Grafana cache"
    safe_clean ~/.prometheus/data/wal/* "Prometheus WAL cache"
    safe_clean ~/.jenkins/workspace/*/target/* "Jenkins workspace cache"
    safe_clean ~/.cache/gitlab-runner/* "GitLab Runner cache"
    safe_clean ~/.github/cache/* "GitHub Actions cache"
    safe_clean ~/.circleci/cache/* "CircleCI cache"
    safe_clean ~/.sonar/* "SonarQube cache"
}

codex_runtime_process_state() {
    mole_pgrep_any -x "codex"
}

# Check whether any file under a staging root is still open. Returns 0 when
# open files exist, 1 on a reliable no-match, and 2 when the probe cannot
# answer (lsof missing, timeout, or unexpected failure).

staging_root_has_open_files() {
    local staging_root="$1"
    command -v lsof > /dev/null 2>&1 || return 2

    local lsof_output=""
    local lsof_error_file=""
    local lsof_rc=0
    lsof_error_file=$(create_temp_file 2> /dev/null || true)
    [[ -n "$lsof_error_file" && -f "$lsof_error_file" && ! -L "$lsof_error_file" ]] || return 2

    if lsof_output=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" lsof -Fn +D "$staging_root" 2> "$lsof_error_file"); then
        [[ -n "$lsof_output" ]]
        return
    else
        lsof_rc=$?
    fi

    # `lsof +D` returns 1 when no open files match. Timeouts or other failures
    # are different. Some probe errors also return 1, so stderr must be empty
    # before treating that status as a reliable no-match.
    [[ "$lsof_rc" -eq 1 && ! -s "$lsof_error_file" ]] && return 1
    return 2
}

# Physical-path gate for a staging directory that must sit exactly one level
# under a fixed, app-owned root below HOME. Prints the resolved physical path,
# or fails when the candidate is outside the root, is not a directory, sits too
# deep, or reaches the root through a symlink. No component below HOME may be a
# link: these are fixed app-owned paths, and accepting one would let a lexical
# staging root be redirected into ordinary user data.
codex_staging_physical_path() {
    local candidate="$1"
    local staging_root="$2"
    local home_prefix="${HOME%/}/"

    case "$candidate" in
        "$staging_root" | "$staging_root"/*) ;;
        *) return 1 ;;
    esac
    [[ -d "$candidate" ]] || return 1
    if [[ "$candidate" != "$staging_root" && "${candidate%/*}" != "$staging_root" ]]; then
        return 1
    fi

    local relative="${candidate#"$home_prefix"}"
    local old_ifs="$IFS"
    local -a components=()
    IFS='/' read -r -a components <<< "$relative"
    IFS="$old_ifs"
    [[ ${#components[@]} -gt 0 ]] || return 1

    local probe="$HOME"
    local component
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || return 1
        probe="$probe/$component"
        [[ -L "$probe" ]] && return 1
    done

    local physical_root=""
    local physical_candidate=""
    physical_root=$(cd -P "$staging_root" 2> /dev/null && pwd -P) || return 1
    physical_candidate=$(cd -P "$candidate" 2> /dev/null && pwd -P) || return 1
    if [[ "$candidate" == "$staging_root" ]]; then
        [[ "$physical_candidate" == "$physical_root" ]] || return 1
    else
        [[ "${physical_candidate%/*}" == "$physical_root" ]] || return 1
    fi

    printf '%s\n' "$physical_candidate"
}
antigravity_or_gemini_running() {
    mole_pgrep_any \
        -x "Antigravity" \
        -x "gemini" \
        -f "antigravity-browser-profile"
}

chrome_devtools_mcp_running() {
    mole_pgrep_any -f "chrome-devtools-mcp"
}

is_codex_runtime_active() {
    local runtime_dir="$1"
    [[ -d "$runtime_dir" ]] || return 1
    [[ -f "$runtime_dir/runtime.json" ]] || return 1
    [[ -d "$runtime_dir/dependencies/node" || -d "$runtime_dir/dependencies/python" ]] || return 1
    return 0
}

is_codex_runtime_stale() {
    local runtime_dir="$1"
    [[ -d "$runtime_dir" ]] || return 1

    local runtime_name
    runtime_name="$(basename "$runtime_dir")"
    case "$runtime_name" in
        tmp* | temp* | *.tmp | incomplete* | *.incomplete | *-incomplete | partial* | *.partial)
            return 0
            ;;
    esac

    if [[ ! -e "$runtime_dir/runtime.json" && ! -e "$runtime_dir/dependencies" ]]; then
        return 0
    fi

    return 1
}

_codex_runtime_size_human() {
    local target="$1"
    local output_var="$2"
    local size_kb=0

    if declare -f get_path_size_kb > /dev/null 2>&1; then
        local size_rc=0
        size_kb=$(get_path_size_kb "$target" 2> /dev/null) || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
    fi

    local formatted_size
    if declare -f bytes_to_human > /dev/null 2>&1; then
        formatted_size=$(bytes_to_human "$((size_kb * 1024))")
    else
        formatted_size="${size_kb} KB"
    fi
    printf -v "$output_var" '%s' "$formatted_size"
}

_codex_runtime_delete_guard_allows() {
    mole_clean_process_guard codex_runtime_process_state "Codex started" || return 1

    if is_codex_runtime_active "$_MOLE_CODEX_RUNTIME_GUARD_PATH" ||
        ! is_codex_runtime_stale "$_MOLE_CODEX_RUNTIME_GUARD_PATH"; then
        _MOLE_CLEAN_GUARD_REASON="runtime state changed"
        return 1
    fi
    return 0
}

_codex_runtime_safe_clean_guarded() {
    local runtime_dir="$1"
    local _MOLE_CODEX_RUNTIME_GUARD_PATH="$runtime_dir"
    local _MOLE_CLEAN_GUARD_REASON="Codex started"
    local guarded_rc=0

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        if ! _codex_runtime_delete_guard_allows; then
            guarded_rc=75
        else
            safe_clean "$runtime_dir" "Codex CLI runtimes"
            return $?
        fi
    else
        safe_clean_guarded \
            _codex_runtime_delete_guard_allows \
            "$runtime_dir" \
            "Codex CLI runtimes" || guarded_rc=$?
    fi

    if [[ $guarded_rc -eq 75 ]]; then
        if [[ "$_MOLE_CLEAN_GUARD_REASON" == "Codex started" ]]; then
            mole_defer_cleanup_family "Codex"
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex runtimes · stopped (${_MOLE_CLEAN_GUARD_REASON})"
            note_activity
        fi
        return 1
    fi
    return "$guarded_rc"
}

clean_codex_runtimes() {
    local runtime_root="$HOME/.cache/codex-runtimes"
    [[ -d "$runtime_root" ]] || return 0

    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$runtime_root"; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Codex runtimes · would skip (whitelist)"
            note_activity
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Codex runtimes · skipped (whitelist)"
        fi
        note_activity
        return 0
    fi

    local has_stale_runtime=false
    local runtime_dir
    while IFS= read -r -d '' runtime_dir; do
        if ! is_codex_runtime_active "$runtime_dir" &&
            is_codex_runtime_stale "$runtime_dir" &&
            mole_cleanup_targets_exist "$runtime_dir"; then
            has_stale_runtime=true
            break
        fi
    done < <(command find "$runtime_root" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)

    local process_state=0
    codex_runtime_process_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ "$has_stale_runtime" != "true" ]]; then
            return 0
        elif [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex runtimes · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Codex"
        fi
        return 0
    fi

    local size_human=""
    _codex_runtime_size_human "$runtime_root" size_human || return $?
    echo -e "  ${GRAY}${ICON_REVIEW}${NC} Codex runtimes · manual review (${size_human})"
    note_activity

    while IFS= read -r -d '' runtime_dir; do
        if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$runtime_dir"; then
            if [[ "${DRY_RUN:-false}" == "true" ]]; then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Codex runtimes · would skip (whitelist)"
                note_activity
            else
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Codex runtimes · skipped (whitelist)"
            fi
            note_activity
            continue
        fi

        if is_codex_runtime_active "$runtime_dir"; then
            debug_log "Codex runtime left for manual review: $runtime_dir"
            continue
        fi

        if is_codex_runtime_stale "$runtime_dir"; then
            _codex_runtime_safe_clean_guarded "$runtime_dir" || return 0
        else
            debug_log "Codex runtime left for manual review: $runtime_dir"
        fi
    done < <(command find "$runtime_root" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)
}

# Codex CLI and Desktop share state under ~/.codex. Keep it out of default
# cleanup so app indexes, sessions, credentials, and local thread state survive.
clean_codex_cli() {
    local codex_root="$HOME/.codex"
    [[ -d "$codex_root" ]] || return 0

    debug_log "Codex CLI state left intact by default: $codex_root"
}

_MOLE_CODEX_MARKETPLACE_STAGING_ROOT=""
_MOLE_CODEX_MARKETPLACE_STAGING_ENTRY=""

_codex_marketplace_staging_entry_is_still_stale() {
    local staging_root="$_MOLE_CODEX_MARKETPLACE_STAGING_ROOT"
    local stale_entry="$_MOLE_CODEX_MARKETPLACE_STAGING_ENTRY"
    [[ -n "$staging_root" && -n "$stale_entry" ]] || return 1
    [[ "${stale_entry%/*}" == "$staging_root" ]] || return 1
    [[ -d "$stale_entry" && ! -L "$stale_entry" ]] || return 1

    local physical_before=""
    local physical_after=""
    physical_before=$(codex_staging_physical_path "$stale_entry" "$staging_root") || return 1

    if [[ -z "$(command find -P "$stale_entry" -maxdepth 0 -type d \
        -mtime +"$MOLE_ORPHAN_AGE_DAYS" 2> /dev/null)" ]]; then
        return 1
    fi

    physical_after=$(codex_staging_physical_path "$stale_entry" "$staging_root") || return 1
    [[ "$physical_before" == "$physical_after" ]] || return 1
    return 0
}

_codex_marketplace_staging_delete_guard_allows() {
    _codex_marketplace_staging_entry_is_still_stale || return 1
    mole_clean_process_guard codex_runtime_process_state "Codex started" || return 1
    if staging_root_has_open_files "$_MOLE_CODEX_MARKETPLACE_STAGING_ROOT"; then
        _MOLE_CLEAN_GUARD_REASON="open files"
        return 1
    else
        local open_file_state=$?
        if [[ "$open_file_state" -eq 2 ]]; then
            _MOLE_CLEAN_GUARD_REASON="open-file check unavailable"
            return 1
        fi
    fi
    _codex_marketplace_staging_entry_is_still_stale || return 1
    return 0
}

_codex_marketplace_staging_safe_clean_guarded() {
    local staging_root="$1"
    local stale_entry="$2"
    local display_name="$3"
    _MOLE_CODEX_MARKETPLACE_STAGING_ROOT="$staging_root"
    _MOLE_CODEX_MARKETPLACE_STAGING_ENTRY="$stale_entry"
    local _MOLE_CLEAN_GUARD_REASON="staging entry changed"

    # No engine-absent fallback here on purpose: a second, degraded copy of the
    # delete guard is a place the guarded and unguarded verdicts can disagree,
    # and the audit in `tests/clean_core.bats` caps how many of those exist.
    # Standalone callers provide `safe_clean_guarded` instead.
    local guarded_rc=0
    safe_clean_guarded _codex_marketplace_staging_delete_guard_allows \
        "$stale_entry" "$display_name" || guarded_rc=$?
    return "$guarded_rc"
}

# Abandoned Codex marketplace staging leftovers (#1389). Completes marketplaces
# such as openai-bundled and configured marketplace dirs are never candidates;
# only exact staging prefixes under fixed roots, aged by MOLE_ORPHAN_AGE_DAYS.
# marketplace-backup-* stays out of scope until recovery semantics are clear.
clean_codex_marketplace_staging() {
    local tmp_root="$HOME/.codex/.tmp"
    [[ -d "$tmp_root" ]] || return 0

    local -a staging_roots=(
        "$tmp_root/bundled-marketplaces"
        "$tmp_root/marketplaces/.staging"
    )
    local -a staging_prefixes=(
        "openai-bundled.staging-"
        "marketplace-upgrade-"
        "marketplace-add-"
    )

    local -a stale_entries=()
    local -a stale_roots=()
    local staging_root prefix stale_entry
    for staging_root in "${staging_roots[@]}"; do
        [[ -d "$staging_root" ]] || continue
        if ! codex_staging_physical_path "$staging_root" "$staging_root" > /dev/null; then
            debug_log "Codex marketplace staging skipped: unsafe root $staging_root"
            continue
        fi
        while IFS= read -r -d '' stale_entry; do
            local base
            base=$(basename "$stale_entry")
            local matched=false
            for prefix in "${staging_prefixes[@]}"; do
                case "$base" in
                    "$prefix"*)
                        matched=true
                        break
                        ;;
                esac
            done
            [[ "$matched" == "true" ]] || continue
            if ! codex_staging_physical_path "$stale_entry" "$staging_root" > /dev/null; then
                continue
            fi
            if ! mole_cleanup_targets_exist "$stale_entry"; then
                continue
            fi
            if [[ -n "$(command find -P "$stale_entry" -maxdepth 0 -type d \
                -mtime +"$MOLE_ORPHAN_AGE_DAYS" 2> /dev/null)" ]]; then
                stale_entries+=("$stale_entry")
                stale_roots+=("$staging_root")
            fi
        done < <(command find -P "$staging_root" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)
    done
    [[ ${#stale_entries[@]} -gt 0 ]] || return 0

    if is_path_whitelisted "$tmp_root" || is_path_whitelisted "$HOME/.codex"; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Codex marketplace staging · would skip (whitelist)"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Codex marketplace staging · skipped (whitelist)"
        fi
        note_activity
        return 0
    fi

    local process_state=0
    codex_runtime_process_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex marketplace staging · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Codex"
        fi
        return 0
    fi

    local open_file_state=0
    # Probe each staging root for open files only when that root still has
    # candidates (open files on an idle sibling root must not block cleanup
    # elsewhere).
    local idx=0
    for stale_entry in "${stale_entries[@]}"; do
        staging_root="${stale_roots[$idx]}"
        idx=$((idx + 1))

        if is_path_whitelisted "$stale_entry"; then
            continue
        fi

        open_file_state=0
        if staging_root_has_open_files "$staging_root"; then
            mole_defer_cleanup_family "Codex"
            return 0
        else
            open_file_state=$?
        fi
        if [[ "$open_file_state" -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex marketplace staging · skipped (open-file check unavailable)"
            note_activity
            return 0
        fi

        local guarded_rc=0
        _codex_marketplace_staging_safe_clean_guarded \
            "$staging_root" "$stale_entry" \
            "Codex marketplace staging" || guarded_rc=$?
        if [[ $guarded_rc -eq 75 ]]; then
            case "${_MOLE_CLEAN_GUARD_REASON:-}" in
                "process state unknown" | "open-file check unavailable")
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex marketplace staging · stopped (${_MOLE_CLEAN_GUARD_REASON})"
                    note_activity
                    ;;
                "staging entry changed")
                    debug_log "Codex marketplace staging entry changed before cleanup: $stale_entry"
                    ;;
                *) mole_defer_cleanup_family "Codex" ;;
            esac
            return 0
        fi
    done
}

# Shared Chromium Default profile caches that are safe to regenerate.
clean_chromium_default_caches() {
    local profile_root="$1"
    local label="$2"
    local running_probe="${3:-}"
    local family="${4:-$label}"

    [[ -d "$profile_root" ]] || return 0

    if [[ -z "$running_probe" ]]; then
        safe_clean "$profile_root/Default/Cache"/* "$label browser cache"
        safe_clean "$profile_root/Default/Code Cache"/* "$label code cache"
        safe_clean "$profile_root/Default/GPUCache"/* "$label GPU cache"
        safe_clean "$profile_root/Default/DawnGraphiteCache"/* "$label Dawn cache"
        safe_clean "$profile_root/Default/DawnWebGPUCache"/* "$label WebGPU cache"
        return 0
    fi

    _dev_safe_clean_process_guarded "$running_probe" "$family" "$label browser cache" \
        "$profile_root/Default/Cache"/* "$label browser cache" || return 1
    _dev_safe_clean_process_guarded "$running_probe" "$family" "$label code cache" \
        "$profile_root/Default/Code Cache"/* "$label code cache" || return 1
    _dev_safe_clean_process_guarded "$running_probe" "$family" "$label GPU cache" \
        "$profile_root/Default/GPUCache"/* "$label GPU cache" || return 1
    _dev_safe_clean_process_guarded "$running_probe" "$family" "$label Dawn cache" \
        "$profile_root/Default/DawnGraphiteCache"/* "$label Dawn cache" || return 1
    _dev_safe_clean_process_guarded "$running_probe" "$family" "$label WebGPU cache" \
        "$profile_root/Default/DawnWebGPUCache"/* "$label WebGPU cache" || return 1
}

# Antigravity (Gemini) keeps a full Chromium profile under
# ~/.gemini/antigravity-browser-profile. Clean its regenerable browser
# caches, mirroring the Antigravity Electron cache cleanup in clean_dev_misc.
clean_antigravity_caches() {
    local ag_profile="$HOME/.gemini/antigravity-browser-profile"
    [[ -d "$ag_profile" ]] || return 0

    mole_cleanup_targets_exist \
        "$ag_profile/Default/Cache"/* \
        "$ag_profile/Default/Code Cache"/* \
        "$ag_profile/Default/GPUCache"/* \
        "$ag_profile/Default/DawnGraphiteCache"/* \
        "$ag_profile/Default/DawnWebGPUCache"/* \
        "$ag_profile/GraphiteDawnCache"/* \
        "$ag_profile/component_crx_cache"/* \
        "$ag_profile/extensions_crx_cache"/* \
        "$ag_profile/Default/Service Worker/CacheStorage"/* || return 0

    local process_state=0
    antigravity_or_gemini_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Antigravity/Gemini caches · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Antigravity/Gemini"
        fi
        return 0
    fi

    clean_chromium_default_caches \
        "$ag_profile" \
        "Antigravity" \
        antigravity_or_gemini_running \
        "Antigravity/Gemini" || return 0
    _dev_safe_clean_process_guarded antigravity_or_gemini_running "Antigravity/Gemini" \
        "Antigravity Graphite cache" "$ag_profile/GraphiteDawnCache"/* "Antigravity Graphite cache" || return 0
    _dev_safe_clean_process_guarded antigravity_or_gemini_running "Antigravity/Gemini" \
        "Antigravity component cache" "$ag_profile/component_crx_cache"/* "Antigravity component cache" || return 0
    _dev_safe_clean_process_guarded antigravity_or_gemini_running "Antigravity/Gemini" \
        "Antigravity extension cache" "$ag_profile/extensions_crx_cache"/* "Antigravity extension cache" || return 0
    _dev_clean_service_worker_process_guarded \
        antigravity_or_gemini_running \
        "Antigravity/Gemini" \
        "Antigravity Service Worker" \
        "Antigravity" \
        "$ag_profile/Default/Service Worker/CacheStorage" || return 0
    # Never clean ~/.gemini/tmp: despite the name it stores gemini-cli
    # conversation checkpoints and prompt history (AI chat state, not temp).
}

clean_chrome_devtools_mcp_caches() {
    local mcp_profile="$HOME/.cache/chrome-devtools-mcp/chrome-profile"
    [[ -d "$mcp_profile" ]] || return 0

    mole_cleanup_targets_exist \
        "$mcp_profile/Default/Cache"/* \
        "$mcp_profile/Default/Code Cache"/* \
        "$mcp_profile/Default/GPUCache"/* \
        "$mcp_profile/Default/DawnGraphiteCache"/* \
        "$mcp_profile/Default/DawnWebGPUCache"/* \
        "$mcp_profile/Default/DawnCache"/* \
        "$mcp_profile/Default/GrShaderCache"/* \
        "$mcp_profile/Default/GraphiteDawnCache"/* \
        "$mcp_profile/GraphiteDawnCache"/* \
        "$mcp_profile/component_crx_cache"/* \
        "$mcp_profile/extensions_crx_cache"/* \
        "$mcp_profile/Default/Service Worker/CacheStorage"/* || return 0

    local process_state=0
    chrome_devtools_mcp_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Chrome DevTools MCP caches · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Chrome DevTools MCP"
        fi
        return 0
    fi

    clean_chromium_default_caches \
        "$mcp_profile" \
        "Chrome DevTools MCP" \
        chrome_devtools_mcp_running \
        "Chrome DevTools MCP" || return 0
    _dev_safe_clean_process_guarded chrome_devtools_mcp_running "Chrome DevTools MCP" \
        "Chrome DevTools MCP Dawn cache" "$mcp_profile/Default/DawnCache"/* "Chrome DevTools MCP Dawn cache" || return 0
    _dev_safe_clean_process_guarded chrome_devtools_mcp_running "Chrome DevTools MCP" \
        "Chrome DevTools MCP shader cache" "$mcp_profile/Default/GrShaderCache"/* "Chrome DevTools MCP shader cache" || return 0
    _dev_safe_clean_process_guarded chrome_devtools_mcp_running "Chrome DevTools MCP" \
        "Chrome DevTools MCP Graphite cache" "$mcp_profile/Default/GraphiteDawnCache"/* \
        "$mcp_profile/GraphiteDawnCache"/* "Chrome DevTools MCP Graphite cache" || return 0
    _dev_safe_clean_process_guarded chrome_devtools_mcp_running "Chrome DevTools MCP" \
        "Chrome DevTools MCP component cache" "$mcp_profile/component_crx_cache"/* "Chrome DevTools MCP component cache" || return 0
    _dev_safe_clean_process_guarded chrome_devtools_mcp_running "Chrome DevTools MCP" \
        "Chrome DevTools MCP extension cache" "$mcp_profile/extensions_crx_cache"/* "Chrome DevTools MCP extension cache" || return 0

    if declare -f clean_service_worker_cache > /dev/null 2>&1; then
        _dev_clean_service_worker_process_guarded \
            chrome_devtools_mcp_running \
            "Chrome DevTools MCP" \
            "Chrome DevTools MCP Service Worker" \
            "Chrome DevTools MCP" \
            "$mcp_profile/Default/Service Worker/CacheStorage" || return 0
    fi
}

# Misc dev tool caches.
clean_dev_misc() {
    # Antigravity browser profile caches (~/.gemini)
    clean_antigravity_caches
    # Prisma ORM engine binaries cache
    safe_clean ~/.cache/prisma/* "Prisma cache"
    # OpenCode AI tool cache
    safe_clean ~/.cache/opencode/* "OpenCode cache"
    # OpenCode snapshots back restore/revert, while diagnostic JSONL logs can
    # contain prompts and transcript events. Neither is default-cleanable.
    # Codex runtimes contain active Node/Python dependencies.
    clean_codex_runtimes
    # Abandoned marketplace staging under ~/.codex/.tmp (completed marketplaces stay).
    clean_codex_marketplace_staging
    # Codex CLI working-directory caches (~/.codex)
    clean_codex_cli
    # Cursor Agent session logs (versions cleaned separately in clean_dev_ai_agents)
    [[ -d "$HOME/.local/share/cursor-agent" ]] && safe_find_delete "$HOME/.local/share/cursor-agent" "*.log" "$MOLE_LOG_AGE_DAYS" "f"
    # Playwright browser revisions are hard-protected by should_protect_path,
    # so no safe_clean call here can ever remove them. They cost a 100-500 MB
    # CDN re-download and a stale registry link does not prove the user is done
    # with the revision. Keep this surface read-only.
    # Chrome DevTools MCP keeps a Chromium profile; clean only rebuildable caches.
    clean_chrome_devtools_mcp_caches
    # Claude Code state under ~/.claude can include persistent memory,
    # plugin registry data, hooks, and session context. Do not clean it
    # automatically; users can remove specific paths manually if needed.
    debug_log "Claude Code state under ~/.claude left intact by default"
}
# Shell and VCS leftovers.
clean_dev_shell() {
    safe_clean ~/.gitconfig.lock "Git config lock"
    safe_clean ~/.gitconfig.bak* "Git config backup"
    safe_clean ~/.oh-my-zsh/cache/* "Oh My Zsh cache"
    safe_clean ~/.config/fish/fish_history.bak* "Fish shell backup"
    safe_clean ~/.bash_history.bak* "Bash history backup"
    safe_clean ~/.zsh_history.bak* "Zsh history backup"
    safe_clean ~/.cache/pre-commit/* "pre-commit cache"
}
# Network tool caches.
clean_dev_network() {
    safe_clean ~/.cache/curl/* "curl cache"
    safe_clean ~/.cache/wget/* "wget cache"
}
# Elixir/Erlang ecosystem.
# Note: ~/.mix/archives contains installed Mix tools - excluded from cleanup
clean_dev_elixir() {
    safe_clean ~/.hex/cache/* "Hex cache"
}
# Haskell has no cleanup stage: ~/.stack/programs holds Stack-installed GHC
# compilers and ~/.cabal/packages is the downloaded source-tarball store cabal
# resolves builds against, so both are toolchain or dependency state rather
# than a redundant copy Mole can drop.
# OCaml ecosystem.
clean_dev_ocaml() {
    safe_clean ~/.opam/download-cache/* "Opam cache"
}

# Remove extension directories that VS Code / Cursor have marked obsolete.
# Each editor writes a .obsolete JSON file under its extensions root whose keys
# are stale extension directory names left behind after an extension update.
clean_editor_obsolete_extensions() {
    local -a editor_roots=(
        "$HOME/.vscode/extensions|VS Code"
        "$HOME/.vscode-insiders/extensions|VS Code Insiders"
        "$HOME/.cursor/extensions|Cursor"
    )
    local entry ext_root editor_label obsolete_file key target
    for entry in "${editor_roots[@]}"; do
        ext_root="${entry%%|*}"
        editor_label="${entry##*|}"
        obsolete_file="$ext_root/.obsolete"
        [[ -f "$obsolete_file" ]] || continue

        while IFS= read -r key; do
            # Each key must be a plain direct-child directory name; reject
            # anything that could escape the extensions root.
            case "$key" in
                "" | "." | ".." | */*) continue ;;
            esac
            target="$ext_root/$key"
            [[ -d "$target" ]] || continue
            safe_clean "$target" "Obsolete $editor_label extension"
        done < <(
            # .obsolete is plain JSON; extract keys portably.
            grep -oE '"[^"]+"[[:space:]]*:' "$obsolete_file" 2> /dev/null |
                sed -E 's/^"(.*)"[[:space:]]*:\s*$/\1/'
        )
    done
}

_run_developer_cleanup_step() {
    local strict=false
    if [[ "${1:-}" == "--strict" ]]; then
        strict=true
        shift
    fi

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ $pending_clean_cancel -eq 124 || $pending_clean_cancel -ge 128 ]]; then
        return "$pending_clean_cancel"
    fi

    local step_rc=0
    "$@" || step_rc=$?
    if [[ $step_rc -eq 124 || $step_rc -ge 128 ]]; then
        _mole_record_clean_cancellation "$step_rc"
        return "$step_rc"
    fi

    pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ $pending_clean_cancel -eq 124 || $pending_clean_cancel -ge 128 ]]; then
        return "$pending_clean_cancel"
    fi
    [[ "$strict" == "true" && $step_rc -ne 0 ]] && return "$step_rc"
    return 0
}

# Main developer tools cleanup sequence.
clean_developer_tools() {
    stop_section_spinner

    # CLI tools and languages
    _run_developer_cleanup_step clean_dev_npm || return $?
    _run_developer_cleanup_step clean_dev_python || return $?
    _run_developer_cleanup_step clean_dev_go || return $?
    _run_developer_cleanup_step clean_dev_mise || return $?
    _run_developer_cleanup_step clean_dev_rust || return $?
    _run_developer_cleanup_step check_rust_toolchains || return $?
    _run_developer_cleanup_step clean_dev_ruby || return $?
    _run_developer_cleanup_step clean_dev_perl || return $?
    _run_developer_cleanup_step clean_dev_docker || return $?
    _run_developer_cleanup_step clean_dev_cloud || return $?
    _run_developer_cleanup_step clean_dev_nix || return $?
    _run_developer_cleanup_step clean_dev_shell || return $?
    _run_developer_cleanup_step clean_dev_frontend || return $?
    _run_developer_cleanup_step clean_project_caches || return $?
    _run_developer_cleanup_step clean_dev_jvm || return $?
    _run_developer_cleanup_step clean_dev_ai_agents || return $?
    _run_developer_cleanup_step clean_dev_other_langs || return $?
    _run_developer_cleanup_step clean_dev_cicd || return $?
    _run_developer_cleanup_step clean_dev_network || return $?
    _run_developer_cleanup_step clean_dev_misc || return $?
    _run_developer_cleanup_step clean_dev_elixir || return $?
    _run_developer_cleanup_step clean_dev_ocaml || return $?


    # GUI developer applications
    _run_developer_cleanup_step clean_editor_obsolete_extensions || return $?
}
