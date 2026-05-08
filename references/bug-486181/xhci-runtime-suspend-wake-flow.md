# xHCI Runtime Suspend 下插入 USB 设备的控制器唤醒流程

> 版本: v1.0
> 日期: 2026-05-07
> 内核源码: references/kfocal (Linux 5.x)
> 场景: xHCI 控制器已进入 runtime suspend (D3cold/D3hot)，系统处于 S0，此时插入 USB 设备唤醒控制器

---

## 一、前置条件：Runtime Suspend 阶段的唤醒准备

### 1.1 触发路径

```
用户空间 idle 超时
  → pm_runtime_autosuspend()
    → hcd_pci_runtime_suspend()              // hcd-pci.c:605
      → suspend_common(dev, do_wakeup=true)  // hcd-pci.c:430
        → xhci_pci_suspend(hcd, true)        // xhci-pci.c:519
          → xhci_suspend(xhci, true)         // xhci.c:995
```

### 1.2 端口唤醒位保留

`xhci.c:18`:
```c
#define PORT_WAKE_BITS  (PORT_WKOC_E | PORT_WKDISC_E | PORT_WKCONN_E)
//                                bit27       bit26         bit25
```

`xhci.c:1012-1014` — `do_wakeup=true` 时跳过清除：
```c
if (!do_wakeup)
    xhci_disable_port_wake_on_bits(xhci);
```

因此每个端口 PORTSC 中 `PORT_WKCONN_E (bit25)` 保持置位，允许硬件检测新设备连接并产生唤醒信号。

### 1.3 xHCI 控制器 suspend 操作

`xhci_suspend()` (`xhci.c:995-1111`) 核心步骤：

| 步骤 | 操作 | 代码位置 |
|------|------|----------|
| 1 | 停止 root hub 轮询 `clear_bit(HCD_FLAG_POLL_RH)` | :1018 |
| 2 | 清除 `CMD_RUN`，等待 `STS_HALT` | :1036-1048 |
| 3 | 保存寄存器 `xhci_save_registers()` | :1052 |
| 4 | 设置 `CMD_CSS`（Controller Save State） | :1055-1057 |
| 5 | 等待 `STS_SAVE` 清零（状态保存完成） | :1059-1080 |

### 1.4 PCI 层电源状态转换

`suspend_common()` (`hcd-pci.c:430`) 中：
- `pci_save_state()` 保存 PCI 配置空间
- `pci_prepare_to_sleep()` 将设备转入 D3hot/D3cold
- 同时使能 PME# 信号（通过 `pci_enable_wake` 或 ACPI `_PRW`）

### 1.5 ACPI 唤醒能力注册

PCI 设备 probe 时，`pci_acpi_setup()` (`pci-acpi.c:1275`) 完成：

```c
// pci-acpi.c:1286-1300
pci_acpi_add_pm_notifier(adev, pci_dev);  // 注册 ACPI PM notify handler
if (!adev->wakeup.flags.valid)
    return;
device_set_wakeup_capable(dev, true);     // 标记设备可唤醒
if (pci_dev->bridge_d3)
    device_wakeup_enable(dev);            // 自动使能唤醒
acpi_pci_wakeup(pci_dev, false);          // 初始状态设置
```

其中 `pci_acpi_add_pm_notifier()` (`pci-acpi.c:879`) 注册的回调为 `pci_acpi_wake_dev`：
```c
return acpi_add_pm_notifier(dev, &pci_dev->dev, pci_acpi_wake_dev);
```

ACPI 的 `_PRW` 对象 (`scan.c:779-845`) 在设备扫描时解析，提取：
- `wakeup->gpe_device` — GPE 所属设备句柄
- `wakeup->gpe_number` — GPE 编号
- `wakeup->sleep_state` — 可唤醒的最深睡眠状态

---

## 二、硬件信号链：设备插入 → 唤醒信号

### 2.1 xHCI 端口硬件检测

