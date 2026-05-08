# xHCI Runtime Suspend 下 S0 插入 USB 设备的唤醒流程

## 1. 场景和结论

本文基于 `references/kfocal/kfocal` 内核源码，整理系统仍处于 ACPI S0 工作态时，xHCI 控制器已经进入 runtime suspend，随后插入 USB 设备并唤醒控制器的硬件和软件流程。

需要先区分两个概念：

- 系统处于 S0，不是从 S3/S4/S5 唤醒整机。
- xHCI 作为 PCI/PCIe 设备可能处于 runtime D3hot/D3cold，需要被端口事件、PME 或 ACPI GPE 拉回 D0。

总体路径如下：

```text
插入 USB 设备
  -> xHCI root port PORTSC 变化，例如 PORT_CONNECT / PORT_CSC
  -> 端口 wake 条件命中，例如 PORT_WKCONN_E
  -> 控制器/平台产生 runtime wake 信号
     -> 路径 A: PCIe native PME interrupt
     -> 路径 B: ACPI _PRW GPE / SCI / Notify(DeviceWake)
  -> PCI PM core 对 xHCI 执行 runtime resume
  -> xhci_resume() 恢复 xHC state 并重启 CMD_RUN
  -> xHCI/USB core 读取并清理 PORTSC change bits
  -> hub_event() 执行端口 debounce、reset、枚举新设备
```

## 2. Runtime Suspend 前置配置

### 2.1 root hub bus suspend 配置端口 wake 位

xHCI root hub 进入 bus suspend 时，驱动会在 `PORTSC` 中配置端口唤醒位。关键代码在：

- `drivers/usb/host/xhci-hub.c:xhci_bus_suspend()`
- `drivers/usb/host/xhci.h` 中定义 `PORT_WKCONN_E`、`PORT_WKDISC_E`、`PORT_WKOC_E`

逻辑要点：

- 如果端口当前没有连接设备，设置 `PORT_WKCONN_E`，用于 wake on connect。
- 如果端口当前已有设备，设置 `PORT_WKDISC_E`，用于 wake on disconnect。
- 通常还设置 `PORT_WKOC_E`，用于 over-current wake。

源码对应：

```text
xhci_bus_suspend()
  wake_enabled = hcd->self.root_hub->do_remote_wakeup
  if (wake_enabled) {
      if (PORT_CONNECT)
          set PORT_WKOC_E | PORT_WKDISC_E
      else
          set PORT_WKOC_E | PORT_WKCONN_E
  }
```

这一步决定了 S0 runtime suspend 后，空端口插入设备能否作为运行时唤醒源。

### 2.2 HCD runtime suspend

PCI HCD 的 runtime suspend 入口在：

- `drivers/usb/core/hcd-pci.c:hcd_pci_runtime_suspend()`
- `drivers/usb/core/hcd-pci.c:suspend_common(dev, true)`

`hcd_pci_runtime_suspend()` 调用：

```text
hcd_pci_runtime_suspend()
  -> suspend_common(dev, true)
     -> check_root_hub_suspended()
     -> hcd->driver->pci_suspend(hcd, do_wakeup)
        -> xhci_pci_suspend()
           -> xhci_suspend(xhci, do_wakeup)
     -> pci_disable_device()
```

其中 `do_wakeup` 固定为 `true`，表示 runtime suspend 场景允许控制器被运行时事件唤醒。

### 2.3 xHCI 控制器级 suspend

xHCI 具体 suspend 在：

- `drivers/usb/host/xhci-pci.c:xhci_pci_suspend()`
- `drivers/usb/host/xhci.c:xhci_suspend()`

`xhci_suspend()` 的关键步骤：

```text
xhci_suspend()
  -> 停止 root hub polling
  -> clear HCD_FLAG_HW_ACCESSIBLE
  -> 清 USBCMD.CMD_RUN
  -> 等待 USBSTS.STS_HALT
  -> 保存 xHC registers/state
  -> 置 USBCMD.CMD_CSS，触发 controller save state
  -> 等待 USBSTS.STS_SAVE 清除
  -> 同步 MSI-X IRQ
```

从这个点开始，驱动侧认为 MMIO 不再可访问，真正的恢复需要先经过 PCI runtime resume。

### 2.4 PCI runtime suspend 配置 PME / ACPI wake

PCI core 的 runtime suspend 路径在：

- `drivers/pci/pci-driver.c:pci_pm_runtime_suspend()`
- `drivers/pci/pci.c:pci_finish_runtime_suspend()`

