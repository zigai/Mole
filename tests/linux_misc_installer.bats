#!/usr/bin/env bats
# Linux installer pattern matching on temp trees, plus darwin pattern parity.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-inst-linux.XXXXXX")"
    export HOME

    mkdir -p "$HOME/Downloads" "$HOME/Desktop"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "linux candidate matching accepts distribution and app formats" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux \
        MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/installer.sh"
for name in app.pkg.tar.zst pkg.deb lib.rpm Tool.AppImage disk.iso src.tar.gz src.tar.xz; do
    if handle_candidate_file "/dl/$name" | grep -q .; then
        echo "MATCH $name"
    else
        echo "NOMATCH $name"
    fi
done
EOF

    [ "$status" -eq 0 ]
    for name in app.pkg.tar.zst pkg.deb lib.rpm Tool.AppImage disk.iso src.tar.gz src.tar.xz; do
        grep -qx "MATCH $name" <<< "$output"
    done
}

@test "linux candidate matching rejects mac and unknown formats" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux \
        MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/installer.sh"
for name in app.dmg installer.pkg setup.mpkg os.xip notes.txt photo.tar.zst; do
    if handle_candidate_file "/dl/$name" | grep -q .; then
        echo "MATCH $name"
    else
        echo "NOMATCH $name"
    fi
done
EOF

    [ "$status" -eq 0 ]
    if grep -q '^MATCH ' <<< "$output"; then
        fail "unexpected MATCH line survived installer filtering"
    fi
    grep -qx 'NOMATCH app.dmg' <<< "$output"
    [[ "$output" == *"NOMATCH installer.pkg"* ]]
}

@test "darwin keeps its historical patterns byte-equivalent in effect" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=darwin \
        FIXTURE_UNAME_S=Darwin PATH="${BATS_TEST_DIRNAME}/fixtures/linux/misc/bin:$PATH" \
        MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/installer.sh"
for name in app.dmg installer.pkg setup.mpkg disk.iso image.xip pkg.deb Tool.AppImage; do
    if handle_candidate_file "/dl/$name" | grep -q .; then
        echo "MATCH $name"
    else
        echo "NOMATCH $name"
    fi
done
echo "paths=${#INSTALLER_SCAN_PATHS[@]}"
EOF

    [ "$status" -eq 0 ]
    for name in app.dmg installer.pkg setup.mpkg disk.iso image.xip; do
        grep -qx "MATCH $name" <<< "$output"
    done
    [[ "$output" == *"NOMATCH pkg.deb"* ]]
    [[ "$output" == *"NOMATCH Tool.AppImage"* ]]
    [[ "$output" != *"paths=3"* ]] # darwin keeps the extended scan path list
}

@test "linux scanner finds linux installers under Downloads" {
    mkdir -p "$HOME/Downloads/nested"
    : > "$HOME/Downloads/tool-1.0-x86_64.AppImage"
    : > "$HOME/Downloads/pkg-1.2-1.fc44.noarch.rpm"
    : > "$HOME/Downloads/nested/app-2.0.pkg.tar.zst"
    : > "$HOME/Downloads/readme.txt"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux \
        MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/installer.sh"
scan_all_installers | sort
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/Downloads/tool-1.0-x86_64.AppImage"* ]]
    [[ "$output" == *"$HOME/Downloads/pkg-1.2-1.fc44.noarch.rpm"* ]]
    [[ "$output" == *"$HOME/Downloads/nested/app-2.0.pkg.tar.zst"* ]]
    [[ "$output" != *"readme.txt"* ]]
}

@test "linux zip detection matches linux payloads inside zips" {
    if ! command -v zip > /dev/null 2>&1 || ! { command -v zipinfo > /dev/null 2>&1 || command -v unzip > /dev/null 2>&1; }; then
        skip "zip tooling unavailable"
    fi

    mkdir -p "$HOME/Downloads/payload"
    : > "$HOME/Downloads/payload/setup.deb"
    (cd "$HOME/Downloads" && zip -q -r linux-payload.zip payload)

    mkdir -p "$HOME/Downloads/plain"
    for i in {1..3}; do : > "$HOME/Downloads/plain/file$i.txt"; done
    (cd "$HOME/Downloads" && zip -q -r plain.zip plain)
    rm -rf "$HOME/Downloads/plain"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux \
        MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/installer.sh"
is_installer_zip "$HOME/Downloads/linux-payload.zip" && echo "PAYLOAD_MATCH"
if is_installer_zip "$HOME/Downloads/plain.zip"; then
    echo "PLAIN_MATCH"
else
    echo "PLAIN_NOMATCH"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PAYLOAD_MATCH"* ]]
    [[ "$output" == *"PLAIN_NOMATCH"* ]]
}

@test "pacman package cache is summarized report-only" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux \
        MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/installer.sh"
cache_dir="\$HOME/pacman-fixture"
mkdir -p "\$cache_dir"
head -c 4096 /dev/zero > "\$cache_dir/foo-1.0-1-x86_64.pkg.tar.zst"
: > "\$cache_dir/bar-2.0-2-any.pkg.tar.zst"
: > "\$cache_dir/keep.db"
_installer_report_pacman_cache "\$cache_dir"
scan_all_installers | sort
exit 0
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Report only: 2 installer packages"* ]]
    # The fixture cache must never appear as a deletable scan result.
    [[ "$output" != *"$HOME/pacman-fixture/foo-1.0-1-x86_64.pkg.tar.zst"* ]]

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=darwin \
        FIXTURE_UNAME_S=Darwin PATH="${BATS_TEST_DIRNAME}/fixtures/linux/misc/bin:$PATH" \
        MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/installer.sh"
_installer_report_pacman_cache "\$HOME/pacman-fixture"
exit 0
EOF
    [ "$status" -eq 0 ]
    [[ "$output" != *"Report only"* ]]
}
