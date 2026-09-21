#!/usr/bin/env bash
# 把内核（Image.gz）组装成 ESP 并写入设备 dsp_b 分区——**无需 fastboot**。
#
# 两种驱动方式：
#   1) 设备在跑系统（Arch/rootfs）：scp + dd（默认）
#   2) 设备停在 initramfs 救援壳：主机起 HTTP，设备 wget+dd（加 REMOTE=initramfs）
#
# 用法:
#   salami/scripts/flash-esp.sh                 # 构建产物 -> scp -> dd dsp_b -> 校验
#   REBOOT=1 salami/scripts/flash-esp.sh        # 写入后重启
#   REMOTE=initramfs salami/scripts/flash-esp.sh  # 救援壳里走 wget（需 telnet 可用）
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT_DIR=${OUT_DIR:-"$REPO_DIR/out/salami"}
DEV=${DEV:-root@10.15.0.2}
HOST_IP=${HOST_IP:-10.15.0.1}
HTTP_PORT=${HTTP_PORT:-8000}
WORK=${WORK:-"$REPO_DIR/out/esp"}
PARTLABEL=${PARTLABEL:-dsp_b}
REMOTE=${REMOTE:-system}
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)
SSHPASS=${SSHPASS:-salami}

[ -f "$OUT_DIR/arch/arm64/boot/Image.gz" ] || { echo "missing $OUT_DIR/arch/arm64/boot/Image.gz (build first)" >&2; exit 1; }

printf '[1/4] assemble ESP\n'
rm -rf "$WORK" "$WORK.img"
mkdir -p "$WORK/efi/boot"
gzip -dc "$OUT_DIR/arch/arm64/boot/Image.gz" >"$WORK/efi/boot/bootaa64.efi"
mkfs.vfat -C "$WORK.img" -F 32 -n EFI 65536 >/dev/null
mcopy -i "$WORK.img" -s "$WORK/efi" ::/efi
MD5=$(md5sum "$WORK.img" | cut -d' ' -f1)
printf '  esp=%s md5=%s\n' "$WORK.img" "$MD5"

if [ "$REMOTE" = "initramfs" ]; then
  printf '[2/4] serve over HTTP (%s:%s)\n' "$HOST_IP" "$HTTP_PORT"
  ( cd "$WORK" && setsid nohup python3 -m http.server "$HTTP_PORT" --bind "$HOST_IP" >/dev/null 2>&1 < /dev/null & )
  sleep 2
  printf '[3/4] device: wget+dd (telnet rescue)\n'
  "$REPO_DIR/../tools/telrun.sh" "wget -q -O /tmp/esp.img http://$HOST_IP:$HTTP_PORT/$(basename "$WORK.img"); md5sum /tmp/esp.img; dd if=/tmp/esp.img of=/dev/sda14 2>/dev/null || true" 60 >/dev/null 2>&1 || true
  # 注意：initramfs 里没有 /dev/disk/by-partlabel（无 udev），需按 PARTNAME 找节点
  "$REPO_DIR/../tools/telrun.sh" "for e in /sys/class/block/sd*/uevent; do grep -q PARTNAME=\$(printf '%s' '$PARTLABEL') \$e && echo /dev/\$(basename \$(dirname \$e)); done" 6
  echo "  -> 手动执行 dd 到上面给出的节点后再 reboot（避免误写分区）" >&2
  exit 0
fi

printf '[2/4] scp ESP to %s\n' "$DEV"
sshpass -p "$SSHPASS" scp "${SSH_OPTS[@]}" "$WORK.img" "$DEV:/tmp/esp.img"

printf '[3/4] dd -> %s and verify\n' "$PARTLABEL"
sshpass -p "$SSHPASS" ssh "${SSH_OPTS[@]}" "$DEV" \
  "dd if=/tmp/esp.img of=/dev/disk/by-partlabel/$PARTLABEL bs=4M 2>/dev/null; sync; md5sum /tmp/esp.img /dev/disk/by-partlabel/$PARTLABEL"

printf '[4/4] done (md5 above should match %s)\n' "$MD5"
if [ "${REBOOT:-0}" = "1" ]; then
  sshpass -p "$SSHPASS" ssh "${SSH_OPTS[@]}" "$DEV" 'sync; systemctl reboot' 2>/dev/null || true
  echo '  reboot requested'
fi
