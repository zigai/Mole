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

    # deb/rpm fixture databases (see the dpkg-query/rpm stub headers) and a
    # pinned distro so the pacman-based tests are immune to whatever native
    # tooling the host running the suite happens to have.
    export MOLE_DISTRO_ID="arch"
    DEB_TSV="$FAKE_DB/dpkg.tsv"
    : > "$DEB_TSV"
    export MOLE_FAKE_DPKG_QUERY="$DEB_TSV"
    : > "$FAKE_DB/owned-deb.txt"
    export MOLE_FAKE_DPKG_OWNED="$FAKE_DB/owned-deb.txt"
    RPM_TSV="$FAKE_DB/rpm.tsv"
    : > "$RPM_TSV"
    export MOLE_FAKE_RPM_DB="$RPM_TSV"
    : > "$FAKE_DB/owned-rpm.txt"
    export MOLE_FAKE_RPM_OWNED="$FAKE_DB/owned-rpm.txt"
}

add_deb_package() {
    local name="$1" size_kib="$2" manual="$3"
    printf '%s\t%s\t%s\n' "$name" "$size_kib" "$manual" >> "$MOLE_FAKE_DPKG_QUERY"
}

add_rpm_package() {
    local name="$1" size_bytes="$2" userinstalled="$3"
    printf '%s\t%s\t%s\n' "$name" "$size_bytes" "$userinstalled" >> "$MOLE_FAKE_RPM_DB"
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
export MOLE_DISTRO_ID="arch"
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
export MOLE_DISTRO_ID="arch"
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
export MOLE_DISTRO_ID="arch"
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
add_deb_owned_path() {
    printf '%s\n' "$1" >> "$MOLE_FAKE_DPKG_OWNED"
}

add_rpm_owned_path() {
    printf '%s\n' "$1" >> "$MOLE_FAKE_RPM_OWNED"
}

@test "deb backend emits rows for manual packages with KiB installed sizes" {
    add_deb_package "frobnicator" 200 1
    add_deb_package "libc6:amd64" 5000 1 # no representative binary: dropped
    printf '#!/bin/sh\n' > "$BIN_ROOT/frobnicator"
    chmod +x "$BIN_ROOT/frobnicator"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_DPKG_QUERY="$MOLE_FAKE_DPKG_QUERY"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
cd "$PROJECT_ROOT"
source lib/uninstall/backends/deb.sh
deb_backend_rows
EOF

    [ "$status" -eq 0 ]
    expected_row="deb|frobnicator|frobnicator|200|$BIN_ROOT/frobnicator"
    [[ "$output" == *"$expected_row"* ]]
    [[ "$output" != *"libc6"* ]]
}

@test "deb size pairs collapse multi-arch names onto bare package names" {
    add_deb_package "libc6:amd64" 5000 1

    run /bin/bash <<EOF
set -uo pipefail
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_DPKG_QUERY="$MOLE_FAKE_DPKG_QUERY"
cd "$PROJECT_ROOT"
source lib/uninstall/backends/deb.sh
_deb_backend_name_size_pairs
EOF

    [ "$status" -eq 0 ]
    [ "$output" = "libc6|5000" ]
}

@test "deb backend drops packages whose representative binary is absent" {
    add_deb_package "ghostpkg" 1024 1

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_DPKG_QUERY="$MOLE_FAKE_DPKG_QUERY"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
cd "$PROJECT_ROOT"
source lib/uninstall/backends/deb.sh
deb_backend_rows
EOF

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "deb ownership probe, installed check, and remove plan" {
    add_deb_owned_path "$HOME/.local/share/packed-deb"
    add_deb_package "presentpkg" 10 1

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_DPKG_QUERY="$MOLE_FAKE_DPKG_QUERY"
export MOLE_FAKE_DPKG_OWNED="$MOLE_FAKE_DPKG_OWNED"
cd "$PROJECT_ROOT"
source lib/uninstall/backends/deb.sh
if deb_backend_owns_path "\$HOME/.local/share/packed-deb"; then echo "owns=hit"; else echo "owns=miss"; fi
if deb_backend_owns_path "\$HOME/unowned-path"; then echo "unowned=hit"; else echo "unowned=miss"; fi
if deb_backend_package_installed presentpkg; then echo "installed=hit"; else echo "installed=miss"; fi
if deb_backend_package_installed ghostpkg; then echo "ghost=hit"; else echo "ghost=miss"; fi
printf 'plan=%s' "\$(deb_backend_remove_plan presentpkg)"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"owns=hit"* ]]
    [[ "$output" == *"unowned=miss"* ]]
    [[ "$output" == *"installed=hit"* ]]
    [[ "$output" == *"ghost=miss"* ]]
    [[ "$output" == *"plan=sudo apt-get -y remove presentpkg"* ]]
}

