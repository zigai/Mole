# Linux Platform Guide

Developer guide for the platform layer in this fork. Mole started as a macOS
tool; this fork makes Linux the primary target while keeping the macOS
behavior intact behind platform gates. Read this before adding a distro
module or touching `lib/platform/`.

## Architecture Overview

```
mole (entrypoint)
  └─ lib/core/common.sh          sources the platform layer in fixed order:
       ├─ lib/core/base.sh
       ├─ lib/platform/platform.sh   (guard var MOLE_PLATFORM_LOADED)
       └─ lib/core/log.sh            (paths become readonly after this)
             │
             ├─ MOLE_PLATFORM=darwin|linux        from uname -s
             ├─ mole_detect_distro()              linux only
             │    └─ sources lib/platform/linux/<ID>.sh,
             │       then ID_LIKE words in order,
             │       else lib/platform/linux/generic.sh
             │
       bin/clean.sh / lib/clean/**      consume plans via preview+confirm+sudo
       lib/uninstall/backends/**        pacman / deb / rpm / flatpak / desktop backends
```

Layers:

1. **Platform layer** (`lib/platform/`). Detects `$MOLE_PLATFORM`, exposes
   path resolvers shared by every module:
   - `mole_state_dir()` — linux: `${XDG_STATE_HOME:-$HOME/.local/state}/mole`
     (operation logs live here); darwin: `$HOME/Library/Logs/mole`
   - `mole_cache_dir()` — `${XDG_CACHE_HOME:-$HOME/.cache}/mole` (both)
   - `mole_config_dir()` — `${XDG_CONFIG_HOME:-$HOME/.config}/mole` (both)
   - `mole_trash_cmd()` — darwin: empty (legacy osascript flow); linux:
     echoes `gio` when available, else empty (caller falls back to permanent
     delete with a single notice line per run)
   - `mole_detect_distro()` reads `${MOLE_OS_RELEASE_FILE:-/etc/os-release}`
     (the env override exists for tests), parses `ID` and `ID_LIKE`, sets
     `MOLE_DISTRO_ID`, then sources the first matching module and calls
     `distro_init` if it is defined.
2. **Distro modules** (`lib/platform/linux/<distro>.sh`). Pure capability
   providers. They NEVER prompt and NEVER execute side effects; they only
   answer queries and echo command plans. The calling code owns previewing,
   confirmation, dry-run, sudo, and execution.
3. **Backends** (`lib/uninstall/backends/{pacman,deb,rpm,flatpak,desktop}.sh`).
   Uninstall enumeration is owned by these backends, not by the distro
   module. Exactly ONE native backend is enabled, chosen by distro
   affinity from `MOLE_DISTRO_ID` (arch*->pacman, debian/ubuntu/mint/pop*->deb,
   fedora/rhel/centos/rocky/alma*->rpm); when the ID is unknown the
   selector falls back to capability probes (first of pacman/rpm/deb whose
   binaries exist). deb rows come from `apt-mark showmanual` sizes via
   `dpkg-query`; rpm rows from `dnf repoquery --userinstalled` sizes via
   `rpm -qa`. Both gate rows on a representative binary under /usr/bin.
   flatpak enabled when the binary exists; desktop-entry backend always
   available for entries not owned by a listed package. Row format is
   internal to these modules (documented in each module header) and must
   feed the existing paginated selector UX.

## Distro Capability Contract

Every `lib/platform/linux/<distro>.sh` implements exactly this contract.
`generic.sh` implements the inert/safe subset (unknown package manager →
package/journal plans echo empty; flatpak plan still honored; AUR dirs
empty).

Two kinds of functions:

- **Queries** (free to run): echo results, return 0 even when empty.
- **Plans**: ECHO the commands to stdout, one per line; the caller previews,
  confirms, and executes through the existing sudo + dry-run plumbing.

Functions:

- `distro_id()` -> echo id (e.g. `"arch"`)
- `distro_pkg_manager()` -> echo `pacman` | empty
- `distro_init()` optional: detect optional tools once (`paccache`,
  `journalctl`, `flatpak`, `systemctl`, `yay`/`paru`) into `DISTRO_*` vars.
- `distro_pkg_cache_plan(keep)` -> e.g. arch: `paccache -rk<keep>` when
  paccache present, plus `paccache -ruk0`; else
  `pacman -Sc --noconfirm`. All require-root commands are prefixed exactly
  `sudo `.
