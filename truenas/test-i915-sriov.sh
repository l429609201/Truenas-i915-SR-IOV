#!/usr/bin/env bash
set -Eeuo pipefail

# ===== 用户配置区：通常只需要修改这里 =====
MODULE_DIR="${MODULE_DIR:-/mnt/tools}"       # 模块所在目录
PCI_DEVICE="${PCI_DEVICE:-0000:00:02.0}"    # 核显 PF 的 PCI 地址
VF_COUNT="${VF_COUNT:-1}"                   # 本次测试创建的 VF 数量：1～7
MAX_VFS="${MAX_VFS:-7}"                     # 驱动允许创建的最大 VF 数量
ENABLE_GUC="${ENABLE_GUC:-3}"               # GuC/HuC 模式，SR-IOV 通常为 3
KEEP_LOADED="${KEEP_LOADED:-0}"             # 0=测试后恢复原驱动；1=成功后保留
# ===== 用户配置区结束 =====

TARGET_KERNEL="${TARGET_KERNEL:-$(uname -r)}"
LOG_FILE="${LOG_FILE:-/tmp/i915-sriov-test-$(date +%Y%m%d-%H%M%S).log}"
VF_CONTROL="/sys/bus/pci/devices/${PCI_DEVICE}/sriov_numvfs"
I915_KO="${MODULE_DIR}/i915.ko"
COMPAT_KO="${MODULE_DIR}/intel_sriov_compat.ko"
ORIGINAL_LOADED=0
CUSTOM_LOADED=0
TEST_OK=0

exec > >(tee -a "${LOG_FILE}") 2>&1

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

module_loaded() {
  # 直接读取 /proc/modules，避免 pipefail 与 grep -q 的 SIGPIPE 造成误判。
  grep -q "^${1} " /proc/modules
}

restore_stock() {
  set +e
  log "开始恢复系统自带 i915"
  [[ -e "${VF_CONTROL}" ]] && echo 0 > "${VF_CONTROL}"
  module_loaded i915 && rmmod i915
  module_loaded intel_sriov_compat && rmmod intel_sriov_compat
  if [[ "${ORIGINAL_LOADED}" -eq 1 ]]; then
    modprobe i915
    if module_loaded i915; then
      log "系统自带 i915 已恢复：$(modinfo -n i915 2>/dev/null)"
    else
      log "严重警告：自动恢复 i915 失败，请使用本地控制台处理"
    fi
  else
    log "测试前 i915 未加载，已恢复为未加载状态"
  fi
  set -e
}

on_exit() {
  status=$?
  if [[ "${status}" -ne 0 || "${TEST_OK}" -ne 1 ]]; then
    log "测试失败（退出码 ${status}）"
    if [[ "${ORIGINAL_LOADED}" -eq 1 || "${CUSTOM_LOADED}" -eq 1 ]] || module_loaded intel_sriov_compat; then
      log "驱动状态已改变，执行自动回退"
      restore_stock
    else
      log "尚未改变驱动状态，无需回退"
    fi
  elif [[ "${KEEP_LOADED}" != 1 ]]; then
    log "测试成功，KEEP_LOADED!=1，执行自动回退"
    restore_stock
  else
    log "测试成功，按要求保留 SR-IOV 驱动和 VF"
  fi
  log "完整日志：${LOG_FILE}"
}
trap on_exit EXIT

[[ "$(id -u)" -eq 0 ]] || { log "错误：请以 root 运行"; exit 1; }
[[ -f "${I915_KO}" ]] || { log "错误：找不到 ${I915_KO}"; exit 1; }
[[ -f "${COMPAT_KO}" ]] || { log "错误：找不到 ${COMPAT_KO}"; exit 1; }
[[ -d "/sys/bus/pci/devices/${PCI_DEVICE}" ]] || {
  log "错误：找不到 PCI 设备 ${PCI_DEVICE}"; exit 1;
}
case "${VF_COUNT}:${MAX_VFS}" in
  [1-7]:[1-7]) ;;
  *) log "错误：VF_COUNT 和 MAX_VFS 必须为 1 到 7"; exit 1 ;;
esac
[[ "${VF_COUNT}" -le "${MAX_VFS}" ]] || {
  log "错误：VF_COUNT 不能大于 MAX_VFS"; exit 1;
}

log "静态检查模块版本"
for module in "${COMPAT_KO}" "${I915_KO}"; do
  vermagic="$(modinfo -F vermagic "${module}")"
  log "$(basename "${module}") vermagic=${vermagic}"
  [[ "${vermagic}" == "${TARGET_KERNEL}"* ]] || {
    log "错误：模块与运行内核 ${TARGET_KERNEL} 不匹配"; exit 1;
  }
done

log "检查 /dev/dri 占用情况"
if [[ -d /dev/dri ]]; then
  fuser_pids="$(fuser /dev/dri/* 2>/dev/null || true)"
  if [[ -n "${fuser_pids//[[:space:]]/}" ]]; then
    fuser -v /dev/dri/* 2>&1 || true
    log "错误：核显仍被占用，请先停止 Apps、容器、VM 或转码服务"
    exit 1
  fi
fi

log "卸载当前 i915（不使用强制卸载）"
if module_loaded i915; then
  ORIGINAL_LOADED=1
  rmmod i915
fi
if module_loaded intel_sriov_compat; then
  rmmod intel_sriov_compat
fi

log "加载 SR-IOV 兼容层和 i915"
insmod "${COMPAT_KO}"
insmod "${I915_KO}" enable_guc="${ENABLE_GUC}" max_vfs="${MAX_VFS}"
CUSTOM_LOADED=1

log "验证模块和参数"
lsmod | grep -E '^(i915|intel_sriov_compat)'
[[ "$(cat /sys/module/i915/parameters/enable_guc)" == "${ENABLE_GUC}" ]] || {
  log "错误：enable_guc 不是 ${ENABLE_GUC}"; exit 1;
}
[[ "$(cat /sys/module/i915/parameters/max_vfs)" == "${MAX_VFS}" ]] || {
  log "错误：max_vfs 不是 ${MAX_VFS}"; exit 1;
}

[[ -e "${VF_CONTROL}" ]] || {
  log "错误：加载驱动后仍未生成 ${VF_CONTROL}"; exit 1;
}
total_vfs="$(cat "/sys/bus/pci/devices/${PCI_DEVICE}/sriov_totalvfs")"
log "sriov_totalvfs=${total_vfs}"
[[ "${total_vfs}" -ge "${VF_COUNT}" ]] || {
  log "错误：硬件报告的 VF 总数不足"; exit 1;
}

log "创建 ${VF_COUNT} 个 VF"
echo 0 > "${VF_CONTROL}"
echo "${VF_COUNT}" > "${VF_CONTROL}"
[[ "$(cat "${VF_CONTROL}")" == "${VF_COUNT}" ]] || {
  log "错误：sriov_numvfs 写入后不匹配"; exit 1;
}
for ((index=0; index<VF_COUNT; index++)); do
  [[ -L "/sys/bus/pci/devices/${PCI_DEVICE}/virtfn${index}" ]] || {
    log "错误：缺少 virtfn${index}"; exit 1;
  }
done

log "VF 创建成功"
lspci -nn | grep -E '00:02|VGA|Display' || true
dmesg | tail -n 120
TEST_OK=1
