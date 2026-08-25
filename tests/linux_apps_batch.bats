#!/usr/bin/env bats
# Linux batch executor: dry-run full plan snapshot, TOCTOU identity
# re-verification skip, and flatpak data-dir preview (contract §5).

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-linux-apps-batch-home.XXXXXX")"
    export HOME

    FIXTURE_BIN="${BATS_TEST_DIRNAME}/fixtures/linux/apps/bin"
    export FIXTURE_BIN

    MOLE_TEST_NO_AUTH=1
    export MOLE_TEST_NO_AUTH
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi

    FAKE_DB="$(mktemp -d "${HOME}/fake-pacman-db.XXXXXX")"
    export FAKE_DB
    : > "$FAKE_DB/packages.tsv"
    : > "$FAKE_DB/owned.txt"
    export MOLE_FAKE_PACMAN_DB="$FAKE_DB"

    BIN_ROOT="$(mktemp -d "${HOME}/fake-bin-root.XXXXXX")"
    export BIN_ROOT
    export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"

    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_STATE_HOME="$HOME/.local/state"

    # selected_apps rows in the shared selector format:
    # epoch|path|name|kind:id|size|last-used|size-kb
    selected_apps=()
}

@test "dry-run prints the full removal plan and changes nothing" {
    add_pkg() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FAKE_DB/packages.tsv"; }
    printf '#!/bin/sh\n' > "$BIN_ROOT/htop"
    chmod +x "$BIN_ROOT/htop"
    add_pkg htop 1 300.00KiB

    local_list="${FAKE_DB}/fake-flatpak.list"
    printf 'org.foo.Editor\tFoo Editor\t120.00 MB\n' > "$local_list"
    mkdir -p "$HOME/.var/app/org.foo.Editor/cache"

    printf '#!/bin/sh\n' > "$BIN_ROOT/cooltui"
    chmod +x "$BIN_ROOT/cooltui"

    mkdir -p "$XDG_CONFIG_HOME/htop"

    # Payload runs from a FILE, not a heredoc on stdin: under bats --jobs
    # (GNU parallel backend) stdin-fed `run bash` scripts have been observed
    # to arrive empty, silently producing a no-op run.
    cat > "$FAKE_DB/payload.sh" <<'PAYLOAD'
set -uo pipefail
export PATH="$FIXTURE_BIN:$PATH"
export MOLE_FAKE_PACMAN_DB="$MOLE_FAKE_PACMAN_DB"
export MOLE_TIMEOUT_QUICK_DETECT_SEC=60
export MOLE_TIMEOUT_SHORT_QUERY_SEC=60
export MOLE_UNINSTALL_LINUX_BIN_DIR="$MOLE_UNINSTALL_LINUX_BIN_DIR"
export MOLE_PLATFORM=linux
export TERM=dumb
export MOLE_DRY_RUN=1
cd "$PROJECT_ROOT"
source lib/core/common.sh
source lib/uninstall/backends/pacman.sh
source lib/uninstall/backends/desktop.sh
source lib/uninstall/backends/flatpak.sh
ensure_sudo_session() { return 0; }
source lib/uninstall/batch.sh

selected_apps=(
    "0|$MOLE_UNINSTALL_LINUX_BIN_DIR/htop|htop|pacman:htop|307KB|Unknown|307"
    "0|$HOME/.var/app/org.foo.Editor|Foo Editor|flatpak:org.foo.Editor|120.0MB|Unknown|122880"
    "0|$MOLE_UNINSTALL_LINUX_BIN_DIR/cooltui|Cool TUI|desktop:$MOLE_UNINSTALL_LINUX_BIN_DIR/cooltui|4KB|Unknown|4"
)

batch_uninstall_applications_linux < /dev/null
echo "rc=$?"
echo "var-app-still-there=$([[ -d $HOME/.var/app/org.foo.Editor ]] && echo yes || echo no)"
PAYLOAD

    run env \
        HOME="$HOME" \
        PROJECT_ROOT="$PROJECT_ROOT" \
        FIXTURE_BIN="$FIXTURE_BIN" \
        MOLE_FAKE_PACMAN_DB="$FAKE_DB" \
        MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT" \
        /bin/bash "$FAKE_DB/payload.sh"

    [ "$status" -eq 0 ]
    # Plan lines per channel
    # Assertions run against a color-stripped copy: rendering may or may not
    # be colorized depending on the invoking environment, but the plan
    # CONTENT is the contract under test.
    local plain_output
    plain_output="$(printf '%s' "$output" | sed $'s/\x1b\[[0-9;]*[A-Za-z]//g')"

    [[ "$plain_output" == *"Plan: sudo pacman -Rns --noconfirm htop"* ]]
    [[ "$plain_output" == *"Plan: flatpak uninstall --noninteractive org.foo.Editor"* ]]
    # Flatpak app data is previewed explicitly (never trusted to --delete-data)
    [[ "$plain_output" == *"App data: "*".var/app/org.foo.Editor"* ]]
    # Safe-tier leftover surfaced for the pacman app
    [[ "$plain_output" == *"~/.config/htop"* ]]
    # Dry-run verdicts count every row as success without side effects
    [[ "$plain_output" == *"Removed 3 application(s)"* ]]
    [[ "$plain_output" == *"rc=0"* ]]
    [[ "$plain_output" == *"var-app-still-there=yes"* ]]
    [[ "$plain_output" != *"DRY RUN MODE"* ]] # banner belongs to bin/uninstall.sh, not the batch module
}

@test "TOCTOU: a row whose package vanished before execution is skipped" {
    # NOTE: htop is deliberately NOT added to the fake package db.
    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_TIMEOUT_QUICK_DETECT_SEC=60
export MOLE_TIMEOUT_SHORT_QUERY_SEC=60
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
export MOLE_PLATFORM=linux
export TERM=dumb
cd "$PROJECT_ROOT"
source lib/core/common.sh
ensure_sudo_session() { return 0; }
source lib/uninstall/batch.sh

selected_apps=("0|$BIN_ROOT/htop|htop|pacman:htop|307KB|Unknown|307")
batch_uninstall_applications_linux < /dev/null
echo "rc=\$?"
printf 'skipped=%s\n' "\${#LINUX_BATCH_SKIPPED[@]}"
printf 'success=%s\n' "\${#LINUX_BATCH_SUCCESS[@]}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"no longer installed in the expected form"* ]]
    [[ "$output" == *"skipped=1"* ]]
    [[ "$output" == *"success=0"* ]]
}

@test "cancel keeps everything untouched" {
    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_TIMEOUT_QUICK_DETECT_SEC=60
export MOLE_TIMEOUT_SHORT_QUERY_SEC=60
export MOLE_PLATFORM=linux
export TERM=dumb
cd "$PROJECT_ROOT"
source lib/core/common.sh
source lib/uninstall/batch.sh

selected_apps=("0|$BIN_ROOT/nope|Nope|desktop:$BIN_ROOT/nope|0KB|Unknown|0")
{ sleep 0.5; printf 'q'; } | batch_uninstall_applications_linux
echo "rc=\$?"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cancelled."* ]]
    [[ "$output" == *"rc=0"* ]]
}
