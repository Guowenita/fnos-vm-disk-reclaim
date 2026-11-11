---
name: fnos-vm-disk-reclaim
description: 诊断并根治 fnOS/飞牛 NAS（及通用 KVM/libvirt）虚拟机 qcow2 磁盘「只涨不缩、反复满盘」问题。当用户报告：虚拟机里删了文件但存储池不释放、qcow2 越来越大、反复自动满盘、重装/迁移后又满、df 远大于 du、Guest 优化驱动器无效时使用。核心知识点：QEMU ide/sata 不转发 TRIM；libvirt 的 discard 有 file 层与 format 层之别，XML <driver discard='unmap'/> 才控制 guest TRIM 是否被接受；修复需 virtio-scsi + discard + cold boot + 全盘 Retrim 五件套。触发词：fnos 磁盘满、虚拟机磁盘不缩小、qcow2 膨胀、TRIM 不生效、discard unmap、存储池满。
---

# fnos-vm-disk-reclaim · 操作技能

## 适用场景

- fnOS/飞牛 NAS 虚拟机所在存储池反复满盘，Guest 内清理无效
- `qemu-img info` 的 `disk size` 只增不减（qcow2 膨胀）
- `df` 远大于 `du`，且无快照、无 deleted-open、`btrfs quota rescan` 无效
- 任何 KVM/libvirt + qcow2 + Windows/Linux Guest 的 TRIM 回收问题

## 工作流（严格按序）

### 第 1 步：只读诊断，禁止先动手

在 NAS 上运行本技能的只读诊断脚本（或等价命令）：

```bash
sudo bash scripts/diagnose.sh [pool]
```

脚本给出四类判定：总线、XML discard、btrfs 健康（unallocated/快照）、deleted-open。
**原则：诊断阶段零写操作。** 不跑 balance、不 define、不删文件、不重启 VM。

### 第 2 步：判定根因（常见优先级）

1. **XML `<driver>` 缺 `discard='unmap'`**（最常见且最隐蔽）
   - 判据：`virsh dumpxml` 中磁盘 `<driver name='qemu' type='qcow2'/>` 无 discard 属性
   - ⚠️ **勿被 qemu 命令行误导**：`-blockdev` 的 file(protocol) 节点带 `"discard":"unmap"` 只表示宿主允许打洞（很多面板会给所有 file 节点统一注入）；**决定 guest TRIM 是否被接受的是 format(qcow2) 节点，它只由 XML `<driver discard='unmap'/>` 控制**（libvirt 官方邮件列表，Peter Krempa）。两层必须同时开。
2. **总线为 SATA/IDE**：QEMU 的 ide-hd/AHCI 仿真不透传 TRIM，必须换 VirtIO SCSI。
3. **qcow2 全预分配/写实 + 历史死簇**：需要一次全盘 Retrim 才能吐还。
4. **btrfs `Device unallocated` 用尽**：df 有余额仍可能 ENOSPC 变只读。
5. `du` 与 `df` 的永久差额：无快照、无 deleted-open、rescan 无效 → 孤儿 extent 真实占用，**不可清理，计入容量预算**，别反复尝试。

### 第 3 步：修复（需用户确认与执行）

修复五件套，缺一不可，**涉及停机与配置变更，必须由用户执行或明确授权**：

```
1. 总线 SATA/IDE → VirtIO SCSI（XML bus='scsi'，需 virtio-scsi controller）
2. <driver name='qemu' type='qcow2' discard='unmap'/>
3. 完全关机再开机（cold boot；virsh reboot 不生效，<driver> 属性在 qemu 进程启动时生效）
4. Guest 全盘 Retrim（Windows: 交互式管理员窗口 defrag /L C:）
5. 注册每周自动 Retrim（scripts/retrim-admin.bat 或 schtasks 命令）
```

关键注意：
- Windows Guest 切总线前确认 vioscsi 已安装且 `sc qc vioscsi` 显示 `START_TYPE = 0 (BOOT_START)`，否则 `INACCESSIBLE_BOOT_DEVICE` 蓝屏。
- 优先走 NAS 管理面板 UI 修改；用 `virsh define` 命令行改时，**改完直接开机，不要回 UI 保存**（面板会用数据库配置覆盖 XML）。
- 改前 `virsh dumpxml > 备份`；回退 = `virsh define 备份文件`。
- Windows 自带 `ScheduledDefrag` 动作是 `defrag -c -h -o -`，**不含 `/L`**，从不发 TRIM。
- **SYSTEM/Session-0 后台会话中 `defrag /L` 实测会空转**（数分钟零 CPU 零读）；首次全盘 Retrim 必须在交互式管理员窗口跑。
- 前台 `defrag /L` 在大卷上很慢（10-40 分钟），提前告知用户勿关窗口。

### 第 4 步：验收（拿数据说话）

| 检查 | 目标 | 命令 |
|---|---|---|
| XML | `discard='unmap'` + `bus='scsi'` | `virsh dumpxml <vm> \| grep -E "discard\|bus='scsi'"` |
| qcow2 disk size | 回落至接近 Guest 实际数据量 | `qemu-img info --force-share <disk>.qcow2` |
| 存储池可用空间 | 大幅回升 | `df -h <pool>` |
| 删除自动回收 | 写入→删除→宿主 `stat` Blocks 下降（NTFS TRIM 异步，等数十秒） | `stat <disk>.qcow2` |

### 第 5 步：遗留披露（如实告知用户）

- 孤儿 extent 死账不可清除（不增长），长期预算 = 死账 + Guest 数据 + 元数据。
- btrfs unallocated 若仍极低：记录在案，data chunk 内空闲可做缓冲；如需归还可试 `btrfs balance start -dusage=0 -musage=0`（零迁移则跳过，勿盲目提高 usage 档重写整卷）。
- Windows 对 `Media=Unspecified` 虚拟盘的日常 TRIM 可能保守；回收不及时时管理员跑 `Set-PhysicalDisk -MediaType SSD` 修正后复测。

## 红线

- 诊断阶段**零写操作**；balance/define/关机等一律先征得用户确认。
- 若 AI 助手自身运行在该虚拟机内，**绝不允许自行 shutdown/restart 该 VM**——会失去后续验证与回退能力；重启步骤交由用户在管理面板执行。
- 迁移/复制 qcow2 必须用 `qemu-img convert` 或 `cp --sparse=always`；**严禁在剩余空间不足的卷上原地 convert**。
- 凭据类信息绝不写入诊断输出、日志或本仓库文件。

## 脚本清单

| 文件 | 用途 |
|---|---|
| `scripts/diagnose.sh` | NAS 侧一键只读诊断（root 运行），输出判定表与修复清单 |
| `scripts/retrim-admin.bat` | Guest Windows 侧：全盘 Retrim + 注册每周任务（右键管理员运行） |
| `scripts/retrim-admin.ps1` | 同上的 PowerShell 版（含介质类型/vioscsi 状态记录） |
