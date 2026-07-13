# TrueNAS SCALE 25.10.4 i915 SR-IOV 构建

本项目通过 GitHub Actions 构建与 `6.12.91-production+truenas` 匹配的 i915 SR-IOV 模块。本地不保存大型内核源码，源码只在 Actions 临时运行器中使用。

> 警告：i915 SR-IOV 属于实验功能。请先备份 TrueNAS 配置，并确保有本地控制台可用于故障恢复。

## 为什么不能直接用旧模块

`yeguixiong/truenas-i915-sriov` 当前现成目录对应 `6.12.15`、`6.12.33`，而 TrueNAS SCALE 25.10.4 实际为：

```bash
uname -r
# 6.12.91-production+truenas
```

外置模块必须与运行内核的版本、配置和 `Module.symvers` 匹配，否则可能出现 `invalid module format` 或符号版本错误。

## 运行 GitHub Actions

1. 将本项目推送到你自己的 GitHub 仓库。
2. 打开 **Actions → 构建 TrueNAS i915 SR-IOV 模块 → Run workflow**。
3. 保持默认参数：
   - `truenas_ref`: `TS-25.10.4`（固定发行标签，避免分支后续变化）
   - `target_kernel`: `6.12.91-production+truenas`
   - `i915_ref`: `2026.03.05.1`
4. 构建完成后下载 Artifact：`i915-sriov-6.12.91-production+truenas`。
5. 检查其中的 `BUILD-INFO.txt` 和 `SHA256SUMS`。

完整内核符号构建比较耗时，这是为了在启用 `CONFIG_MODVERSIONS` 时生成正确的 `Module.symvers`，而不是仅靠不完整的 `modules_prepare`。

## 上传到 TrueNAS 后验证

假设模块解压到 `/mnt/Sys/Tool/modules/i915-sriov/`：

```bash
uname -r
find /mnt/Sys/Tool/modules/i915-sriov -name '*.ko' -exec modinfo {} \; | grep -E 'filename|depends|vermagic'
```

所有待加载模块的 `vermagic` 都应包含：

```text
6.12.91-production+truenas
```

## 首次手工测试

不要直接添加开机脚本。先停止使用核显的容器、应用和虚拟机，然后在本地控制台测试：

```bash
MODULE_DIR=/mnt/Sys/Tool/modules/i915-sriov
I915_KO=$(find "$MODULE_DIR" -name i915.ko -print -quit)
COMPAT_KO=$(find "$MODULE_DIR" -name intel_sriov_compat.ko -print -quit)

rmmod i915
[ -z "$COMPAT_KO" ] || insmod "$COMPAT_KO"
insmod "$I915_KO" enable_guc=3 max_vfs=7
echo 1 > /sys/bus/pci/devices/0000:00:02.0/sriov_numvfs

lspci -nn | grep -E 'VGA|Display'
dmesg | tail -n 100
```

`echo 1` 表示创建一个 VF；确认稳定后可改为 `1` 到 `7`。如果 `rmmod i915` 提示模块正在使用，应先找出占用者，不要强制卸载。

## 配置 TrueNAS 开机脚本

手工测试成功后，将项目中的 `truenas/enable-i915-sriov.sh` 复制到数据集，例如：

```bash
cp enable-i915-sriov.sh /mnt/Sys/Tool/modules/enable-i915-sriov.sh
chmod +x /mnt/Sys/Tool/modules/enable-i915-sriov.sh
```

进入 **系统 → 高级设置 → 开机/关机脚本**，添加 **Post Init / 启动后执行**：

```bash
/mnt/Sys/Tool/modules/enable-i915-sriov.sh
```

脚本默认从 `/mnt/Sys/Tool/modules/i915-sriov` 加载模块并创建 1 个 VF。需要修改时可通过环境变量调用：

```bash
MODULE_DIR=/mnt/其他路径 VF_COUNT=2 PCI_DEVICE=0000:00:02.0 \
  /mnt/Sys/Tool/modules/enable-i915-sriov.sh
```

## 分配给 Incus VM

VF 创建成功后先用 `lspci` 确认地址，例如 `0000:00:02.1`，再执行：

```bash
incus config device add Windows iGPU pci address=0000:00:02.1
```

不要把 PF `0000:00:02.0` 分配给 VM；它由 TrueNAS 主机持有并负责创建 VF。

## 升级注意事项

TrueNAS 每次升级后先执行 `uname -r`。只要结果变化，就必须针对新内核重新构建模块，不能继续复用旧 Artifact。
