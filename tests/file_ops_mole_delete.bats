#!/usr/bin/env bats

# Exercises permanent mode (default), trash mode (via the gio stub so real
# filesystem Trash is never touched), dry-run, and the deletions log.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-mole-delete.XXXXXX")"
    export SANDBOX
    export MOLE_DELETE_LOG="$SANDBOX/deletions.log"
    export MOLE_TEST_TRASH_DIR="$SANDBOX/Trash"
    export MOLE_TEST_NO_AUTH=1
    unset MOLE_DELETE_MODE
    unset MOLE_DRY_RUN
}

teardown() {
    rm -rf "$SANDBOX"
}

prelude() {
    cat <<EOF
set -euo pipefail
export MOLE_DELETE_LOG="$MOLE_DELETE_LOG"
export MOLE_TEST_TRASH_DIR="$MOLE_TEST_TRASH_DIR"
export MOLE_TEST_NO_AUTH=1
source "$PROJECT_ROOT/lib/core/common.sh"
EOF
}

@test "mole_delete defaults to permanent mode and removes the target" {
    local victim="$SANDBOX/victim"
    mkdir -p "$victim"
    : > "$victim/keep.txt"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
mole_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]] || return 1
    # Trash dir must remain empty in permanent mode.
    [[ -z "$(ls -A "$MOLE_TEST_TRASH_DIR" 2> /dev/null || true)" ]]
}

@test "safe_remove final sink guard preserves timeout and signal cancellation" {
    local victim="$SANDBOX/final-guard-victim"
    mkdir -p "$victim"
    : > "$victim/keep.txt"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_CURRENT_COMMAND=clean
guard_rc=0
final_guard() { return "\$guard_rc"; }
_MOLE_SAFE_REMOVE_FINAL_GUARD=final_guard
for guard_rc in 124 130; do
    MOLE_CLEAN_CANCEL_STATUS=0
    set +e
    safe_remove "$victim" true 1
    actual_rc=\$?
    set -e
    printf 'GUARD:%s ACTUAL:%s CANCEL:%s\n' \
        "\$guard_rc" "\$actual_rc" "\$MOLE_CLEAN_CANCEL_STATUS"
done
[[ -d "$victim" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"GUARD:124 ACTUAL:124 CANCEL:124"* ]] || return 1
    [[ "$output" == *"GUARD:130 ACTUAL:130 CANCEL:130"* ]] || return 1
    [[ -d "$victim" ]]
}

@test "Trash mode refuses sudo-required app below mutable parent" {
    local victim="$SANDBOX/RootOwned.app"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
unset MOLE_TEST_NO_AUTH
export MOLE_DELETE_MODE=trash
_mole_privileged_path_has_mutable_ancestor() { return 0; }
set +e
mole_delete "$victim" true
rc=\$?
set -e
printf 'RC=%s\n' "\$rc"
[[ \$rc -eq \$MOLE_ERR_MUTABLE_PARENT ]] || exit 1
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ -f "$victim/data.txt" ]] || return 1
    [[ "$output" == *"RC=15"* ]] || return 1
    [ "$(awk -F'\t' 'END { print $4 }' "$MOLE_DELETE_LOG")" = "mutable-parent" ]
}

@test "permanent delete refuses sudo-required app below mutable Applications" {
    local victim="$SANDBOX/RootOwnedPermanent.app"
    local trace="$SANDBOX/permanent-app.log"
    mkdir -p "$victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
unset MOLE_TEST_NO_AUTH
export MOLE_DELETE_MODE=permanent
_mole_privileged_path_has_mutable_ancestor() { return 0; }
safe_remove() { printf 'SAFE_REMOVE\n' >> "$trace"; return 0; }
safe_sudo_remove() { printf 'SAFE_SUDO_REMOVE\n' >> "$trace"; return 0; }
set +e
mole_delete "$victim" true
rc=\$?
set -e
printf 'RC=%s\n' "\$rc"
[[ \$rc -eq \$MOLE_ERR_MUTABLE_PARENT ]] || exit 1
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ -d "$victim" ]] || return 1
    [[ "$output" == *"RC=15"* ]] || return 1
    [[ ! -s "$trace" ]] || return 1
    [ "$(awk -F'\t' 'END { print $4 }' "$MOLE_DELETE_LOG")" = "mutable-parent" ]
}

