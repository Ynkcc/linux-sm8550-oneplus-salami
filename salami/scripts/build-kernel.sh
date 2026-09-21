#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
KERNEL_PROFILE=${KERNEL_PROFILE:-debug}
JOBS=${JOBS:-$(nproc)}
DTS="arch/arm64/boot/dts/qcom/sm8550-oneplus-salami.dts"
BASE_CONFIG_FRAGMENT="$REPO_DIR/salami/configs/salami.config"

case "$KERNEL_PROFILE" in
  debug)
    OUT_DIR=${OUT_DIR:-"$REPO_DIR/out/salami"}
    CONFIG_FRAGMENTS=("$BASE_CONFIG_FRAGMENT"
                      "$REPO_DIR/salami/configs/salami-storage.config"
                      "$REPO_DIR/salami/configs/salami-wifi.config")
    ;;
  release)
    OUT_DIR=${OUT_DIR:-"$REPO_DIR/out/salami-release"}
    CONFIG_FRAGMENTS=("$BASE_CONFIG_FRAGMENT"
                      "$REPO_DIR/salami/configs/salami-storage.config"
                      "$REPO_DIR/salami/configs/salami-release.config")
    ;;
  *)
    printf 'unknown KERNEL_PROFILE: %s\n' "$KERNEL_PROFILE" >&2
    exit 2
    ;;
esac

DTB="$OUT_DIR/arch/arm64/boot/dts/qcom/sm8550-oneplus-salami.dtb"

if [ ! -f "$REPO_DIR/Makefile" ] || [ ! -d "$REPO_DIR/scripts/kconfig" ]; then
  cat >&2 <<'EOF'
Populate this repository with the pinned Linux source before building.
Keep the salami files in place, then rerun salami/scripts/build-kernel.sh.
EOF
  exit 2
fi

if [ ! -f "$REPO_DIR/$DTS" ]; then
  printf 'missing DTS: %s\n' "$REPO_DIR/$DTS" >&2
  exit 1
fi

for CONFIG_FRAGMENT in "${CONFIG_FRAGMENTS[@]}"; do
  if [ ! -f "$CONFIG_FRAGMENT" ]; then
    printf 'missing config fragment: %s\n' "$CONFIG_FRAGMENT" >&2
    exit 1
  fi
done

INITRAMFS_FILE="$REPO_DIR/salami/initramfs/out/initramfs-salami.cpio.gz"

# init/VERSION 比已打包 cpio 新（或 cpio 缺失）时重建，避免嵌入陈旧 initramfs
if [ ! -f "$INITRAMFS_FILE" ] || [ "$REPO_DIR/salami/initramfs/init" -nt "$INITRAMFS_FILE" ] \
   || [ "$REPO_DIR/salami/initramfs/VERSION" -nt "$INITRAMFS_FILE" ]; then
  "$REPO_DIR/salami/scripts/build-initramfs.sh"
fi

mkdir -p "$OUT_DIR"

printf 'profile=%s\n' "$KERNEL_PROFILE"
printf 'out=%s\n' "$OUT_DIR"

# ccache 加速（可用时自动启用；数组形式保证 "CC=ccache clang" 作为单个 make 参数）
KBUILD_CC=()
if command -v ccache >/dev/null 2>&1; then
  KBUILD_CC=("CC=ccache clang")
fi

make -C "$REPO_DIR" O="$OUT_DIR" ARCH=arm64 LLVM=1 "${KBUILD_CC[@]}" defconfig

if [ -x "$REPO_DIR/scripts/kconfig/merge_config.sh" ]; then
  "$REPO_DIR/scripts/kconfig/merge_config.sh" -m -O "$OUT_DIR" "$OUT_DIR/.config" "${CONFIG_FRAGMENTS[@]}"
else
  for CONFIG_FRAGMENT in "${CONFIG_FRAGMENTS[@]}"; do
    cat "$CONFIG_FRAGMENT" >>"$OUT_DIR/.config"
  done
fi

printf 'CONFIG_INITRAMFS_SOURCE="%s"\n' "$INITRAMFS_FILE" >>"$OUT_DIR/.config"

make -C "$REPO_DIR" O="$OUT_DIR" ARCH=arm64 LLVM=1 "${KBUILD_CC[@]}" olddefconfig
make -C "$REPO_DIR" O="$OUT_DIR" ARCH=arm64 LLVM=1 "${KBUILD_CC[@]}" -j"$JOBS" Image.gz qcom/sm8550-oneplus-salami.dtb

if [ ! -f "$DTB" ]; then
  printf 'expected DTB was not produced: %s\n' "$DTB" >&2
  exit 1
fi

printf 'kernel=%s\n' "$OUT_DIR/arch/arm64/boot/Image.gz"
printf 'dtb=%s\n' "$DTB"
