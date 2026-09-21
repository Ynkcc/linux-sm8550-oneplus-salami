#!/usr/bin/env bash
# Temporarily boot the salami mainline kernel on a connected device:
#   Image.gz is decompressed to raw Image (fastboot boot needs an uncompressed
#   kernel; ABL treats it as the payload of a boot image it assembles itself).
#   ABL on kalama accepts an uncompressed Image + dtb via `fastboot boot`.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROFILE=${PROFILE:-debug}

case "$PROFILE" in
  debug)          OUT_DIR="$REPO_DIR/out/salami" ;;
  release)        OUT_DIR="$REPO_DIR/out/salami-release" ;;
  *) printf 'unknown PROFILE: %s\n' "$PROFILE" >&2; exit 2 ;;
esac

KERNEL_GZ="$OUT_DIR/arch/arm64/boot/Image.gz"
DTB="$OUT_DIR/arch/arm64/boot/dts/qcom/sm8550-oneplus-salami.dtb"

[ -f "$KERNEL_GZ" ] || { printf 'missing %s\n' "$KERNEL_GZ" >&2; exit 1; }
[ -f "$DTB" ] || { printf 'missing %s\n' "$DTB" >&2; exit 1; }

TMPDIR_BOOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BOOT"' EXIT

gzip -dc "$KERNEL_GZ" >"$TMPDIR_BOOT/Image"

# build a header-v4 boot image so ABL knows how to stage kernel + dtb
mkbootimg \
  --header_version 4 \
  --pagesize 4096 \
  --kernel "$TMPDIR_BOOT/Image" \
  --dtb "$DTB" \
  --cmdline "noreboot" \
  --os_version 16.0.0 \
  --os_patch_level "$(date +%Y-%m)" \
  --output "$TMPDIR_BOOT/boot.img"

fastboot boot "$TMPDIR_BOOT/boot.img"