@test "rpm backend emits rows with byte sizes truncated to KiB" {
    add_rpm_package "frobnicator" 262144 1 # exactly 256 KiB
    add_rpm_package "tinytool" 2047 1      # truncates to 1 KiB
    add_rpm_package "dep-lib" 9999999 0    # dependency: never listed
    printf '#!/bin/sh\n' > "$BIN_ROOT/frobnicator"
    printf '#!/bin/sh\n' > "$BIN_ROOT/tinytool"
    chmod +x "$BIN_ROOT/frobnicator" "$BIN_ROOT/tinytool"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_RPM_DB="$MOLE_FAKE_RPM_DB"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
cd "$PROJECT_ROOT"
source lib/uninstall/backends/rpm.sh
rpm_backend_rows
EOF

    [ "$status" -eq 0 ]
    expected_row="rpm|frobnicator|frobnicator|256|$BIN_ROOT/frobnicator"
    [[ "$output" == *"$expected_row"* ]]
    expected_row="rpm|tinytool|tinytool|1|$BIN_ROOT/tinytool"
    [[ "$output" == *"$expected_row"* ]]
    [[ "$output" != *"dep-lib"* ]]
}

@test "rpm backend drops packages whose representative binary is absent" {
    add_rpm_package "ghostpkg" 4096 1

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_RPM_DB="$MOLE_FAKE_RPM_DB"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
cd "$PROJECT_ROOT"
source lib/uninstall/backends/rpm.sh
rpm_backend_rows
EOF

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "rpm ownership probe, installed check, and remove plan" {
    add_rpm_owned_path "$HOME/.local/share/packed-rpm"
    add_rpm_package "presentpkg" 10 1

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_RPM_DB="$MOLE_FAKE_RPM_DB"
export MOLE_FAKE_RPM_OWNED="$MOLE_FAKE_RPM_OWNED"
cd "$PROJECT_ROOT"
source lib/uninstall/backends/rpm.sh
if rpm_backend_owns_path "\$HOME/.local/share/packed-rpm"; then echo "owns=hit"; else echo "owns=miss"; fi
if rpm_backend_owns_path "\$HOME/unowned-path"; then echo "unowned=hit"; else echo "unowned=miss"; fi
if rpm_backend_package_installed presentpkg; then echo "installed=hit"; else echo "installed=miss"; fi
if rpm_backend_package_installed ghostpkg; then echo "ghost=hit"; else echo "ghost=miss"; fi
printf 'plan=%s' "\$(rpm_backend_remove_plan presentpkg)"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"owns=hit"* ]]
    [[ "$output" == *"unowned=miss"* ]]
    [[ "$output" == *"installed=hit"* ]]
    [[ "$output" == *"ghost=miss"* ]]
    [[ "$output" == *"plan=sudo dnf -y remove presentpkg"* ]]
}

@test "backend selection follows distro affinity and enables one native backend" {
    add_deb_package "debapp" 10 1
    add_rpm_package "rpmapp" 10 1
    printf '#!/bin/sh\n' > "$BIN_ROOT/htop"
    chmod +x "$BIN_ROOT/htop"
    add_package "htop" "1" "1.00 MiB"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_FAKE_DPKG_QUERY="$MOLE_FAKE_DPKG_QUERY"
export MOLE_FAKE_RPM_DB="$MOLE_FAKE_RPM_DB"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
touch "$FAKE_DB/fake-flatpak.list"
export MOLE_FAKE_FLATPAK_LIST="$FAKE_DB/fake-flatpak.list"
cd "$PROJECT_ROOT"
source lib/uninstall/enumerate.sh

MOLE_DISTRO_ID=fedora fedora_out=\$(enumerate_linux_backends)
MOLE_DISTRO_ID=debian debian_out=\$(enumerate_linux_backends)
printf 'fedora-first=%s\n' "\$(printf '%s\\n' "\$fedora_out" | sed -n 1p)"
printf 'debian-first=%s\n' "\$(printf '%s\\n' "\$debian_out" | sed -n 1p)"
native_count=\$(printf '%s\\n' "\$fedora_out" | grep -Ecx 'pacman|deb|rpm')
printf 'native_count=%s\n' "\$native_count"
printf '%s\\n' "\$fedora_out" | grep -qx flatpak && printf '%s\\n' "\$fedora_out" | grep -qx desktop \\
    && echo "aux-backends=present" || echo "aux-backends=missing"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"fedora-first=rpm"* ]]
    [[ "$output" == *"debian-first=deb"* ]]
    [[ "$output" != *"fedora-first=pacman"* && "$output" != *"fedora-first=deb"* ]]
    [[ "$output" == *"native_count=1"* ]]
    # flatpak + desktop are always appended alongside the native backend.
    [[ "$output" == *"aux-backends=present"* ]]
}

