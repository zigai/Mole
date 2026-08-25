#!/usr/bin/env bats

# Tests for lib/clean/linux_system.sh (Linux `mo clean` system maintenance
# and the report-only orphan package summary). Distro capability functions
# are stubbed per the platform contract; privileged commands run through the
# fake sudo in tests/fixtures/linux/clean/bin so nothing touches real sudo.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-linux-clean-sys.XXXXXX")"
    export HOME

    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    FAKE_BIN="$BATS_TEST_DIRNAME/fixtures/linux/clean/bin"
    export FAKE_BIN

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

@test "system maintenance dry-run previews distro plans without executing them" {
    local trace="$HOME/dry-trace.log"
    : > "$trace"

    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=true \
        PATH="$FAKE_BIN:$PATH" MOLE_FAKE_TRACE="$trace" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
YELLOW='' GRAY='' GREEN='' BLUE='' NC='' ICON_DRY_RUN='' ICON_SUCCESS='' ICON_WARNING='' ICON_LIST=''
DRY_RUN=true
distro_pkg_cache_plan() { printf 'sudo paccache -rk3\nsudo paccache -ruk0\n'; }
distro_pkg_cache_summary() { echo "1.2GB in cache"; }
distro_journal_vacuum_plan() { echo "sudo journalctl --vacuum-size=100M --vacuum-time=2weeks"; }
note_activity() { :; }

source "$PROJECT_ROOT/lib/clean/linux_system.sh"
clean_linux_system_maintenance
SCRIPT
)

    [[ "$result" == *"would run: sudo paccache -rk3"* ]] || return 1
    [[ "$result" == *"would run: sudo paccache -ruk0"* ]] || return 1
    [[ "$result" == *"would run: sudo journalctl --vacuum-size=100M"* ]] || return 1
    [[ "$result" == *"Package cache · 1.2GB in cache"* ]] || return 1
    # Nothing may execute during a preview.
    [[ ! -s "$trace" ]]
}

@test "system maintenance executes distro plans through sudo plumbing" {
    local trace="$HOME/real-trace.log"
    : > "$trace"

    local result
    mkdir -p "$HOME/var-tmp-empty"
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=false \
        MOLE_VARTMP_DIR="$HOME/var-tmp-empty" \
        PATH="$FAKE_BIN:$PATH" MOLE_FAKE_TRACE="$trace" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
YELLOW='' GRAY='' GREEN='' BLUE='' NC='' ICON_DRY_RUN='' ICON_SUCCESS='' ICON_WARNING='' ICON_LIST=''
DRY_RUN=false
safe_sudo_find_delete() { echo "UNEXPECTED_SUDO_DELETE:$*" >&2; exit 1; }
distro_pkg_cache_plan() { printf 'sudo paccache -rk3\n'; }
distro_journal_vacuum_plan() { echo "sudo journalctl --vacuum-size=100M --vacuum-time=2weeks"; }
distro_flatpak_unused_plan() { echo "flatpak uninstall --unused --noninteractive"; }
note_activity() { :; }

source "$PROJECT_ROOT/lib/clean/linux_system.sh"
clean_linux_system_maintenance
SCRIPT
)

    grep -q '^paccache -rk3$' "$trace" || return 1
    grep -q '^journalctl --vacuum-size=100M --vacuum-time=2weeks$' "$trace" || return 1
    # The fake sudo records every privileged wrapper invocation.
    grep -q '^sudo paccache -rk3$' "$trace" || return 1
    grep -q '^sudo journalctl --vacuum-size' "$trace" || return 1
    grep -q '^flatpak uninstall --unused --noninteractive$' "$trace" || return 1
    # No failure row when everything succeeded.
    [[ "$result" != *"command(s) failed"* ]]
}

@test "missing distro capabilities keep system maintenance silent and successful" {
    local trace="$HOME/caps-trace.log"
    : > "$trace"

    local result rc=0
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=false \
        PATH="$FAKE_BIN:$PATH" MOLE_FAKE_TRACE="$trace" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
YELLOW='' GRAY='' GREEN='' BLUE='' NC='' ICON_DRY_RUN='' ICON_SUCCESS='' ICON_WARNING='' ICON_LIST=''
DRY_RUN=false
# No distro_* functions defined at all.
note_activity() { :; }

source "$PROJECT_ROOT/lib/clean/linux_system.sh"
clean_linux_system_maintenance
SCRIPT
) || rc=$?

    [[ $rc -eq 0 ]] || return 1
    [[ ! -s "$trace" ]]
}