```
USB 设备插入
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  xHCI Port 硬件自动检测 (xHCI Spec §4.19.2)            │
│                                                          │
│  USB2 端口: 检测 D+ 上拉电阻 → 连接状态变化             │
│  USB3 端口: Rx Detection → 连接状态变化                 │
│                                                          │
│  PORTSC 寄存器硬件自动设置:                              │
│    PORT_CONNECT (bit0)  = 1   设备已连接                 │
│    PORT_CSC (bit17)     = 1   Connect Status Change      │
│    PLS (Port Link State): Disabled → Polling/Rx.Detect   │
│                                                          │
│  由于 PORT_WKCONN_E=1 (bit25)，端口检测到连接后：        │
│    → xHC 内部产生唤醒请求                                │
│    → 向上级发送 PME# 信号                                │
└─────────────────────────────────────────────────────────┘
```

### 2.2 唤醒信号的两条传播路径

```
                    xHC (D3cold)
                        │
                   PME# 信号
                        │
              ┌─────────┴─────────┐
              ▼                   ▼
     ┌────────────────┐  ┌─────────────────────┐
     │  路径A: Native  │  │  路径B: ACPI GPE    │
     │  PCIe PME       │  │  (平台固件路由)      │
     │                 │  │                      │
     │  PME# → PCIe   │  │  PME# → 南桥/PCH    │
     │  Root Port      │  │  → GPE 中断          │
     │  → 中断控制器   │  │  → ACPI 子系统       │
     └────────┬────────┘  └─────────┬───────────┘
              │                     │
              ▼                     ▼
       pcie_pme_irq()        acpi_ev_gpe_dispatch()
              │                     │
              └──────────┬──────────┘
                         ▼
              pm_request_resume(&xhci_dev)
```

两条路径的选择取决于 BIOS/固件配置：
- **Native PCIe PME**: PCIe Root Port 直接捕获 PME#，由内核 PCIe PME 驱动处理
- **ACPI GPE**: 固件将 PME# 路由到 ACPI GPE，由 ACPI 子系统处理

以下分别详述。

---

## 三、路径A：Native PCIe PME 唤醒流程

### 3.1 PME 中断触发

Root Port 的 PCIe PME 中断处理：

**`pcie_pme_irq()` (`pme.c:265-289`)**
```c
irqreturn_t pcie_pme_irq(int irq, void *context)
{
    // 1. 读取 Root Port 的 PCI_EXP_RTSTA 寄存器
    pcie_capability_read_dword(port, PCI_EXP_RTSTA, &rtsta);

    // 2. 检查 PME 状态位
    if (rtsta & PCI_EXP_RTSTA_PME) {
        // 3. 先禁用 PME 中断，防止重复触发
        pcie_pme_interrupt_enable(port, false);
        // 4. 调度 work 队列异步处理
        schedule_work(&data->work);  // → pcie_pme_work_fn
    }
    return IRQ_HANDLED;
}
```

### 3.2 PME Work 处理

**`pcie_pme_work_fn()` (`pme.c:214-258`)**

循环处理所有挂起的 PME 事件：
```c
static void pcie_pme_work_fn(struct work_struct *work)
{
    for (;;) {
        pcie_capability_read_dword(port, PCI_EXP_RTSTA, &rtsta);
        if (rtsta & PCI_EXP_RTSTA_PME) {
            pcie_clear_root_pme_status(port);      // 清除 Root Port PME 状态
            pcie_pme_handle_request(port, rtsta & 0xffff);  // 提取 Requester ID
            continue;
        }
        if (!(rtsta & PCI_EXP_RTSTA_PENDING))
            break;
    }
    pcie_pme_interrupt_enable(port, true);  // 处理完毕，重新使能 PME 中断
}
```

### 3.3 定位唤醒设备

**`pcie_pme_handle_request()` (`pme.c:130-208`)**

用 Root Port 捕获的 Requester ID 定位产生 PME 的设备：
```c
static void pcie_pme_handle_request(struct pci_dev *port, u16 req_id)
{
    u8 busnr = req_id >> 8, devfn = req_id & 0xff;

    // 先检查是否 Root Port 自身产生
    if (port->devfn == devfn && port->bus->number == busnr) {
        if (pci_check_pme_status(port)) {
            pm_request_resume(&port->dev);
            found = true;
        }
        goto out;
    }

    // 按 bus:devfn 查找 xHCI PCI 设备
    bus = pci_find_bus(pci_domain_nr(port->bus), busnr);
    // ... 遍历 bus->devices ...

    if (found) {
        pci_check_pme_status(dev);       // 清除设备的 PME_Status
        pci_wakeup_event(dev);           // 记录 wakeup event
        pm_request_resume(&dev->dev);    // 提交 runtime resume 请求
    }
}
```