关键逻辑：

```text
pci_pm_runtime_suspend()
  -> driver runtime_suspend，也就是 hcd_pci_runtime_suspend()
  -> pci_save_state()
  -> pci_finish_runtime_suspend()

pci_finish_runtime_suspend()
  -> pci_target_state(dev, device_can_wakeup(&dev->dev))
  -> __pci_enable_wake(dev, target_state, pci_dev_run_wake(dev))
  -> pci_set_power_state(dev, target_state)
```

`__pci_enable_wake()` 会做两件事：

- 如果设备支持对应电源态 PME，调用 `pci_pme_active(dev, true)`，设置 PMCSR 中的 `PME_Enable`，并清 `PME_Status`。
- 调用 `platform_pci_set_wakeup(dev, true)`，在 ACPI 平台上对应 `acpi_pci_wakeup()`，可能启用设备或上游 bridge 的 GPE wake。

注意：runtime wake 使用 `pci_dev_run_wake()` 判断运行时唤醒能力，不完全等同于系统睡眠的 `device_may_wakeup()` 策略。

## 3. 插入 USB 设备后的 PORTSC 变化

设备插入空 root port 后，xHC 端口逻辑检测到连接变化。

常见 `PORTSC` 位变化：

- `PORT_CONNECT` 置 1：端口检测到连接。
- `PORT_CSC` 置 1：connect status change。
- USB3 端口还可能出现 `PORT_PLC`：port link status change。
- 如果链路配置失败，可能出现 `PORT_CEC`：config error change。

位定义在：

- `drivers/usb/host/xhci.h`

关键定义：

```text
PORT_CONNECT  bit 0
PORT_PE       bit 1
PORT_PLS_MASK bits 5:8
PORT_CSC      bit 17
PORT_PLC      bit 22
PORT_CEC      bit 23
PORT_WKCONN_E bit 25
PORT_WKDISC_E bit 26
PORT_WKOC_E   bit 27
```

因为 suspend 前空端口设置了 `PORT_WKCONN_E`，连接状态变化会命中 wake 条件。之后硬件将 wake 信号向上游传播，具体可能表现为 PCIe PME，也可能表现为 ACPI GPE。

## 4. 路径 A：PCIe Native PME Interrupt

如果平台使用 OS native PME，xHCI 产生 PME 后，Root Port 收到 PCIe PME Message：

```text
xHCI PMCSR.PME_Status = 1
  -> PCIe PME Message
  -> Root Port Root Status.PME = 1
  -> Root Port PME IRQ
```

内核处理入口：

- `drivers/pci/pcie/pme.c:pcie_pme_irq()`
- `drivers/pci/pcie/pme.c:pcie_pme_work_fn()`
- `drivers/pci/pcie/pme.c:pcie_pme_handle_request()`

软件流程：

```text
pcie_pme_irq()
  -> read Root Status
  -> if Root Status PME set:
       pcie_pme_interrupt_enable(port, false)
       schedule_work(&data->work)

pcie_pme_work_fn()
  -> read Root Status
  -> pcie_clear_root_pme_status(port)
  -> pcie_pme_handle_request(port, requester_id)

pcie_pme_handle_request()
  -> 根据 Requester ID 找到 xHCI pci_dev
  -> pci_check_pme_status(dev)
       - 检查并清 PMCSR.PME_Status
       - 关闭 PMCSR.PME_Enable 防止中断风暴
  -> pci_wakeup_event(dev)
  -> pm_request_resume(&dev->dev)
```

如果 Requester ID 指向 Root Port 自身，代码会先检查 Root Port PME status；如果不是 Root Port 自身，则根据 bus/devfn 找 PME source。若无法直接定位，还会扫描 subordinate bus。

## 5. 路径 B：ACPI GPE / SCI / Notify

如果平台使用 ACPI `_PRW`/GPE 报告 wake，runtime suspend 期间 PCI core 会通过平台 PM ops 启用 ACPI wake。

### 5.1 启用 GPE

相关代码：

- `drivers/pci/pci.c:__pci_enable_wake()`
- `drivers/pci/pci-acpi.c:acpi_pci_wakeup()`
- `drivers/acpi/device_pm.c:__acpi_device_wakeup_enable()`

流程：

