# bug610493 Hygon PSP S3 唤醒后关机卡死问题分析

## 1. 问题背景

- 问题编号：bug610493
- 问题现象：机器先进 S3，再唤醒后执行关机，系统卡死。
- 故障内核：`5.4.18-113-generic #102-KYLINOS`
- 正常内核：升级到 `5.4.18-145` 后正常。
- 参考日志：`references/bug-610493/minicomclose.txt`
- 参考源码：`references/kfocal/kfocal`

故障日志中的关键平台信息：

```text
Linux version 5.4.18-113-generic ... 5.4.18-113.102-generic
CPU0: Hygon C86 3250  8-core Processor
DMI: KaiTian 90UNS00SKX/3501, BIOS W09KT26A 03/08/2024
pci 0000:05:00.2: [1d94:1456] type 00 class 0x108000
ccp 0000:05:00.2: psp enabled
ccp 0000:05:00.2: CSV API:1.1 build:1573
```

## 2. 故障现象与调用栈

关机过程中，`shutdown` 进程进入 D 状态并被 hung task 检测到：

```text
INFO: task shutdown:1 blocked for more than 61 seconds.
shutdown        D    0     1      0 0x00004080
Call Trace:
 __schedule
 schedule
 schedule_timeout
 __sev_do_cmd_locked+0x1d9/0x400
 __sev_platform_shutdown_locked+0x36/0x90
 sev_platform_shutdown.isra.0+0x3c/0xd0
 psp_dev_destroy+0x21/0xb0
 sp_destroy+0x30/0x80
 sp_pci_shutdown+0x1a/0x20
 pci_device_shutdown+0x3a/0x60
 device_shutdown+0x113/0x1a0
 kernel_power_off+0x35/0x70
 __do_sys_reboot+0x121/0x210
```

该栈说明系统已经进入内核关机路径，卡在 PCI 设备 shutdown 阶段的 Hygon/AMD CCP PSP 驱动中。具体为：

```text
device_shutdown()
  -> pci_device_shutdown()
    -> sp_pci_shutdown()
      -> sp_destroy()
        -> psp_dev_destroy()
          -> sev_firmware_shutdown()
            -> sev_platform_shutdown()
              -> __sev_platform_shutdown_locked()
                -> __sev_do_cmd_locked(SEV_CMD_SHUTDOWN)
```

## 3. 代码路径分析

### 3.1 `5.4.18-113` 中的关机逻辑

在 `drivers/crypto/ccp/psp-dev.c` 中，`psp_dev_destroy()` 会调用 `sev_firmware_shutdown()`：

```c
static void sev_firmware_shutdown(struct psp_device *psp)
{
	sev_platform_shutdown(NULL);

	if (sev_es_tmr) {
		wbinvd_on_all_cpus();
		free_pages((unsigned long)sev_es_tmr,
			   get_order(SEV_ES_TMR_SIZE));
		sev_es_tmr = NULL;
	}
}
```

`sev_platform_shutdown()` 最终调用：

```c
__sev_do_cmd_locked(SEV_CMD_SHUTDOWN, NULL, error);
```

`__sev_do_cmd_locked()` 写入 PSP command/response 寄存器后，等待 PSP 完成中断：

```c
psp->sev_int_rcvd = 0;
iowrite32(reg, psp->io_regs + psp->vdata->cmdresp_reg);
ret = sev_wait_cmd_ioc(psp, &reg, psp_timeout);
```

而 `sev_wait_cmd_ioc()` 的等待条件是：

```c
wait_event_timeout(psp->sev_int_queue,
		   psp->sev_int_rcvd, timeout * HZ);
```

`psp->sev_int_rcvd` 只有在 PSP IRQ handler 收到 `PSP_CMD_COMPLETE` 并读取到 `PSP_CMDRESP_RESP` 后才会置位。因此，如果 S3 唤醒后 PSP 中断未恢复、PSP firmware 状态未同步，或 PSP command/response 寄存器状态异常，关机阶段发送 `SEV_CMD_SHUTDOWN` 后就可能一直等不到完成事件。

