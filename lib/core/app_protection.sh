#!/bin/bash
# Mole - Application Protection
# System critical and data-protected application lists

set -euo pipefail

if [[ -n "${MOLE_APP_PROTECTION_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_APP_PROTECTION_LOADED=1

_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${MOLE_BASE_LOADED:-}" ]] && source "$_MOLE_CORE_DIR/base.sh"
if [[ -z "${MOLE_TIMEOUT_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeout.sh
    source "$_MOLE_CORE_DIR/timeout.sh"
fi
if [[ -z "${MOLE_TIMEOUTS_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeouts.sh
    source "$_MOLE_CORE_DIR/timeouts.sh"
fi

# Declare WHITELIST_PATTERNS if not already set (used by is_path_whitelisted)
if ! declare -p WHITELIST_PATTERNS &> /dev/null; then
    declare -a WHITELIST_PATTERNS=()
fi

# Bundle ID / pattern data is sourced from a sibling file so this file
# stays focused on logic. See app_protection_data.sh for the lists.
# shellcheck source=lib/core/app_protection_data.sh
source "$_MOLE_CORE_DIR/app_protection_data.sh"

# Centralized check for critical system components (case-insensitive)
is_critical_system_component() {
    local token="$1"
    [[ -z "$token" ]] && return 1

    local lower
    lower=$(echo "$token" | LC_ALL=C tr '[:upper:]' '[:lower:]')

    case "$lower" in
        *backgroundtaskmanagement* | *loginitems* | *systempreferences* | *systemsettings* | *settings* | *preferences* | *controlcenter* | *biometrickit* | *sfl* | *tcc*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


# Check if application data should be protected during cleanup
should_protect_data() {
    local bundle_id="$1"

    case "$bundle_id" in
        loginwindow | dock | systempreferences | finder | safari)
            return 0
            ;;
        # CUPS is an OS-provided subsystem with no user-facing app; without this
        # guard its printing-preferences id (which holds the default printer and
        # recent printers) looks orphaned. See #731.
        org.cups.*)
            return 0
            ;;
        backgroundtaskmanagement* | keychain* | security* | bluetooth* | wifi* | network* | tcc)
            return 0
            ;;
        notification* | accessibility* | universalaccess* | HIToolbox*)
            return 0
            ;;
        *inputmethod* | *InputMethod* | *IME | textinput* | TextInput*)
            return 0
            ;;
        keyboard* | Keyboard* | inputsource* | InputSource* | keylayout* | KeyLayout*)
            return 0
            ;;
        GlobalPreferences | .GlobalPreferences | org.pqrs.Karabiner*)
            return 0
            ;;
        com.1password.* | com.agilebits.* | com.lastpass.* | com.dashlane.* | com.bitwarden.*)
            return 0
            ;;
        com.jetbrains.* | JetBrains* | com.microsoft.* | com.visualstudio.*)
            return 0
            ;;
        com.sublimetext.* | com.sublimehq.* | Cursor | Claude | ChatGPT | com.openai.codex | Codex | codex-runtimes | Ollama)
            return 0
            ;;
        # Specific match to avoid ShellCheck redundancy warning with com.clash.*
        com.clash.app)
            return 0
            ;;
        com.nssurge.* | com.v2ray.* | com.clash.* | ClashX* | Surge* | Shadowrocket* | Quantumult*)
            return 0
            ;;
        clash-* | Clash-* | *-clash | *-Clash | clash.* | Clash.* | clash_* | *clash-verge* | *Clash-Verge* | clashverge* | ClashVerge*)
            return 0
            ;;
        com.docker.* | com.getpostman.* | com.insomnia.*)
            return 0
            ;;
    esac

    return 1
}

# Shared XDG and user-local roots contain state owned by many unrelated tools.
# App display names such as "Local", "Config", or "Cache" can spell these
# roots with different casing, which still resolves to the same directory on a
# default case-insensitive APFS volume. Protect the shared roots themselves but
# not app-specific children such as ~/.config/zed or ~/.local/share/firefox.
_mole_is_shared_home_state_root() {
    local path="${1%/}"
    case "$path" in
        "$HOME"/.[Cc][Aa][Cc][Hh][Ee] | \
            "$HOME"/.[Cc][Oo][Nn][Ff][Ii][Gg] | \
            "$HOME"/.[Ll][Oo][Cc][Aa][Ll] | \
            "$HOME"/.[Ll][Oo][Cc][Aa][Ll]/[Bb][Ii][Nn] | \
            "$HOME"/.[Ll][Oo][Cc][Aa][Ll]/[Ll][Ii][Bb] | \
            "$HOME"/.[Ll][Oo][Cc][Aa][Ll]/[Ss][Hh][Aa][Rr][Ee] | \
            "$HOME"/.[Ll][Oo][Cc][Aa][Ll]/[Ss][Tt][Aa][Tt][Ee])
            return 0
            ;;
    esac
    return 1
}

