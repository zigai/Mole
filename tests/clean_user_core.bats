#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-user-core.XXXXXX")"
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

@test "validate_external_volume_target canonicalizes root before comparing target" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/linux_user.sh"

mock_bin="$HOME/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/diskutil" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$mock_bin/diskutil"
export PATH="$mock_bin:$PATH"

real_root="$(mktemp -d "$HOME/ext-real.XXXXXX")"
link_root="$HOME/ext-link"
ln -s "$real_root" "$link_root"
mkdir -p "$link_root/USB"
export MOLE_EXTERNAL_VOLUMES_ROOT="$link_root"

resolved=$(validate_external_volume_target "$link_root/USB")
echo "RESOLVED=$resolved"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"RESOLVED="*"/USB"* ]] || return 1
    [[ "$output" != *"must be under"* ]]
}
