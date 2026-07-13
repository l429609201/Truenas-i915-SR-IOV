#!/usr/bin/env bash
set -Eeuo pipefail

# 所有大型源码只存在于 Actions 工作目录，避免污染 TrueNAS 主机和本地项目。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${RUNNER_TEMP:-${ROOT_DIR}/.build}"
KERNEL_DIR="${WORK_DIR}/truenas-linux"
DRIVER_DIR="${WORK_DIR}/i915-sriov-dkms"
OUT_DIR="${ROOT_DIR}/out"

: "${TRUENAS_REF:=TS-25.10.4}"
: "${TARGET_KERNEL:=6.12.91-production+truenas}"
: "${I915_REF:=2026.03.05.1}"

STAGE="${1:-all}"
LOG_DIR="${ROOT_DIR}/logs"

# 每个 Actions Step 都是新 Shell，因此版本变量必须在每次调用时一致导出。
export EXTRAVERSION=-production
export LOCALVERSION=+truenas
export CC="${KERNEL_CC:-gcc}"

init_workspace() {
  rm -rf "${KERNEL_DIR}" "${DRIVER_DIR}" "${OUT_DIR}"
  mkdir -p "${OUT_DIR}" "${LOG_DIR}"
}

fetch_kernel() {
  echo "获取 TrueNAS 内核 ${TRUENAS_REF}"
  git clone --depth 1 --branch "${TRUENAS_REF}" \
    https://github.com/truenas/linux.git "${KERNEL_DIR}"
  git -C "${KERNEL_DIR}" rev-parse HEAD > "${WORK_DIR}/truenas-commit.txt"
  # TrueNAS 官方构建会删除 Git 元数据，避免 kernelrelease 追加 -g<提交号>。
  rm -rf "${KERNEL_DIR}/.git"
}

configure_kernel() {
  echo "生成并验证 TrueNAS production 配置"
  cd "${KERNEL_DIR}"
  make defconfig
  ./scripts/kconfig/merge_config.sh .config \
    scripts/package/truenas/debian_amd64.config \
    scripts/package/truenas/truenas.config \
    scripts/package/truenas/tn-production.config
  # 后缀只由 make 级 LOCALVERSION 提供，Kconfig 中清空以避免重复。
  ./scripts/config --set-str LOCALVERSION ""
  ./scripts/config --disable LOCALVERSION_AUTO
  # 官方打包流程会生成这些证书；纯源码 Actions 构建不存在对应文件，必须清空路径。
  ./scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
  ./scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
  ./scripts/config --set-str MODULE_SIG_KEY "certs/signing_key.pem"
  make olddefconfig
  make syncconfig

  echo "最终关键配置："
  grep -E '^CONFIG_LOCALVERSION=|^CONFIG_LOCALVERSION_AUTO=|^CONFIG_SYSTEM_TRUSTED_KEYS=|^CONFIG_SYSTEM_REVOCATION_KEYS=|^CONFIG_MODULE_SIG_KEY=' \
    .config include/config/auto.conf || true
  ACTUAL_KERNEL="$(make -s kernelrelease)"
  echo "kernelrelease=${ACTUAL_KERNEL}"
  if [[ "${ACTUAL_KERNEL}" != "${TARGET_KERNEL}" ]]; then
    echo "错误：源码版本为 ${ACTUAL_KERNEL}，目标为 ${TARGET_KERNEL}" >&2
    exit 1
  fi
}

build_kernel() {
  echo "构建 vmlinux 和完整 Module.symvers"
  cd "${KERNEL_DIR}"
  # runner 工具链可能产生非功能性警告，外部复现时不启用 WERROR。
  ./scripts/config --disable WERROR
  make olddefconfig
  make -j"$(nproc)" vmlinux modules
  [[ -s Module.symvers ]] || {
    echo "错误：未生成 Module.symvers，无法保证模块 ABI 匹配" >&2
    exit 1
  }
}

fetch_driver() {
  echo "获取 i915 SR-IOV ${I915_REF}"
  git clone --depth 1 --branch "${I915_REF}" \
    https://github.com/strongtz/i915-sriov-dkms.git "${DRIVER_DIR}"
}

build_driver() {
  echo "编译 i915 SR-IOV 外置模块"
  make -C "${KERNEL_DIR}" M="${DRIVER_DIR}" modules
}

package_modules() {
  echo "打包并校验模块"
  rm -rf "${OUT_DIR}"
  mkdir -p "${OUT_DIR}"
  while IFS= read -r -d '' module; do
    cp "${module}" "${OUT_DIR}/$(basename "${module}")"
  done < <(find "${DRIVER_DIR}" -type f -name '*.ko' -print0)
  find "${OUT_DIR}" -type f -name '*.ko' -print0 | \
    xargs -0 -r -n1 strip --strip-debug

  MODULE_COUNT="$(find "${OUT_DIR}" -maxdepth 1 -name '*.ko' | wc -l)"
  [[ "${MODULE_COUNT}" -gt 0 ]] || {
    echo "错误：没有找到 .ko 产物" >&2
    exit 1
  }

  {
    echo "TrueNAS ref: ${TRUENAS_REF}"
    echo "Target kernel: ${TARGET_KERNEL}"
    echo "i915 SR-IOV ref: ${I915_REF}"
    echo "TrueNAS commit: $(cat "${WORK_DIR}/truenas-commit.txt")"
    echo "i915 commit: $(git -C "${DRIVER_DIR}" rev-parse HEAD)"
    echo
    find "${OUT_DIR}" -name '*.ko' -print0 | while IFS= read -r -d '' module; do
      echo "[$(basename "${module}")]"
      modinfo "${module}" | grep -E '^(filename|version|depends|vermagic):' || true
      echo
    done
  } > "${OUT_DIR}/BUILD-INFO.txt"
  find "${OUT_DIR}" -name '*.ko' -exec sha256sum '{}' \; > "${OUT_DIR}/SHA256SUMS"

  FAILED=0
  while IFS= read -r -d '' module; do
    VERMAGIC="$(modinfo -F vermagic "${module}")"
    if [[ "${VERMAGIC}" != "${TARGET_KERNEL}"* ]]; then
      echo "错误：$(basename "${module}") vermagic=${VERMAGIC}" >&2
      FAILED=1
    fi
  done < <(find "${OUT_DIR}" -name '*.ko' -print0)
  [[ "${FAILED}" -eq 0 ]] || exit 1
  cat "${OUT_DIR}/BUILD-INFO.txt"
}

run_stage() {
  case "$1" in
    init) init_workspace ;;
    fetch-kernel) fetch_kernel ;;
    configure-kernel) configure_kernel ;;
    build-kernel) build_kernel ;;
    fetch-driver) fetch_driver ;;
    build-driver) build_driver ;;
    package) package_modules ;;
    *) echo "错误：未知阶段 $1" >&2; exit 2 ;;
  esac
}

if [[ "${STAGE}" == "all" ]]; then
  for item in init fetch-kernel configure-kernel build-kernel fetch-driver build-driver package; do
    run_stage "${item}"
  done
else
  run_stage "${STAGE}"
fi
