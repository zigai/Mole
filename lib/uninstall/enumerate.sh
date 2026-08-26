#!/bin/bash
# Mole - Linux uninstall enumeration: backend merge, dedupe, and index build.
#
# Merges the active native backend (pacman on Arch, deb on Debian-family,
# rpm on Fedora/RHEL-family), flatpak, and desktop backends (row format
# documented in lib/uninstall/backends/pacman.sh) into the selector's app
# index. Exactly ONE native backend is enabled per run. Dedupe priority when
# two backends surface the same identity:
#
#   1. native row (the package manager owns the payload)
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
# "pacman:<pkg>", "deb:<pkg>", "rpm:<pkg>", "flatpak:<app-id>", or
# "desktop:<binary-path>".
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
if [[ -z "${MOLE_UNINSTALL_BACKEND_DEB_LOADED:-}" ]]; then
    # shellcheck source=lib/uninstall/backends/deb.sh
    source "$_MOLE_ENUMERATE_DIR/backends/deb.sh"
fi
if [[ -z "${MOLE_UNINSTALL_BACKEND_RPM_LOADED:-}" ]]; then
    # shellcheck source=lib/uninstall/backends/rpm.sh
    source "$_MOLE_ENUMERATE_DIR/backends/rpm.sh"
fi
if [[ -z "${MOLE_UNINSTALL_BACKEND_FLATPAK_LOADED:-}" ]]; then
    # shellcheck source=lib/uninstall/backends/flatpak.sh
    source "$_MOLE_ENUMERATE_DIR/backends/flatpak.sh"
fi
if [[ -z "${MOLE_UNINSTALL_BACKEND_DESKTOP_LOADED:-}" ]]; then
    # shellcheck source=lib/uninstall/backends/desktop.sh
    source "$_MOLE_ENUMERATE_DIR/backends/desktop.sh"
fi

# Resolve the ONE active native package backend: "pacman", "deb", or "rpm".
# Distro affinity wins when MOLE_DISTRO_ID is known (arch family -> pacman,
# debian family -> deb, fedora/rhel family -> rpm); unknown distros fall back
# to capability probes so generic systems still get whatever native tooling
# exists. Echoes nothing when no native backend is usable.
_enumerate_linux_native_backend() {
    local id="${MOLE_DISTRO_ID:-}"
    if [[ -z "$id" ]] && declare -f mole_detect_distro > /dev/null 2>&1; then
        mole_detect_distro > /dev/null 2>&1 || true
        id="${MOLE_DISTRO_ID:-}"
    fi
    case "$id" in
        arch | archlinux | manjaro | endeavouros | garuda | artix | cachyos)
            if pacman_backend_available; then
                echo "pacman"
                return 0
            fi
            ;;
        debian | ubuntu | mint | pop | elementary | kali | zorin | devuan | neon)
            if deb_backend_available; then
                echo "deb"
                return 0
            fi
            ;;
        fedora | rhel | centos | rocky | almalinux | alma | ol)
            if rpm_backend_available; then
                echo "rpm"
                return 0
            fi
            ;;
    esac
    # Unknown distro (or the affinity backend is missing): capability probes,
    # first match wins so only one native backend is ever enabled.
    if pacman_backend_available; then
        echo "pacman"
    elif deb_backend_available; then
        echo "deb"
    elif rpm_backend_available; then
        echo "rpm"
    fi
}

# Ask whichever native package backend is active whether it owns an absolute
# path. Shared by the desktop-entry backend and the batch executor so
# ownership checks are never hardcoded to pacman.
native_backend_owns_path() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    case "$(_enumerate_linux_native_backend)" in
        pacman) pacman_backend_owns_path "$path" ;;
        deb) deb_backend_owns_path "$path" ;;
        rpm) rpm_backend_owns_path "$path" ;;
        *) return 1 ;;
    esac
}

# Echo the enabled backend names, one per line: exactly one native backend
# (when any is usable) plus flatpak and desktop.
enumerate_linux_backends() {
    local native=""
    native=$(_enumerate_linux_native_backend)
    if [[ -n "$native" ]]; then
        echo "$native"
    fi
    if flatpak_backend_available; then
        echo "flatpak"
    fi
    echo "desktop"
}

# Checksum of the active native package list plus the flatpak list; empty
# inputs hash to a stable sentinel so an empty system is still cacheable.
enumerate_linux_fingerprint() {
    local native=""
    native=$(_enumerate_linux_native_backend)
    local combined=""
    combined=$( {
        case "$native" in
            pacman) pacman_backend_explicit_packages ;;
            deb) deb_backend_explicit_packages ;;
            rpm) rpm_backend_explicit_packages ;;
        esac
        echo "---"
        flatpak_backend_app_ids
    } 2> /dev/null | LC_ALL=C cksum) || combined=""
    combined="${combined%% *}"
    printf '%s' "${combined:-none}"
}

# True when a native (pacman/deb/rpm) row id is denied for uninstallation.
_enumerate_linux_package_protected() {
    local pkg="$1"
    if declare -f is_protected_linux_package > /dev/null 2>&1; then
        is_protected_linux_package "$pkg" && return 0
    fi
    return 1
}

# Merge raw backend rows: dedupe by id and target path, drop protected
# packages, and emit rows in backend priority order (native, flatpak,
# desktop).
enumerate_linux_rows() {
    local merged_file=""
    merged_file=$(mktemp "${TMPDIR:-/tmp}/mole.enumerate.XXXXXX") || return 1

    local native=""
    native=$(_enumerate_linux_native_backend)
    case "$native" in
        pacman) pacman_backend_rows >> "$merged_file" 2> /dev/null || true ;;
        deb) deb_backend_rows >> "$merged_file" 2> /dev/null || true ;;
        rpm) rpm_backend_rows >> "$merged_file" 2> /dev/null || true ;;
    esac
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
        if [[ "$kind" == "$native" ]] && _enumerate_linux_package_protected "$id"; then
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
            if (kind == "flatpak") return "flatpak:" id
            if (kind == "desktop") return "desktop:" path
            # Native package rows (pacman/deb/rpm) all carry the package id.
            return kind ":" id
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
