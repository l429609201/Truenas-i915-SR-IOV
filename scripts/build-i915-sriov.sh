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

rm -rf "${KERNEL_DIR}" "${DRIVER_DIR}" "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

echo "[1/6] 获取 TrueNAS 内核 ${TRUENAS_REF}"
git clone --depth 1 --branch "${TRUENAS_REF}" \
  https://github.com/truenas/linux.git "${KERNEL_DIR}"
KERNEL_COMMIT="$(git -C "${KERNEL_DIR}" rev-parse HEAD)"
# TrueNAS 官方构建会在配置前删除 Git 元数据，避免 kernelrelease 自动追加 -g<提交号>。
rm -rf "${KERNEL_DIR}/.git"

echo "[2/6] 生成与 TrueNAS production 一致的内核配置"
cd "${KERNEL_DIR}"
export EXTRAVERSION=-production
export LOCALVERSION=+truenas
export CC="${KERNEL_CC:-gcc}"
make defconfig
./scripts/kconfig/merge_config.sh .config \
  scripts/package/truenas/debian_amd64.config \
  scripts/package/truenas/truenas.config \
  scripts/package/truenas/tn-production.config
# 后缀只由 make 级 LOCALVERSION 提供；Kconfig 中清空，避免生成 +truenas+truenas。
./scripts/config --set-str LOCALVERSION ""
./scripts/config --disable LOCALVERSION_AUTO
make olddefconfig
make syncconfig

echo "最终版本配置："
grep -E '^CONFIG_LOCALVERSION=|^CONFIG_LOCALVERSION_AUTO=' .config include/config/auto.conf || true
echo "make LOCALVERSION=${LOCALVERSION} EXTRAVERSION=${EXTRAVERSION}"

ACTUAL_KERNEL="$(make -s kernelrelease)"
if [[ "${ACTUAL_KERNEL}" != "${TARGET_KERNEL}" ]]; then
  echo "错误：源码生成的内核版本为 ${ACTUAL_KERNEL}，目标为 ${TARGET_KERNEL}" >&2
  exit 1
fi

echo "[3/6] 构建 vmlinux 和内核模块符号"
# CONFIG_MODVERSIONS 下外置模块依赖完整 Module.symvers，不能只做 modules_prepare。
# TrueNAS 官方配置开启 WERROR；不同 runner 工具链可能产生非功能性警告，外部复现时关闭该限制。
./scripts/config --disable WERROR
make olddefconfig
make -j"$(nproc)" vmlinux modules
if [[ ! -s Module.symvers ]]; then
  echo "错误：未生成 Module.symvers，无法保证模块 ABI 匹配" >&2
  exit 1
fi

echo "[4/6] 获取 i915 SR-IOV ${I915_REF}"
git clone --depth 1 --branch "${I915_REF}" \
  https://github.com/strongtz/i915-sriov-dkms.git "${DRIVER_DIR}"

echo "[5/6] 编译外置模块"
make -C "${KERNEL_DIR}" M="${DRIVER_DIR}" modules

# 新版驱动除 i915 外还可能依赖兼容层；平铺打包，便于上传到 TrueNAS。
while IFS= read -r -d '' module; do
  cp "${module}" "${OUT_DIR}/$(basename "${module}")"
done < <(find "${DRIVER_DIR}" -type f -name '*.ko' -print0)
find "${OUT_DIR}" -type f -name '*.ko' -print0 | xargs -0 -r -n1 strip --strip-debug

MODULE_COUNT="$(find "${OUT_DIR}" -maxdepth 1 -type f -name '*.ko' | wc -l)"
if [[ "${MODULE_COUNT}" -eq 0 ]]; then
  echo "错误：编译完成但没有找到 .ko 产物" >&2
  exit 1
fi

{
  echo "TrueNAS ref: ${TRUENAS_REF}"
  echo "Target kernel: ${TARGET_KERNEL}"
  echo "i915 SR-IOV ref: ${I915_REF}"
  echo "TrueNAS commit: ${KERNEL_COMMIT}"
  echo "i915 commit: $(git -C "${DRIVER_DIR}" rev-parse HEAD)"
  echo
  find "${OUT_DIR}" -type f -name '*.ko' -print0 | while IFS= read -r -d '' module; do
    echo "[$(basename "${module}")]"
    modinfo "${module}" | grep -E '^(filename|version|depends|vermagic):' || true
    echo
  done
} > "${OUT_DIR}/BUILD-INFO.txt"

find "${OUT_DIR}" -type f -name '*.ko' -exec sha256sum '{}' \; \
  > "${OUT_DIR}/SHA256SUMS"

echo "[6/6] 验证全部模块的 vermagic"
FAILED=0
while IFS= read -r -d '' module; do
  VERMAGIC="$(modinfo -F vermagic "${module}")"
  if [[ "${VERMAGIC}" != "${TARGET_KERNEL}"* ]]; then
    echo "错误：$(basename "${module}") 的 vermagic 为 ${VERMAGIC}" >&2
    FAILED=1
  fi
done < <(find "${OUT_DIR}" -maxdepth 1 -type f -name '*.ko' -print0)
if [[ "${FAILED}" -ne 0 ]]; then
  exit 1
fi
cat "${OUT_DIR}/BUILD-INFO.txt"