```text
__pci_enable_wake(dev, state, true)
  -> pci_pme_active(dev, true)
  -> platform_pci_set_wakeup(dev, true)
     -> acpi_pci_wakeup(dev, true)
        -> acpi_pm_set_device_wakeup()
           or acpi_pm_set_bridge_wakeup()
        -> __acpi_device_wakeup_enable()
           -> acpi_enable_wakeup_device_power()
           -> acpi_enable_gpe()
```

如果 xHCI ACPI companion 自身有 `_PRW`，通常启用设备自己的 GPE；否则可能向上游 bridge 或 root bus 传播，由上游 ACPI wake GPE 承接。

### 5.2 SCI 中断和 GPE dispatch

插入设备导致平台 GPE status 置位后，SCI 进入 ACPICA：

- `drivers/acpi/acpica/evsci.c:acpi_ev_sci_xrupt_handler()`
- `drivers/acpi/acpica/evgpe.c:acpi_ev_gpe_detect()`
- `drivers/acpi/acpica/evgpe.c:acpi_ev_detect_gpe()`
- `drivers/acpi/acpica/evgpe.c:acpi_ev_gpe_dispatch()`

流程：

```text
SCI interrupt
  -> acpi_ev_sci_xrupt_handler()
     -> acpi_ev_fixed_event_detect()
     -> acpi_ev_gpe_detect()
        -> 遍历 GPE block
        -> 读取 GPE status / enable register
        -> acpi_ev_detect_gpe()
           -> 确认 status & enable bit active
           -> acpi_ev_gpe_dispatch()
              -> disable GPE，避免重复触发
              -> edge GPE 先 clear status
              -> dispatch handler / _Lxx / _Exx / implicit notify
```

若该 GPE 是 implicit notify 类型，ACPICA 会排队发送：

```text
ACPI_NOTIFY_DEVICE_WAKE
```

对应代码在 `drivers/acpi/acpica/evgpe.c:acpi_ev_asynch_execute_gpe_method()`。

### 5.3 ACPI wake notify 到 PCI runtime resume

Linux ACPI PM notify handler：

- `drivers/acpi/device_pm.c:acpi_pm_notify_handler()`
- `drivers/pci/pci-acpi.c:pci_acpi_wake_dev()`
- `drivers/pci/pci-acpi.c:pci_acpi_wake_bus()`

PCI 设备注册 PM notifier 的位置：

- `drivers/pci/pci-acpi.c:pci_acpi_setup()`
- `drivers/pci/pci-acpi.c:pci_acpi_add_pm_notifier()`

流程：

```text
ACPI_NOTIFY_DEVICE_WAKE
  -> acpi_pm_notify_handler()
     -> pm_wakeup_ws_event()
     -> context.func()

对于 PCI device:
  context.func = pci_acpi_wake_dev()

pci_acpi_wake_dev()
  -> if current_state == PCI_D3cold:
       pci_wakeup_event()
       pm_request_resume()
       return
  -> if pme_support:
       pci_check_pme_status()
  -> pci_wakeup_event()
  -> pm_request_resume()
  -> pci_pme_wakeup_bus(subordinate)
```

对于 PCI root bus：

```text
pci_acpi_wake_bus()
  -> pci_pme_wakeup_bus(root->bus)
```

所以 ACPI GPE 最终也会归结到 `pm_request_resume(&pci_dev->dev)`。

## 6. PCI / xHCI Runtime Resume

PM core 收到 `pm_request_resume()` 后，对 xHCI PCI device 执行 runtime resume。

### 6.1 PCI runtime resume

代码入口：

- `drivers/pci/pci-driver.c:pci_pm_runtime_resume()`

流程：

```text
pci_pm_runtime_resume()
  -> pci_restore_standard_config()
  -> pci_enable_wake(pci_dev, PCI_D0, false)
  -> pci_fixup_resume_early / pci_fixup_resume
  -> driver runtime_resume()
```

对于 USB HCD：

- `drivers/usb/core/hcd-pci.c:hcd_pci_runtime_resume()`

```text
hcd_pci_runtime_resume()
  -> resume_common(dev, PM_EVENT_AUTO_RESUME)
     -> pci_enable_device()
     -> pci_set_master()
     -> hcd->driver->pci_resume()
        -> xhci_pci_resume()
```

### 6.2 xHCI resume

代码：

- `drivers/usb/host/xhci-pci.c:xhci_pci_resume()`
- `drivers/usb/host/xhci.c:xhci_resume()`

关键流程：