---

## 四、路径B：ACPI GPE 唤醒流程（补充）

### 4.1 GPE 硬件触发

当 BIOS/固件将 xHCI 的 PME# 信号路由到 ACPI GPE 而非 Native PCIe PME 时：

```
xHC PME# → 南桥/PCH GPE 引脚 → 触发 SCI (System Control Interrupt)
    → ACPI 中断处理程序 acpi_irq() → acpi_ev_gpe_detect()
```

### 4.2 GPE 事件分发

**`acpi_ev_gpe_dispatch()` (`evgpe.c:748-847`)**

这是所有 GPE 事件的核心分发函数：

```c
u32 acpi_ev_gpe_dispatch(struct acpi_namespace_node *gpe_device,
                         struct acpi_gpe_event_info *gpe_event_info,
                         u32 gpe_number)
{
    // 1. 立即禁用该 GPE，防止持续触发
    status = acpi_hw_low_set_gpe(gpe_event_info, ACPI_GPE_DISABLE);  // :765

    // 2. 边沿触发：立即清除状态位
    if (ACPI_GPE_EDGE_TRIGGERED)
        acpi_hw_clear_gpe(gpe_event_info);  // :778

    // 3. 根据调度类型分发
    switch (ACPI_GPE_DISPATCH_TYPE(gpe_event_info->flags)) {

    case ACPI_GPE_DISPATCH_HANDLER:
        // 直接调用已注册的 handler（在中断上下文）
        return_value = gpe_event_info->dispatch.handler->address(
            gpe_device, gpe_number,
            gpe_event_info->dispatch.handler->context);  // :803-808
        break;

    case ACPI_GPE_DISPATCH_METHOD:
        // 异步执行 ACPI _Lxx/_Exx 方法
        acpi_os_execute(OSL_GPE_HANDLER,
                        acpi_ev_asynch_execute_gpe_method,
                        gpe_event_info);  // :823-825
        break;

    case ACPI_GPE_DISPATCH_NOTIFY:
        // 异步发送 Implicit Notify
        acpi_os_execute(OSL_GPE_HANDLER,
                        acpi_ev_asynch_execute_gpe_method,
                        gpe_event_info);  // :823-825
        break;
    }
}
```

### 4.3 GPE 异步处理

**`acpi_ev_asynch_execute_gpe_method()` (`evgpe.c:455-535`)**

在工作队列中异步执行：

```c
static void ACPI_SYSTEM_X_FACE acpi_ev_asynch_execute_gpe_method(void *context)
{
    switch (ACPI_GPE_DISPATCH_TYPE(gpe_event_info->flags)) {

    case ACPI_GPE_DISPATCH_NOTIFY:
        // 向关联的设备发送 ACPI_NOTIFY_DEVICE_WAKE (0x02)
        notify = gpe_event_info->dispatch.notify_list;
        while (notify) {
            acpi_ev_queue_notify_request(
                notify->device_node,
                ACPI_NOTIFY_DEVICE_WAKE);  // :481-483
            notify = notify->next;
        }
        break;

    case ACPI_GPE_DISPATCH_METHOD:
        // 执行 ASL _Lxx (Level) 或 _Exx (Edge) 方法
        info->prefix_node = gpe_event_info->dispatch.method_node;
        acpi_ns_evaluate(info);  // :506
        break;
    }

    // 处理完毕后重新使能 GPE
    acpi_os_execute(OSL_NOTIFY_HANDLER,
                    acpi_ev_asynch_enable_gpe, gpe_event_info);  // :526-527
}
```

### 4.4 设备唤醒 Notify 处理

`acpi_ev_queue_notify_request()` 将 `ACPI_NOTIFY_DEVICE_WAKE` 排队后，最终到达注册的 notify handler。

**`acpi_pm_notify_handler()` (`device_pm.c:464-492`)** — 这是在 `pci_acpi_setup()` 时通过 `acpi_add_pm_notifier()` 注册的：

