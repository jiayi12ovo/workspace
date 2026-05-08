# [Bug-526691] Zhaoxin KX-7000平台热重启后xHCI控制器僵死导致USB设备丢失的分析

> **文档版本**：v1.0
> **生成日期**：2026-04-20
> **变更摘要**：初始版本，基于排查对话与dmesg日志生成完整知识库文档。
> **基于内核版本**：5.4.18-142-generic
> **涉及硬件/平台**：Zhaoxin KX-7000 (ZXE CRB)
>
> **版本历史**：
>
> | 版本 | 日期 | 变更摘要 |
> |------|------|----------|
> | v1.0 | 2026-04-20 | 初始版本，基于排查对话与dmesg日志生成完整知识库文档 |

---

## 1. 故障现象与背景

在Zhaoxin KX-7000平台（机型：Shanghai Zhaoxin Semiconductor Co., Ltd. ZXE CRB）上进行系统热重启（Warm Reboot）压力测试时，偶发性出现重启后所有USB设备全部丢失的现象。测试环境为Kylin-Desktop-V10-SP1系统，内核版本5.4.18-142-generic。测试期望重启1000次无掉设备现象，但在实际执行中低概率触发该故障。

故障发生后，`lsusb`无法检测到任何USB设备，xHCI控制器（PCI地址0000:00:12.0）在`lspci`中仍可见，但对应的`xhci_hcd`驱动未成功绑定，表明控制器处于不可用状态。

## 2. 问题排查与源码解析

### 2.1 日志分析

通过分析故障现场的dmesg日志，xHCI控制器在内核初始化的极早期阶段（约0.37秒）即报错：

```text
[    0.368096] kernel: pci 0000:00:12.0: xHCI HW did not halt within 16000 usec status = 0x1018
[    0.368211] kernel: pci 0000:00:12.0: quirk_usb_early_handoff+0x0/0x674 took 15780 usecs
```

随后在驱动加载阶段（约0.64秒）再次失败：

```text
[    0.624154] kernel: xhci_hcd 0000:00:12.0: xHCI Host Controller
[    0.624163] kernel: xhci_hcd 0000:00:12.0: new USB bus registered, assigned bus number 1
[    0.640172] kernel: xhci_hcd 0000:00:12.0: Host halt failed, -110
[    0.640173] kernel: xhci_hcd 0000:00:12.0: can't setup: -110
[    0.640176] kernel: xhci_hcd 0000:00:12.0: USB bus 1 deregistered
[    0.640282] kernel: xhci_hcd 0000:00:12.0: init 0000:00:12.0 fail, -110
[    0.640432] kernel: xhci_hcd: probe of 0000:00:12.0 failed with error -110
```

**关键标注：**

- **status = 0x1018**：xHCI `USBSTS`寄存器值，逐位解析如下：
  - Bit 3 (EINT = 1)：事件中断挂起
  - Bit 4 (PCD = 1)：端口变化检测挂起
  - **Bit 12 (HCE = 1)**：Host Controller Error，这是核心错误标志。根据xHCI规范，此位置1表示控制器内部检测到不可恢复的错误，控制器可能停止响应常规的运行/停止命令。
- **-110**：Linux内核错误码`ETIMEDOUT`，表示操作超时。

### 2.2 内核机制定位

第一阶段报错源自`drivers/usb/host/pci-quirks.c`中的`quirk_usb_handoff_xhci()`函数。该函数在内核早期PCI设备枚举阶段被调用，负责从BIOS手中接管xHCI控制器：

```c
/* drivers/usb/host/pci-quirks.c */
static void quirk_usb_handoff_xhci(struct pci_dev *pdev)
{
    ...
    /* Send the halt and disable interrupts command */
    val = readl(op_reg_base + XHCI_CMD_OFFSET);
    val &= ~(XHCI_CMD_RUN | XHCI_IRQS);
    writel(val, op_reg_base + XHCI_CMD_OFFSET);

    /* Wait for the HC to halt - poll every 125 usec (one microframe). */
    timeout = handshake(op_reg_base + XHCI_STS_OFFSET, XHCI_STS_HALT, 1,
            XHCI_MAX_HALT_USEC, 125);
    if (timeout) {
        val = readl(op_reg_base + XHCI_STS_OFFSET);
        dev_warn(&pdev->dev,
             "xHCI HW did not halt within %d usec status = 0x%x\n",
             XHCI_MAX_HALT_USEC, val);
    }
    ...
}
```

该函数的逻辑是：清除`USBCMD`寄存器的`RUN`位，然后通过`handshake()`轮询等待`USBSTS`的`HCHalted`位置1，超时上限为16000微秒（`XHCI_MAX_HALT_USEC`）。

