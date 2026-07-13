#!/bin/sh
set -eu

# 修改这里即可适配你的数据集路径和 VF 数量，避免升级时改动系统分区。
MODULE_DIR="${MODULE_DIR:-/mnt/Sys/Tool/modules/i915-sriov}"
VF_COUNT="${VF_COUNT:-1}"
PCI_DEVICE="${PCI_DEVICE:-0000:00:02.0}"
VF_CONTROL="/sys/bus/pci/devices/${PCI_DEVICE}/sriov_numvfs"

I915_KO="$(find "${MODULE_DIR}" -name i915.ko -print -quit)"
COMPAT_KO="$(find "${MODULE_DIR}" -name intel_sriov_compat.ko -print -quit)"

if [ -z "${I915_KO}" ]; then
  echo "错误：${MODULE_DIR} 中找不到 i915.ko" >&2
  exit 1
fi
if [ ! -e "${VF_CONTROL}" ]; then
  echo "错误：${PCI_DEVICE} 不存在 sriov_numvfs，请核对核显 PCI 地址" >&2
  exit 1
fi
case "${VF_COUNT}" in
  [1-7]) ;;
  *) echo "错误：VF_COUNT 必须是 1 到 7" >&2; exit 1 ;;
esac

# 先清除已有 VF，确保 TrueNAS 重复执行 Post Init 脚本时行为可预测。
echo 0 > "${VF_CONTROL}"

# 不使用强制卸载；若核显正被应用占用，应先停止占用者，避免系统不稳定。
if lsmod | grep -q '^i915 '; then
  rmmod i915
fi

# 新版 SR-IOV 驱动可能依赖兼容层，因此必须先于 i915 加载。
if [ -n "${COMPAT_KO}" ] && ! lsmod | grep -q '^intel_sriov_compat '; then
  insmod "${COMPAT_KO}"
fi
insmod "${I915_KO}" enable_guc=3 max_vfs=7
echo "${VF_COUNT}" > "${VF_CONTROL}"

echo "已为 ${PCI_DEVICE} 创建 ${VF_COUNT} 个 VF"
lspci -nn | grep -E 'VGA|Display' || true