@test "permanent delete preserves mutable-parent classification when the sink recheck catches a race" {
    local victim="$SANDBOX/RacedPermanent.app"
    local trace="$SANDBOX/permanent-race.log"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
unset MOLE_TEST_NO_AUTH
export MOLE_DELETE_MODE=permanent
probe_round=0
_mole_privileged_path_has_mutable_ancestor() {
    probe_round=\$((probe_round + 1))
    [[ \$probe_round -ge 2 ]]
}
run_with_timeout() { printf '1\n'; }
safe_remove() { printf 'SAFE_REMOVE\n' >> "$trace"; return 0; }
safe_sudo_remove() { printf 'SAFE_SUDO_REMOVE\n' >> "$trace"; return 0; }
set +e
mole_delete "$victim" true
rc=\$?
set -e
printf 'RC=%s\n' "\$rc"
[[ \$rc -eq \$MOLE_ERR_MUTABLE_PARENT ]] || exit 1
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ -f "$victim/data.txt" ]] || return 1
    [[ "$output" == *"RC=15"* ]] || return 1
    [[ ! -s "$trace" ]] || return 1
    [ "$(awk -F'\t' 'END { print $4 }' "$MOLE_DELETE_LOG")" = "mutable-parent" ]
}

@test "permanent symlink delete preserves mutable-parent classification at the sink" {
    local target="$SANDBOX/target.app"
    local victim="$SANDBOX/RacedPermanentLink.app"
    local trace="$SANDBOX/permanent-link-race.log"
    mkdir -p "$target"
    ln -s "$target" "$victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
unset MOLE_TEST_NO_AUTH
export MOLE_DELETE_MODE=permanent
probe_round=0
_mole_privileged_path_has_mutable_ancestor() {
    probe_round=\$((probe_round + 1))
    [[ \$probe_round -ge 2 ]]
}
run_with_timeout() { printf '1\n'; }
safe_remove_symlink() { printf 'SAFE_REMOVE_SYMLINK\n' >> "$trace"; return 0; }
set +e
mole_delete "$victim" true
rc=\$?
set -e
printf 'RC=%s\n' "\$rc"
[[ \$rc -eq \$MOLE_ERR_MUTABLE_PARENT ]] || exit 1
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ -L "$victim" ]] || return 1
    [[ "$output" == *"RC=15"* ]] || return 1
    [[ ! -s "$trace" ]] || return 1
    [ "$(awk -F'\t' 'END { print $4 }' "$MOLE_DELETE_LOG")" = "mutable-parent" ]
}

@test "mutable-parent diagnosis recommends manual Trash without promising container cleanup" {
    run /bin/bash --noprofile --norc <<EOF
$(prelude)
diagnose_removal_failure "\$MOLE_ERR_MUTABLE_PARENT" "Microsoft Word"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"cannot safely use elevated deletion"* ]] || return 1
    [[ "$output" == *"Move the app to the Trash"* ]] || return 1
    [[ "$output" == *"protected containers and app data untouched"* ]] || return 1
    [[ "$output" != *"mo clean"* ]] || return 1
}

@test "mole_delete writes a tab-separated log line per call" {
    local victim="$SANDBOX/logged"
    : > "$victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
mole_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ -s "$MOLE_DELETE_LOG" ]] || return 1

    # Expect 5 tab-separated fields: timestamp, mode, size_kb, status, path.
    local fields
    fields=$(awk -F'\t' 'END { print NF }' "$MOLE_DELETE_LOG")
    [ "$fields" -eq 5 ]

    # Status column must be "ok" for a successful permanent delete.
    local status_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$MOLE_DELETE_LOG")
    [ "$status_col" = "ok" ]
}

@test "mole_delete rejects symlinks to protected system paths" {
    local victim="$SANDBOX/system-link"
    ln -s "/System" "$victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
mole_delete "$victim"
EOF

    [ "$status" -eq 1 ]
    [[ -L "$victim" ]] || return 1

    local status_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$MOLE_DELETE_LOG")
    [ "$status_col" = "rejected" ]
}

