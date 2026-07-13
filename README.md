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

## 部署到 TrueNAS

将两个模块和两个脚本统一放到持久化数据集目录 `/mnt/tools`：

```text
/mnt/tools/
├── i915.ko
├── intel_sriov_compat.ko
├── test-i915-sriov.sh
└── enable-i915-sriov.sh
```

处理 Windows 换行并添加执行权限：

```bash
sed -i 's/\r$//' /mnt/tools/test-i915-sriov.sh /mnt/tools/enable-i915-sriov.sh
chmod 755 /mnt/tools/test-i915-sriov.sh /mnt/tools/enable-i915-sriov.sh
```

检查运行内核和模块版本：

```bash
uname -r
modinfo -F vermagic /mnt/tools/i915.ko
modinfo -F vermagic /mnt/tools/intel_sriov_compat.ko
```

两个模块的 `vermagic` 开头必须与 `uname -r` 完全一致。脚本通过 `/proc/modules` 判断模块状态，避免 `pipefail` 与 `grep -q` 组合造成误判。

## 首次安全测试

不要直接添加开机脚本。先停止使用核显的 Apps、容器、转码服务和虚拟机，并检查 `/dev/dri`：

```bash
fuser -v /dev/dri/* 2>/dev/null
```

没有进程占用后，以 root 执行自动恢复测试：

```bash
KEEP_LOADED=0 bash /mnt/tools/test-i915-sriov.sh
```

测试脚本会检查模块版本和设备占用，加载兼容层与自定义 i915，创建 1 个 VF，并验证 `enable_guc=3`、`max_vfs=7` 和 `virtfn0`。`KEEP_LOADED=0` 表示测试结束后尝试恢复系统驱动；任何情况下都不要使用 `rmmod -f i915`。

成功证据包括：

```text
Running in SR-IOV PF mode
Running in SR-IOV VF mode
Enabled 1 VFs
VF 创建成功
```

## 配置 TrueNAS 开机启动

实机测试发现 Post Init 阶段系统 i915 已绑定核显 PF。`enable-i915-sriov.sh` 会先通过 PCI `unbind` 安全释放 PF，再替换模块并重新绑定，不使用强制卸载。

进入 **系统设置 → 高级设置 → 开机/关机脚本 → 添加**：

| 项目 | 设置 |
|---|---|
| 类型 | 命令（Command） |
| 什么时候 | 初始化后期（Post Init） |
| 超时 | 120 秒 |
| 启用 | 是 |
| 描述 | 启用 Intel i915 SR-IOV |

创建 7 个 VF 的命令必须填写为一整行：

```bash
/bin/sh -c 'MODULE_DIR=/mnt/tools PCI_DEVICE=0000:00:02.0 VF_COUNT=7 MAX_VFS=7 ENABLE_GUC=3 /bin/sh /mnt/tools/enable-i915-sriov.sh > /mnt/tools/i915-sriov-boot.log 2>&1'
```

使用单个 `>` 覆盖旧日志，避免上次失败记录与本次结果混合。第一次启动可将 `VF_COUNT=7` 改为 `VF_COUNT=1`，确认稳定后再增加。不能选择“初始化前期”，因为该阶段 `/mnt/tools` 所在数据集可能尚未挂载。

## 重启后验证

```bash
cat /mnt/tools/i915-sriov-boot.log
lsmod | grep -E '^(i915|intel_sriov_compat)'
printf 'enable_guc='; cat /sys/module/i915/parameters/enable_guc
printf 'max_vfs='; cat /sys/module/i915/parameters/max_vfs
printf 'total_vfs='; cat /sys/bus/pci/devices/0000:00:02.0/sriov_totalvfs
printf 'num_vfs='; cat /sys/bus/pci/devices/0000:00:02.0/sriov_numvfs
lspci -Dnn | grep '0000:00:02'
dmesg | grep -Ei 'i915|sriov|guc|huc' | tail -n 100
```

创建 7 个 VF 时，预期参数为 `enable_guc=3`、`max_vfs=7`、`total_vfs=7`、`num_vfs=7`，并枚举 PF `0000:00:02.0` 与 VF `0000:00:02.1`～`0000:00:02.7`。

已在以下环境完成实机验证：

- TrueNAS SCALE 25.10.4；
- 内核 `6.12.91-production+truenas`；
- Intel Alder Lake-S GT1 UHD Graphics 730，设备 ID `8086:4692`；
- 成功创建 7 个 VF；
- GuC submission、HuC authentication 和 SR-IOV PF/VF 模式正常。

若启动失败，先查看 `/mnt/tools/i915-sriov-boot.log` 和 `dmesg`。禁用 Post Init 任务并重启即可恢复系统默认启动流程，不要强制卸载正在使用的 i915。

## 分配给 Incus VM

VF 创建成功后先用 `lspci` 确认地址，例如 `0000:00:02.1`，再执行：

```bash
incus config device add Windows iGPU pci address=0000:00:02.1
```

不要把 PF `0000:00:02.0` 分配给 VM；它由 TrueNAS 主机持有并负责创建 VF。

## 升级注意事项

TrueNAS 每次升级后先执行 `uname -r`。只要结果变化，就必须针对新内核重新构建模块，不能继续复用旧 Artifact。
