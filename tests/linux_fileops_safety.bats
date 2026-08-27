#!/usr/bin/env bats

# Linux critical-path denies (contract §4): deletion validation refuses
# linux system roots and user secret stores; the whitelist loader refuses to
# whitelisting them and keeps hard-safety entries merged for every user.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-linux-fileops-safety.XXXXXX")"
    export SANDBOX
    HOME_DIR="$SANDBOX/home"
    mkdir -p "$HOME_DIR"
    export HOME_DIR
    export MOLE_TEST_NO_AUTH=1
    # Immunity against cross-suite leakage: scripts/test.sh sources
    # lib/core files into its own shell, which exports MOLE_PLATFORM (and
    # friends) into every bats worker. Drop the inherited preset so the
    # library's own "linux" default applies.
    unset MOLE_PLATFORM MOLE_DISTRO_ID MOLE_OS_RELEASE_FILE MOLE_LOG_ROTATED || true
}

teardown() {
    rm -rf "$SANDBOX"
}

prelude() {
    cat <<EOF
set -euo pipefail
export HOME="$HOME_DIR"
export MOLE_TEST_NO_AUTH=1
source "$PROJECT_ROOT/lib/core/common.sh"
EOF
}

@test "validate_path_for_deletion refuses linux system roots" {
    run /bin/bash --noprofile --norc <<EOF
$(prelude)
for p in /etc /etc/passwd /boot /boot/vmlinuz /efi /proc /proc/1 /sys \
    /dev /run /srv /lib /lib64 /usr /usr/bin/env /var/lib/pacman /var/lib/rpm; do
    if validate_path_for_deletion "\$p" 2> /dev/null; then
        echo "NOT-DENIED \$p"
    fi
done
EOF

    [ "$status" -eq 0 ]
    [[ -z "$output" ]] || return 1
}

@test "validate_path_for_deletion refuses user secret stores but not their neighbors" {
    mkdir -p "$HOME_DIR/.ssh" "$HOME_DIR/.gnupg" "$HOME_DIR/.config/app-cache"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
denied=0
for p in "$HOME_DIR/.ssh" "$HOME_DIR/.ssh/id_rsa" "$HOME_DIR/.gnupg" \\
    "$HOME_DIR/.config"; do
    if validate_path_for_deletion "\$p" 2> /dev/null; then
        echo "NOT-DENIED \$p"
    fi
done
if validate_path_for_deletion "$HOME_DIR/.config/app-cache" 2> /dev/null; then
    echo "CHILD-ALLOWED-OK"
fi
echo DONE
EOF

    [ "$status" -eq 0 ]
    grep -q "CHILD-ALLOWED-OK" <<< "$output" || return 1
    grep -q "^DONE$" <<< "$output" || return 1
    ! grep -q "NOT-DENIED" <<< "$output" || return 1
}

@test "whitelist loader rejects linux critical paths with a warning" {
    wl="$HOME_DIR/.config/mole/whitelist"
    mkdir -p "$(dirname "$wl")"
    printf '%s\n' "/etc" "$HOME_DIR/.ssh" "$HOME_DIR/.config" "$HOME_DIR/.cache/pizza*" > "$wl"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
load_mole_whitelist
printf 'count=%s\n' "\${#WHITELIST_PATTERNS[@]}"
for w in "\${WHITELIST_PATTERNS[@]}"; do echo "PATTERN \$w"; done
printf 'warnings=%s\n' "\${#WHITELIST_WARNINGS[@]}"
EOF

    # One surviving user pattern plus the two merged linux safety entries
    # (mole cache + state roots). Trash was deliberately removed from the
    # safety set: mo clean empties Trash CONTENTS by design.
    [ "$(grep -c '^PATTERN ' <<< "$output")" -eq 3 ] || return 1
    grep -qF "$HOME_DIR/.cache/pizza*" <<< "$output" || return 1
    grep -qF "$HOME_DIR/.cache/mole*" <<< "$output" || return 1
    # One warning per rejected critical line.
    [ "$(grep -c '^warnings=' <<< "$output")" -eq 1 ]
    warnings_line="$(grep '^warnings=' <<< "$output")"
    [ "$warnings_line" = "warnings=3" ] || return 1
}

@test "linux safety patterns stay merged when a user whitelist exists" {
    wl="$HOME_DIR/.config/mole/whitelist"
    mkdir -p "$HOME_DIR/.cache" "$HOME_DIR/.config/mole"
    : > "$HOME_DIR/.cache/keepme-data"
    printf '%s\n' "$HOME_DIR/.cache/keepme*" > "$wl"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
load_mole_whitelist
for p in "\${WHITELIST_PATTERNS[@]}"; do echo "PATTERN \$p"; done
safe_remove "$HOME_DIR/.cache/keepme-data" true >/dev/null 2>&1 && echo REMOVED || echo KEPT
[[ -e "$HOME_DIR/.cache/keepme-data" ]] && echo EXISTS || echo GONE
EOF

    [ "$status" -eq 0 ]
    grep -qF "$HOME_DIR/.cache/mole*" <<< "$output" || return 1
    grep -qF "$HOME_DIR/.local/state/mole*" <<< "$output" || return 1
    # Trash was deliberately removed from safety patterns: mo clean empties
    # its CONTENTS by design (see clean_linux_trash); the dir itself is never
    # a sweep target.
    grep -qF "$HOME_DIR/.local/share/Trash*" <<< "$output" && return 1
    grep -q "^EXISTS$" <<< "$output" || return 1
}
