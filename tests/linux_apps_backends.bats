#!/usr/bin/env bats
# Linux uninstall enumeration backends: pacman / flatpak / desktop rows,
# merge dedupe, and the inventory fingerprint (contract §5).

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-linux-apps-backends-home.XXXXXX")"
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
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi

    FAKE_DB="$(mktemp -d "${HOME}/fake-pacman-db.XXXXXX")"
    export FAKE_DB
    : > "$FAKE_DB/packages.tsv"
    : > "$FAKE_DB/owned.txt"

    BIN_ROOT="$(mktemp -d "${HOME}/fake-bin.XXXXXX")"
    export BIN_ROOT

    export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
    export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
    export MOLE_DESKTOP_APPLICATIONS_DIRS=""
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_STATE_HOME="$HOME/.local/state"
}

add_package() {
    local name="$1" explicit="$2" size="$3"
    printf '%s\t%s\t%s\n' "$name" "$explicit" "$size" >> "$FAKE_DB/packages.tsv"
}

add_owned_path() {
    printf '%s\n' "$1" >> "$FAKE_DB/owned.txt"
}

@test "pacman backend emits rows for explicit packages with installed sizes" {
    add_package "htop" "1" "200.00 KiB"
    add_package "ripgrep" "1" "4.50 MiB"
    add_package "systemd" "0" "40.00 MiB" # dependency: never listed
    printf '#!/bin/sh\n' > "$BIN_ROOT/htop"
    chmod +x "$BIN_ROOT/htop"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
cd "$PROJECT_ROOT"
source lib/uninstall/backends/pacman.sh
pacman_backend_rows
EOF

    [ "$status" -eq 0 ]
    expected_row="pacman|htop|htop|200|$BIN_ROOT/htop"
    [[ "$output" == *"$expected_row"* ]]
}

@test "pacman backend drops packages whose representative binary is absent" {
    add_package "ghostpkg" "1" "10.00 MiB"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
cd "$PROJECT_ROOT"
source lib/uninstall/backends/pacman.sh
pacman_backend_rows
EOF

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "flatpak backend emits app ids, names, sizes and data-dir targets" {
    mkdir -p "$HOME/.var/app/org.foo.Editor"

    local_list="${HOME}/fake-flatpak.list"
    printf 'org.foo.Editor\tFoo Editor\t120.00 MB\norg.bar.Cli\tBar CLI\t\n' > "$local_list"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_FLATPAK_LIST="$local_list"
cd "$PROJECT_ROOT"
source lib/uninstall/backends/flatpak.sh
flatpak_backend_rows
EOF

    [ "$status" -eq 0 ]
    expected_row="flatpak|org.foo.Editor|Foo Editor|122880|$HOME/.var/app/org.foo.Editor"
    [[ "$output" == *"$expected_row"* ]]
    [[ "$output" == *"flatpak|org.bar.Cli|Bar CLI|0|"* ]]
}

@test "desktop backend emits unowned entries and skips package-owned ones" {
    add_owned_path "/usr/share/applications/owned.desktop"
    printf '#!/bin/sh\n' > "$BIN_ROOT/free-tool"
    printf '#!/bin/sh\n' > "$BIN_ROOT/packed-tool"
    chmod +x "$BIN_ROOT/free-tool" "$BIN_ROOT/packed-tool"
    add_package "packed-tool" "1" "1.00 MiB"

    apps_dir="${HOME}/.local/share/applications"
    mkdir -p "$apps_dir"
    cat > "$apps_dir/free-tool.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Free Tool
Exec=free-tool %U
TryExec=free-tool
DESK
    cat > "$apps_dir/packed-tool.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Packed Tool
Exec=packed-tool
DESK
    cat > "$apps_dir/nodisplay.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Hidden App
NoDisplay=true
DESK
    add_owned_path "$BIN_ROOT/packed-tool"
    cat > "$apps_dir/flatpaked.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Flatpak App
X-Flatpak=true
Exec=free-tool
DESK

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
export MOLE_DESKTOP_APPLICATIONS_DIRS="$apps_dir"
cd "$PROJECT_ROOT"
source lib/uninstall/backends/desktop.sh
desktop_backend_rows
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"desktop|free-tool|Free Tool|"*"$BIN_ROOT/free-tool"* ]]
    [[ "$output" != *"packed-tool"* ]]
    [[ "$output" != *"nodisplay"* ]]
    [[ "$output" != *"flatpaked"* ]]
}

@test "merge dedupes rows by identity across backends" {
    # Two desktop entries resolving to the same binary collapse into one row.
    printf '#!/bin/sh\n' > "$BIN_ROOT/dual"
    chmod +x "$BIN_ROOT/dual"
    apps_dir="${HOME}/.local/share/applications"
    mkdir -p "$apps_dir"
    cat > "$apps_dir/dual.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Dual
Exec=dual
DESK
    cat > "$apps_dir/dual-alt.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Dual Alt
TryExec=dual
DESK

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
export MOLE_DESKTOP_APPLICATIONS_DIRS="$apps_dir"
cd "$PROJECT_ROOT"
source lib/core/common.sh
source lib/uninstall/enumerate.sh
enumerate_linux_rows | grep -c '^desktop|'
EOF

    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "index builds selector rows with kind:id channel encoding" {
    add_package "htop" "1" "300.00 KiB"
    printf '#!/bin/sh\n' > "$BIN_ROOT/htop"
    chmod +x "$BIN_ROOT/htop"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
export MOLE_DESKTOP_APPLICATIONS_DIRS="\$HOME/__none__"
cd "$PROJECT_ROOT"
source lib/core/common.sh
source lib/uninstall/enumerate.sh
out=\$(mktemp)
enumerate_linux_index "\$out"
cat "\$out"
rm -f "\$out"
EOF

    [ "$status" -eq 0 ]
    expected_row="0|$BIN_ROOT/htop|htop|pacman:htop|307KB|Unknown|300"
    [[ "$output" == *"$expected_row"* ]]
}

@test "inventory fingerprint tracks package and flatpak lists" {
    add_package "htop" "1" "1.00 MiB"
    printf '#!/bin/sh\n' > "$BIN_ROOT/htop"
    chmod +x "$BIN_ROOT/htop"
    touch "${HOME}/fake-flatpak.list"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
touch "$FAKE_DB/fake-flatpak.list"
export MOLE_FAKE_FLATPAK_LIST="$FAKE_DB/fake-flatpak.list"
cd "$PROJECT_ROOT"
source lib/core/common.sh
source lib/uninstall/enumerate.sh
before=\$(enumerate_linux_fingerprint)
printf 'htop-extra\t1\t9.99 MiB\n' >> "$FAKE_DB/packages.tsv"
after=\$(enumerate_linux_fingerprint)
printf '%s\n%s\n' "\$before" "\$after"
EOF

    [ "$status" -eq 0 ]
    local first second
    first=$(printf '%s\n' "$output" | sed -n 1p)
    second=$(printf '%s\n' "$output" | sed -n 2p)
    [[ -n "$first" && -n "$second" && "$first" != "$second" ]]
}