```c
static void acpi_pm_notify_handler(acpi_handle handle, u32 val, void *not_used)
{
    if (val != ACPI_NOTIFY_DEVICE_WAKE)
        return;

    adev = acpi_bus_get_acpi_device(handle);

    mutex_lock(&acpi_pm_notifier_lock);
    if (adev->wakeup.flags.notifier_present) {
        // 1. 记录 wakeup source 事件
        pm_wakeup_ws_event(adev->wakeup.ws, 0, acpi_s2idle_wakeup());  // :480

        // 2. 调用注册的回调函数
        if (adev->wakeup.context.func) {
            adev->wakeup.context.func(&adev->wakeup.context);  // :485
        }
    }
    mutex_unlock(&acpi_pm_notifier_lock);
}
```

### 4.5 PCI 设备唤醒回调

对于 PCI 设备，`wakeup.context.func` 就是 **`pci_acpi_wake_dev()`** (`pci-acpi.c:840-863`)：

```c
static void pci_acpi_wake_dev(struct acpi_device_wakeup_context *context)
{
    struct pci_dev *pci_dev = to_pci_dev(context->dev);

    if (pci_dev->pme_poll)
        pci_dev->pme_poll = false;              // 停止 PME 轮询

    if (pci_dev->current_state == PCI_D3cold) {
        pci_wakeup_event(pci_dev);              // 记录 wakeup event
        pm_request_resume(&pci_dev->dev);       // 请求 runtime resume
        return;
    }

    // 非 D3cold：还需要检查并清除 PME Status
    if (pci_dev->pme_support)
        pci_check_pme_status(pci_dev);          // :856-857

    pci_wakeup_event(pci_dev);
    pm_request_resume(&pci_dev->dev);           // 请求 runtime resume

    pci_pme_wakeup_bus(pci_dev->subordinate);   // 唤醒子总线上的设备
}
```

### 4.6 ACPI GPE 路径完整调用链

```
┌─ 硬件层 ────────────────────────────────────────────────────┐
│  USB 设备插入 → xHC 端口检测 → PORTSC.CSC=1                │
│  → PORT_WKCONN_E 触发 → xHC 产生 PME#                     │
│  → 南桥/PCH 将 PME# 路由到 GPE 引脚                       │
│  → 触发 SCI 中断                                           │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌─ ACPI ACPICA 层 ───────────────────────────────────────────┐
│  acpi_ev_gpe_detect()                                       │
│    → 扫描 GPE 状态寄存器，发现已使能且置位的 GPE           │
│    → acpi_ev_gpe_dispatch(gpe_device, gpe_event_info, n)    │
│        │                                                    │
│        ├─ 禁用 GPE (ACPI_GPE_DISABLE)       // evgpe.c:765 │
│        ├─ 边沿触发则清除状态位                // evgpe.c:778 │
│        │                                                    │
│        ├─ DISPATCH_HANDLER: 直接调用 handler                │
│        │                                                    │
│        ├─ DISPATCH_METHOD:                                  │
│        │    acpi_os_execute(acpi_ev_asynch_execute_gpe_method)│
│        │      → acpi_ns_evaluate() 执行 _Lxx/_Exx          │
│        │                                                    │
│        └─ DISPATCH_NOTIFY:                                  │
│             acpi_os_execute(acpi_ev_asynch_execute_gpe_method)│
│               → acpi_ev_queue_notify_request(               │
│                     node, ACPI_NOTIFY_DEVICE_WAKE)          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌─ ACPI PM 层 ───────────────────────────────────────────────┐
│  Notify 0x02 (DEVICE_WAKE) 到达                             │
│    → acpi_pm_notify_handler()              // device_pm.c:464│
│        │                                                    │
│        ├─ pm_wakeup_ws_event()   // 记录 wakeup source     │
│        │                                                    │
│        └─ adev->wakeup.context.func(&context)               │
│             → pci_acpi_wake_dev()          // pci-acpi.c:840│
│                 │                                           │
│                 ├─ pci_dev->pme_poll = false                │
│                 ├─ D3cold 分支:                              │
│                 │    pci_wakeup_event(pci_dev)               │
│                 │    pm_request_resume(&pci_dev->dev)        │
│                 │                                           │
│                 └─ 非 D3cold 分支:                           │
│                      pci_check_pme_status(pci_dev)           │
│                      pci_wakeup_event(pci_dev)               │
│                      pm_request_resume(&pci_dev->dev)        │
│                      pci_pme_wakeup_bus(subordinate)         │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                   pm_request_resume()
                  (进入共同的 Resume 流程)
```

---

## 五、共同的 Resume 流程

两条路径最终都调用 `pm_request_resume(&xhci_pdev->dev)`，此后流程完全相同。

