# 案例实录：fnOS SSD 存储池反复满盘的完整根治过程

> 数据来自一次真实故障处置（2026-11，环境细节已脱敏）。
> 时间线压缩为「阶段」，读数均为实测值。

## 环境

| 项 | 值 |
|---|---|
| NAS | fnOS（飞牛），8 核 / 16GB |
| 事发存储池 | 系统 SSD 第三分区，btrfs，**182.47 GiB**（整盘已被 EFI + 系统分区 + 该池分完，无法扩容） |
| 虚拟机 | 1 台 Windows 10（GPU 直通），系统盘 qcow2：**virtual 150 GiB / 实际分配 120.47 GiB** |
| Guest vioscsi | VirtIO SCSI pass-through 驱动已装，`START_TYPE = 0 (BOOT_START)`、RUNNING |

## 症状

- 存储池可用空间一路下滑：`6.7G → 6.4G → 5.5G → 5.3G → 5.2G → 5.0G / 98%`（数小时内）
- 用户在虚拟机里清理了 20G，宿主毫无反应；此前重装/迁移过，又自己满回来
- `btrfs Device unallocated` 只剩 1 MiB（chunk 全分配，ENOSPC 变只读风险）

## 诊断（先排除，后定性）

| 假设 | 检查 | 结论 |
|---|---|---|
| 快照持有已删块 | `btrfs subvolume list`（root） | ✗ 仅 1 个常规子卷，无快照 |
| 进程持有已删文件 | `lsof +L1`（root） | ✗ 仅两个字节级临时文件 |
| 回收站 | 面板回收站列表 | ✗ 空 |
| 权限漏读 | root `du` 复算 | ✗ 与普通用户一致 |
| 配额账本错乱 | `btrfs quota rescan -w` 执行 | ✗ rescan 后 qgroup/df 均无变化 → **非账本问题** |
| 挂起 balance | `btrfs balance status` | ✗ 无 |
| **du 与 df 差额** | 173 GiB vs 121 GiB | **52 GiB 定性为孤儿/未释放 extent，真实占用、不可清理**，计入预算 |

关键三测：

1. 提权 `defrag /L C:` → ExitCode 0，宿主 `disk size` 纹丝不动（120 GiB）
2. Guest 写 256MB → 删除 → 宿主 `stat` Blocks **不降反涨** → guest TRIM 未被接受
3. 导出 qemu 完整命令行 → `scsi-hd` ✓ 但 `libvirt-1-format`（qcow2 节点）**无 discard**，`"discard":"unmap"` 只在 4 个 file(protocol) 节点（含 OVMF/ISO——明显是面板无差别注入）

## 根因（三层）

```
第 1 层  总线 SATA(ide-hd)：QEMU 的 IDE/AHCI 仿真不透传 TRIM
第 2 层  XML <driver> 无 discard='unmap'：qcow2 format 层默认 ignore，
         guest 的每个 TRIM 被静默丢弃（file 层的 discard:unmap 只管宿主打洞，两层别混）
第 3 层  120.47 GiB 全预分配 + 历史死簇：修通路后还需一次全盘 Retrim 吐还
```

佐证：libvirt 邮件列表（Peter Krempa）——「用户设置只作用于 format 节点，它决定 guest discard 是否被接受」。

## 修复（两次停机，共约 10 分钟）

**第 1 次**：管理面板把磁盘总线 `SATA → VirtIO SCSI`，关机→开机。
→ 实测 TRIM 仍不通（同款 256MB 探针 Blocks 仍上涨）——**单独换总线不够**。

**第 2 次**：同一编辑页勾选磁盘 `Discard` 开关（等价于 XML `discard='unmap'`），**完全关机再开机**（cold boot）。
→ 开机后 Windows 自动 TRIM + 一次全盘 `defrag /L C:`：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 存储池可用 | 5.0G / 98% | **30G / 84%** |
| qcow2 实际分配 | 120.47 GiB | **85.56 GiB**（punch hole 回收 **34.9 GiB**） |
| 删除后宿主行为 | 不降反涨 | **Blocks 两连降**（179420928 → 179418496 → 179418240） |

删除探针（写 256MB→删→宿主采样）从「上涨」翻转为「持续下降」，证明 NTFS 异步 TRIM → qcow2 punch hole → btrfs 回收全链路打通。

## 长期预算（修复后模型）

```
52 GiB 死账（固定，不增长）+ ~86 GiB 虚拟盘（随 Guest 数据浮动）+ ~2 GiB 元数据 ≈ 140 GiB
182 GiB - 140 GiB ≈ 40 GiB+ 余量；Guest 数据 ≤105~110 GiB 即可长期稳留 20 GiB+
```

每周日 03:00 SYSTEM 任务自动 Retrim 兜底（Windows 自带 ScheduledDefrag 不带 `/L`，从不 TRIM）。

## 踩坑记录（价值最高的部分）

1. **qemu 命令行有 `"discard":"unmap"` ≠ 配置正确**。file 层与 format 层是两个开关，本案例第一次判断就是被 file 层的注入误导，多花了一轮停机。判据永远以 `virsh dumpxml` 的 `<driver discard='unmap'/>` 为准。
2. **`virsh reboot` 不生效**，必须完全关机再开机（`<driver>` 属性在 qemu 进程启动时生效）。
3. **Session-0 SYSTEM 后台跑 `defrag /L` 会空转**（8 分钟 0.06 秒 CPU、0 字节读）。首次全盘 Retrim 用交互式管理员窗口。
4. **`defrag /L` 返回 0 不代表做了事**——设备不支持时 Windows 静默跳过。验收只认宿主侧 `qemu-img info`/`stat` 数字。
5. `btrfs balance -dusage=0` 与 `-dusage=10` 均零迁移（185 个 chunk 使用均匀 83.9%）——**别盲目提高 usage 档重写整卷**，收益不进 df。
6. Windows 把该盘识别为 `Media=Unspecified`，日常 TRIM 偏保守；`Set-PhysicalDisk -MediaType SSD` 可修正（管理员）。
7. NTFS 删除的 TRIM 是**异步批量**的，删除后等数十秒再采样宿主。