### 3.2 `5.4.18-113` 缺少 PSP suspend/resume

`5.4.18-113` 中 `drivers/crypto/ccp/sp-dev.c` 的 `sp_suspend()` / `sp_resume()` 只处理 CCP 设备：

```c
int sp_suspend(struct sp_device *sp, pm_message_t state)
{
	if (sp->dev_vdata->ccp_vdata)
		ccp_dev_suspend(sp, state);

	return 0;
}

int sp_resume(struct sp_device *sp)
{
	if (sp->dev_vdata->ccp_vdata)
		ccp_dev_resume(sp);

	return 0;
}
```

该版本没有在 S3 suspend/resume 过程中对 Hygon PSP/CSV 做退出、重新使能中断、重新初始化等处理。

### 3.3 `5.4.18-145` 中的相关修复

对比 `5.4.18-113.102..5.4.18-145.134`，`drivers/crypto/ccp` 中有两个与该问题高度相关的补丁。

#### 补丁一：`2998ef373df2`

```text
HYGON: bugfix: ccp: fix S4 kernel panic issue on HYGON cpu
```

该补丁虽然标题写的是 S4，但修改点位于通用 `CONFIG_PM` suspend/resume 路径，S3 同样会经过。

新增逻辑：

- `sp_suspend()` 中，如果是 Hygon 且设备存在 PSP vdata，则调用 `psp_dev_suspend()`。
- `sp_resume()` 中，如果是 Hygon 且设备存在 PSP vdata，则调用 `psp_dev_resume()`。
- `psp_dev_suspend()` 调用 `psp_pci_exit()`，主动执行 PSP/SEV firmware shutdown。
- `psp_dev_resume()` 重新写 `inten_reg` 使能 PSP 中断，并调用 `psp_pci_init()` 重新初始化 PSP/CSV。

关键代码：

```c
if (sp->dev_vdata->psp_vdata &&
	boot_cpu_data.x86_vendor == X86_VENDOR_HYGON) {
	ret = psp_dev_suspend(sp, state);
	if (ret)
		return ret;
}
```

```c
int psp_dev_resume(struct sp_device *sp)
{
	struct psp_device *psp;

	psp = sp->psp_data;
	iowrite32(-1, psp->io_regs + psp->vdata->inten_reg);

	psp_pci_init();

	return 0;
}
```

该补丁从 `5.4.18-123.112` 起已包含，`5.4.18-113.102` 不包含。

#### 补丁二：`7e35e15f3a78`

```text
HYGON: crypto/ccp: add psp device existence check for suspend/resume
```

该补丁在 `psp_dev_suspend()` / `psp_dev_resume()` 中增加 `psp_master` 判空：

```c
struct psp_device *psp = psp_master;

if (!psp)
	return 0;
```

并在 resume 阶段使用 `psp_master` 而不是直接使用 `sp->psp_data`。该补丁主要提升健壮性，避免 PSP master 不存在时出现空指针访问。该补丁从 `5.4.18-131.120` 起已包含，`5.4.18-145.134` 包含。

## 4. 问题分析结论

该问题大概率是 Hygon PSP/CSV 设备在 S3 唤醒后的驱动状态与硬件/固件状态不同步导致。

`5.4.18-113` 中，CCP 驱动的 PM 路径没有对 Hygon PSP 执行 suspend/resume 操作。S3 期间平台可能会重置或改变 PSP firmware、PSP 中断使能、command/response 寄存器或 TMR 相关状态；但驱动侧仍保留 `psp_master`、`sev_state` 等旧状态，认为 SEV/CSV platform 仍处于 INIT 状态。