@test "mole_delete dry-run does not touch the filesystem but still logs" {
    local victim="$SANDBOX/dry"
    : > "$victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_DRY_RUN=1
mole_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ -e "$victim" ]] || return 1

    local status_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$MOLE_DELETE_LOG")
    [ "$status_col" = "dry-run" ]
}

@test "mole_delete records a forensic log entry for rejected paths" {
    run /bin/bash --noprofile --norc <<EOF
$(prelude)
mole_delete "/tmp/../etc/hosts"
EOF

    [ "$status" -ne 0 ]
    # Rejection IS logged (security-relevant), with status="rejected" and size=0.
    # Audit trails need to distinguish refused-by-policy from never-attempted.
    [[ -s "$MOLE_DELETE_LOG" ]] || return 1
    local status_col size_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$MOLE_DELETE_LOG")
    size_col=$(awk -F'\t' 'END { print $3 }' "$MOLE_DELETE_LOG")
    [ "$status_col" = "rejected" ]
    [ "$size_col" = "0" ]
}

@test "mole_delete is a no-op on a non-existent path" {
    run /bin/bash --noprofile --norc <<EOF
$(prelude)
mole_delete "$SANDBOX/does-not-exist"
EOF

    [ "$status" -eq 0 ]
    [[ ! -s "$MOLE_DELETE_LOG" ]]
}

@test "mole_delete rejects unknown delete mode without touching target" {
    local victim="$SANDBOX/invalid_mode_target"
    : > "$victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_DELETE_MODE=surprise
mole_delete "$victim"
EOF

    [ "$status" -ne 0 ]
    [[ -e "$victim" ]] || return 1

    local mode_col status_col
    mode_col=$(awk -F'\t' 'END { print $2 }' "$MOLE_DELETE_LOG")
    status_col=$(awk -F'\t' 'END { print $4 }' "$MOLE_DELETE_LOG")
    [ "$mode_col" = "surprise" ]
    [ "$status_col" = "invalid-mode" ]
    [[ "$output" == *'expected "permanent" or "trash"'* ]]
}

@test "mole_delete warns once for repeated invalid delete mode" {
    local first="$SANDBOX/invalid_mode_first"
    local second="$SANDBOX/invalid_mode_second"
    : > "$first"
    : > "$second"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_DELETE_MODE=surprise
set +e
mole_delete "$first"
first_rc=\$?
mole_delete "$second"
second_rc=\$?
set -e
[[ \$first_rc -ne 0 && \$second_rc -ne 0 ]] || exit 1
EOF

    [ "$status" -eq 0 ]
    [[ -e "$first" ]] || return 1
    [[ -e "$second" ]] || return 1
    [[ "$(grep -c 'invalid MOLE_DELETE_MODE' <<< "$output")" -eq 1 ]]
}

@test "mole_delete records 'unknown' (not 0) when size measurement fails" {
    # Override get_path_size_kb to simulate a measurement failure (non-numeric
    # output, non-zero exit). The actual delete still goes through safe_remove
    # so the file is removed; only the log size column should differ.
    local victim="$SANDBOX/measureless"
    : > "$victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
get_path_size_kb() { echo "ERR"; return 1; }
mole_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]] || return 1
    local size_col
    size_col=$(awk -F'\t' 'END { print $3 }' "$MOLE_DELETE_LOG")
    [ "$size_col" = "unknown" ]
}

@test "mole_delete stops before Trash or permanent removal when sizing is interrupted" {
    local trash_victim="$SANDBOX/interrupted-trash-size"
    local sudo_victim="$SANDBOX/interrupted-sudo-size"
    mkdir -p "$trash_victim" "$sudo_victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
get_path_size_kb() { return 130; }
_mole_linux_gio_trash() { return 130; }
safe_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "\$1"
    return 99
}

export MOLE_DELETE_MODE=trash
trash_rc=0
mole_delete "$trash_victim" || trash_rc=\$?
printf 'TRASH_RC=%s\n' "\$trash_rc"

