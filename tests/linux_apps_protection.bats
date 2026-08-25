#!/usr/bin/env bats
# Linux safety additions (contract §4): critical path denies, protected
# package denies, data-protected leftover ids, and the pacman-ownership guard
# hook. Darwin tables stay empty behind the platform gate.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-linux-apps-protection-home.XXXXXX")"
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

    export XDG_CONFIG_HOME="${XDG_CONFIG_HOME_OVERRIDE:-$HOME/.config}"
    unset XDG_CONFIG_HOME_OVERRIDE
}

@test "critical system paths are denied, including children" {
    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export MOLE_PLATFORM=linux
cd "$PROJECT_ROOT"
source lib/core/common.sh
for p in /boot /boot/efi /boot/grub/grub.cfg /etc /etc/passwd /usr /usr/bin \
         /bin /lib /proc/self /var/lib/pacman/local /var/lib/rpm; do
    if should_protect_path "\$p"; then echo "deny \$p"; else echo "ALLOW \$p"; fi
done
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"ALLOW"* ]]
}

@test "~/.ssh style user dirs deny contents; ~/.config denies only itself" {
    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export MOLE_PLATFORM=linux
cd "$PROJECT_ROOT"
source lib/core/common.sh
check() {
    if should_protect_path "\$1"; then echo "deny"; else echo "allow"; fi
}
echo "ssh-dir=\$(check "$HOME/.ssh")"
echo "ssh-key=\$(check "$HOME/.ssh/id_ed25519")"
echo "gnupg=\$(check "$HOME/.gnupg/pubring.kbx")"
echo "config-self=\$(check "$HOME/.config")"
echo "config-child=\$(check "$HOME/.config/myapp")"
echo "home-child=\$(check "$HOME/Documents")"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"ssh-dir=deny"* ]]
    [[ "$output" == *"ssh-key=deny"* ]]
    [[ "$output" == *"gnupg=deny"* ]]
    [[ "$output" == *"config-self=deny"* ]]
    [[ "$output" == *"config-child=allow"* ]]
    [[ "$output" == *"home-child=allow"* ]]
}

@test "system-critical packages are denied from removal, normal apps are not" {

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export MOLE_PLATFORM=linux
cd "$PROJECT_ROOT"
source lib/core/common.sh
if is_protected_linux_package systemd; then echo "deny systemd"; else echo "ALLOW systemd"; fi
if is_protected_linux_package pacman; then echo "deny pacman"; else echo "ALLOW pacman"; fi
if is_protected_linux_package htop; then echo "deny htop"; else echo "allow htop"; fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"deny systemd"* ]]
    [[ "$output" == *"deny pacman"* ]]
    [[ "$output" == *"allow htop"* ]]
    [[ "$output" != *"ALLOW"* ]]
}

@test "data-protected leftover ids match case-insensitively" {
    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export MOLE_PLATFORM=linux
cd "$PROJECT_ROOT"
source lib/core/common.sh
should_protect_linux_leftover_id Firefox && echo "hit-firefox"
should_protect_linux_leftover_id keepassxc && echo "hit-keepassxc"
should_protect_linux_leftover_id myapp || echo "miss-myapp"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"hit-firefox"* ]]
    [[ "$output" == *"hit-keepassxc"* ]]
    [[ "$output" == *"miss-myapp"* ]]
}

@test "pacman-owned paths are denied during uninstall flows" {
    printf '%s\n' "$HOME/.local/share/packedapp" > "$FAKE_DB/owned.txt"
    mkdir -p "$HOME/.local/share/packedapp"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_PLATFORM=linux
cd "$PROJECT_ROOT"
source lib/core/common.sh

target="$HOME/.local/share/packedapp"
MOLE_UNINSTALL_MODE=0
if mole_pacman_owns_path "\$target"; then echo "hook-hit"; else echo "hook-miss"; fi

MOLE_UNINSTALL_MODE=1
if should_protect_path "\$target"; then echo "guarded-in-uninstall"; else echo "UNGUARDED"; fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"hook-hit"* ]]
    [[ "$output" == *"guarded-in-uninstall"* ]]
    [[ "$output" != *"UNGUARDED"* ]]
}

@test "darwin keeps the linux tables empty behind the gate" {
    # Sourced standalone: common.sh re-detects the real platform, which on a
    # Linux CI host would override the darwin simulation.
    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export MOLE_PLATFORM=darwin
cd "$PROJECT_ROOT"
source lib/core/app_protection_data.sh
echo "packages=\${#SYSTEM_CRITICAL_PACKAGES[@]}"
echo "ids=\${#DATA_PROTECTED_IDS[@]}"
echo "syspaths=\${#LINUX_CRITICAL_SYSTEM_PATHS[@]}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"packages=0"* ]]
    [[ "$output" == *"ids=0"* ]]
    [[ "$output" == *"syspaths=0"* ]]
}
