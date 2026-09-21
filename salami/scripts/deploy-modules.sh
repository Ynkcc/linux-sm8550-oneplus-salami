#!/usr/bin/env bash
# 构建并把 salami 需要的内核模块部署到设备（rootfs 的 /usr/lib/modules/<release>）
#
# 背景：设备用 ATH12K=m / PCI_PWRCTRL_PWRSEQ=m / DRM_MSM=m 等模块化驱动；
# 内核 release 字符串随 git 提交变化（-dirty 也会变），因此**每次重编内核后
# 必须重新部署模块并 depmod**，否则 modprobe 报 "Exec format error"（vermagic 失配）。
#
# 用法：
#   salami/scripts/deploy-modules.sh              # 构建+部署+depmod
#   DEV=root@10.15.0.2 salami/scripts/deploy-modules.sh
#   SKIP_BUILD=1 salami/scripts/deploy-modules.sh # 只重新打包已有产物
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT_DIR=${OUT_DIR:-"$REPO_DIR/out/salami"}
DEV=${DEV:-root@10.15.0.2}
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)
JOBS=${JOBS:-$(nproc)}
TARBALL=${TARBALL:-/tmp/salami-mods.tgz}

# 需要部署的模块（相对 $OUT_DIR 的路径）
MODS=(
  drivers/pci/pwrctrl/pci-pwrctrl-pwrseq.ko      # PCIe 上电（WCN7850 枚举前提）
  drivers/net/wireless/ath/ath12k/ath12k.ko
  drivers/net/wireless/ath/ath12k/wifi7/ath12k_wifi7.ko
  drivers/gpu/drm/msm/msm.ko                     # GPU
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
printf 'release=%s\n' "$REL"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  # 顶层 modules：release 变化后只有这一步会重新 modpost/link 出正确 vermagic 的 .ko
  printf '[1/3] make modules ...\n'
  make -C "$REPO_DIR" O="$OUT_DIR" ARCH=arm64 LLVM=1 CC="ccache clang" -j"$JOBS" modules >/dev/null
fi

RAW_REL=${REL%%-dirty}   # 去掉 -dirty，用作设备侧 live 内核目录探测

printf '[2/3] pack %s\n' "$TARBALL"
tar czf "$TARBALL" -C "$OUT_DIR" "${MODS[@]}"

printf '[3/3] deploy to %s ...\n' "$DEV"
# shellcheck disable=SC2029
sshpass -p salami scp "${SSH_OPTS[@]}" "$TARBALL" "$DEV:/tmp/"

# 说明：设备侧 /usr/lib/modules/<rel> 可能不存在（新 release），需建；
# 解包到 <rel>/kernel 以符合标准布局。
sshpass -p salami ssh "${SSH_OPTS[@]}" "$DEV" bash -s <<EOF
set -e
REL="$REL"
M="/usr/lib/modules/\$REL/kernel"
mkdir -p "\$M"
tar xzf /tmp/$(basename "$TARBALL") -C "\$M"
depmod -a "\$REL"
echo "deployed \$(ls -d /usr/lib/modules/\$REL)"
# 校验一个关键模块的 vermagic 与当前内核一致
modinfo -F vermagic "\$M/drivers/pci/pwrctrl/pci-pwrctrl-pwrseq.ko"
uname -r
EOF
printf 'done.\n'
