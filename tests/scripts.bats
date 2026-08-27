#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-scripts-home.XXXXXX")"
    export HOME

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

setup() {
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    export TERM="dumb"
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME"
}

@test "check.sh --help shows usage information" {
    run "$PROJECT_ROOT/scripts/check.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || return 1
    [[ "$output" == *"--format"* ]] || return 1
    [[ "$output" == *"--no-format"* ]]
}

@test "check.sh script exists and is valid" {
    [ -f "$PROJECT_ROOT/scripts/check.sh" ]
    [ -x "$PROJECT_ROOT/scripts/check.sh" ]

    run /bin/bash -c "grep -q 'Mole Check' '$PROJECT_ROOT/scripts/check.sh'"
	[ "$status" -eq 0 ]
}

@test "diagnostic guidance check rejects equivalent pipe-to-shell spellings across lines" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
eval "$(sed -n '/^check_diagnostic_guidance()/,/^}/p' "$PROJECT_ROOT/scripts/check.sh")"

safe="$HOME/safe-guidance.md"
cat > "$safe" <<'SAFE'
Download `Mole-Diagnose.command` with `curl -o`, inspect it, then open it manually.
SAFE
check_diagnostic_guidance "$safe"

assert_unsafe() {
	local name="$1"
	local guidance="$2"
	local unsafe="$HOME/unsafe-${name}.md"
	printf '%s\n' "$guidance" > "$unsafe"
	if check_diagnostic_guidance "$unsafe"; then
		echo "UNEXPECTED_UNSAFE_PASS:$name"
		exit 1
	fi
}

assert_unsafe path '`curl https://example.test/Mole-Diagnose.command | /bin/bash`'
assert_unsafe command '`curl https://example.test/Mole-Diagnose.command | command bash`'
assert_unsafe sudo '`curl https://example.test/Mole-Diagnose.command | sudo -u root bash`'
assert_unsafe env $'`curl https://example.test/Mole-Diagnose.command \\\n  | env MODE=1 zsh`'
assert_unsafe tee $'`curl https://example.test/Mole-Diagnose.command |\n  tee /tmp/diagnose | dash`'
assert_unsafe quoted "\`curl https://example.test/Mole-Diagnose.command | 'bash'\`"
assert_unsafe ansi_c "\`curl https://example.test/Mole-Diagnose.command | \$'bash'\`"
assert_unsafe ksh '`curl https://example.test/Mole-Diagnose.command | ksh`'
assert_unsafe escaped '`curl https://example.test/Mole-Diagnose.command | ba\sh`'
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" != *"UNEXPECTED_UNSAFE_PASS:"* ]]
}

@test "test.sh script exists and is valid" {
    [ -f "$PROJECT_ROOT/scripts/test.sh" ]
    [ -x "$PROJECT_ROOT/scripts/test.sh" ]

    run /bin/bash -c "grep -q 'Mole Test Runner' '$PROJECT_ROOT/scripts/test.sh'"
    [ "$status" -eq 0 ]
}

@test "test.sh includes test lint step" {
    run /bin/bash -c "grep -q 'Test script lint' '$PROJECT_ROOT/scripts/test.sh'"
    [ "$status" -eq 0 ]
}

@test "Makefile has build target for Go binaries" {
    run /bin/bash -c "grep -Eq '(^|[[:space:]])(go|\\$\\(GO\\))[[:space:]]+build' '$PROJECT_ROOT/Makefile'"
    [ "$status" -eq 0 ]
}

@test "release builds disable cgo and check minimum macOS version" {
    run /bin/bash -c "grep -q '^RELEASE_GO_ENV := CGO_ENABLED=0$' '$PROJECT_ROOT/Makefile'"
    [ "$status" -eq 0 ]
    run /bin/bash -c "grep -q 'scripts/check_release_minos.sh' '$PROJECT_ROOT/.github/workflows/release.yml'"
    [ "$status" -eq 0 ]
    [ -x "$PROJECT_ROOT/scripts/check_release_minos.sh" ]
}

@test "release workflow keeps the Homebrew Core PR open (#1209)" {
    local workflow="$PROJECT_ROOT/.github/workflows/release.yml"
    if [[ "$(uname -s)" != "Darwin" ]]; then
        skip "macOS-only flow"
    fi

    run grep -F "Have you followed the [guidelines for contributing]" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "pulls?state=all&head=tw93:" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'PR_STATE" != "open"' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'core_status=published' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'core_status=pr-open' "$workflow"
    [ "$status" -eq 0 ]

    run awk '
        /name: Update Homebrew formula \(Official Core\)/ { in_step = 1 }
        in_step && /continue-on-error:/ { found = 1 }
        in_step && /name: Verify formula updates/ { exit found ? 1 : 0 }
        END { if (!in_step) exit 1 }
    ' "$workflow"
    [ "$status" -eq 0 ]
}

@test "install.sh supports dev branch installs" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
eval "$(sed -n '/^source_archive_url()/,/^}/p' "$PROJECT_ROOT/install.sh")"
[[ "$(source_archive_url dev "")" == "https://github.com/zigai/Mole/archive/refs/heads/dev.tar.gz" ]]
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run /bin/bash -c "grep -q 'MOLE_VERSION=\"dev\"' '$PROJECT_ROOT/install.sh'"
    [ "$status" -eq 0 ]
}

@test "release workflow keeps Homebrew distribution on official core only" {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        skip "macOS-only flow"
    fi
    run grep -q 'update-homebrew-core:' "$PROJECT_ROOT/.github/workflows/release.yml"
    [ "$status" -eq 0 ]

    run grep -Eq 'update-personal-tap:|tw93/homebrew-tap|PAT_TOKEN' "$PROJECT_ROOT/.github/workflows/release.yml"
    [ "$status" -ne 0 ]

    [ ! -e "$PROJECT_ROOT/scripts/update_homebrew_tap_formula.sh" ]

    run grep -Eq 'Homebrew tap|personal tap' "$PROJECT_ROOT/.claude/skills/release-notes/SKILL.md"
    [ "$status" -ne 0 ]
    run grep -q 'Homebrew Core PR is workflow-driven' "$PROJECT_ROOT/.claude/skills/release-notes/SKILL.md"
    [ "$status" -eq 0 ]
}

@test "no shell function shares another's body under a different name" {
    # This gate also lives in check.sh, but CI runs scripts/test.sh and never
    # check.sh, so without this case it could not block a pull request. The
    # class it catches is invisible to grep: the copies that matter have
    # already had their variables renamed, which is why review reads them as
    # separate helpers. Run the script with --list to inspect every group.
    run python3 "$PROJECT_ROOT/scripts/audit_function_duplication.py"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}
