#!/bin/bash
# Mole - flatpak uninstall enumeration backend (Linux).
#
# Row format (INTERNAL to lib/uninstall/backends/*, see pacman.sh header):
#
#     <backend>|<id>|<display-name>|<size-kb>|<target-path>
#
# Backend selection (contract §5): enabled whenever the `flatpak` binary is
# present, independent of the distro module.
#
# Removal policy (contract §5): ~/.var/app/<id> is enumerated for explicit
# preview by the caller and never trusted to --delete-data; this backend only
# plans `flatpak uninstall --noninteractive <id>`.

if [[ -n "${MOLE_UNINSTALL_BACKEND_FLATPAK_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UNINSTALL_BACKEND_FLATPAK_LOADED=1

flatpak_backend_available() {
    command -v flatpak > /dev/null 2>&1
}

flatpak_backend_app_ids() {
    flatpak_backend_available || return 0
    LC_ALL=C flatpak list --app --columns=application 2> /dev/null || return 0
}

# Convert a flatpak human size token pair ("<value> <unit>") into whole KiB.
_flatpak_backend_size_to_kb() {
    local value="$1"
    local unit="${2:-}"
    if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "0"
        return 0
    fi
    case "$unit" in
        kB | KB) LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", v }' ;;
        MB | MiB) LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", v * 1024 }' ;;
        GB | GiB) LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", v * 1048576 }' ;;
        B) LC_ALL=C awk -v v="$value" 'BEGIN { printf "%d", v / 1024 }' ;;
        *) echo "0" ;;
    esac
}

# Emit one row per installed app. Older flatpaks print an empty or bytes-only
# size column; unknown sizes degrade to "0" and the selector shows "--".
flatpak_backend_rows() {
    local listing=""
    if ! listing=$(LC_ALL=C flatpak list --app --columns=application,name,size 2> /dev/null); then
        return 0
    fi

    local line app_id name size_kb raw_value raw_unit target
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        app_id="${line%%$'\t'*}"
        line="${line#*$'\t'}"
        name="${line%%$'\t'*}"

        raw_value=""
        raw_unit=""
        if [[ "$line" == *$'\t'* ]]; then
            line="${line#*$'\t'}"
            # shellcheck disable=SC2086  # split value/unit deliberately
            set -- $line
            raw_value="${1:-}"
            raw_unit="${2:-}"
        fi

        [[ -n "$app_id" ]] || continue
        if [[ -z "$name" || "$name" == "null" ]]; then
            name="$app_id"
        fi

        size_kb=$(_flatpak_backend_size_to_kb "$raw_value" "$raw_unit")

        target="$HOME/.var/app/$app_id"
        if [[ ! -d "$target" ]]; then
            target=""
        fi

        name="${name//|//}"
        printf 'flatpak|%s|%s|%s|%s\n' "$app_id" "$name" "$size_kb" "$target"
    done <<< "$listing"
}

# Plan line for removing an app. Executed only after the caller re-verifies
# the id is still installed (TOCTOU spirit preserved).
flatpak_backend_uninstall_plan() {
    local app_id="$1"
    [[ -n "$app_id" ]] || return 1
    printf 'flatpak uninstall --noninteractive %s\n' "$app_id"
}

flatpak_backend_app_installed() {
    local app_id="$1"
    [[ -n "$app_id" ]] || return 1
    flatpak_backend_app_ids | grep -Fxq -- "$app_id"
}
