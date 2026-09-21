# linux-sm8550-oneplus-salami

一加 11 5G（PHB110，代号 `salami`，SM8550 / Kalama）主线 Linux 内核适配仓库。方法与目录结构沿用 `linux-sm8250-xiaomi-lmi`（lmi）项目：设备适配收进单个设备 dts + config fragment + 构建脚本，rootfs 保持纯净。

## 当前状态

内核侧首轮移植完成，可产出 `Image.gz + dtb`，通过 `fastboot boot` 临时启动验证（bootloader 已解锁）。

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| 串口控制台 | 待验证 | uart7（0x09880000），earlycon 已配 |
| UFS | 待验证 | 沿用 mtp regulator 映射 |
| USB（pmic-glink + eusb2） | 待验证 | orientation GPIO 按 mtp 为 TLMM 11，未实测 |
| 按键 | 待验证 | 音量下 = PM8550 GPIO6；音量上 = PMK8550 resin；电源键 = pwrkey |
| PCIe0/1 | 待验证 | 预留给 WLAN/BT |
| 屏幕 | 未开始 | 三星 AMB670YF07 CS（1440x3216 DSC cmd，reset=TLMM133），需新写 panel driver |
| 触摸 | 未开始 | Synaptics S3908 @ i2c4 0x4b，irq=TLMM25，reset=TLMM24，2.8V 使能 GPIO=TLMM10，1.8V 供 L4B |
| 音频 | 未开始 | WCD938x + TAS5805M/ADD2010 功放 |
| WiFi/BT | 未开始 | 驱动已编入（ath11k+MHI / hci_qca），待加 qcom,wcn7850/wcn6750-pmu 节点与固件 |
| 充电/电量 | 未开始 | 走 pmic-glink battery |

## 构建

依赖：任意支持 LLVM=1 的 host clang。

```
salami/scripts/build-kernel.sh                      # debug, out/salami
KERNEL_PROFILE=release salami/scripts/build-kernel.sh
```

产物：

- `out/salami/arch/arm64/boot/Image.gz`
- `out/salami/arch/arm64/boot/dts/qcom/sm8550-oneplus-salami.dtb`

## 实机启动（临时，不刷分区）

设备进 fastboot 模式后：

```
salami/scripts/fastboot-boot.sh
```

脚本会把 Image.gz 解压为裸 Image，按 stock 参数（header v4、pagesize 4096）组 boot image，DTB 放入 dtb 字段，然后 `fastboot boot`。这只影响本次开机，重启即回原系统。

## 目录

| 路径 | 用途 |
| --- | --- |
| `arch/arm64/boot/dts/qcom/sm8550-oneplus-salami.dts` | 设备树（唯一设备适配点） |
| `salami/configs/salami.config` | 基础 fragment（debug/release 共用） |
| `salami/configs/salami-release.config` | release 叠加层（cmdline + 服务器能力） |
| `salami/scripts/build-kernel.sh` | 构建入口 |
| `salami/scripts/fastboot-boot.sh` | fastboot 临时启动 |

## 硬件事实来源

- 下游 DT：`../android_kernel_modules_and_devicetree_oneplus_sm8550`（OnePlusOSS 官方开源，GPL）
- 下游内核：`../android_kernel_oneplus_sm8550`（5.15 GKI，仅内核仓，DT 已剥离）
- 主线骨架：`sm8550-mtp.dts`（同 SoC，PMIC 家族一致，面板 reset GPIO 同为 TLMM133）

## 已知假设（待实机确认）

1. RPMH regulator 电压映射沿用 mtp 模板，未逐轨核对 salami 下游 DT，RPMH 会按 bootloader 请求兜底；
2. type-c orientation GPIO 取 mtp 的 TLMM 11；
3. `gpio-reserved-ranges = <28 4>, <32 8>, <40 4>` 参照 lmi/SM8550 常见布局；
4. WLAN 实际芯片待 `lspci` 确认（WCN6750→ath11k 或 WCN7850→需 ath12k）；
5. 远程处理器固件路径指向 `qcom/sm8550/oneplus/salami/`，需从设备 `/vendor/firmware` 提取后按此路径放置（不入库）。
