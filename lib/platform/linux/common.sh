#!/bin/bash
# Mole - Linux Shared Platform Helpers
# Loaded by platform.sh when mole_detect_platform resolves to linux.
# Distro-specific capability modules live next to this file (arch.sh,
# generic.sh) and are selected by mole_detect_distro.

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_LINUX_COMMON_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_LINUX_COMMON_LOADED=1

# True when $1 resolves to an executable in PATH.
have_cmd() {
    command -v "$1" > /dev/null 2>&1
}

linux_cache_home() {
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}"
}

linux_config_home() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

linux_data_home() {
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

linux_state_home() {
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# Trash root for user files; gio trash manages the files/ and info/
# subdirectories itself.
linux_trash_dir() {
    printf '%s\n' "$(linux_data_home)/Trash"
}

mole_state_dir() {
    printf '%s\n' "$(linux_state_home)/mole"
}

# Echo "gio" when gio is available to route deletions to the Trash, else
# echo nothing (callers fall back to permanent delete with a notice).
mole_trash_cmd() {
    if have_cmd gio; then
        printf 'gio\n'
    fi
    return 0
}