# Linux safety additions (contract §4).
# Exact package-name match against SYSTEM_CRITICAL_PACKAGES. Used by the
# Linux uninstall enumeration to keep core system packages out of the
# selector, and by the batch executor as a removal-time deny.
is_protected_linux_package() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 1
    local pattern
    for pattern in "${SYSTEM_CRITICAL_PACKAGES[@]+"${SYSTEM_CRITICAL_PACKAGES[@]}"}"; do
        [[ "$pkg" == "$pattern" ]] && return 0
    done
    return 1
}

# Exact case-insensitive id match against DATA_PROTECTED_IDS: leftover
# discovery must surface these through the review-only tier even when the
# exact-id evidence would otherwise be safe.
should_protect_linux_leftover_id() {
    local app_id="$1"
    [[ -n "$app_id" ]] || return 1
    local lowered_id lowered_pattern pattern
    lowered_id=$(printf '%s' "$app_id" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    for pattern in "${DATA_PROTECTED_IDS[@]+"${DATA_PROTECTED_IDS[@]}"}"; do
        lowered_pattern=$(printf '%s' "$pattern" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        [[ "$lowered_id" == "$lowered_pattern" ]] && return 0
        # Flatpak ids are reverse-DNS (org.keepassxc.KeePassXC); also accept a
        # match on the final segment so DATA_PROTECTED_IDS entries apply.
        [[ "${lowered_id##*.}" == "$lowered_pattern" ]] && return 0
    done
    return 1
}

# Absolute system locations that are never deletable on Linux (dir itself
# and everything beneath). The user entries protect the directory AND its
# contents; ~/.config protects only the directory itself so children stay
# sweepable.
is_linux_critical_system_path() {
    local path="${1%/}"
    [[ -n "$path" ]] || return 1

    local critical
    for critical in "${LINUX_CRITICAL_SYSTEM_PATHS[@]+"${LINUX_CRITICAL_SYSTEM_PATHS[@]}"}"; do
        if [[ "$path" == "$critical" || "$path" == "$critical"/* ]]; then
            return 0
        fi
    done

    local user_entry
    for user_entry in "${LINUX_CRITICAL_USER_PATHS[@]+"${LINUX_CRITICAL_USER_PATHS[@]}"}"; do
        if [[ "$path" == "$HOME/$user_entry" || "$path" == "$HOME/$user_entry"/* ]]; then
            return 0
        fi
    done

    # ~/.config itself is denied; its children are handled by
    # _mole_is_shared_home_state_root and the normal sweep rules.
    if [[ "$path" == "${XDG_CONFIG_HOME:-$HOME/.config}" ]]; then
        return 0
    fi

    return 1
}

# Native-package-ownership guard: a path owned by an installed package must
# never be deleted manually; removal goes through the distro package manager
# itself. Probes pacman, then rpm, then dpkg by availability. Active during
# uninstall flows where the candidate set is small; sweeps on clean paths do
# not pay a per-path subprocess cost.
mole_pacman_owns_path() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    if command -v pacman > /dev/null 2>&1; then
        LC_ALL=C pacman -Qoq -- "$path" > /dev/null 2>&1
    elif command -v rpm > /dev/null 2>&1; then
        LC_ALL=C rpm -qf --queryformat '%{NAME}\n' -- "$path" > /dev/null 2>&1
    elif command -v dpkg-query > /dev/null 2>&1; then
        # Same database as `dpkg -S`, without taking the dpkg lock.
        LC_ALL=C dpkg-query -S -- "$path" > /dev/null 2>&1
    else
        return 1
    fi
}

# Centralized logic to protect system settings and critical paths.
#
# In uninstall mode (MOLE_UNINSTALL_MODE=1), only system-critical components are protected.
# Data-protected apps can be uninstalled when user explicitly chooses to.
#
# Args: $1 - path to check
# Returns: 0 if protected, 1 if safe to delete
should_protect_path() {
    local path="$1"
    [[ -z "$path" ]] && return 1

    if _mole_is_shared_home_state_root "$path"; then
        return 0
    fi

    # Critical system and user-path denies (contract §4).
    if is_linux_critical_system_path "$path"; then
        return 0
    fi

    # Mole's own runtime state is never deletable; cleanup cannot remove its
    # active log targets.
    local _mole_state_root="${XDG_STATE_HOME:-$HOME/.local/state}/mole"
    if [[ "$path" == "$_mole_state_root" || "$path" == "$_mole_state_root"/* ]]; then
        return 0
    fi

    # Package-ownership guard (contract §5): never manually delete a file an
    # installed package owns. Bounded to uninstall flows so cache sweeps do
    # not pay a per-path subprocess.
    if [[ "${MOLE_UNINSTALL_MODE:-0}" == "1" ]] && mole_pacman_owns_path "$path"; then
        return 0
    fi

    # Codex CLI keeps conversation indexes, auth, and app state in cache-
    # shaped paths under ~/.codex. Default cleanup must not remove those
    # records.
    case "$path" in
        */.codex/sessions | */.codex/sessions/* | \
            */.codex/auth.json | */.codex/history.jsonl | \
            */.codex/state_*.sqlite | */.codex/logs_*.sqlite | \
            */.codex/session_index.jsonl | */.codex/cache/session_index.jsonl | \
            */.codex/cache/codex_app_directory | */.codex/cache/codex_app_directory/*)
            return 0
            ;;
    esac

    # Check if the filename itself matches any protected patterns.
    # Skipped in uninstall mode - user explicitly chose to remove this app.
    if [[ "${MOLE_UNINSTALL_MODE:-0}" != "1" ]]; then
        local filename="${path##*/}"
        if should_protect_data "$filename"; then
            return 0
        fi
    fi

    return 1
}

# Check if a path is protected by whitelist patterns
# Args: $1 - path to check
# Returns: 0 if whitelisted, 1 if not
is_path_whitelisted() {
    local target_path="$1"
    [[ -z "$target_path" ]] && return 1

    # Safety patterns protect regardless of user whitelist state, so bare
    # sourcing (tests, direct module calls) gets the same guarantees as a
    # full command run. Idempotent merge.
    if declare -F ensure_safety_whitelist_patterns > /dev/null 2>&1; then
        ensure_safety_whitelist_patterns || true
    fi

    # Normalize path (remove trailing slash, collapse consecutive slashes).
    # Callers sometimes concat a glob expansion that already ends in `/`
    # with a sub-path that begins with `/`, producing `.../Default//Service
    # Worker/...`. Without collapsing, those never match a whitelist entry
    # written with single separators. See #724.
    #
    # Note: on bash 3.2 (macOS default), `${var//\/\//\/}` leaves a literal
    # backslash in the replacement. Indirect variables sidestep that.
    local _slash_single="/"
    local _slash_double="//"
    local normalized_target="${target_path%/}"
    while [[ "$normalized_target" == *"$_slash_double"* ]]; do
        normalized_target="${normalized_target//$_slash_double/$_slash_single}"
    done

    # Empty whitelist means nothing is protected
    [[ ${#WHITELIST_PATTERNS[@]} -eq 0 ]] && return 1

    for pattern in "${WHITELIST_PATTERNS[@]}"; do
        # Pattern is already expanded/normalized in bin/clean.sh
        local check_pattern="${pattern%/}"
        while [[ "$check_pattern" == *"$_slash_double"* ]]; do
            check_pattern="${check_pattern//$_slash_double/$_slash_single}"
        done
        local has_glob="false"
        case "$check_pattern" in
            *\** | *\?* | *\[*)
                has_glob="true"
                ;;
        esac

        # Check for exact match or glob pattern match
        # shellcheck disable=SC2053
        if [[ "$normalized_target" == "$check_pattern" ]] ||
            [[ "$normalized_target" == $check_pattern ]]; then
            return 0
        fi

        # Check if target is a parent directory of a whitelisted path
        # e.g., if pattern is /path/to/dir/subdir and target is /path/to/dir,
        # the target should be protected to preserve its whitelisted children
        if [[ "$check_pattern" == "$normalized_target"/* ]]; then
            return 0
        fi

        # Check if target is a child of a whitelisted directory path
        if [[ "$has_glob" == "false" && "$normalized_target" == "$check_pattern"/* ]]; then
            return 0
        fi
    done

    return 1
}