随后关机进入 `sp_pci_shutdown()`，驱动在 `psp_dev_destroy()` 中尝试发送 `SEV_CMD_SHUTDOWN`。由于 S3 唤醒后 PSP 侧状态未被重新初始化或中断未恢复，命令完成中断没有正常到达，`__sev_do_cmd_locked()` 卡在等待队列中，最终触发 hung task。

升级到 `5.4.18-145` 后正常，是因为该版本已经包含 Hygon PSP suspend/resume 修复：S3 前主动 shutdown PSP firmware，S3 后重新使能 PSP 中断并重新执行 PSP init，使驱动状态与 PSP firmware 状态重新同步。

## 5. 问题解决方案

### 5.1 推荐方案

将故障环境升级到 `5.4.18-145` 或更高版本。

该方案已由现象验证：`5.4.18-145` 后 S3 唤醒再关机正常。

### 5.2 最小回合方案

如必须基于 `5.4.18-113` 做最小修复，建议优先回合以下补丁：

1. `2998ef373df2 HYGON: bugfix: ccp: fix S4 kernel panic issue on HYGON cpu`
2. `7e35e15f3a78 HYGON: crypto/ccp: add psp device existence check for suspend/resume`

其中 `2998ef373df2` 是核心修复，负责增加 Hygon PSP suspend/resume；`7e35e15f3a78` 是配套健壮性修复，负责避免 PSP master 不存在时访问空指针。

### 5.3 验证方案

建议按如下顺序验证：

1. 基线复现：`5.4.18-113`，执行 S3 -> 唤醒 -> 关机，确认可复现 shutdown D 状态卡死。
2. 单独回合 `2998ef373df2` 后验证：执行 S3 -> 唤醒 -> 关机，观察是否恢复正常。
3. 同时回合 `2998ef373df2` + `7e35e15f3a78` 后验证：确认无关机卡死、无 resume 阶段空指针或 PSP 初始化异常。
4. 使用 `5.4.18-145` 或更高版本回归验证：确认问题关闭。

建议关注日志：

```text
ccp ... psp enabled
CSV API:...
SEV: failed to INIT
sev command ... timed out
psp initialization failed
shutdown blocked
```

## 6. 后续计划与建议

1. 在缺陷单中将问题归类为 Hygon PSP/CSV PM 状态恢复问题，而不是普通 systemd shutdown 或文件系统卸载问题。
2. 优先确认 `2998ef373df2` 是否可以干净回合到 `5.4.18-113` 维护分支；若存在依赖，再同步补齐必要的 PSP/CCP 上下文修改。
3. 将 `7e35e15f3a78` 作为配套补丁一起回合，降低 suspend/resume 中 PSP master 不存在时的异常风险。
4. 增加 Hygon 平台 S3/S4 电源管理回归用例，至少覆盖：
   - S3 -> 唤醒 -> 关机
   - S3 -> 唤醒 -> 重启
   - 多次 S3 循环后关机
   - S4 -> 唤醒后继续运行
5. 若后续仍有偶发卡死，建议加临时调试日志：
   - `psp_dev_suspend()` / `psp_dev_resume()` 入口与返回值
   - `psp_pci_exit()` / `psp_pci_init()` 入口与返回值
   - `sev_platform_shutdown()` 返回值
   - `__sev_do_cmd_locked()` 中 `cmdresp_reg`、`intsts_reg`、`inten_reg` 的读数
   - `psp->sev_state`、`psp_dead`、`sev_comm_mode`

## 7. 总结

bug610493 的核心链路为：

```text
S3 resume 后 Hygon PSP 状态未恢复
  -> shutdown 阶段 psp_dev_destroy()
  -> sev_platform_shutdown()
  -> SEV_CMD_SHUTDOWN 等不到 PSP command complete
  -> shutdown 进程 D 状态
  -> hung task panic
```

`5.4.18-145` 正常的关键原因是已包含 Hygon PSP suspend/resume 处理，使 S3 后 PSP 中断与 firmware 状态重新初始化，避免关机阶段卡在 `SEV_CMD_SHUTDOWN`。