### 5.1 PCI Runtime Resume

```
pm_request_resume(&xhci_pdev->dev)
    → pm_runtime_resume()
      → dev->driver->pm->runtime_resume()
        → hcd_pci_runtime_resume()                   // hcd-pci.c:616
          → resume_common(dev, PM_EVENT_AUTO_RESUME) // hcd-pci.c:485
```

**`resume_common()` (`hcd-pci.c:485-524`)**：

```c
static int resume_common(struct device *dev, int event)
{
    retval = pci_enable_device(pci_dev);     // PCI 设备从 D3 回到 D0
    pci_set_master(pci_dev);                 // 恢复 bus master 能力

    if (hcd->driver->pci_resume && !HCD_DEAD(hcd)) {
        retval = hcd->driver->pci_resume(hcd,
                    event == PM_EVENT_RESTORE);  // → xhci_pci_resume
    }
}
```

### 5.2 xHCI Controller Resume

**`xhci_pci_resume()` (`xhci-pci.c:545-580`) → `xhci_resume()` (`xhci.c:1120-1297`)**

```
xhci_pci_resume(hcd, hibernated=false)
    → xhci_resume(xhci, hibernated=false)
```

核心步骤：

```
 ┌─ xhci_resume() ─────────────────────────────────────────────────┐
 │                                                                  │
 │  ① 设置 HW_ACCESSIBLE 标志                        // :1145      │
 │     set_bit(HCD_FLAG_HW_ACCESSIBLE, &hcd->flags);               │
 │                                                                  │
 │  ② 等待 Controller Not Ready 清除（最多10秒）      // :1158      │
 │     xhci_handshake(STS_CNR, 0, 10*1000*1000)                    │
 │                                                                  │
 │  ③ 恢复保存的寄存器                                // :1167      │
 │     xhci_restore_registers(xhci)                                 │
 │                                                                  │
 │  ④ 设置命令环 Dequeue 指针                         // :1169      │
 │     xhci_set_cmd_ring_deq(xhci)                                  │
 │                                                                  │
 │  ⑤ Controller Restore State (CRS)                  // :1172      │
 │     command |= CMD_CRS;                                          │
 │     writel(command, &xhci->op_regs->command);                    │
 │     等待 STS_RESTORE 清零（最多100ms）               // :1180      │
 │                                                                  │
 │  ⑥ 设置 CMD_RUN 启动控制器                         // :1247      │
 │     command |= CMD_RUN;                                          │
 │     等待 STS_HALT 清零                               // :1249      │
 │                                                                  │
 │  ⑦ 检查挂起的端口事件                               // :1268      │
 │     if (xhci_pending_portevent(xhci)) {                          │
 │         usb_hcd_resume_root_hub(shared_hcd);  // USB3 roothub   │
 │         usb_hcd_resume_root_hub(hcd);         // USB2 roothub   │
 │     }                                                            │
 │                                                                  │
 │  ⑧ 重新启动端口轮询                                // :1288-1294 │
 │     set_bit(HCD_FLAG_POLL_RH, &hcd->flags);                     │
 │     usb_hcd_poll_rh_status(hcd);                                 │
 │                                                                  │
 └──────────────────────────────────────────────────────────────────┘
```

### 5.3 端口事件检测

**`xhci_pending_portevent()` (`xhci.c:954-987`)** — 检测到插入事件的关键函数：

```c
static bool xhci_pending_portevent(struct xhci_hcd *xhci)
{
    // 先检查 USBSTS 的 EINT 位
    status = readl(&xhci->op_regs->status);
    if (status & STS_EINT)
        return true;

    // xHCI spec §4.19.2 注意事项:
    // change bit 置位和 Port Status Change Event 写入 Event Ring 之间有延迟
    // 因此必须额外扫描 PORTSC

    // 扫描所有 USB2 端口
    for (usb2 ports) {
        portsc = readl(ports[port_index]->addr);
        if (portsc & PORT_CHANGE_MASK ||        // CSC|PEC|WRC|OCC|RC|PLC|CEC
            (portsc & PORT_PLS_MASK) == XDEV_RESUME)
            return true;
    }
    // 扫描所有 USB3 端口（逻辑相同）
    for (usb3 ports) { ... }

    return false;
}
```

