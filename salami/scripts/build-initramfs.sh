#!/usr/bin/env bash
# Build the salami bring-up initramfs cpio.gz using the pinned static arm64
# busybox from the lmi initramfs repo (same workspace layout as lmi).
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SRC_DIR="$REPO_DIR/salami/initramfs"
OUT_DIR="$SRC_DIR/out"
CPIO_FILE="$OUT_DIR/initramfs-salami.cpio.gz"

BUSYBOX=${BUSYBOX:-"$REPO_DIR/../lmi/sm8250-xiaomi-lmi-initramfs/tools/arm64-busybox/busybox"}

[ -x "$BUSYBOX" ] || { printf 'missing static busybox: %s\n' "$BUSYBOX" >&2; exit 1; }
[ -f "$SRC_DIR/init" ] || { printf 'missing %s/init\n' "$SRC_DIR" >&2; exit 1; }

mkdir -p "$OUT_DIR"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/bin" "$STAGE/sbin" "$STAGE/proc" "$STAGE/sys" "$STAGE/dev" \
         "$STAGE/dev/pts" "$STAGE/config" "$STAGE/run" "$STAGE/tmp" "$STAGE/newroot"

# ---- 固件 staging ----
# 内建的 serdev/hci_qca 在 rootfs 挂载【之前】就 probe WCN7850 BT，此时只有
# initramfs 可见，若固件不在 initramfs 里则会 -2（ENOENT）导致 BT 起不来。
# WCN7850(Hamilton) BT 固件来自 linux-firmware（qca/hmt*，约 300KB）。
FW_SRC=${FW_SRC:-"$REPO_DIR/../linux-firmware"}
if [ -d "$FW_SRC/qca" ]; then
    mkdir -p "$STAGE/lib/firmware/qca"
    cp -f "$FW_SRC"/qca/hmt* "$STAGE/lib/firmware/qca/" 2>/dev/null || true
fi

cp "$BUSYBOX" "$STAGE/bin/busybox"
chmod 755 "$STAGE/bin/busybox"
# 建立基础工具符号链接，防止 busybox --install 失败后命令解析缺失
# （init 的 M3 诊断段依赖 grep/fold/dmesg 等，务必齐全）
for applet in sh ash mount umount cat echo sleep ls mkdir ln chmod mknod \
              grep sed awk dmesg head tail fold basename dirname sort \
              printf cut ps uname sync setsid cttyhack true false; do
  ln -sf busybox "$STAGE/bin/$applet"
done

install -m 755 "$SRC_DIR/init" "$STAGE/init"
# 注入 init 版本号并递增（构建一次 +1），用于屏幕上确认打包的是新版 init
INIT_VER=$(cat "$SRC_DIR/VERSION" 2>/dev/null || echo 1)
sed -i "s/@VER@/$INIT_VER/g" "$STAGE/init"
echo $((INIT_VER + 1)) >"$SRC_DIR/VERSION"

# fakeroot 优先（免 root、属主/设备节点确定）；无 fakeroot 时回退 sudo
if command -v fakeroot >/dev/null 2>&1; then
    fakeroot -- sh -c '
        set -e
        mknod -m 600 "$1/dev/console" c 5 1 2>/dev/null || true
        mknod -m 666 "$1/dev/null" c 1 3 2>/dev/null || true
        cd "$1"
        find . -print0 | LC_ALL=C sort -z | cpio --null -o -H newc --owner=0:0 2>/dev/null | gzip -9
    ' sh "$STAGE" >"$CPIO_FILE"
else
    ( cd "$STAGE" && sudo mknod -m 600 dev/console c 5 1 && \
      sudo mknod -m 666 dev/null c 1 3 && \
      sudo find . -print0 | LC_ALL=C sort -z | sudo cpio --null -o -H newc --owner=0:0 2>/dev/null | gzip -9 ) >"$CPIO_FILE"
fi
sha256sum "$CPIO_FILE" >"$CPIO_FILE.sha256"

# 生成 manifest，便于确认内核里实际打进了哪些 applet/文件
{
  printf 'initramfs=%s\n' "$CPIO_FILE"
  printf 'busybox=%s\n' "$BUSYBOX"
  ( cd "$STAGE" && find . -type f -o -type l | LC_ALL=C sort )
} >"${CPIO_FILE%.cpio.gz}.manifest"

printf 'initramfs=%s\n' "$CPIO_FILE"