**问题所在**：当控制器处于HCE错误状态时，它无法响应标准的停止命令，`handshake()`必然超时。而函数在超时后仅打印一条警告，**并未尝试通过`CMD_RESET`（HCRST）强制复位控制器**，导致硬件持续处于僵死状态。

第二阶段报错源自`xhci_hcd`驱动的probe流程。`xhci_setup_hc()`再次尝试halt控制器，依然超时，最终probe以`-110`失败返回。

## 3. 关联知识梳理与底层协议背景

### 3.1 xHCI控制器状态机与复位流程

根据xHCI Specification (Revision 1.2) 第4.2节，控制器状态转换遵循以下规则：

- **正常运行 → HCHalted**：软件清除`USBCMD.RS`（Run/Stop）位后，控制器应在16ms内停止所有调度活动，并将`USBSTS.HCH`（HCHalted）置1。
- **Host Controller Error (HCE)**：当此位被硬件置1时，表示控制器内部发生了不可恢复的错误。规范明确要求软件必须通过设置`USBCMD.HCRST`（Host Controller Reset）位来复位控制器，或执行更高级别的硬件复位（如PCI Reset、Power-On Reset）。
- **复位后的状态**：`HCRST`操作会清除控制器内部所有运行时状态，将寄存器恢复到默认值。复位完成后，`HCRST`位由硬件自动清零，`USBSTS.HCH`置1（控制器处于已停止的干净状态），此时驱动可正常接管初始化。

### 3.2 Linux内核xHCI接管流程

在正常的Linux启动流程中，xHCI控制器的接管分为两个阶段：

1. **早期接管（pci-quirks阶段）**：在PCI设备枚举期间，`quirk_usb_handoff_xhci()`负责从BIOS手中获取控制权。该函数向BIOS发送所有权转移请求，然后尝试halt控制器。
2. **驱动初始化（xhci_hcd阶段）**：`xhci_hcd`驱动probe时，再次halt控制器，然后执行`xhci_reset()`，分配Ring、Context等数据结构，完成控制器初始化。

**关键设计缺陷**：`quirk_usb_handoff_xhci()`假设控制器总是能正常响应halt命令，缺少对HCE状态的容错处理。在warm reboot场景下，如果前一系统中控制器进入了错误状态，而BIOS在重启过程中未执行硬件复位，接管函数将面对一个无法halt的僵死控制器。

## 4. 结论与解决方案

**根本原因（Root Cause）：**

在Zhaoxin KX-7000平台上进行warm reboot时，xHCI控制器被留置在`HCE=1`的内部错误状态。内核早期的`pci-quirks`接管机制（`quirk_usb_handoff_xhci()`）仅尝试通过清除RUN位来停止控制器，未在halt失败时对处于HCE状态的控制器执行`CMD_RESET`强制复位，导致硬件从接管阶段起即处于不可用状态，后续`xhci_hcd`驱动初始化必然失败，所有USB设备丢失。

该问题的偶发性源于HCE状态并非每次warm reboot都会触发，其触发与重启前控制器的工作负载、内部微码状态以及BIOS在重启流程中是否执行了PCI Reset等因素相关。

**解决方案（Solution / Workaround）：**

1. **内核补丁（推荐方案）**：在`drivers/usb/host/pci-quirks.c`的`quirk_usb_handoff_xhci()`函数中，针对halt失败且`HCE=1`的情况，增加强制复位逻辑。对于Zhaoxin厂商的控制器，该逻辑应作为quirk专门应用：

```c
if (timeout) {
    val = readl(op_reg_base + XHCI_STS_OFFSET);
    dev_warn(&pdev->dev,
         "xHCI HW did not halt within %d usec status = 0x%x\n",
         XHCI_MAX_HALT_USEC, val);

    /* 如果控制器报告HCE且为Zhaoxin设备, 强制复位 */
    if ((val & XHCI_STS_HCE) &&
        (pdev->vendor == PCI_VENDOR_ID_ZHAOXIN)) {
        val = readl(op_reg_base + XHCI_CMD_OFFSET);
        writel(val | XHCI_CMD_RESET, op_reg_base + XHCI_CMD_OFFSET);
        /* 等待复位完成, HCRST位由硬件自动清零 */
        handshake(op_reg_base + XHCI_CMD_OFFSET,
                  XHCI_CMD_RESET, 0, 1000000, 125);
    }
}
```

2. **BIOS侧优化**：建议BIOS厂商在系统启动（特别是从warm reboot路径启动）时，对xHCI控制器执行完整的硬件复位或通过`HCRST`进行控制器初始化，确保交给OS的控制器处于干净的初始状态。

3. **短期规避方案**：在内核启动参数中添加`pci=realloc`，该参数会触发PCI资源的重新分配，在某些情况下可间接促成控制器的复位。另外，冷启动（断电重启）可触发硬件的Power-On Reset，从而规避该问题，适用于非压力测试的生产恢复场景。
