#!/bin/bash
# Mole - Linux leftover discovery for uninstalled applications.
#
# Contract §5 tiering:
#
#   safe tier   : exact-id directories under the XDG roots
#                 (<config>/<id>, <data>/<id>, <cache>/<id>, <state>/<id>)
#                 plus the dotfile forms ~/<id>, ~/.<id>, ~/.<id>rc.
#                 Eligible for automatic removal once the app is gone and
#                 path protection passes.
#
#   review tier : display-name-derived candidates (exact name match only,
#                 no wildcards or generic-word matching) under the same XDG
#                 roots and home dotfile forms. Never deleted automatically;
#                 surfaced as "Review only".
#
# Escalations to review-only regardless of tier:
#   - id listed in DATA_PROTECTED_IDS (app_protection_data.sh)
#   - path still owned by an installed pacman package (never delete
#     pacman-owned files; contract §5)
#
# All functions are queries: they echo candidate paths or verdicts and never
# modify anything.

if [[ -n "${MOLE_UNINSTALL_LEFTOVERS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UNINSTALL_LEFTOVERS_LOADED=1

_MOLE_LEFTOVERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_UNINSTALL_BACKEND_PACMAN_LOADED:-}" ]]; then
    # shellcheck source=lib/uninstall/backends/pacman.sh
    source "$_MOLE_LEFTOVERS_DIR/backends/pacman.sh"
fi

# XDG base roots used by leftover discovery. Kept inline (standard
# parameter expansions) so this module stays testable without the platform
# layer; values match contract §1's linux root getters.
_leftovers_xdg_roots() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}"
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# Flatpak per-app data directory (contract §5: previewed explicitly before
# any flatpak removal).
leftovers_flatpak_data_dir() {
    local app_id="$1"
    [[ -n "$app_id" ]] || return 1
    printf '%s/.var/app/%s\n' "$HOME" "$app_id"
}

# Safe-tier candidates for an exact application id (existing paths only).
leftovers_exact_paths() {
    local app_id="$1"

    local root
    while IFS= read -r root; do
        [[ -e "$root/$app_id" ]] && printf '%s/%s\n' "$root" "$app_id"
    done < <(_leftovers_xdg_roots)

    local home_form
    for home_form in "$HOME/$app_id" "$HOME/.$app_id" "$HOME/.${app_id}rc"; do
        [[ -e "$home_form" ]] && printf '%s\n' "$home_form"
    done
}

# Review-tier candidates derived from the display name (existing paths only,
# exact-name match at maxdepth 1; case-insensitive compare, no globs).
leftovers_review_paths() {
    local display_name="$1"
    [[ -n "$display_name" ]] || return 0

    # Reject generic/common words: single common nouns match too many
    # unrelated directories (same policy as LAUNCH_AGENT_NAME_COMMON_WORDS).
    case "$display_name" in
        [Ee]ditor | [Tt]erminal | [Ff]iles | [Ss]ettings | [Cc]enter | [Mm]anager | [Hh]elper | [Uu]tility | [Tt]ools | [Ss]ystem)
            return 0
            ;;
    esac

    local root
    while IFS= read -r root; do
        [[ -d "$root" ]] || continue
        local -a matches=()
        local entry
        while IFS= read -r entry; do
            matches+=("$entry")
        done < <(command find "$root" -mindepth 1 -maxdepth 1 2> /dev/null)
        local candidate
        for candidate in "${matches[@]+"${matches[@]}"}"; do
            if [[ "${candidate##*/}" == "$display_name" ]]; then
                printf '%s\n' "$candidate"
            elif [[ "${candidate##*/}" == "$display_name".* ]]; then
                printf '%s\n' "$candidate"
            fi
        done
    done < <(_leftovers_xdg_roots)

    if [[ -e "$HOME/$display_name" ]]; then
        printf '%s\n' "$HOME/$display_name"
    fi
}

# Echo "yes" when the id must always go through the review tier.
leftover_is_data_protected_id() {
    local app_id="$1"
    [[ -n "$app_id" ]] || return 1

    if declare -f should_protect_linux_leftover_id > /dev/null 2>&1; then
        should_protect_linux_leftover_id "$app_id" || return 1
        echo "yes"
        return 0
    fi

    return 1
}

# Echo the owning package names for a path when pacman is present and owns
# it; quiet nonzero otherwise.
leftover_owner_packages() {
    local path="$1"
    pacman_backend_owns_path "$path" || return 1
    LC_ALL=C pacman -Qoq -- "$path" 2> /dev/null
}

# Classify one leftover candidate path.
# Echoes: "safe" | "review" | "skip"
#   skip   : pacman-owned or inside a protected system location
#   review : data-protected id or display-name-derived evidence
#   safe   : exact-id evidence with no ownership conflict
leftovers_classify_path() {
    local path="$1"
    local reason="${2:-}" # "id" (exact-id) or "name" (display-derived)

    [[ -n "$path" && -e "$path" ]] || {
        echo "skip"
        return 0
    }

    if declare -f is_linux_critical_system_path > /dev/null 2>&1 &&
        is_linux_critical_system_path "$path"; then
        echo "skip"
        return 0
    fi

    if leftover_owner_packages "$path" > /dev/null 2>&1; then
        echo "skip"
        return 0
    fi

    if [[ "$reason" != "id" ]]; then
        echo "review"
        return 0
    fi

    if leftover_is_data_protected_id "${path##*/}" > /dev/null 2>&1; then
        echo "review"
        return 0
    fi

    echo "safe"
}

# Running-app warning (tri-state via mole_pgrep_any):
# echoes "running" | "clear" | "unknown".
leftovers_running_state() {
    local app_id="$1"
    local display_name="${2:-}"

    local -a probes=()
    [[ -n "$app_id" ]] && probes+=(-x "$app_id")
    [[ -n "$display_name" && "$display_name" != "$app_id" ]] && probes+=(-x "$display_name")
    [[ ${#probes[@]} -eq 0 ]] && probes+=(-f "$app_id")

    mole_pgrep_any "${probes[@]}"
}
