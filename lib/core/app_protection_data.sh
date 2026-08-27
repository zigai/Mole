#!/bin/bash
# Mole - Application Protection Data
# Static protection lists, sourced by lib/core/app_protection.sh.
# Keep this file data-only. Logic belongs in app_protection.sh.

set -euo pipefail

if [[ -n "${MOLE_APP_PROTECTION_DATA_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_APP_PROTECTION_DATA_LOADED=1

# ============================================================================
# Linux safety tables (contract §4). Consumed by app_protection.sh (path
# denies, package denies) and lib/uninstall/leftovers.sh (review tier).
# ============================================================================

# System-critical packages: never surfaced for removal by `mo uninstall`
# and never removed as a dependency cascade target.
readonly SYSTEM_CRITICAL_PACKAGES=(
    "bash"
    "coreutils"
    "filesystem"
    "glibc"
    "systemd"
    "systemd-sysvcompat"
    "util-linux"
    "linux"
    "linux-lts"
    "linux-hardened"
    "linux-firmware"
    "mkinitcpio"
    "grub"
    "pacman"
    "sudo"
    "shadow"
    "openssh"
    "networkmanager"
    "dbus"
    "udev"

    # Cross-distro criticals (Debian / Fedora families), additive to the
    # Arch entries above: kernel and bootloader-adjacent, libc, init,
    # sudo, coreutils, and the package managers themselves.
    "kernel"
    "linux-image-amd64"
    "linux-generic"
    "systemd-sysv"
    "libc6"
    "dnf"
    "apt"
    "dpkg"
    "rpm"
)

# Ids whose leftovers always go through the review-only tier even when the
# exact-id evidence would otherwise be safe.
readonly DATA_PROTECTED_IDS=(
    "firefox"
    "chromium"
    "google-chrome"
    "brave"
    "thunderbird"
    "keepassxc"
    "docker"
    "podman"
    "libvirt"
    "networkmanager"
    "bluetooth"
    "gpg-agent"
    "ssh-agent"
    "pipewire"
    "wireplumber"
)

# Absolute system locations that must never be deleted. The user entries
# protect the directory AND its contents; ~/.config protects the
# directory itself only (children stay sweepable).
readonly LINUX_CRITICAL_SYSTEM_PATHS=(
    "/boot"
    "/boot/efi"
    "/efi"
    "/etc"
    "/usr"
    "/bin"
    "/sbin"
    "/lib"
    "/lib64"
    "/proc"
    "/sys"
    "/dev"
    "/run"
    "/srv"
    "/var/lib/pacman"
    "/var/lib/rpm"
)
readonly LINUX_CRITICAL_USER_PATHS=(
    ".ssh"
    ".gnupg"
    ".password-store"
    ".pki"
    ".kube"
    ".aws"
)
