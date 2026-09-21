#!/usr/bin/env bash
# Build a copydown-bootshim boot image for salami, mirroring the lmi flow:
# ABL loads the shim (fake arm64 Image header), the shim copies the embedded
# uncompressed Image over the load region and jumps into the kernel with x0
# pointing at the embedded runtime DTB. The stock DTB is appended after the
# gzip'd shim payload and placed in the boot image dtb field for ABL
# compatibility.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROFILE=${PROFILE:-debug}
TEMPLATE=${TEMPLATE:-"$REPO_DIR/salami/bootshim/linux-copydown-embedded-dtb.S.in"}
STOCK_DTB=${STOCK_DTB:-/tmp/salami-stock-fdt.bin}

case "$PROFILE" in
  debug)          OUT_DIR="$REPO_DIR/out/salami" ;;
  release)        OUT_DIR="$REPO_DIR/out/salami-release" ;;
  *) printf 'unknown PROFILE: %s\n' "$PROFILE" >&2; exit 2 ;;
esac

KERNEL_GZ="$OUT_DIR/arch/arm64/boot/Image.gz"
DTB="$OUT_DIR/arch/arm64/boot/dts/qcom/sm8550-oneplus-salami.dtb"
BOOT_OUT="$OUT_DIR/boot-copydown-salami.img"

for f in "$KERNEL_GZ" "$DTB" "$TEMPLATE" "$STOCK_DTB"; do
  [ -f "$f" ] || { printf 'missing %s\n' "$f" >&2; exit 1; }
done

CLANG=${CLANG:-clang}
LD_LLD=${LD_LLD:-ld.lld}
OBJCOPY=${OBJCOPY:-llvm-objcopy}
for tool in "$CLANG" "$LD_LLD" "$OBJCOPY"; do
  command -v "$tool" >/dev/null || { printf 'missing tool: %s\n' "$tool" >&2; exit 1; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

gzip -dc "$KERNEL_GZ" >"$WORK/Image"

sed -e "s|@LINUX_IMAGE@|$WORK/Image|" -e "s|@RUNTIME_DTB@|$DTB|" \
    "$TEMPLATE" >"$WORK/shim.S"

"$CLANG" --target=aarch64-none-elf -c "$WORK/shim.S" -o "$WORK/shim.o"
"$LD_LLD" -Ttext=0x0 --image-base=0x0 --entry=_start "$WORK/shim.o" -o "$WORK/shim.elf"
"$OBJCOPY" -O binary "$WORK/shim.elf" "$WORK/shim.bin"
gzip -9 -c "$WORK/shim.bin" >"$WORK/shim.gz"

cat "$WORK/shim.gz" "$STOCK_DTB" >"$WORK/payload"

mkbootimg \
  --header_version 2 \
  --pagesize 4096 \
  --base 0x80000000 \
  --kernel_offset 0x80000 \
  --ramdisk_offset 0x1000000 \
  --dtb_offset 0x1f00000 \
  --kernel "$WORK/payload" \
  --dtb "$STOCK_DTB" \
  --cmdline "noreboot" \
  --os_version 16.0.0 \
  --os_patch_level "$(date +%Y-%m)" \
  --output "$BOOT_OUT"

printf 'boot=%s\n' "$BOOT_OUT"
