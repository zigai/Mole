#!/usr/bin/env bats

# Linux trash routing for mole_delete (contract §6): gio trash success,
# permanent-delete fallback with a single notice when gio fails or is
# absent, and unchanged dry-run ledger semantics.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    FIXTURES="$PROJECT_ROOT/tests/fixtures/linux/fileops"
    export FIXTURES
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-linux-fileops-delete.XXXXXX")"
    export SANDBOX
    HOME_DIR="$SANDBOX/home"
    mkdir -p "$HOME_DIR"
    export HOME_DIR
    TRASH_DIR="$SANDBOX/Trash"
    mkdir -p "$TRASH_DIR"
    export TRASH_DIR
    DELETE_LOG="$SANDBOX/deletions.log"
    export DELETE_LOG
    GIO_LOG="$SANDBOX/gio.log"
    export GIO_LOG
    export MOLE_TEST_NO_AUTH=1
}

teardown() {
    rm -rf "$SANDBOX"
}

prelude() {
    cat <<EOF
set -euo pipefail
export HOME="$HOME_DIR"
export PATH="$FIXTURES:\$PATH"
export MOLE_DELETE_LOG="$DELETE_LOG"
export MOLE_TEST_TRASH_DIR="$TRASH_DIR"
export MOLE_TEST_GIO_LOG="$GIO_LOG"
export MOLE_TEST_NO_AUTH=1
source "$PROJECT_ROOT/lib/core/common.sh"
mole_trash_cmd() { printf '%s\n' "\${MOLE_TEST_TRASH_CMD-gio}"; }
EOF
}

@test "trash mode on linux moves the path via gio trash" {
    victim="$SANDBOX/victim"
    mkdir -p "$victim/cache"
    : > "$victim/cache/blob"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
MOLE_DELETE_MODE=trash mole_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]] || return 1
    awk -F'\t' '$2 == "trash" && $4 == "ok" { found = 1 } END { exit found ? 0 : 1 }' "$DELETE_LOG" || return 1
    grep -qF "$victim" "$DELETE_LOG" || return 1
    grep -q "gio trash" "$GIO_LOG" || return 1
    # Forensic log records the recoverable move.
}

@test "gio failure falls back to permanent delete with one notice line" {
    victim_a="$SANDBOX/a"
    victim_b="$SANDBOX/b"
    : > "$victim_a"
    : > "$victim_b"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
MOLE_TEST_GIO_MODE=fail MOLE_DELETE_MODE=trash mole_delete "$victim_a"
echo "rc_a=\$?" >&2
MOLE_DELETE_MODE=trash mole_delete "$victim_b"
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim_a" ]] || return 1
    [[ ! -e "$victim_b" ]] || return 1
    # Exactly one notice line across the whole run.
    [ "$(grep -c "deleting permanently" <<< "$output")" -eq 1 ] || return 1
    grep -q "trash-unavailable-permanent-fallback" "$DELETE_LOG" || return 1
}

@test "absent gio falls back to permanent delete" {
    victim="$SANDBOX/gone"
    : > "$victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
MOLE_TEST_TRASH_CMD="" MOLE_DELETE_MODE=trash mole_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]] || return 1
    grep -q "deleting permanently" <<< "$output" || return 1
    [[ -z "$(cat "$GIO_LOG" 2> /dev/null || true)" ]] || return 1
}

@test "dry-run ledger semantics are identical in linux trash mode" {
    victim="$SANDBOX/dry"
    : > "$victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
MOLE_DRY_RUN=1 MOLE_DELETE_MODE=trash mole_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ -e "$victim" ]] || return 1
    [[ -z "$(cat "$GIO_LOG" 2> /dev/null || true)" ]] || return 1
    grep -q "dry-run" "$DELETE_LOG" || return 1
}