unset MOLE_TEST_NO_AUTH
export MOLE_DELETE_MODE=permanent
_mole_privileged_path_has_mutable_ancestor() { return 1; }
run_with_timeout() { return 130; }
safe_sudo_remove() {
    printf 'UNEXPECTED_SUDO_REMOVE:%s\n' "\$1"
    return 99
}
sudo_rc=0
mole_delete "$sudo_victim" true || sudo_rc=\$?
printf 'SUDO_RC=%s\n' "\$sudo_rc"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"TRASH_RC=130"* ]] || return 1
    [[ "$output" == *"SUDO_RC=130"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_"* ]] || return 1
    [[ -e "$trash_victim" ]] || return 1
    [[ -e "$sudo_victim" ]]
}

@test "safe_remove refuses a replacement reached through a swapped parent" {
    local parent="$SANDBOX/bound-parent"
    local victim="$parent/victim"
    mkdir -p "$victim"
    printf 'original\n' > "$victim/data"

    # Resolve the identity flags the same way base.sh does instead of
    # relying on _mole_snapshot_path_identity, whose GNU stat handling is
    # broken (see REALBUGS).
    local expected_parent expected_parent_id expected_target_id
    expected_parent="$(cd -P "$parent" && pwd -P)"
    expected_parent_id="$(stat -c '%d:%i' "$expected_parent")"
    expected_target_id="$(stat -c '%d:%i' "$victim")"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)

mv "$parent" "$parent.original"
mkdir -p "$victim"
printf 'replacement\n' > "$victim/data"

rc=0
safe_remove "$victim" true 1 "" \
    "$expected_parent" "$expected_parent_id" "$expected_target_id" || rc=\$?
[[ \$rc -ne 0 ]] || exit 1
[[ -f "$victim/data" && -f "$parent.original/victim/data" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "safe_remove records a clean interruption and blocks later deletion sinks" {
    local first="$SANDBOX/interrupted-clean-delete"
    local second="$SANDBOX/later-clean-delete"
    mkdir -p "$first" "$second"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_CURRENT_COMMAND=clean
export MOLE_CLEAN_CANCEL_STATUS=0
rm() { return 130; }
rc=0
safe_remove "$first" true 1 || rc=\$?
[[ \$rc -eq 130 ]] || exit 1
[[ \$MOLE_CLEAN_CANCEL_STATUS -eq 130 ]] || exit 1

rm() {
    printf 'UNEXPECTED_RM:%s\n' "\$1"
    /bin/rm "\$@"
}
rc=0
safe_remove "$second" true 1 || rc=\$?
[[ \$rc -eq 130 ]] || exit 1
[[ -d "$first" && -d "$second" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_RM"* ]]
}

@test "mole_delete never binds a replacement installed during identity snapshot" {
    local victim="$SANDBOX/snapshot-race.app"
    mkdir -p "$victim"
    printf 'original\n' > "$victim/data"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_DELETE_MODE=permanent
expected_identity=\$("\$STAT_BSD" "\$_MOLE_STAT_ID_MTIME_FLAG" "$victim")
eval "\$(declare -f _mole_snapshot_path_identity | sed '1s/_mole_snapshot_path_identity/_real_mole_snapshot_path_identity/')"
_mole_snapshot_path_identity() {
    local snap_rc=0
    _real_mole_snapshot_path_identity "\$1" || snap_rc=\$?
    # Swap even when the probe failed so the refusal contract is exercised
    # on every platform (a broken identity probe must still fail closed).
    mv "\$1" "\$1.original"
    mkdir -p "\$1"
    printf 'replacement\n' > "\$1/data"
    return "\$snap_rc"
}
safe_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "\$1"
    return 0
}

rc=0
mole_delete "$victim" false "\$expected_identity" || rc=\$?
[[ \$rc -ne 0 ]] || exit 1
[[ -f "$victim/data" && -f "$victim.original/data" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "mole_delete dry-run propagates an interrupted preview registration" {
    local victim="$SANDBOX/interrupted-preview"
    mkdir -p "$victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_DRY_RUN=1
_record_file_ops_dry_run_target() { return 130; }
safe_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "\$1"
    return 99
}
rc=0
mole_delete "$victim" || rc=\$?
printf 'RC=%s\n' "\$rc"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ -d "$victim" ]] || return 1
    [ "$(awk -F'\t' 'END { print $4 }' "$MOLE_DELETE_LOG")" = "interrupted" ]
}

@test "mole_delete warns once per session when audit log is unwritable" {
    local victim="$SANDBOX/log_blocked"
    : > "$victim"
    local broken_log_dir="$SANDBOX/no_write/logs"
    mkdir -p "$(dirname "$broken_log_dir")"
    chmod 0555 "$(dirname "$broken_log_dir")"

    run /bin/bash --noprofile --norc <<EOF
set -euo pipefail
export MOLE_DELETE_LOG="$broken_log_dir/deletions.log"
export MOLE_TEST_TRASH_DIR="$MOLE_TEST_TRASH_DIR"
export MOLE_TEST_NO_AUTH=1
source "$PROJECT_ROOT/lib/core/common.sh"
mole_delete "$victim"
# Second call in the same shell must NOT print again.
: > "$SANDBOX/second_victim"
mole_delete "$SANDBOX/second_victim"
EOF

    chmod 0755 "$(dirname "$broken_log_dir")"

    [ "$status" -eq 0 ]
    # Warning visible exactly once.
    local warn_count
    warn_count=$(printf '%s\n' "$output" | grep -c "deletions audit log unavailable" || true)
    [ "$warn_count" = "1" ]
}

@test "get_path_size_kb bounds a hung du instead of wedging the sizing worker" {
    # Regression: the primary sizing du (file_ops.sh get_path_size_kb) ran
    # WITHOUT run_with_timeout while every sibling call site was bounded, so
    # one stalled SMB/FUSE mount wedged a parallel scan worker forever. The
    # stub du sleeps far past the 1s override; a bounded helper returns the
    # timeout status quickly, while an unbounded one trips the bats timeout.
    local stub_dir="$SANDBOX/stub-bin"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/du" <<'STUB'
#!/bin/bash
sleep 30
echo "999999 /"
STUB
    chmod +x "$stub_dir/du"

    local victim_dir="$SANDBOX/big-dir"
    mkdir -p "$victim_dir"

    local started elapsed
    started=$SECONDS
    run /bin/bash --noprofile --norc <<EOF
set -euo pipefail
export PATH="$stub_dir:\$PATH"
export MOLE_TIMEOUT_DISK_VERIFY_SEC=1
export MOLE_TEST_NO_AUTH=1
source "$PROJECT_ROOT/lib/core/common.sh"
get_path_size_kb "$victim_dir"
EOF
    elapsed=$((SECONDS - started))

    [ "$status" -eq 124 ]
    [ -z "$output" ] || return 1
    # Generous ceiling: 1s timeout + escalation grace, never 30s.
    [ "$elapsed" -lt 10 ] || return 1
}

@test "safe_sudo_remove accepts a precomputed size without another du probe" {
    local victim="$SANDBOX/precomputed-sudo"
    local fake_bin="$SANDBOX/precomputed-bin"
    local trace="$SANDBOX/precomputed-sudo.log"
    mkdir -p "$victim" "$fake_bin"
    printf 'payload' > "$victim/data.txt"

    cat > "$fake_bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$MOLE_TEST_TRACE"
if [[ "${1:-}" == "-n" ]]; then
    shift
fi
"$@"
SH
    chmod +x "$fake_bin/sudo"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
unset MOLE_TEST_NO_AUTH MOLE_TEST_MODE
export PATH="$fake_bin:\$PATH"
export MOLE_TEST_TRACE="$trace"
_mole_privileged_path_has_mutable_ancestor() { return 1; }
safe_sudo_remove "$victim" 7
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ ! -e "$victim" ]] || return 1
    [[ "$(grep -c -- 'rm -rf' "$trace" 2> /dev/null || true)" -eq 1 ]] || return 1
    [[ "$(grep -c -- 'du -skP' "$trace" 2> /dev/null || true)" -eq 0 ]]
}
