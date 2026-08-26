#!/bin/bash
# Mole - desktop-entry uninstall enumeration backend (Linux).
#
# Row format (INTERNAL to lib/uninstall/backends/*, see pacman.sh header):
#
#     <backend>|<id>|<display-name>|<size-kb>|<target-path>
#
# Selection logic (contract §5): scan /usr/share/applications and
# ~/.local/share/applications for *.desktop entries whose Exec/TryExec binary
# resolves on PATH (or as an executable absolute path). Entries are skipped
# when any of the following holds:
#
#   - Type != Application, NoDisplay=true, or Hidden=true
#   - the .desktop file itself is owned by an enumerated native package
#     (pacman/deb/rpm ownership check)
#   - the resolved binary is owned by a native package
#   - the resolved binary lives under ~/.var/app (flatpak territory)
#
# The target-path of a row is the resolved binary; removal trashes that
# binary plus its .desktop entry. This module never deletes anything itself.

if [[ -n "${MOLE_UNINSTALL_BACKEND_DESKTOP_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UNINSTALL_BACKEND_DESKTOP_LOADED=1

_MOLE_DESKTOP_BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_UNINSTALL_ENUMERATE_LOADED:-}" ]]; then
    # Pulls in every backend plus the native_backend_owns_path dispatcher;
    # guard vars make this cycle-safe when enumerate.sh loads us first.
    # shellcheck source=lib/uninstall/enumerate.sh
    source "$_MOLE_DESKTOP_BACKEND_DIR/../enumerate.sh"
fi

desktop_backend_available() {
    return 0
}

# Extract the first token of a freedesktop Exec= value: strips surrounding
# quotes and trailing field codes (%f %F %u %U etc.).
_desktop_backend_exec_first_token() {
    local exec_value="$1"
    local token=""
    # shellcheck disable=SC2086  # word splitting is the point here
    set -- $exec_value
    token="${1:-}"
    [[ "$token" == \'* || "$token" == \"* ]] && token="${token:1:${#token}-2}"
    while [[ "$token" == *%[fFuUdDnNvmkic] ]]; do
        token="${token%?}"
    done
    printf '%s' "$token"
}
desktop_backend_roots() {
    # Colon-separated override for tests (same pattern as MOLE_OS_RELEASE_FILE);
    # real systems scan the XDG application directories.
    if [[ -n "${MOLE_DESKTOP_APPLICATIONS_DIRS:-}" ]]; then
        local dir
        local IFS=':'
        for dir in $MOLE_DESKTOP_APPLICATIONS_DIRS; do
            printf '%s\n' "$dir"
        done
        return 0
    fi
    printf '%s\n' "/usr/share/applications"
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
}
_desktop_backend_parse_keys() {
    local desktop_file="$1"
    LC_ALL=C awk '
        /^\[/ { in_entry = ($0 == "[Desktop Entry]"); next }
        in_entry && /^(Type|Name|Exec|TryExec|NoDisplay|Hidden|X-Flatpak)=/ { print }
    ' "$desktop_file" 2> /dev/null
}

_desktop_backend_resolve_binary() {
    local exec_token="$1"
    local try_exec="$2"

    if [[ -n "$try_exec" ]]; then
        if [[ "$try_exec" == /* ]]; then
            [[ -x "$try_exec" ]] && {
                printf '%s' "$try_exec"
                return 0
            }
        else
            command -v -- "$try_exec" 2> /dev/null && return 0
        fi
    fi

    [[ -n "$exec_token" ]] || return 1

    if [[ "$exec_token" == /* ]]; then
        [[ -x "$exec_token" ]] && {
            printf '%s' "$exec_token"
            return 0
        }
        return 1
    fi

    command -v -- "$exec_token" 2> /dev/null
}

# Emit rows for resolvable, unowned desktop applications.
desktop_backend_rows() {
    desktop_backend_available || return 0

    local root dir_name desktop_file app_id display_name entry_key entry_value
    local exec_value try_exec exec_token binary

    while IFS= read -r root; do
        [[ -d "$root" ]] || continue
        while IFS= read -r -d '' desktop_file; do
            dir_name="${desktop_file%/*}"
            [[ "$dir_name" == "$root" ]] || continue # top-level entries only

            app_id="${desktop_file##*/}"
            app_id="${app_id%.desktop}"

            exec_value=""
            try_exec=""
            display_name=""
            local no_display="" hidden="" is_flatpak="" entry_type=""
            while IFS= read -r entry_line; do
                entry_key="${entry_line%%=*}"
                entry_value="${entry_line#*=}"
                case "$entry_key" in
                    Type) entry_type="$entry_value" ;;
                    Name) display_name="$entry_value" ;;
                    Exec) exec_value="$entry_value" ;;
                    TryExec) try_exec="$entry_value" ;;
                    NoDisplay) no_display="$entry_value" ;;
                    Hidden) hidden="$entry_value" ;;
                    X-Flatpak) is_flatpak="$entry_value" ;;
                esac
            done < <(_desktop_backend_parse_keys "$desktop_file")

            [[ "$entry_type" == "Application" || -z "$entry_type" ]] || continue
            case "$no_display" in true | True | TRUE | 1) continue ;; esac
            case "$hidden" in true | True | TRUE | 1) continue ;; esac
            case "$is_flatpak" in true | True | TRUE | 1) continue ;; esac

            # Package-owned launchers belong to their package's uninstall row.
            if native_backend_owns_path "$desktop_file"; then
                continue
            fi

            exec_token=$(_desktop_backend_exec_first_token "$exec_value")
            binary=$(_desktop_backend_resolve_binary "$exec_token" "$try_exec") || continue
            [[ -n "$binary" ]] || continue

            # Never surface flatpak-managed payloads here.
            case "$binary" in
                "$HOME"/.var/app/*) continue ;;
            esac
            if native_backend_owns_path "$binary"; then
                continue
            fi

            [[ -n "$display_name" ]] || display_name="$app_id"

            local size_kb="0"
            size_kb=$(get_path_size_kb "$binary" 2> /dev/null || echo "0")
            [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb="0"

            display_name="${display_name//|//}"
            printf 'desktop|%s|%s|%s|%s\n' "$app_id" "$display_name" "$size_kb" "$binary"
        done < <(command find "$root" -maxdepth 1 -name '*.desktop' -print0 2> /dev/null)
    done < <(desktop_backend_roots)
}
