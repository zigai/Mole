#!/bin/bash
# Mole - macOS Platform Defaults
# Loaded by platform.sh when mole_detect_platform resolves to darwin.
# Keeps macOS behavior identical to the pre-fork layout: logs live under
# ~/Library/Logs/mole and deletion keeps using the legacy osascript flow.

# macOS has no distro layering; keep the identifier empty so callers can
# distinguish "not a Linux distribution" from any real distribution ID.
export MOLE_DISTRO_ID="${MOLE_DISTRO_ID:-}"

mole_state_dir() {
    printf '%s\n' "${HOME}/Library/Logs/mole"
}

# macOS callers use the legacy osascript Trash flow directly; nothing to emit.
mole_trash_cmd() {
    :
}