此时插入设备的端口 PORTSC 中：
- **PORT_CSC (bit17) = 1** — 连接状态已变化
- **PORT_CONNECT (bit0) = 1** — 设备已连接
- `PORT_CHANGE_MASK` 匹配成功 → 返回 `true`

### 5.4 Root Hub 恢复与设备枚举

`usb_hcd_resume_root_hub()` 唤醒 khubd 内核线程：

**`xhci_hub_status_data()` (`xhci-hub.c:1490-1547`)** — khubd 调用，读取端口变化：

```c
int xhci_hub_status_data(struct usb_hcd *hcd, char *buf)
{
    mask = PORT_CSC | PORT_PEC | PORT_OCC | PORT_PLC | PORT_WRC | PORT_CEC;

    for (i = 0; i < max_ports; i++) {
        temp = readl(ports[i]->addr);          // 读 PORTSC
        if ((temp & mask) != 0) {
            buf[(i + 1) / 8] |= 1 << (i + 1) % 8;  // 置位对应端口 bit
            status = 1;
        }
    }
    return status ? retval : 0;  // 通知 usbcore 有变化
}
```

USB core hub driver 检测到变化后：
1. `GetPortStatus` → 读取 PORTSC 详细状态
2. `ClearPortFeature(PORT_FEAT_C_CONNECTION)` → 写 PORTSC 清除 PORT_CSC (RW1C)
3. `hub_port_connect()` → 进入标准枚举流程

---

## 六、PORTSC 寄存器变化时序

| 时刻 | PORT_CONNECT<br>(bit0) | PORT_CSC<br>(bit17) | PORT_PE<br>(bit1) | PLS | PORT_WKCONN_E<br>(bit25) |
|------|:---:|:---:|:---:|:---:|:---:|
| Runtime Suspend 前 | 0 | 0 | 0 | Disabled | 1 |
| 设备插入（硬件自动） | **1** | **1** | 0 | Polling | 1 |
| xHCI Resume 完成 | 1 | 1 | 0 | Rx.Detect | 1 |
| khubd GetPortStatus | 1 | 1 | 0 | Enabled/U0 | 1 |
| ClearPortFeature | 1 | **0**(W1C) | 0 | Enabled/U0 | 1 |
| Port Reset 完成 | 1 | 0 | **1** | U0 (USB3) | 1 |

注: PORT_CSC 为 Write-1-to-Clear (RW1C) 位。

---

## 七、两条路径对比

| 维度 | Native PCIe PME | ACPI GPE |
|------|-----------------|----------|
| 触发源 | PCIe Root Port 捕获 PME# | 南桥/PCH 将 PME# 路由到 GPE |
| 中断入口 | `pcie_pme_irq()` | SCI → `acpi_ev_gpe_detect()` |
| 设备定位 | Root Port RTSTA 的 Requester ID | GPE → `_PRW` 映射 → ACPI Device |
| 处理线程 | `pcie_pme_work_fn` (work queue) | `acpi_ev_asynch_execute_gpe_method` (kthread) |
| PME状态清除 | `pci_check_pme_status()` | `pci_acpi_wake_dev()` 内 `pci_check_pme_status()` |
| Resume请求 | `pm_request_resume()` | `pm_request_resume()` |
| 适用场景 | PCIe Native PME 开启 | BIOS 覆盖 PME 路由到 GPE |
| 可配置性 | `pcie_aspm=` / `pci=nomsi` | ACPI 表 (_PRW, _Lxx/_Exx) |
| Resume 后续 | 完全相同 | 完全相同 |

---

## 八、完整端到端流程图

