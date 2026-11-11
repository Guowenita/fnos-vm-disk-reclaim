# fnos-vm-disk-reclaim

> **fnOS（飞牛）NAS 虚拟机磁盘「只涨不缩、反复满盘」根治方案**
> 同样适用于任何 KVM/libvirt + qcow2 + Windows Guest 环境（Proxmox、PVE 直签 libvirt 亦同）。

[![案例验证](https://img.shields.io/badge/%E6%A1%88%E4%BE%8B%E9%AA%8C%E8%AF%81-%E5%9B%9E%E6%94%B634.9GiB-brightgreen)](case-study.md)
[![类型](https://img.shields.io/badge/%E7%B1%BB%E5%9E%8B-%E6%8E%92%E9%9A%9C%E6%96%B9%E6%B3%95%E8%AE%BA-blue)](#八-常见坑-faq)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 一、你大概率遇到了这个问题

- 虚拟机里**删了文件 / 清了空间**，NAS 存储池的已用空间却**一个字节都不降**
- 存储池**反复自动涨满**，甚至重装虚拟机系统、迁移磁盘后又满回来
- Windows Guest 里跑「优化驱动器」、清理工具，宿主侧毫无反应
- `du` 加起来的文件远小于 `df` 显示的已用空间，中间差了几十 GiB

**这不是玄学，是三层配置叠加的静默失败。**

## 二、TL;DR（太长不看版）

```
修复 = 磁盘总线 SATA/IDE → VirtIO SCSI
     + libvirt XML <driver discard='unmap'/>
     + 完全关机再开机（cold boot，重启不算）
     + Guest Windows 一次全盘 Retrim（defrag /L C:）
     + 注册每周自动 Retrim 计划任务
```

五件事缺一不可。本仓库提供：一键只读诊断脚本（NAS 侧）、Guest 侧自动 Retrim 脚本、验收清单、真实案例数据。

## 三、根因：三层静默失败

### 第 1 层：总线不对 —— QEMU 的 `ide-hd`/AHCI 不转发 TRIM

QEMU 对 IDE/AHCI 仿真的磁盘设备**不支持 discard 透传**。磁盘挂在 SATA/IDE 总线上时，Guest 发的 TRIM 在设备层就被丢弃，宿主永远收不到。

### 第 2 层：XML 缺 `discard='unmap'`（最常见、最隐蔽）

libvirt 的 blockdev 是两层的：

```
-device scsi-hd,...,drive=libvirt-1-format
                        │
-blockdev {"driver":"qcow2", "file":"libvirt-1-storage"}      ← format 层：guest TRIM 的接受开关
                        │
-blockdev {"driver":"file", "filename":"disk.qcow2",
           "discard":"unmap"}                                    ← file 层：宿主打洞许可
```

**两层不是一回事。** libvirt 开发者 Peter Krempa 在官方邮件列表的原话：

> "discard:unmap 只加在 protocol(file) 节点……**用户设置（XML `<driver discard='unmap'/>`）只作用于 format 节点，它决定 guest 的 discard 是否被接受**。"

很多管理面板（包括 fnOS）会给所有 file 节点统一注入 `"discard":"unmap"`，这**只表示宿主允许打洞**。如果 XML 里 `<driver name='qemu' type='qcow2'/>` 没写 `discard='unmap'`，format 层默认 `ignore` —— **Guest 的每个 TRIM 都被静默丢弃**。只看 qemu 命令行里有 `discard:unmap` 就认为"宿主侧已配置好"，是最典型的误判。

### 第 3 层：qcow2 全预分配 / 长期写实 + 历史「死簇」

- `qemu-img info` 的 `disk size` 只增不减；`stat` 显示 `Blocks×512 ≈ Size` 说明全预分配
- Guest 曾经写过又删掉的数据，在 qcow2 里以死簇形式留存（复制/迁移不带稀疏参数也会把盘写实——社区实测 44G 拖成 120G）
- 修复通路后，需要**一次全盘 Retrim** 才能把历史死簇吐还给宿主

### 完整链路（修复后应有的样子）

```
Windows 删除文件 / Retrim
   → NTFS 发 TRIM（fsutil DisableDeleteNotify = 0）
   → vioscsi 驱动（需 BOOT_START）
   → virtio-scsi (scsi-hd)
   → qcow2 format 层 discard=unmap   ←★ 第 2 层开关
   → 释放 cluster + fallocate(PUNCH_HOLE)
   → 宿主文件系统（btrfs/ext4/xfs）回收 extent
   → 存储池可用空间回升  ←★ 你最终看到的数字
```

## 四、快速开始

### 步骤 1：诊断（NAS 侧，只读，不改任何数据）

```bash
sudo bash scripts/diagnose.sh            # 自动扫所有卷
sudo bash scripts/diagnose.sh /vol3      # 或指定卷
```

脚本会输出每个虚拟磁盘的判定表：总线是否 virtio-scsi、XML 是否带 `discard='unmap'`、qcow2 虚拟/实际大小、btrfs chunk 与 unallocated 状态、是否存在快照或 deleted-open 占用，并给出针对性修复建议。

### 步骤 2：改宿主配置（两条路二选一）

**路径 A：fnOS Web UI（推荐）**

1. 虚拟机应用 → 目标 VM → **关机**（等状态变「已关机」）
2. 编辑 → 硬件/磁盘 → 选中系统盘：
   - 总线/控制器类型：`SATA/IDE` → **`VirtIO SCSI`**
   - **`Discard`/「丢弃」开关 → 启用**（没有此开关见路径 B）
3. 保存 → **开机**（必须完全关机再开，`virsh reboot` 不生效）

**路径 B：virsh 命令行（界面找不到 Discard 开关时）**

```bash
sudo virsh shutdown <vm-name>                        # 等状态 shut off
sudo virsh dumpxml <vm-name> > /path/backup/vm.xml   # 改前备份

# 只改系统盘两处（用编辑器或 sed，注意别动光驱）
#   <driver name='qemu' type='qcow2'/>                → 加 discard='unmap'
#   <target dev='sdX' bus='sata'/>                    → bus='scsi'
sudo virsh define /path/backup/vm.xml
sudo virsh start <vm-name>

# 验证（应输出 discard='unmap' 且 bus='scsi'）
sudo virsh dumpxml <vm-name> | grep -E "driver name='qemu' type='qcow2'|bus='scsi'"
```

> ⚠️ `virsh define` 之后**直接开机，不要回 Web UI 再点保存** —— 部分面板会用自己数据库里的配置覆盖 XML。

> ⚠️ Windows Guest 切总线前确认 vioscsi 驱动已安装且 `START_TYPE = 0 (BOOT_START)`（管理员 CMD：`sc qc vioscsi`），否则可能 `INACCESSIBLE_BOOT_DEVICE` 蓝屏。virtio-win ISO 的 Guest 一般已具备。

### 步骤 3：Guest Windows 侧收尾

管理员 PowerShell / CMD：

```bat
:: 1. 确认 TRIM 已启用（应输出 0）
fsutil behavior query DisableDeleteNotify

:: 2. 一次全盘 Retrim（把历史死簇吐还给宿主，可能 10-40 分钟，别关窗口）
defrag /L C:

:: 3. 注册每周自动 Retrim（SYSTEM，周日凌晨 3 点）
schtasks /Create /TN "VM-AutoRetrim" /TR "C:\Windows\System32\defrag.exe /L C:" /SC WEEKLY /D SUN /ST 03:00 /RU SYSTEM /RL HIGHEST /F
```

或者直接使用本仓库脚本（右键 → 以管理员身份运行）：`scripts/retrim-admin.bat`

> Windows 自带的 `ScheduledDefrag` 任务动作是 `defrag -c -h -o -$`，**不含 `/L`**，从不发 TRIM —— 这就是"系统每周都优化却从不回收"的直接原因。

### 步骤 4：验收

| 检查点 | 目标 | 命令（NAS 侧） |
|---|---|---|
| XML | `<driver ... discard='unmap'/>` + `bus='scsi'` | `virsh dumpxml <vm> \| grep discard` |
| qcow2 实际大小 | 显著回落（向 Guest 实际数据量靠拢） | `qemu-img info --force-share <disk>.qcow2` |
| 存储池可用空间 | 大幅回升 | `df -h <vol>` |
| 删除自动回收 | 写入→删除测试后宿主盘缩小 | `stat <disk>.qcow2` 观察 `Blocks` |
| 每周任务 | 已注册且状态正常 | Guest：`schtasks /Query /TN "VM-AutoRetrim"` |

删除测试示例（Guest 侧 PowerShell）：

```powershell
$p = "$env:TEMP\trimtest.bin"
$buf = New-Object byte[] 1048576; (New-Object System.Random).NextBytes($buf)
$fs = [System.IO.File]::Create($p)
1..256 | ForEach-Object { $fs.Write($buf, 0, $buf.Length) }
$fs.Flush($true); $fs.Close()
[System.IO.File]::Delete($p)     # 删除后数十秒内，宿主 stat Blocks 应下降
```

## 五、验收通过后的运行模型

```
虚拟盘容量（如 150G）只是天花板，不预占
宿主实际占用 ≈ Guest 实际数据量（随增删上下波动）
每周 SYSTEM Retrim 兜底回收碎片
```

## 六、btrfs 存储池的两个附加检查（fnOS 用户重点关注）

1. **`Device unallocated` 用尽**：`btrfs filesystem usage <vol>` 若显示 unallocated 仅剩几 MiB，即使 df 有余额，btrfs 也可能因无法分配新 metadata chunk 而 ENOSPC 变只读。可先跑 `btrfs balance start -dusage=0 -musage=0 <vol>`（满盘时唯一零风险档）尝试归还空 chunk。
2. **`du` 与 `df` 的永久差额**：若无快照、无 deleted-open（`lsof +L1`）、`btrfs quota rescan` 无效，则属于孤儿/未释放 extent（真实占用）。它不增长，但只能靠整卷重建清除 —— 请把它计入长期容量预算，不要反复尝试"清理"。

## 七、作为 AI 助手 Skill 使用（WorkBuddy / Claude Code 等）

```bash
# WorkBuddy 用户级技能安装
git clone https://github.com/Guowenita/fnos-vm-disk-reclaim.git
cp -r fnos-vm-disk-reclaim ~/.workbuddy/skills/fnos-vm-disk-reclaim
# 会话刷新后即可触发，见 SKILL.md
```

## 八、常见坑（FAQ）

**Q1：qemu 命令行里明明有 `"discard":"unmap"`，为什么还是不回收？**
它在 file(protocol) 层，只管宿主打洞；决定 Guest TRIM 是否被接受的是 format(qcow2) 层，由 XML `<driver discard='unmap'/>` 控制。两层必须同时开。参见第三节第 2 层。

**Q2：`defrag /L C:` 提示成功（ExitCode 0）但宿主盘没变？**
设备层（总线/XML discard）不通时 Windows 静默跳过，退出码照样是 0。先修宿主配置再跑。

**Q3：为什么必须 cold boot，`virsh reboot` 不行？**
`<driver>` 属性和磁盘总线改动在 qemu 进程启动时生效，`reboot` 是 Guest 内重启、不重建 qemu 设备拓扑。

**Q4：SYSTEM 计划任务里的 defrag 空转不干活？**
实测 Session 0 后台会话中 `defrag /L` 可能挂起（数分钟零 CPU、零读）。首次全盘 Retrim 请用**交互式管理员窗口**跑；每周任务保留做兜底，或在 GUI「优化驱动器」确认其工作。

**Q5：Retrim 跑完 disk size 只降了一点？**
Windows 对识别为 `Media=Unspecified` 的虚拟盘，TRIM 行为可能保守。管理员 PowerShell 执行 `Set-PhysicalDisk -MediaType SSD` 修正介质类型后复测。另外 NTFS 删除的 TRIM 是**异步批量**的，删除后等几十秒再采样。

**Q6：迁移/复制虚拟盘要注意什么？**
务必用 `qemu-img convert` 或 `cp --sparse=always`，普通复制会把稀疏盘写实（社区实测 44G → 120G）。严禁在剩余空间不足的卷上原地 convert。

**Q7：改了 XML 但被改回去了？**
Web UI 保存会用面板数据库覆盖手改的 XML。命令行 `virsh define` 后直接开机，不要回界面再保存。

## 九、真实案例

详见 [case-study.md](case-study.md)：一个 fnOS NAS SSD 存储池从 98% 满盘（可用 5G、持续恶化）到 84%（可用 30G）、qcow2 从 120.47 GiB 打洞回收 34.9 GiB 的完整诊断-修复-验收记录，含完整时间线与每一步实测数据。

## 十、参考与致谢

- libvirt 邮件列表（Peter Krempa 关于两层 blockdev 的说明）：<https://lists.libvirt.org/archives/list/users@lists.libvirt.org/message/QUN7PBFM52K6R4RNBU7CHGFPJ7QOOTA5>
- libvirt 域 XML 格式文档（磁盘 `discard` 属性）：<https://libvirt.org/formatdomain.html#hard-drives-floppy-disks-cdroms>
- 飞牛官方论坛相关讨论（虚拟机存储空间 / qcow2 复制写实）
- QEMU blockdev 文档

## License

[MIT](LICENSE)
