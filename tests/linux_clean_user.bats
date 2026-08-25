#!/usr/bin/env bats

# Tests for lib/clean/linux_user.sh (Linux `mo clean` user essentials).
# Core delete-layer primitives are stubbed; the module under test must only
# orchestrate targets into them.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-linux-clean-user.XXXXXX")"
    export HOME

    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    mkdir -p "$HOME"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "user cache sweep skips mole dirs and browser roots, sweeps the rest" {
    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=true /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
mole_state_dir() { printf '%s\n' "$HOME/.local/state/mole"; }
mole_cache_dir() { printf '%s\n' "$HOME/.cache/mole"; }
safe_clean() {
    # Mirror _safe_clean_impl's convention: the last argument is the label.
    local label="${*: -1}"
    local count=$(($# - 1))
    local i
    for ((i = 1; i <= count; i++)); do
        printf 'TARGET:%s|LABEL:%s\n' "${!i}" "$label"
    done
}
note_activity() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
debug_log() { :; }

mkdir -p "$HOME/.cache/mole" "$HOME/.cache/mole/ledger"
touch "$HOME/.cache/mole/ledger/sentinel"
mkdir -p "$HOME/.cache/google-chrome/Default" "$HOME/.cache/some-tool" "$HOME/.cache/.hidden-cache"

source "$PROJECT_ROOT/lib/clean/linux_user.sh"
clean_linux_user_cache_sweep
SCRIPT
)

    [[ "$result" == *"TARGET:$HOME/.cache/some-tool"* ]] || return 1
    [[ "$result" == *"TARGET:$HOME/.cache/.hidden-cache"* ]] || return 1
    [[ "$result" == *"|LABEL:User cache"* ]] || return 1
    [[ "$result" != *"google-chrome"* ]] || return 1
    [[ "$result" != *"/.cache/mole"* ]] || return 1
    [[ -f "$HOME/.cache/mole/ledger/sentinel" ]]
}

@test "browser cache step sweeps contents of browser roots only" {
    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=true /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
safe_clean() {
    local label="${*: -1}"
    local count=$(($# - 1))
    local i
    for ((i = 1; i <= count; i++)); do
        printf 'TARGET:%s\n' "${!i}"
    done
}
note_activity() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
debug_log() { :; }

mkdir -p "$HOME/.cache/google-chrome/Default" "$HOME/.cache/firefox/abc.default"
mkdir -p "$HOME/.cache/not-a-browser"
touch "$HOME/.cache/google-chrome/Default/Cache_Data" "$HOME/.cache/firefox/abc.default/cache2"

source "$PROJECT_ROOT/lib/clean/linux_user.sh"
clean_linux_browser_caches
SCRIPT
)

    [[ "$result" == *".cache/google-chrome/Default"* ]] || return 1
    [[ "$result" == *".cache/firefox/abc.default"* ]] || return 1
    [[ "$result" != *"not-a-browser"* ]] || return 1
}

@test "trash dry-run records a ledger entry per item and deletes nothing" {
    local trash_dir="$HOME/.local/share/Trash"
    rm -rf "$trash_dir"
    mkdir -p "$trash_dir/files" "$trash_dir/info"
    mkdir -p "$trash_dir/files/old-project"
    touch "$trash_dir/files/plain-file" "$trash_dir/info/plain-file.trashinfo" "$trash_dir/info/old-project.trashinfo"

    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=true \
        MOLE_LINUX_TRASH_DIR="$trash_dir" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
DRY_RUN=true
YELLOW='' NC='' ICON_DRY_RUN=''
get_path_size_kb() { echo 12; }
record_dry_run_cleanup_target() { printf 'LEDGER:%s:%s\n' "$1" "$2"; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
_mole_record_clean_cancellation() { :; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1" >&2; exit 1; }
note_activity() { :; }
stop_section_spinner() { :; }
debug_log() { :; }

source "$PROJECT_ROOT/lib/clean/linux_user.sh"
clean_linux_trash
SCRIPT
)

    [[ "$result" == *"LEDGER:$trash_dir/files/plain-file:12"* ]] || return 1
    [[ "$result" == *"LEDGER:$trash_dir/files/old-project:12"* ]] || return 1
    [[ "$result" == *"would empty, 2 items"* ]] || return 1
    [[ "$result" != *".trashinfo"* ]] || return 1
    [[ -e "$trash_dir/files/plain-file" ]]
}

@test "trash real mode empties both files and info through the delete layer" {
    local trash_dir="$HOME/.local/share/Trash"
    rm -rf "$trash_dir"
    mkdir -p "$trash_dir/files/old-project" "$trash_dir/info"
    touch "$trash_dir/files/old-project/data" "$trash_dir/files/plain-file" "$trash_dir/info/plain-file.trashinfo"

    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=false \
        MOLE_LINUX_TRASH_DIR="$trash_dir" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
DRY_RUN=false
GREEN='' NC='' ICON_SUCCESS=''
safe_remove() {
    # Stand-in for the linux permanent-delete path of the shared funnel.
    printf 'REMOVE:%s\n' "$1"
    rm -rf -- "$1"
}
is_path_whitelisted() { return 1; }
note_activity() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
debug_log() { :; }

source "$PROJECT_ROOT/lib/clean/linux_user.sh"
clean_linux_trash
SCRIPT
)

    [[ "$result" == *"Trash · emptied, 2 items"* ]] || return 1
    [[ -z "$(find "$trash_dir/files" "$trash_dir/info" -mindepth 1 -print -quit 2> /dev/null)" ]]
}

@test "whitelisted trash directory is skipped entirely" {
    local trash_dir="$HOME/.local/share/Trash"
    rm -rf "$trash_dir"
    mkdir -p "$trash_dir/files"
    touch "$trash_dir/files/keep-me"

    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=false \
        MOLE_LINUX_TRASH_DIR="$trash_dir" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
DRY_RUN=false
is_path_whitelisted() { [[ "$1" == "$MOLE_LINUX_TRASH_DIR" ]]; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1" >&2; exit 1; }
note_activity() { :; }
stop_section_spinner() { :; }
debug_log() { :; }

export MOLE_LINUX_TRASH_DIR
source "$PROJECT_ROOT/lib/clean/linux_user.sh"
clean_linux_trash
SCRIPT
)

    [[ -z "$result" ]] || return 1
    [[ -e "$trash_dir/files/keep-me" ]]
}

@test "AUR helper cache dirs from the distro module are swept" {
    local aur_yay="$HOME/.cache/yay"
    local aur_paru="$HOME/.cache/paru"
    rm -rf "$aur_yay" "$aur_paru"
    mkdir -p "$aur_yay" "$aur_paru"
    touch "$aur_yay/pkg.tar.gz" "$aur_paru/pkg2.tar.gz"

    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=true /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
DRY_RUN=true
YELLOW='' GREEN='' NC='' ICON_DRY_RUN='' ICON_SUCCESS=''
distro_aur_cache_dirs() {
    printf '%s\n' "$HOME/.cache/yay" "$HOME/.cache/paru"
}
safe_clean() {
    local label="${*: -1}"
    local count=$(($# - 1))
    local i
    for ((i = 1; i <= count; i++)); do
        printf 'TARGET:%s|LABEL:%s\n' "${!i}" "$label"
    done
}
note_activity() { :; }
debug_log() { :; }

source "$PROJECT_ROOT/lib/clean/linux_user.sh"
clean_linux_aur_caches
SCRIPT
)

    [[ "$result" == *"TARGET:$aur_yay/pkg.tar.gz|LABEL:AUR helper cache"* ]] || return 1
    [[ "$result" == *"TARGET:$aur_paru/pkg2.tar.gz|LABEL:AUR helper cache"* ]] || return 1
}

@test "AUR helper cache step stays silent when the distro reports no dirs" {
    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=true /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
DRY_RUN=true
YELLOW='' GREEN='' NC='' ICON_DRY_RUN='' ICON_SUCCESS=''
distro_aur_cache_dirs() { :; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN:$*" >&2; exit 1; }

source "$PROJECT_ROOT/lib/clean/linux_user.sh"
clean_linux_aur_caches
SCRIPT
)

    [[ -z "$result" ]]
}
