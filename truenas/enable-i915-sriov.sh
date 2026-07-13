#!/bin/sh
set -eu

# ===== 用户配置区：通常只需要修改这里 =====
MODULE_DIR="${MODULE_DIR:-/mnt/tools}"       # i915.ko 与 intel_sriov_compat.ko 所在目录
PCI_DEVICE="${PCI_DEVICE:-0000:00:02.0}"    # 核显 PF 的 PCI 地址
VF_COUNT="${VF_COUNT:-7}"                   # 实际创建的 VF 数量：1～7
MAX_VFS="${MAX_VFS:-7}"                     # 驱动允许创建的最大 VF 数量
ENABLE_GUC="${ENABLE_GUC:-3}"               # GuC/HuC 模式，SR-IOV 通常为 3
# ===== 用户配置区结束 =====

VF_CONTROL="/sys/bus/pci/devices/${PCI_DEVICE}/sriov_numvfs"
PCI_PATH="/sys/bus/pci/devices/${PCI_DEVICE}"
I915_DRIVER="/sys/bus/pci/drivers/i915"
I915_KO="${MODULE_DIR}/i915.ko"
COMPAT_KO="${MODULE_DIR}/intel_sriov_compat.ko"
ORIGINAL_LOADED=0
CUSTOM_LOADED=0

module_loaded() {
  # 直接读取 /proc/modules，避免管道状态导致已加载模块被误判。
  grep -q "^${1} " /proc/modules
}

unbind_i915() {
  # 先解绑 PF，释放驱动引用；不使用危险的强制卸载。
  if [ -L "${PCI_PATH}/driver" ] && [ "$(basename "$(readlink -f "${PCI_PATH}/driver")")" = "i915" ]; then
    printf '%s\n' "${PCI_DEVICE}" > "${I915_DRIVER}/unbind"
  fi
}

bind_i915() {
  # 模块加载通常会自动探测；未自动绑定时再显式绑定 PF。
  if [ ! -L "${PCI_PATH}/driver" ]; then
    printf '%s\n' "${PCI_DEVICE}" > "${I915_DRIVER}/bind"
  fi
}

restore_on_error() {
  status=$?
  [ "${status}" -eq 0 ] && return
  set +e
  [ -e "${VF_CONTROL}" ] && echo 0 > "${VF_CONTROL}"
  if [ "${CUSTOM_LOADED}" -eq 1 ] && module_loaded i915; then
    unbind_i915
    rmmod i915
  fi
  module_loaded intel_sriov_compat && rmmod intel_sriov_compat
  if [ "${ORIGINAL_LOADED}" -eq 1 ]; then
    modprobe i915
    bind_i915
  fi
  echo "错误：启用 SR-IOV 失败，已尝试恢复系统 i915" >&2
  exit "${status}"
}
trap restore_on_error EXIT

[ -f "${I915_KO}" ] || { echo "错误：找不到 ${I915_KO}" >&2; exit 1; }
[ -f "${COMPAT_KO}" ] || { echo "错误：找不到 ${COMPAT_KO}" >&2; exit 1; }
[ -d "${PCI_PATH}" ] || {
  echo "错误：找不到 PCI 设备 ${PCI_DEVICE}" >&2; exit 1;
}
case "${VF_COUNT}:${MAX_VFS}" in
  [1-7]:[1-7]) ;;
  *) echo "错误：VF_COUNT 和 MAX_VFS 必须是 1 到 7" >&2; exit 1 ;;
esac
[ "${VF_COUNT}" -le "${MAX_VFS}" ] || {
  echo "错误：VF_COUNT 不能大于 MAX_VFS" >&2; exit 1;
}

# 重复执行时先清除已有 VF；首次执行可能尚无该节点。
[ ! -e "${VF_CONTROL}" ] || echo 0 > "${VF_CONTROL}"

# Post Init 时系统 i915 已绑定 PF，必须先解绑才能安全卸载。
if module_loaded i915; then
  ORIGINAL_LOADED=1
  unbind_i915
  rmmod i915
fi
if module_loaded intel_sriov_compat; then
  rmmod intel_sriov_compat
fi

# 自定义兼容层必须先于 i915 加载，再确认 PF 已绑定。
insmod "${COMPAT_KO}"
insmod "${I915_KO}" enable_guc="${ENABLE_GUC}" max_vfs="${MAX_VFS}"
CUSTOM_LOADED=1
bind_i915

# 明确验证参数，避免脚本成功但实际仍是系统自带驱动。
[ "$(cat /sys/module/i915/parameters/enable_guc)" = "${ENABLE_GUC}" ] || {
  echo "错误：enable_guc 未生效" >&2; exit 1;
}
[ "$(cat /sys/module/i915/parameters/max_vfs)" = "${MAX_VFS}" ] || {
  echo "错误：max_vfs 未生效" >&2; exit 1;
}

# sriov_numvfs 可能在新版 i915 加载后才出现，因此此时再检查。
[ -e "${VF_CONTROL}" ] || {
  echo "错误：加载驱动后未生成 ${VF_CONTROL}" >&2; exit 1;
}
echo "${VF_COUNT}" > "${VF_CONTROL}"

echo "已为 ${PCI_DEVICE} 创建 ${VF_COUNT} 个 VF（max_vfs=${MAX_VFS}, enable_guc=${ENABLE_GUC}）"
lspci -nn | grep -E '00:02|VGA|Display' || true
