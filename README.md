<div align="center">
  <h1>Mole</h1>
  <p><em>Deep clean and optimize your Linux.</em></p>
  <p>A Linux-focused fork of the Mole maintenance toolkit — CLI only, Arch Linux first.</p>
</div>

<p align="center">
  <a href="https://github.com/zigai/Mole/releases"><img src="https://img.shields.io/github/v/tag/zigai/Mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
</p>

## What This Is

**Mole** is a terminal-first maintenance toolkit
for power users: inspect reclaimable space, remove known-safe leftovers,
uninstall software safely, run bounded maintenance, and check system health —
all reviewable, logged, and dry-run capable.

This fork ports the Mole CLI to **Linux**:

- **Arch Linux first** — pacman cache cleanup, orphan package removal,
  journald vacuuming, AUR helper cache sweeping.
- **Extensible distro modules** — each distro implements a small capability
  contract (`distro_id`, `distro_pkg_manager`, plan functions); unknown
  distros fall back to a safe generic module. See
  [docs/linux-platform.md](docs/linux-platform.md).
- **macOS retained** — the original macOS behavior still exists behind the
  platform gate (`$MOLE_PLATFORM == darwin`), so the upstream codebase stays
  mergeable.
- **CLI only** — no GUI. See the roadmap below.

## Features

Mapped to real commands in this fork:

- `mo clean` — reviews known-safe caches, logs, temporary files, developer
  artifacts, and leftovers from uninstalled software. On Arch: pacman package
  cache pruning (`paccache`), journal vacuum, AUR helper caches, user
  `~/.cache/*` sweep with mole's own state excluded.
- `mo uninstall` — removes installed packages/apps plus related leftovers,
  using pacman, flatpak, and desktop-entry backends. Never deletes
  package-owned files blindly; ownership is queried first.
- `mo optimize` — bounded, previewable maintenance tasks.
- `mo analyze` — terminal disk explorer (Go TUI): navigate, filter,
  multi-select, confirmed moves to Trash via `gio trash`.
- `mo status` — read-only system health dashboard with stable JSON/NDJSON
  automation output.
- `mo purge` — cleans project build artifacts from explicitly configured scan
  directories.
- `mo installer` — finds and removes leftover installer files.
- `mo history`, `mo completion`, `mo update`, `mo remove` — operation log,
  shell completion, self-update, self-removal.

The macOS-only `mo touchid` command is not part of the Linux CLI.

## Install

### Arch Linux (PKGBUILD)

This repository ships a [PKGBUILD](packaging/arch/PKGBUILD). Build and
install with your AUR helper or manually:

```bash
git clone https://github.com/zigai/Mole.git mole && cd mole/packaging/arch
makepkg -si
```

Or point your AUR helper at this PKGBUILD once it is published to the AUR.

### One-liner script

```bash
curl -fsSL https://raw.githubusercontent.com/zigai/Mole/main/install.sh | bash
```

The script detects your OS (Linux is the primary target; macOS uses the
upstream-compatible path), installs to `/usr/local/bin` by default, and asks
for an administrator password only if that directory needs it.

<details>
<summary><strong>Other install options</strong></summary>

Install a specific release tag or track the development branch:

```bash
curl -fsSL https://raw.githubusercontent.com/zigai/Mole/main/install.sh | bash -s -- 1.52.0
curl -fsSL https://raw.githubusercontent.com/zigai/Mole/main/install.sh | bash -s -- main
```

Install into a user-owned prefix so `mo update` never needs sudo:

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/zigai/Mole/main/install.sh | bash -s -- --prefix "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

Add the same `PATH` export to your shell profile (`~/.bashrc`,
`~/.zshrc`) for new terminals.

</details>

Both `mo` and `mole` entry names are installed; they are equivalent.

## Quick Start

```bash
mo                           # Interactive menu
mo clean                     # Deep cleanup of known-safe caches and leftovers
mo uninstall                 # Remove installed software + their leftovers
mo optimize                  # Bounded maintenance tasks
mo analyze                   # Visual disk explorer (or 'mo analyse')
mo status                    # Read-only system health dashboard
mo purge                     # Clean project build artifacts
mo installer                 # Find and remove installer files

mo completion                # Set up shell tab completion
mo history                   # Review cleanup activity
mo update                    # Update Mole
mo remove                    # Remove Mole from system
mo --help                    # Show help
mo --version                 # Show installed version
```

Preview before you delete:

```bash
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run

mo clean --dry-run --debug   # Preview + detailed logs
mo clean --whitelist         # Manage protected caches
mo optimize --whitelist      # Manage protected optimization rules
mo purge --paths             # Configure project scan directories
mo analyze /var              # Analyze any specific directory
```

Selections made with `mo clean --whitelist` persist in
`~/.config/mole/whitelist`.

## Safety

Mole can remove files, so it validates paths, protects shared and system-owned
locations, and asks for confirmation when an action needs it. When Mole cannot
prove an item is safe to change, it skips or refuses it.

- **Dry-run first.** Every destructive command supports `--dry-run`; review
  the exact plan before letting Mole act. Add `--debug` for detail.
- **Whitelist.** Protect caches with `mo clean --whitelist`, maintenance items
  with `mo optimize --whitelist`.
- **Logs.** Cleanup activity is recorded under
  `~/.local/state/mole` (override `XDG_STATE_HOME` to relocate); review with
  `mo history` or disable logging with `MO_NO_OPLOG=1`.
- **Recoverable by default.** User-facing removals go to the Trash
  (`~/.local/share/Trash`) via `gio trash` when available.
- **System paths are protected.** `/boot`, `/etc`, `/usr`, `/var/lib/pacman`
  and friends are hard denies, alongside credential stores like `~/.ssh`,
  `~/.gnupg`, and `~/.config`.

Review [SECURITY.md](SECURITY.md) for reporting guidance and safety
boundaries.

## Adding a Distro

Distro support is a single shell module implementing a small capability
contract — queries echo results, plans echo commands that the caller previews
and confirms. See [docs/linux-platform.md](docs/linux-platform.md) for the
full contract, a worked Fedora skeleton, and the testing guide.

## Roadmap

- More distro modules beyond Arch (the generic fallback already works
  everywhere; per-distro polish lands as modules are contributed).
- Broader uninstall backend coverage (currently pacman, flatpak,
  desktop entries).
- Explicitly out of scope: a **GUI**, and the companion **Mac app**
  (upstream's Mole Mac). This fork is CLI only.

## License & Credits

- Licensed under **GPLv3** ([LICENSE](LICENSE)), same as upstream.
- Upstream: [tw93/Mole](https://github.com/tw93/Mole) — all credit for the
  original macOS tool goes to Tw93 and its contributors.
- Fork deltas: Linux platform layer (`lib/platform/`), distro capability
  contract, Linux delete semantics (`gio trash`, GNU stat), XDG path layout,
  Linux packaging (`packaging/arch/PKGBUILD`), Linux CI, and this fork's
  install/self-update endpoints (`zigai/Mole`). The Go module path is left
  identical to upstream so merges from upstream stay cheap.