@test "/var/tmp stale cleanup previews only entries older than the window" {
    local vartmp="$HOME/var-tmp-dry"
    rm -rf "$vartmp"
    mkdir -p "$vartmp/stale-dir"
    touch "$vartmp/stale-file" "$vartmp/fresh-file"
    touch -t 202001010000 "$vartmp/stale-file" "$vartmp/stale-dir"

    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=true \
        MOLE_VARTMP_DIR="$vartmp" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
YELLOW='' GRAY='' GREEN='' BLUE='' NC='' ICON_DRY_RUN='' ICON_SUCCESS='' ICON_WARNING='' ICON_LIST=''
DRY_RUN=true
safe_sudo_find_delete() { echo "UNEXPECTED_SUDO_DELETE:$*" >&2; exit 1; }
note_activity() { :; }

source "$PROJECT_ROOT/lib/clean/linux_system.sh"
clean_linux_vartmp_stale
SCRIPT
)

    [[ "$result" == *"Stale /var/tmp entries · would remove, 2 items older than 7d"* ]] || return 1
}

@test "/var/tmp stale cleanup routes removal through safe_sudo_find_delete" {
    local vartmp="$HOME/var-tmp-real"
    rm -rf "$vartmp"
    mkdir -p "$vartmp/stale-dir"
    touch "$vartmp/stale-file" "$vartmp/fresh-file"
    touch -t 202001010000 "$vartmp/stale-file" "$vartmp/stale-dir"

    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=false \
        MOLE_VARTMP_DIR="$vartmp" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
YELLOW='' GRAY='' GREEN='' BLUE='' NC='' ICON_DRY_RUN='' ICON_SUCCESS='' ICON_WARNING='' ICON_LIST=''
DRY_RUN=false
safe_sudo_find_delete() {
    printf 'SUDO_FIND:%s:%s:%s\n' "$1" "$3" "$4"
    MOLE_SAFE_SUDO_FIND_DELETE_COUNT=2
}
note_activity() { :; }

export MOLE_VARTMP_DIR
source "$PROJECT_ROOT/lib/clean/linux_system.sh"
clean_linux_vartmp_stale
SCRIPT
)

    [[ "$result" == *"SUDO_FIND:$vartmp:7:f"* ]] || return 1
    [[ "$result" == *"SUDO_FIND:$vartmp:7:d"* ]] || return 1
    [[ "$result" == *"removed 2 items"* ]] || return 1
}

@test "/var/tmp stale cleanup stays quiet when everything is fresh" {
    local vartmp="$HOME/var-tmp-fresh"
    rm -rf "$vartmp"
    mkdir -p "$vartmp"
    touch "$vartmp/recent"

    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=true \
        MOLE_VARTMP_DIR="$vartmp" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
YELLOW='' GRAY='' GREEN='' BLUE='' NC='' ICON_DRY_RUN='' ICON_SUCCESS='' ICON_WARNING='' ICON_LIST=''
DRY_RUN=true
safe_sudo_find_delete() { echo "UNEXPECTED_SUDO_DELETE:$*" >&2; exit 1; }
note_activity() { :; }

source "$PROJECT_ROOT/lib/clean/linux_system.sh"
clean_linux_vartmp_stale
SCRIPT
)

    [[ -z "$result" ]]
}

@test "orphan packages are reported without any removal attempt" {
    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=true /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
YELLOW='' GRAY='' NC='' ICON_REVIEW=''
DRY_RUN=true
distro_orphans_list() {
    printf '%s\n' pkg-one pkg-two pkg-three pkg-four pkg-five pkg-six pkg-seven
}
distro_orphans_remove_plan() { echo "REMOVAL_MUST_NOT_RUN" >&2; exit 1; }
note_activity() { :; }

source "$PROJECT_ROOT/lib/clean/linux_system.sh"
report_linux_orphan_packages
SCRIPT
)

    [[ "$result" == *"Orphan packages · 7 found:"* ]] || return 1
    [[ "$result" == *"pkg-one pkg-two pkg-three pkg-four pkg-five, …"* ]] || return 1
    [[ "$result" != *"pacman -Rns"* ]] || return 1
    [[ "$result" == *"mo optimize"* ]] || return 1
}

@test "orphan report is silent when there are no orphans or no capability" {
    local result
    result=$(env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_PLATFORM=linux DRY_RUN=true /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
YELLOW='' GRAY='' GREEN='' BLUE='' NC='' ICON_DRY_RUN='' ICON_SUCCESS='' ICON_WARNING='' ICON_LIST=''
DRY_RUN=true
distro_orphans_list() { :; }

source "$PROJECT_ROOT/lib/clean/linux_system.sh"
report_linux_orphan_packages

distro_orphans_list() { :; }
unset -f distro_orphans_list
report_linux_orphan_packages
SCRIPT
)

    [[ -z "$result" ]]
}
