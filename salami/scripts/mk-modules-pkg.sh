#!/usr/bin/env bash
# 把 salami 需要的**内核模块**打成 pacman 包，并生成/更新本地仓库。
#
# 对标 aston 的 "-oneplus-aston.deb" 升级模型：内核走 ESP(dsp_b) 更新，模块/固件走
# 包管理器更新；设备侧 `pacman -Sy salami && pacman -S salami-modules` 即可，
# 不再手动 scp + depmod。安装后由 .INSTALL 自动执行 depmod。
#
# 用法:
#   salami/scripts/mk-modules-pkg.sh              # 构建模块 -> 打包含仓库
#   SKIP_BUILD=1 salami/scripts/mk-modules-pkg.sh # 用现有产物
#   SERVE=1 salami/scripts/mk-modules-pkg.sh      # 打完后主机 HTTP 服务仓库
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT_DIR=${OUT_DIR:-"$REPO_DIR/out/salami"}
PKG_OUT=${PKG_OUT:-"$REPO_DIR/out/pkg"}
REPO_OUT=${REPO_OUT:-"$REPO_DIR/out/repo-salami"}
JOBS=${JOBS:-$(nproc)}
PKGNAME=${PKGNAME:-salami-modules}
HOST_IP=${HOST_IP:-10.15.0.1}
HTTP_PORT=${HTTP_PORT:-8000}

MODS=(
  drivers/pci/pwrctrl/pci-pwrctrl-pwrseq.ko
  drivers/net/wireless/ath/ath12k/ath12k.ko
  drivers/net/wireless/ath/ath12k/wifi7/ath12k_wifi7.ko
  drivers/gpu/drm/msm/msm.ko
  drivers/gpu/drm/drm_exec.ko
  drivers/gpu/drm/drm_gpuvm.ko
  drivers/gpu/drm/scheduler/gpu-sched.ko
  drivers/gpu/drm/display/drm_display_helper.ko
  drivers/gpu/drm/display/drm_dp_aux_bus.ko
  drivers/soc/qcom/mdt_loader.ko
  drivers/soc/qcom/ocmem.ko
  drivers/soc/qcom/ubwc_config.ko
  drivers/media/cec/core/cec.ko
  drivers/media/mc/mc.ko
)

REL=$(make -s -C "$REPO_DIR" O="$OUT_DIR" ARCH=arm64 kernelrelease)
REL_SAN=${REL//-/.}                     # pacman 的 pkgver 不能含 '-'
PKGVER="$REL_SAN-1"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  printf '[1/3] make modules ...\n'
  make -C "$REPO_DIR" O="$OUT_DIR" ARCH=arm64 LLVM=1 CC="ccache clang" -j"$JOBS" modules >/dev/null
fi

printf '[2/3] pack %s %s\n' "$PKGNAME" "$PKGVER"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
BASE="$STAGE/usr/lib/modules/$REL/kernel"   # 标准布局：/usr/lib/modules/<rel>/kernel/...
mkdir -p "$BASE"
for m in "${MODS[@]}"; do
  src="$OUT_DIR/$m"
  [ -f "$src" ] || { printf 'missing module: %s\n' "$m" >&2; exit 1; }
  install -D -m 644 "$src" "$BASE/$m"
done

# 内核模块元数据：**必须**带 modules.order，否则 Arch 的 60-depmod.hook 会认为
# 该目录不是内核模块目录，直接删掉 modules.dep 等索引（实测踩坑）。
# 注意必须放在 <rel>/ 根下（不是 <rel>/kernel/ 下）。
MDIR="$STAGE/usr/lib/modules/$REL"
for meta in modules.order modules.builtin modules.builtin.modinfo; do
  [ -f "$OUT_DIR/$meta" ] && install -m 644 "$OUT_DIR/$meta" "$MDIR/$meta"
done

# 开机自动加载：PCIe 供电（WCN7850 枚举前提）
mkdir -p "$STAGE/usr/lib/modules-load.d"
printf 'pci_pwrctrl_pwrseq\n' >"$STAGE/usr/lib/modules-load.d/salami.conf"

cat >"$STAGE/.PKGINFO" <<EOF
pkgname = $PKGNAME
pkgbase = $PKGNAME
pkgver = $PKGVER
pkgdesc = salami bring-up kernel modules for $REL
url = https://github.com/salami
builddate = $(date +%s)
packager = salami-bringup
size = $(du -sb "$STAGE" | cut -f1)
arch = aarch64
license = GPL
EOF

cat >"$STAGE/.INSTALL" <<EOF
post_install() {
  # 绝对路径 + 记录日志（pacman 钩子环境与交互 shell 可能不同）
  /usr/bin/depmod -a "$REL" >/var/log/salami-modules-depmod.log 2>&1 || true
  if [ -f "/usr/lib/modules/$REL/modules.dep" ]; then
    echo "salami-modules: depmod ok for $REL"
  else
    echo "salami-modules: WARNING depmod did not produce modules.dep for $REL (see /var/log/salami-modules-depmod.log)" >&2
    sed -n '1,10p' /var/log/salami-modules-depmod.log >&2 || true
  fi
}
post_upgrade() {
  post_install
}
EOF

mkdir -p "$PKG_OUT" "$REPO_OUT"
PKGFILE="$PKG_OUT/$PKGNAME-$PKGVER-aarch64.pkg.tar.zst"
if command -v bsdtar >/dev/null 2>&1; then
  ( cd "$STAGE" && bsdtar --zstd --uid 0 --gid 0 -cf "$PKGFILE" .PKGINFO .INSTALL usr )
else
  ( cd "$STAGE" && tar --zstd --owner=root --group=root -cf "$PKGFILE" .PKGINFO .INSTALL usr )
fi
printf '  pkg=%s (%s)\n' "$PKGFILE" "$(du -h "$PKGFILE" | cut -f1)"

printf '[3/3] repo-add -> %s\n' "$REPO_OUT"
cp -f "$PKGFILE" "$REPO_OUT/"
repo-add -q "$REPO_OUT/salami.db.tar.gz" "$REPO_OUT/$(basename "$PKGFILE")"

cat <<EOF

设备侧安装（一次性配置源，之后每次升级只需后两行）：
  cat >> /etc/pacman.conf <<'CONF'
  [salami]
  SigLevel = Optional TrustAll
  Server = http://$HOST_IP:$HTTP_PORT
  CONF
  pacman -Sy salami
  pacman -S --noconfirm $PKGNAME

主机侧发布仓库：
  cd $REPO_OUT && python3 -m http.server $HTTP_PORT --bind $HOST_IP
EOF

if [ "${SERVE:-0}" = "1" ]; then
  ( cd "$REPO_OUT" && setsid nohup python3 -m http.server "$HTTP_PORT" --bind "$HOST_IP" >/dev/null 2>&1 < /dev/null & )
  sleep 1
  printf 'serving %s on http://%s:%s\n' "$REPO_OUT" "$HOST_IP" "$HTTP_PORT"
fi