```text
xhci_resume()
  -> set HCD_FLAG_HW_ACCESSIBLE
  -> 等 USBSTS.STS_CNR 清除
  -> xhci_restore_registers()
  -> xhci_set_cmd_ring_deq()
  -> 置 USBCMD.CMD_CRS
  -> 等 USBSTS.STS_RESTORE 清除
  -> 置 USBCMD.CMD_RUN
  -> 等 STS_HALT 清除
  -> xhci_pending_portevent()
       检查 STS_EINT、PORT_CHANGE_MASK、XDEV_RESUME
  -> 如果有 pending port event:
       usb_hcd_resume_root_hub()
  -> 重新打开 root hub polling
  -> usb_hcd_poll_rh_status()
```

`xhci_pending_portevent()` 很重要，因为 xHCI spec 允许 `PORTSC` change bit 置位到 Port Status Change Event TRB 写入 Event Ring 之间有延迟。驱动不能只依赖 `USBSTS.EINT`。

## 7. Root Hub 和 USB Core 处理 PORTSC 变化

xHCI 恢复运行后，端口变化被传给 USB core。

### 7.1 xHCI interrupt/event ring 路径

如果恢复后 event ring 中有 Port Status Change Event：

- `drivers/usb/host/xhci-ring.c:handle_port_status()`

流程：

```text
handle_port_status()
  -> 读取 port_id
  -> 读取 PORTSC
  -> 如果 hcd->state == HC_STATE_SUSPENDED:
       usb_hcd_resume_root_hub(hcd)
  -> 根据 PORT_PLC / link state 处理 remote wake
  -> 对普通 port status change:
       set HCD_FLAG_POLL_RH
       usb_hcd_poll_rh_status(hcd)
```

源码中特别说明：xHCI port status change event 在所有 change bits 的 OR 从 0 到 1 时产生。如果已有 change bit 没清，后续变化可能不会再产生 event，所以驱动会切到 polling，避免漏事件。

### 7.2 hub_status_data 读取 PORTSC

代码：

- `drivers/usb/host/xhci-hub.c:xhci_hub_status_data()`
- `drivers/usb/host/xhci-hub.c:xhci_get_port_status()`

`xhci_hub_status_data()` 扫描所有 root ports：

```text
if (PORT_CSC | PORT_PEC | PORT_OCC | PORT_PLC | PORT_WRC | PORT_CEC)
    在 hub status bitmap 中置对应端口 bit
```

`xhci_get_port_status()` 将 xHCI `PORTSC` 转换成 USB hub 通用状态：

```text
PORT_CSC -> USB_PORT_STAT_C_CONNECTION
PORT_PEC -> USB_PORT_STAT_C_ENABLE
PORT_OCC -> USB_PORT_STAT_C_OVERCURRENT
PORT_RC  -> USB_PORT_STAT_C_RESET
PORT_CONNECT -> USB_PORT_STAT_CONNECTION
PORT_PE      -> USB_PORT_STAT_ENABLE
```

### 7.3 USB hub workqueue 枚举设备

代码：

- `drivers/usb/core/hcd.c:usb_hcd_poll_rh_status()`
- `drivers/usb/core/hub.c:hub_event()`
- `drivers/usb/core/hub.c:hub_port_connect_change()`

流程：

```text
usb_hcd_poll_rh_status()
  -> hcd->driver->hub_status_data()
  -> 完成 root hub interrupt URB 或设置 poll pending

hub_event()
  -> usb_autopm_get_interface()
  -> 遍历有 event/change/wakeup bit 的端口
  -> hub_port_connect_change()

hub_port_connect_change()
  -> 清 USB_PORT_FEAT_C_CONNECTION
  -> debounce
  -> port reset
  -> 分配 usb_device
  -> usb_new_device()
  -> 设备枚举和 driver match
```

## 8. PME 路径和 GPE 路径的关系

二者并不是互斥的抽象层，而是平台实现不同导致的不同入口。

### Native PME

适用于 OS 管理 PCIe PME service 的场景：

```text
xHCI PME Message
  -> Root Port PME IRQ
  -> pcie_pme_irq()
  -> pcie_pme_work_fn()
  -> pci_check_pme_status()
  -> pm_request_resume()
```

### ACPI GPE

适用于平台通过 `_PRW`/GPE/SCI 通知 wake 的场景：

```text
平台 GPE
  -> SCI
  -> ACPICA GPE dispatch
  -> Notify(DeviceWake)
  -> acpi_pm_notify_handler()
  -> pci_acpi_wake_dev()
  -> pm_request_resume()
```

### 共同终点

两条路径最终都到：