```
 USB设备插入
      │
      ▼
 xHC Port硬件: PORTSC.CSC=1, PORT_CONNECT=1
 PORT_WKCONN_E=1 → xHC产生PME#
      │
      ├──────────────────────┬───────────────────────┐
      ▼                      ▼                       │
 ┌─────────────┐      ┌──────────────┐               │
 │ Native PME  │      │  ACPI GPE    │               │
 │             │      │              │               │
 │ Root Port   │      │ SCI → GPE   │               │
 │ RTSTA.PME=1 │      │ detect      │               │
 │             │      │              │               │
 │ pcie_pme_   │      │ ev_gpe_     │               │
 │ irq()       │      │ dispatch()  │               │
 │             │      │              │               │
 │ schedule_   │      │ DISPATCH_   │               │
 │ work()      │      │ NOTIFY/METHOD│               │
 │             │      │              │               │
 │ pcie_pme_   │      │ asynch_     │               │
 │ work_fn()   │      │ execute_gpe │               │
 │             │      │ _method()   │               │
 │ pcie_pme_   │      │              │               │
 │ handle_     │      │ NOTIFY=     │               │
 │ request()   │      │ DEVICE_WAKE │               │
 │             │      │              │               │
 │ pci_check_  │      │ acpi_pm_    │               │
 │ pme_status()│      │ notify_     │               │
 │             │      │ handler()   │               │
 │             │      │              │               │
 │ pm_request_ │      │ pci_acpi_   │               │
 │ resume()    │      │ wake_dev()  │               │
 └──────┬──────┘      │              │               │
        │             │ pm_request_  │               │
        │             │ resume()     │               │
        │             └──────┬───────┘               │
        │                    │                       │
        └────────┬───────────┘                       │
                 ▼                                   │
        pm_runtime_resume()                          │
                 │                                   │
                 ▼                                   │
        hcd_pci_runtime_resume()                     │
          → resume_common()                          │
            → pci_enable_device()  [D3→D0]           │
            → pci_set_master()                       │
            → xhci_pci_resume()                      │
              → xhci_resume()                        │
                │                                    │
                ├─ xhci_restore_registers()          │
                ├─ CMD_CRS (恢复控制器状态)           │
                ├─ CMD_RUN  (启动控制器)              │
                │                                    │
                ├─ xhci_pending_portevent()  ◄───────┘
                │     → PORT_CSC=1 → return true
                │
                ├─ usb_hcd_resume_root_hub()
                │     → 唤醒 khubd
                │
                └─ 重新启动端口轮询
                     │
                     ▼
              khubd: hub_events()
                │
                ├─ xhci_hub_status_data()
                │    → 读PORTSC, 返回变化端口bitmap
                │
                ├─ GetPortStatus
                │    → 读取 PORT_CONNECT=1, PORT_CSC=1
                │
                ├─ ClearPortFeature(C_CONNECTION)
                │    → 清除 PORT_CSC (W1C)
                │
                └─ hub_port_connect()
                     → Port Reset → Set Address
                     → Get Descriptor → 加载驱动
```

---

## 九、关键源码文件索引

| 文件 | 关键函数 | 职责 |
|------|---------|------|
| `drivers/usb/host/xhci.c` | `xhci_suspend()`, `xhci_resume()`, `xhci_pending_portevent()` | xHC 挂起/恢复 |
| `drivers/usb/host/xhci-pci.c` | `xhci_pci_suspend()`, `xhci_pci_resume()`, `xhci_pme_quirk()` | PCI 层 glue |
| `drivers/usb/host/xhci-hub.c` | `xhci_hub_status_data()`, `xhci_bus_suspend()` | 端口状态/Hub |
| `drivers/usb/host/xhci-ring.c` | `handle_port_status()` | 端口状态变化事件处理 |
| `drivers/usb/host/xhci.h` | PORT_* 位定义, PORT_WAKE_BITS | 寄存器宏定义 |
| `drivers/usb/core/hcd-pci.c` | `suspend_common()`, `resume_common()`, `hcd_pci_runtime_*` | USB PCI PM 框架 |
| `drivers/pci/pcie/pme.c` | `pcie_pme_irq()`, `pcie_pme_work_fn()`, `pcie_pme_handle_request()` | Native PCIe PME |
| `drivers/pci/pci-acpi.c` | `pci_acpi_wake_dev()`, `pci_acpi_setup()`, `acpi_pci_wakeup()` | PCI-ACPI 唤醒桥接 |
| `drivers/acpi/acpica/evgpe.c` | `acpi_ev_gpe_dispatch()`, `acpi_ev_asynch_execute_gpe_method()` | GPE 核心分发 |
| `drivers/acpi/device_pm.c` | `acpi_pm_notify_handler()`, `acpi_add_pm_notifier()` | ACPI PM notify |
| `drivers/acpi/scan.c` | `_PRW` 解析, `acpi_bus_get_wakeup_device_flags()` | ACPI 设备唤醒能力发现 |
| `drivers/acpi/wakeup.c` | `acpi_enable_wakeup_devices()`, `acpi_disable_wakeup_devices()` | S-state 唤醒设备管理 |
