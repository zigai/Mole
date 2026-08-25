#!/bin/bash
# Mole - Linux uninstall enumeration: backend merge, dedupe, and index build.
#
# Merges the pacman / flatpak / desktop backends (row format documented in
# lib/uninstall/backends/pacman.sh) into the selector's app index. Dedupe
# priority when two backends surface the same identity:
#
#   1. pacman row (package owns the payload)
#   2. flatpak row
#   3. desktop-entry row
#
# A row collapses when its id was already seen OR its target path was already
# claimed by an earlier backend row.
#
# The final index uses the same pipe format as the macOS scan so the existing
# selector glue (lib/ui/app_selector.sh) and summary rendering work unchanged:
#
#     <last-used-epoch>|<target-path>|<display-name>|<kind:id>|<size>|<last-used>|<size-kb>
#
# kind:id encodes the removal channel for lib/uninstall/linux_batch.sh:
# "pacman:<pkg>", "flatpak:<app-id>", or "desktop:<binary-path>".
#
# Inventory fingerprint (metadata-cache key): checksum of the package list
# plus the flatpak app list.

if [[ -n "${MOLE_UNINSTALL_ENUMERATE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UNINSTALL_ENUMERATE_LOADED=1

_MOLE_ENUMERATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_UNINSTALL_BACKEND_PACMAN_LOADED:-}" ]]; then
    # shellcheck source=lib/uninstall/backends/pacman.sh
    source "$_MOLE_ENUMERATE_DIR/backends/pacman.sh"
fi
if [[ -z "${MOLE_UNINSTALL_BACKEND_FLATPAK_LOADED:-}" ]]; then
    # shellcheck source=lib/uninstall/backends/flatpak.sh
    source "$_MOLE_ENUMERATE_DIR/backends/flatpak.sh"
fi
if [[ -z "${MOLE_UNINSTALL_BACKEND_DESKTOP_LOADED:-}" ]]; then
    # shellcheck source=lib/uninstall/backends/desktop.sh
    source "$_MOLE_ENUMERATE_DIR/backends/desktop.sh"
fi

# Echo the enabled backend names, one per line.
enumerate_linux_backends() {
    if declare -f mole_detect_distro > /dev/null 2>&1 && [[ -z "${MOLE_DISTRO_ID:-}" ]]; then
        mole_detect_distro > /dev/null 2>&1 || true
    fi
    if pacman_backend_available; then
        echo "pacman"
    fi
    if flatpak_backend_available; then
        echo "flatpak"
    fi
    echo "desktop"
}

# Checksum of the package + flatpak lists; empty inputs hash to a stable
# sentinel so an empty system is still cacheable.
enumerate_linux_fingerprint() {
    local combined=""
    combined=$( {
        pacman_backend_explicit_packages
        echo "---"
        flatpak_backend_app_ids
    } 2> /dev/null | LC_ALL=C cksum) || combined=""
    combined="${combined%% *}"
    printf '%s' "${combined:-none}"
}

# True when a pacman row id is denied for uninstallation.
_enumerate_linux_package_protected() {
    local pkg="$1"
    if declare -f is_protected_linux_package > /dev/null 2>&1; then
        is_protected_linux_package "$pkg" && return 0
    fi
    return 1
}

# Merge raw backend rows: dedupe by id and target path, drop protected
# packages, and emit rows in backend priority order (pacman, flatpak,
# desktop).
enumerate_linux_rows() {
    local merged_file=""
    merged_file=$(mktemp "${TMPDIR:-/tmp}/mole.enumerate.XXXXXX") || return 1

    pacman_backend_rows >> "$merged_file" 2> /dev/null || true
    flatpak_backend_rows >> "$merged_file" 2> /dev/null || true
    desktop_backend_rows >> "$merged_file" 2> /dev/null || true

    LC_ALL=C awk -F'|' '
        {
            key = $2
            path = $5
            if (!(key in seen) && !(path != "" && path in seen_path)) {
                seen[key] = 1
                if (path != "") {
                    seen_path[path] = 1
                }
                order[++count] = $0
            }
        }
        END {
            for (i = 1; i <= count; i++) print order[i]
        }
    ' "$merged_file" | while IFS= read -r row; do
        local kind="${row%%|*}"
        local id
        id=$(printf '%s' "$row" | cut -d'|' -f2)
        if [[ "$kind" == "pacman" ]] && _enumerate_linux_package_protected "$id"; then
            continue
        fi
        printf '%s\n' "$row"
    done

    rm -f "$merged_file"
}

# Build the selector index file at $1 from the merged rows. Returns nonzero
# only when the caller asked for a file but nothing could be written; an
# empty enumeration writes an empty file and returns 0.
enumerate_linux_index() {
    local out_file="$1"
    [[ -n "$out_file" ]] || return 1
    : > "$out_file"

    enumerate_linux_rows | LC_ALL=C awk -F'|' -v out="$out_file" '
        function human_size(kb) {
            if (kb !~ /^[0-9]+$/ || kb <= 0) return "--"
            bytes = kb * 1024
            if (bytes >= 1000000000)
                return sprintf("%.2fGB", bytes / 1000000000)
            if (bytes >= 1000000)
                return sprintf("%.1fMB", bytes / 1000000)
            if (bytes >= 1000)
                return sprintf("%dKB", int((bytes + 500) / 1000))
            return sprintf("%dB", bytes)
        }
        function target_for(kind, id, path) {
            if (kind == "pacman") return "pacman:" id
            if (kind == "flatpak") return "flatpak:" id
            return "desktop:" path
        }
        {
            kind = $1; id = $2; name = $3; kb = $4; path = $5
            if (kind == "flatpak") {
                # The natural removal target even when not yet created;
                # bin/uninstall.sh skips the existence check on Linux.
                path = ENVIRON["HOME"] "/.var/app/" id
            } else if (path == "") {
                path = "/usr/bin/" id
            }
            line = sprintf("0|%s|%s|%s|%s|%s|%s",
                path, name, target_for(kind, id, path),
                human_size(kb), "Unknown", (kb ~ /^[0-9]+$/ ? kb : 0))
            print line >> out
        }
    '

    LC_ALL=C sort -t'|' -k3,3f "$out_file" -o "$out_file"
}