```text
pm_request_resume(&xhci_pci_dev->dev)
  -> pci_pm_runtime_resume()
  -> hcd_pci_runtime_resume()
  -> xhci_pci_resume()
  -> xhci_resume()
  -> USB root hub / hub_event / enumeration
```

## 9. 排查关注点

如果插入 USB 后 xHCI 没有从 runtime suspend 醒来，建议按以下顺序排查：

1. root hub 是否真的进入 suspend，且空端口是否设置了 `PORT_WKCONN_E`。
2. xHCI PCI device 是否配置了 PMCSR `PME_Enable`，目标电源态是否支持 PME。
3. 上游 Root Port 的 `Root Control.PMEIE` 是否打开，`Root Status.PME` 是否置位。
4. 是否走 ACPI wake：设备或上游 bridge 是否有 `_PRW`，对应 GPE 是否 enabled。
5. SCI/GPE counter 是否增长，`acpi_pm_notify_handler()` 是否收到 `ACPI_NOTIFY_DEVICE_WAKE`。
6. `pm_request_resume()` 是否触发，PCI device runtime status 是否从 suspended 变 active。
7. resume 后 `PORT_CSC` 是否仍在，`xhci_pending_portevent()` 是否识别到了 pending event。
8. USB core 是否进入 `hub_event()`，是否清了 `C_CONNECTION` 并开始 debounce/reset。

## 10. 关键源码索引

USB/xHCI：

- `drivers/usb/core/hcd-pci.c`
  - `hcd_pci_runtime_suspend()`
  - `hcd_pci_runtime_resume()`
  - `suspend_common()`
  - `resume_common()`
- `drivers/usb/host/xhci-pci.c`
  - `xhci_pci_suspend()`
  - `xhci_pci_resume()`
  - `xhci_pme_quirk()`
- `drivers/usb/host/xhci.c`
  - `xhci_suspend()`
  - `xhci_resume()`
  - `xhci_pending_portevent()`
- `drivers/usb/host/xhci-hub.c`
  - `xhci_bus_suspend()`
  - `xhci_bus_resume()`
  - `xhci_hub_status_data()`
  - `xhci_get_port_status()`
- `drivers/usb/host/xhci-ring.c`
  - `handle_port_status()`
  - `handle_device_notification()`
- `drivers/usb/core/hcd.c`
  - `usb_hcd_resume_root_hub()`
  - `usb_hcd_poll_rh_status()`
- `drivers/usb/core/hub.c`
  - `hub_event()`
  - `hub_port_connect_change()`
  - `usb_remote_wakeup()`

PCI / PME：

- `drivers/pci/pci-driver.c`
  - `pci_pm_runtime_suspend()`
  - `pci_pm_runtime_resume()`
- `drivers/pci/pci.c`
  - `pci_finish_runtime_suspend()`
  - `__pci_enable_wake()`
  - `pci_pme_active()`
  - `pci_check_pme_status()`
  - `pci_pme_wakeup_bus()`
  - `pci_dev_run_wake()`
- `drivers/pci/pcie/pme.c`
  - `pcie_pme_irq()`
  - `pcie_pme_work_fn()`
  - `pcie_pme_handle_request()`
  - `pcie_pme_interrupt_enable()`

ACPI / GPE：

- `drivers/pci/pci-acpi.c`
  - `acpi_pci_wakeup()`
  - `pci_acpi_wake_dev()`
  - `pci_acpi_wake_bus()`
  - `pci_acpi_setup()`
- `drivers/acpi/device_pm.c`
  - `__acpi_device_wakeup_enable()`
  - `acpi_pm_notify_handler()`
  - `acpi_pm_set_device_wakeup()`
  - `acpi_pm_set_bridge_wakeup()`
- `drivers/acpi/acpica/evsci.c`
  - `acpi_ev_sci_xrupt_handler()`
  - `acpi_ev_gpe_xrupt_handler()`
- `drivers/acpi/acpica/evgpe.c`
  - `acpi_ev_gpe_detect()`
  - `acpi_ev_detect_gpe()`
  - `acpi_ev_gpe_dispatch()`
  - `acpi_ev_asynch_execute_gpe_method()`
- `drivers/acpi/scan.c`
  - `acpi_wakeup_gpe_init()`
  - `_PRW` wakeup flags 初始化
- `drivers/acpi/wakeup.c`
  - `acpi_enable_wakeup_devices()`
  - `acpi_disable_wakeup_devices()`

