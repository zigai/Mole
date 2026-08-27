#!/bin/bash
# Mole self-removal: manual binaries, completion snippets, config/cache/logs.
# Extracted from the `mole` dispatcher, which now only routes.

set -euo pipefail

if [[ -n "${MOLE_MANAGE_REMOVE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_MANAGE_REMOVE_LOADED=1

# Removes binaries, completion snippets, and Mole-owned XDG dirs; the config
# dir holds user-authored state (whitelist, purge config), so it goes to the
# trash via gio when available and is left in place otherwise (#1346 parity).
_remove_mole_linux() {
    local dry_run_mode="${1:-false}"
    local test_mode=false
    if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        test_mode=true
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner "Detecting Mole installations..."
    else
        echo "Detecting installations..."
    fi

    local -a manual_installs=()
    local -a alias_installs=()

    local found_mole found_mo
    if [[ "$test_mode" != "true" ]]; then
        found_mole=$(command -v mole 2> /dev/null || true)
        [[ -n "$found_mole" && -f "$found_mole" ]] && manual_installs+=("$found_mole")
        found_mo=$(command -v mo 2> /dev/null || true)
        [[ -n "$found_mo" && -f "$found_mo" ]] && alias_installs+=("$found_mo")
    fi

    local -a binary_fallback=("$HOME/.local/bin/mole" "/usr/local/bin/mole")
    local -a alias_fallback=("$HOME/.local/bin/mo" "/usr/local/bin/mo")
    if [[ "$test_mode" == "true" ]]; then
        binary_fallback=("$HOME/.local/bin/mole")
        alias_fallback=("$HOME/.local/bin/mo")
    fi

    local path
    for path in "${binary_fallback[@]}"; do
        [[ -f "$path" ]] && manual_installs+=("$path")
    done
    for path in "${alias_fallback[@]}"; do
        [[ -f "$path" ]] && alias_installs+=("$path")
    done

    local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/mole"
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/mole"

    # Completion snippets installed by `mo completion` (fish files plus the
    # source line dropped into bash/zsh rc files).
    local -a fish_snippets=(
        "${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions/mole.fish"
        "${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions/mo.fish"
    )

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    printf '\n'

    if [[ ${#manual_installs[@]} -eq 0 && ${#alias_installs[@]} -eq 0 &&
        ! -d "$config_dir" && ! -d "$cache_dir" && ! -d "$state_dir" ]]; then
        printf '%s\n\n' "${YELLOW}No Mole installation detected${NC}"
        exit 0
    fi

    # Dry-run mode: show preview and exit without confirmation
    if [[ "$dry_run_mode" == "true" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, no files will be removed"
        echo ""
        echo -e "${YELLOW}Remove Mole${NC}, would delete the following:"
        local install
        for install in ${manual_installs[@]+"${manual_installs[@]}"} ${alias_installs[@]+"${alias_installs[@]}"}; do
            [[ -f "$install" ]] && echo -e "  ${GRAY}${ICON_LIST} Would remove: ${install}${NC}"
        done
        local snippet
        for snippet in "${fish_snippets[@]}"; do
            [[ -f "$snippet" ]]                 && echo -e "  ${GRAY}${ICON_LIST} Would remove: ${snippet}${NC}" || true
        done
        if grep -Eqs '(^# Mole shell completion$|(mole|mo)[[:space:]]+completion)' \
            "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" > /dev/null 2>&1; then
            echo -e "  ${GRAY}${ICON_LIST} Would strip completion entries from shell rc files${NC}"
        fi
        if [[ -d "$config_dir" ]]; then
            echo -e "  ${GRAY}${ICON_LIST} Would move to trash: $config_dir${NC}"
        fi
        if [[ -d "$cache_dir" ]]; then
            echo -e "  ${GRAY}${ICON_LIST} Would remove: $cache_dir${NC}"
        fi
        if [[ -d "$state_dir" ]]; then
            echo -e "  ${GRAY}${ICON_LIST} Would remove: $state_dir${NC}"
        fi

        printf '\n%s\n\n' "${GREEN}${ICON_SUCCESS}${NC} Dry run complete, no changes made"
        exit 0
    fi

    echo -e "${YELLOW}Remove Mole${NC}, will delete the following:"
    local install
    for install in ${manual_installs[@]+"${manual_installs[@]}"} ${alias_installs[@]+"${alias_installs[@]}"}; do
        echo "  ${ICON_LIST} $install"
    done
    local snippet
    for snippet in "${fish_snippets[@]}"; do
        if [[ -f "$snippet" ]]; then
            echo "  ${ICON_LIST} $snippet"
        fi
    done
    echo "  ${ICON_LIST} $config_dir (to trash)"
    echo "  ${ICON_LIST} $cache_dir"
    echo "  ${ICON_LIST} $state_dir"
    echo -ne "${PURPLE}${ICON_ARROW}${NC} Press ${GREEN}Enter${NC} to confirm, ${GRAY}ESC${NC} to cancel: "

    IFS= read -r -s -n1 key || key=""
    if declare -F drain_pending_input > /dev/null 2>&1; then
        drain_pending_input # Clean up any escape sequence remnants
    fi
    case "$key" in
        $'\e')
            exit 0
            ;;
        "" | $'\n' | $'\r')
            printf "\r\033[K" # Clear the prompt line
            ;;
        *)
            exit 0
            ;;
    esac

    local has_error=false

    _linux_remove_binary() {
        local target="$1"
        if [[ ! -w "$(dirname "$target")" ]]; then
            if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]] || ! sudo rm -f "$target" 2> /dev/null; then
                return 1
            fi
        else
            if ! rm -f "$target" 2> /dev/null; then
                return 1
            fi
        fi
    }

    for install in ${manual_installs[@]+"${manual_installs[@]}"} ${alias_installs[@]+"${alias_installs[@]}"}; do
        if [[ -f "$install" ]] && ! _linux_remove_binary "$install"; then
            has_error=true
        fi
    done

    for snippet in "${fish_snippets[@]}"; do
        if [[ -f "$snippet" ]] && ! rm -f "$snippet" 2> /dev/null; then
            has_error=true
        fi
    done

    # Strip completion source lines from rc files (same pattern completion.sh
    # uses when it rewrites an entry).
    local rc_file
    for rc_file in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        if [[ -f "$rc_file" ]] && grep -Eq '(^# Mole shell completion$|(mole|mo)[[:space:]]+completion)' "$rc_file" 2> /dev/null; then
            local temp_rc
            temp_rc=$(mktemp) || {
                has_error=true
                continue
            }
            grep -Ev '(^# Mole shell completion$|(mole|mo)[[:space:]]+completion)' "$rc_file" > "$temp_rc" || true
            if ! mv "$temp_rc" "$rc_file" 2> /dev/null; then
                rm -f "$temp_rc" 2> /dev/null || true # SAFE: exact mktemp-created rc rewrite scratch file.
                has_error=true
            fi
        fi
    done

    if [[ -d "$cache_dir" ]]; then
        rm -rf "$cache_dir" 2> /dev/null || true # SAFE: hardcoded Mole-owned dir, -d guarded
    fi
    if [[ -d "$state_dir" ]]; then
        rm -rf "$state_dir" 2> /dev/null || true # SAFE: hardcoded Mole-owned dir, -d guarded
    fi
    if [[ -d "$config_dir" ]]; then
        if command -v gio > /dev/null 2>&1 && gio trash "$config_dir" 2> /dev/null; then
            :
        else
            has_error=true
            log_warning "Could not move $config_dir to trash; left in place"
            log_warning "Manual step: rm -rf $config_dir (or install gio and rerun)"
        fi
    fi

    local final_message
    if [[ "$has_error" == "true" ]]; then
        final_message="${YELLOW}${ICON_ERROR} Mole uninstalled with some errors, thank you for using Mole!${NC}"
    else
        final_message="${GREEN}${ICON_SUCCESS} Mole uninstalled successfully, thank you for using Mole!${NC}"
    fi
    printf '\n%s\n\n' "$final_message"

    exit 0
}

# Remove flow: script installs only.
remove_mole() {
    _remove_mole_linux "${1:-false}"
    return 0
}
