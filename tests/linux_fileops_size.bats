#!/usr/bin/env bats

# Linux-correct size accounting (contract §6): get_path_size_kb and
# calculate_total_size must agree with `du -skP` on the physical allocation
# basis, including sparse files, and must keep deduplicating nested paths.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-linux-fileops-size.XXXXXX")"
    export SANDBOX
    HOME_DIR="$SANDBOX/home"
    mkdir -p "$HOME_DIR"
    export HOME_DIR
    export MOLE_TEST_NO_AUTH=1
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

@test "get_path_size_kb matches du -skP for a regular file" {
    f="$SANDBOX/file.bin"
    dd if=/dev/urandom of="$f" bs=1024 count=17 status=none

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
get_path_size_kb "$f"
du -skP "$f" | awk '{print \$1}'
EOF

    [ "$status" -eq 0 ]
    reported="$(sed -n 1p <<< "$output")"
    expected="$(sed -n 2p <<< "$output")"
    [ "$reported" = "$expected" ]
}

@test "sparse files are measured by allocated blocks, not logical size" {
    sparse="$SANDBOX/sparse.bin"
    truncate -s 1048576 "$sparse"
    dd if=/dev/urandom of="$sparse" conv=notrunc seek=512 bs=1024 count=4 status=none

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
get_path_size_kb "$sparse"
du -skP "$sparse" | awk '{print \$1}'
EOF

    [ "$status" -eq 0 ]
    reported="$(sed -n 1p <<< "$output")"
    expected="$(sed -n 2p <<< "$output")"
    [ "$reported" = "$expected" ]
    # The logical file is 1 MiB; allocated must be far below that.
    [ "$reported" -lt 512 ] || return 1
}

@test "directory sizing matches du over a temp tree" {
    tree="$SANDBOX/tree"
    mkdir -p "$tree/a/b"
    dd if=/dev/urandom of="$tree/a/one" bs=1024 count=9 status=none
    dd if=/dev/urandom of="$tree/a/b/two" bs=1024 count=33 status=none

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
get_path_size_kb "$tree"
du -skP "$tree" | awk '{print \$1}'
EOF

    [ "$status" -eq 0 ]
    reported="$(sed -n 1p <<< "$output")"
    expected="$(sed -n 2p <<< "$output")"
    [ "$reported" = "$expected" ]
}

@test "calculate_total_size deduplicates nested paths without double counting" {
    tree="$SANDBOX/tree"
    mkdir -p "$tree/sub"
    dd if=/dev/urandom of="$tree/top" bs=1024 count=5 status=none
    dd if=/dev/urandom of="$tree/sub/inner" bs=1024 count=7 status=none

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
calculate_total_size "$tree
$tree/sub
$tree/top"
du -skP "$tree" | awk '{print \$1}'
EOF

    [ "$status" -eq 0 ]
    # Only one copy of the tree is counted even though three overlapping
    # paths were supplied.
    total="$(sed -n 1p <<< "$output")"
    [[ "$total" =~ ^[0-9]+$ ]] || return 1
    [ "$total" -gt 0 ] || return 1
    du_expected="$(sed -n 2p <<< "$output")"
    [ "$total" = "$du_expected" ]
}