- `distro_pkg_cache_summary()` -> human one-liner (size of pkg cache) or
  empty.
- `distro_orphans_list()` -> package names, one per line (arch:
  `pacman -Qtdq`).
- `distro_orphans_remove_plan()` -> e.g.
  `sudo pacman -Rns --noconfirm <orphans...>` (single line), or empty when
  none.
- `distro_journal_vacuum_plan()` -> e.g.
  `sudo journalctl --vacuum-size=100M --vacuum-time=2weeks` when systemd is
  present, else empty.
- `distro_flatpak_unused_plan()` ->
  `flatpak uninstall --unused --noninteractive` when flatpak is present,
  else empty.
- `distro_aur_cache_dirs()` -> extra user-cache dirs to sweep (arch:
  `~/.cache/yay ~/.cache/paru` when a helper is detected), else empty.

Uninstall enumeration is NOT part of this contract (see backends above).
Never manually delete package-owned files; query the package manager for
ownership first (e.g. `pacman -Qoq`).

## Path Mapping (Linux)

| Concern           | macOS (upstream)                  | Linux (this fork)                                        |
| ----------------- | --------------------------------- | -------------------------------------------------------- |
| Operation logs    | `~/Library/Logs/mole`             | `${XDG_STATE_HOME:-~/.local/state}/mole`                 |
| Cache/config      | `~/Library/Caches`, `~/.config`…  | `${XDG_CACHE_HOME:-~/.cache}/mole`, `${XDG_CONFIG_HOME:-~/.config}/mole` |
| Trash             | Finder Trash via osascript        | `~/.local/share/Trash/files` + `info` via `gio trash`    |
| User cache sweep  | `~/Library/Caches/*`              | `~/.cache/*` (always excludes mole's own state dir)      |
| Package cache     | n/a                               | distro module plan (root, via `sudo ` prefix)            |
| Journald vacuum   | n/a                               | `sudo journalctl --vacuum-size=100M --vacuum-time=2weeks`|
| `/var/tmp`        | n/a                               | stale entries, root plan                                 |
| Coredumps/crashes | n/a                               | `/var/lib/systemd/coredump`, `/var/crash` — REPORT-ONLY  |

Dropped on Linux (deleted cleanly on the linux path, kept for darwin behind
gates): Time Machine, APFS snapshots, iOS firmware/backups, Apple Silicon
caches, Finder metadata, iCloud/Mail dirs, Xcode/iOS tooling.

## Shipped Modules & Adding a New Distro

Three capability modules ship in-tree:

| Module | Matches via | Package manager | Uninstall backend |
|---|---|---|---|
| `arch.sh` | `ID=arch`, `ID_LIKE` containing `arch` | pacman | pacman |
| `debian.sh` | `ID=debian`, ubuntu/mint/pop!_os via `ID_LIKE` | apt | deb |
| `fedora.sh` | `ID=fedora`, rhel/centos/rocky/alma via `ID_LIKE` | dnf | rpm |

Unknown distros load `generic.sh`: flatpak cleanup still works, package
and journal plans stay inert.

To add another distro, create `lib/platform/linux/<id>.sh` following the
real modules (read `arch.sh`, `debian.sh`, or `fedora.sh` first - they are
the contract made concrete). Skeleton shape:

```bash
#!/bin/bash
# <Distro> distro module. Queries echo results; plans echo one command per
# line ("sudo "-prefixed when root is required). Never prompt, never mutate.

distro_id() { printf 'opensuse\n'; }
distro_pkg_manager() { printf 'zypper\n'; }

distro_init() {
    # Detect optional tools ONCE into DISTRO_* vars (called by platform.sh).
    DISTRO_JOURNALCTL=""; DISTRO_SYSTEMCTL=""; DISTRO_FLATPAK=""
    have_cmd journalctl && DISTRO_JOURNALCTL="journalctl"
    have_cmd systemctl && DISTRO_SYSTEMCTL="systemctl"
    have_cmd flatpak    && DISTRO_FLATPAK="flatpak"
}

distro_pkg_cache_plan() {
    have_cmd zypper || return 0
    printf 'sudo zypper clean -a\n'
}

distro_pkg_cache_summary() {
    local dir="${MOLE_PKG_CACHE_DIR:-/var/cache/zypp/packages}"
    [[ -d "$dir" ]] || return 0
    # Every du MUST be bounded (tests audit this).
    local size
    size="$(run_with_timeout "${MOLE_TIMEOUT_DISK_VERIFY_SEC:-15}" \
        du -sh "$dir" 2> /dev/null | cut -f1)" || return 0
    [[ -n "$size" ]] && printf 'Zypper package cache: %s\n' "$size"
    return 0
}

distro_orphans_list()          { return 0; }
distro_orphans_remove_plan()   { return 0; }
distro_journal_vacuum_plan() {
    [[ -n "$DISTRO_JOURNALCTL" && -n "$DISTRO_SYSTEMCTL" ]] && \
        printf 'sudo journalctl --vacuum-size=100M --vacuum-time=2weeks\n'
    return 0
}
distro_flatpak_unused_plan() {
    [[ -n "$DISTRO_FLATPAK" ]] && printf 'flatpak uninstall --unused --noninteractive\n'
    return 0
}
distro_aur_cache_dirs() { return 0; }
```

Notes:

- `have_cmd()` comes from `lib/platform/linux/common.sh` (sourced before the
  distro module). Use the XDG root getters there instead of hardcoding paths.
- The resolver picks the module up from `/etc/os-release`; derivatives
  resolve through `ID_LIKE` automatically.
- If your distro needs native-package uninstall rows, add a backend under
  `lib/uninstall/backends/` mirroring `deb.sh`/`rpm.sh` and register its
  affinity in `_enumerate_linux_native_backend` (enumerate.sh).

## Testing Guide

Tests use bats-core. Conventions:

- New test files are named `tests/linux_<area>_*.bats` where area is one of
  `platform`, `fileops`, `clean`, `apps`, `misc`.
- Per-test isolation: create a fresh `$HOME` with `mktemp -d` in `setup`,
  remove it in `teardown`. Never write to the real home.
- Fake binaries are hand-written stub scripts placed in a PATH stub dir your
  test creates under `tests/fixtures/linux/<area>/`. Prepend that dir to
  `PATH`; stubs must be deterministic and side-effect free.
- Override `/etc/os-release` discovery in tests with
  `MOLE_OS_RELEASE_FILE=/path/to/fake-os-release`.
- Never edit `scripts/test.sh`; run bats directly on your files.

Example invocation:

```bash
MOLE_TEST_NO_AUTH=1 bats tests/linux_platform_distro.bats
```

Minimal skeleton:

```bash
#!/usr/bin/env bats

setup() {
    TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mole-test-XXXXXX")"
    export HOME="$TEST_HOME"
    STUB_DIR="$TEST_HOME/stubs"
    mkdir -p "$STUB_DIR"
    printf '#!/bin/bash\necho flatpak-stub "$@"\n' > "$STUB_DIR/flatpak"
    chmod +x "$STUB_DIR/flatpak"
    export PATH="$STUB_DIR:$PATH"
}

teardown() {
    rm -rf "$TEST_HOME"
}

@test "flatpak unused plan honors presence of flatpak" {
    run bash -c '
        source lib/platform/linux/generic.sh
        distro_flatpak_unused_plan
    '
    [ "$status" -eq 0 ]
    [ "$output" = "flatpak uninstall --unused --noninteractive" ]
}
```

Stub conventions:

- One script per faked binary, named exactly like the binary.
- Echo stable output; exit 0 unless the test asserts failure handling.
- Keep stubs inside the fixture dir so they never leak into other tests;
  the per-test `PATH` prepend scopes them anyway.

## Safety Invariants to Preserve

- Modules never prompt and never execute side effects — plans only.
- Require-root plan lines start with exactly `sudo `.
- Dry-run (`MOLE_DRY_RUN=1`) and real mode share the same candidate plan.
- Linux critical denies (`/boot`, `/etc`, `/usr`, `/var/lib/pacman`, …) and
  user denies (`~/.ssh`, `~/.gnupg`, `~/.config`, …) extend the existing
  protection arrays platform-conditionally; check
  `should_protect_path()` before adding cleanup behavior.
- Self-update/self-remove never contact the original upstream's endpoints;
  everything points at this fork.