@test "unknown distros fall back to capability probes for the native backend" {
    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$BIN_ROOT:$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_FAKE_DPKG_QUERY="$MOLE_FAKE_DPKG_QUERY"
export MOLE_FAKE_RPM_DB="$MOLE_FAKE_RPM_DB"
export MOLE_UNINSTALL_LINUX_BIN_DIR="$BIN_ROOT"
unset MOLE_DISTRO_ID
export MOLE_OS_RELEASE_FILE="$PROJECT_ROOT/tests/fixtures/linux/platform/os-release/no-id"
cd "$PROJECT_ROOT"
source lib/platform/platform.sh
source lib/uninstall/enumerate.sh
enumerate_linux_backends | sed -n 1p
EOF

    [ "$status" -eq 0 ]
    [ "$output" = "pacman" ]
}

@test "inventory fingerprint tracks the active native package list" {
    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_DPKG_QUERY="$MOLE_FAKE_DPKG_QUERY"
export MOLE_DISTRO_ID="debian"
touch "$FAKE_DB/fake-flatpak.list"
export MOLE_FAKE_FLATPAK_LIST="$FAKE_DB/fake-flatpak.list"
cd "$PROJECT_ROOT"
source lib/uninstall/enumerate.sh
before=\$(enumerate_linux_fingerprint)
printf 'debextra\t777\t1\n' >> "$MOLE_FAKE_DPKG_QUERY"
after=\$(enumerate_linux_fingerprint)
printf '%s\n%s\n' "\$before" "\$after"
EOF

    [ "$status" -eq 0 ]
    local first second
    first=$(printf '%s\n' "$output" | sed -n 1p)
    second=$(printf '%s\n' "$output" | sed -n 2p)
    [[ -n "$first" && -n "$second" && "$first" != "$second" ]]
}

@test "native_backend_owns_path asks whichever native backend is active" {
    add_owned_path "$HOME/arch-owned-path"
    add_deb_owned_path "$HOME/deb-owned-path"
    add_rpm_owned_path "$HOME/rpm-owned-path"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_FAKE_DPKG_QUERY="$MOLE_FAKE_DPKG_QUERY"
export MOLE_FAKE_DPKG_OWNED="$MOLE_FAKE_DPKG_OWNED"
export MOLE_FAKE_RPM_DB="$MOLE_FAKE_RPM_DB"
export MOLE_FAKE_RPM_OWNED="$MOLE_FAKE_RPM_OWNED"
cd "$PROJECT_ROOT"
source lib/uninstall/enumerate.sh

MOLE_DISTRO_ID=rpm-does-not-exist
MOLE_DISTRO_ID=fedora
if native_backend_owns_path "\$HOME/rpm-owned-path"; then echo "rpm=hit"; else echo "rpm=miss"; fi
MOLE_DISTRO_ID=debian
if native_backend_owns_path "\$HOME/deb-owned-path"; then echo "deb=hit"; else echo "deb=miss"; fi
MOLE_DISTRO_ID=arch
if native_backend_owns_path "\$HOME/arch-owned-path"; then echo "arch=hit"; else echo "arch=miss"; fi
if native_backend_owns_path "\$HOME/unowned-path"; then echo "miss-case-broken"; else echo "unowned=miss"; fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"rpm=hit"* ]]
    [[ "$output" == *"deb=hit"* ]]
    [[ "$output" == *"arch=hit"* ]]
    [[ "$output" == *"unowned=miss"* ]]
    [[ "$output" != *"miss-case-broken"* ]]
}
