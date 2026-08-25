#!/usr/bin/env bats
# remove.sh linux dry-run plan correctness: binaries, completion snippets,
# and XDG config/cache/state dirs, with no Homebrew or pacman assumptions.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    FIXTURES="${BATS_TEST_DIRNAME}/fixtures/linux/misc"
    export FIXTURES
}

teardown_file() {
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-rm-linux.XXXXXX")"
    export HOME
    mkdir -p "$HOME/.local/bin" "$HOME/.cache/mole" "$HOME/.config/mole" \
        "$HOME/.local/state/mole" "$HOME/.config/fish/completions"
    printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/mo"
    chmod +x "$HOME/.local/bin/mo"
    : > "$HOME/.config/fish/completions/mo.fish"
    : > "$HOME/.config/fish/completions/mole.fish"
    : > "$HOME/.bashrc"
    printf "# Mole shell completion\nif output=\"\$(mole completion bash 2>/dev/null)\"; then eval \"\$output\"; fi\n" >> "$HOME/.bashrc"
}

teardown() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
}

@test "linux dry-run lists every artifact class without deleting anything" {
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux MOLE_TEST_MODE=1 \
        /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/remove.sh"
remove_mole true
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN MODE"* ]]
    [[ "$output" == *"Would remove: $HOME/.local/bin/mo"* ]]
    [[ "$output" == *"Would move to trash: $HOME/.config/mole"* ]]
    [[ "$output" == *"Would remove: $HOME/.cache/mole"* ]]
    [[ "$output" == *"Would remove: ${XDG_STATE_HOME:-$HOME/.local/state}/mole"* ]]
    [[ "$output" == *"$HOME/.config/fish/completions/mo.fish"* ]]
    [[ "$output" == *"Would strip completion entries from shell rc files"* ]]
    [[ "$output" != *"brew"* ]]
    # Nothing may actually be removed in dry-run.
    [ -f "$HOME/.local/bin/mo" ]
    [ -d "$HOME/.cache/mole" ]
    [ -f "$HOME/.bashrc" ]
}

@test "linux dry-run reports no installation on a clean home" {
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux MOLE_TEST_MODE=1 \
        XDG_CONFIG_HOME= XDG_CACHE_HOME= XDG_STATE_HOME= \
        /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
# Source first: core wiring may recreate Mole-owned dirs at load time.
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/remove.sh"
rm -rf "$HOME"/.local/bin/mo "$HOME"/.cache/mole "$HOME"/.config/mole \
    "$HOME"/.local/state/mole "$HOME"/.config/fish
remove_mole true
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No Mole installation detected"* ]]
}

@test "linux detection ignores brew entirely even when installed" {
    local fake_bin="$HOME/fakebin"
    mkdir -p "$fake_bin"
    printf '#!/bin/bash\nexit 0\n' > "$fake_bin/brew"
    chmod +x "$fake_bin/brew"

    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux MOLE_TEST_MODE=1 \
        PATH="$fake_bin:$PATH" \
        /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/remove.sh"
remove_mole true
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"brew uninstall"* ]]
    [[ "$output" != *"Homebrew"* ]]
}
