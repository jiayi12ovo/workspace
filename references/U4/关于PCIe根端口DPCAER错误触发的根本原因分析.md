## 关于PCIe根端口DPC/AER错误触发的根本原因分析

---

### **1. 问题概述**
在NH55（搭载C86-3456M CPU）机器S3/S4老化测试时，观测到**USB4 PCIe设备从深度休眠状态（D3cold）唤醒时，根端口触发DPC与AER错误，导致设备链路被隔离而无法访问。**  
- **核心错误**：根端口 `00:01.1` 报告 `ACSViol`（访问控制服务违规），触发DPC隔离。  
- **直接影响**：下游Thunderbolt设备（ASMedia 2425）在唤醒后配置空间完全不可访问，系统误判为“设备移除”。  
- **问题稳定性**： 测试24台机器，2-4台机器报错。  

---

### **2. 问题分析**
#### **2.1 内核日志**

NH55机器上，AER模式默认是Firmware first，固件处理PCIe AER错误，但仍然没能恢复成功。在开启pcie_ports=native，转到os处理后，内核在异常点接收到了AER错误上报，日志如下：

```
[时间线]
[  739.990714] [6198] pci_bridge_wait_for_secondary_bus:4806: pcieport 0000:02:03.0: waiting 100 ms for downstream link
[  740.093749]     power-0362 __acpi_power_on       : Power resource [P0HI] turned on
 ACPI成功打开设备电源资源 `[P0HI]`（_ON方法执行）。
[  740.118962] pcieport 0000:00:01.1: DPC: containment event, status:0x1f01 source:0x0009 
[  740.119331] pcieport 0000:00:01.1: DPC: unmasked uncorrectable error detected
根端口 `00:01.1` 触发DPC事件（状态:0x1f01，源:0x0009）。
[  740.119824] pcieport 0000:00:01.1: AER: PCIe Bus Error: severity=Uncorrected (Non-Fatal), type=Transaction Layer, (Receiver ID)
[  740.120072] pcieport 0000:00:01.1: AER:   device [1d94:14c3] error status/mask=00200000/04400000
[  740.120442] pcieport 0000:00:01.1: AER:    [21] ACSViol                (First)
同一根端口报告AER错误：`ACSViol`（访问控制违规）。
[  740.121556] [222] pcie_do_recovery:201: pcieport 0000:00:01.1: broadcast error_detected message
[  740.125251] device_pm-0280 device_set_power      : Device [NHI0] transitioned to D0
[  740.125257] [6198] acpi_pci_set_power_state:1055: thunderbolt 0000:2c:00.0: power state changed by ACPI to D0
[  740.125261] thunderbolt 0000:2c:00.0: can't change power state from D3cold to D0 (config space inaccessible)
配置空间访问失败：“config space inaccessible”。
```
![image-20251215101840623](/home/jiayi/.config/Typora/typora-user-images/image-20251215101840623.png)

DPC/AER错误在电源资源打开后 25ms内立即触发，表明下游设备电源资源开启（`_ON`）或者初始化动作（`_PS0`)触发了访问控制错误。

#### **2.2 PCIe拓扑结构**
```
+-01.1（海光root bridge）-[01-44]----00.0-[02-2c]--+-00.0-[03-16]--
 |                                                +-01.0-[17-2a]--
 |                                                +-02.0-[2b]----00.0  ASMedia 2426
 |                                                +-03.0-[2c]----00.0  ASMedia 2425（NHI控制器）
```
- **故障点**：设备 `0000:2c:00.0`（ASMedia 2425） → 上游桥 `0000:02:03.0` → 根端口 `0000:00:01.1`。  
- **影响范围**：根端口下游整个子树配置空间无法访问，最后造成设备移除。

#### **2.3 ACPI固件**
反编译了设备ACPI方法 `_PS0`，发现其包含有一些硬件访问序列：
```asl
Method (_PS0) {
    FWFW (FW94, PDHI)          // 潜在风险的固件写入
    If ((ACSK != Zero)) {
        SMNW (0x01100098, One) // MMIO写入
        SMNW (0x0004A348, 0xFFFE0069)
        ...
    }
}
```
---

### **3. 技术分析与假设**
#### **3.1 故障逻辑**
1. **触发**：设备唤醒时，ACPI执行 `_ON`、`_PS0` 方法分别上电和初始化硬件。  
3. **检测**：根端口 `00:01.1` 的ACS硬件逻辑检测到 `ACSViol`。  
4. **隔离**：DPC机制立即隔离下游链路（防止错误扩散）。    
6. **访问失败**：驱动尝试访问已被隔离的设备，失败。

#### **3.2 关键疑问（需厂商协助）**
- **DPC错误码解析**：  
  DPC状态 `0x1f01` 与源 `0x0009` 的具体含义？确认 `ACSViol` 在此场景下的具体触发条件，以及如果解决使得不发生该报错。   
- **错误恢复机制**：  
  DPC隔离后，系统通过 `pcie_do_recovery` 尝试恢复，但为何最终仍失败？是否需要平台特定复位序列？  

### 4. 修复方案

BIOS调整，在2c:00.0进D3后，关闭DPC Trigger Enable，恢复D0后再开启。因此在D3->D0的切换过程中，不会发生DPC隔离链路，规避了问题。

### **5. 附件**

1. **PCIe拓扑图**（`lspci && lspci -tv` 输出）。  

00:00.0 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c0
00:00.2 IOMMU: Chengdu Haiguang IC Design Co., Ltd. Device 149e
00:01.0 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c2
00:01.1 PCI bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c3
00:01.2 PCI bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c3
00:01.3 PCI bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c3
00:01.5 PCI bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c3
00:01.6 PCI bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c3
00:02.0 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c2
00:03.0 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c2
00:07.0 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c2
00:07.1 PCI bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c4
00:08.0 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c2
00:08.1 PCI bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c4
00:0b.0 SMBus: Chengdu Haiguang IC Design Co., Ltd. FCH SMBus Controller (rev 59)
00:0b.3 ISA bridge: Chengdu Haiguang IC Design Co., Ltd. FCH LPC Bridge (rev 51)
00:18.0 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14d0
00:18.1 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14d1
00:18.2 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14d2
00:18.3 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14d3
00:18.4 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14d4
00:18.5 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14d5
00:18.6 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14d6
00:18.7 Host bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14d7
01:00.0 PCI bridge: ASMedia Technology Inc. Device 2421 (rev 01)
02:00.0 PCI bridge: ASMedia Technology Inc. Device 2423 (rev 01)
02:01.0 PCI bridge: ASMedia Technology Inc. Device 2423 (rev 01)
02:02.0 PCI bridge: ASMedia Technology Inc. Device 2423 (rev 01)
02:03.0 PCI bridge: ASMedia Technology Inc. Device 2423 (rev 01)
2b:00.0 USB controller: ASMedia Technology Inc. Device 2426 (rev 01)
2c:00.0 USB controller: ASMedia Technology Inc. Device 2425 (rev 01)
45:00.0 VGA compatible controller: Innosilicon Co Ltd Fantasy II-M
46:00.0 Non-Volatile memory controller: MAXIO Technology (Hangzhou) Ltd. NVMe SSD Controller MAP1602 (DRAM-less) (rev 01)
47:00.0 Ethernet controller: Realtek Semiconductor Co., Ltd. RTL8111/8168/8211/8411 PCI Express Gigabit Ethernet Controller (rev 15)
48:00.0 Network controller: Realtek Semiconductor Co., Ltd. RTL8852BE PCIe 802.11ax Wireless Network Controller
49:00.0 Non-Essential Instrumentation [1300]: Chengdu Haiguang IC Design Co., Ltd. Device 14c5
49:00.2 Encryption controller: Chengdu Haiguang IC Design Co., Ltd. Device 14c6
49:00.3 Encryption controller: Chengdu Haiguang IC Design Co., Ltd. Device 14d8
4a:00.0 Non-Essential Instrumentation [1300]: Chengdu Haiguang IC Design Co., Ltd. Device 14c5
4a:00.1 USB controller: Chengdu Haiguang IC Design Co., Ltd. Device 148c
4a:00.2 USB controller: Chengdu Haiguang IC Design Co., Ltd. Device 148c
4a:00.6 Audio device: Chengdu Haiguang IC Design Co., Ltd. Device 14c9

-[0000:00]-+-00.0  Chengdu Haiguang IC Design Co., Ltd. Device 14c0
           +-00.2  Chengdu Haiguang IC Design Co., Ltd. Device 149e
           +-01.0  Chengdu Haiguang IC Design Co., Ltd. Device 14c2
           +-01.1-[01-44]----00.0-[02-2c]--+-00.0-[03-16]--
           |                               +-01.0-[17-2a]--
           |                               +-02.0-[2b]----00.0  ASMedia Technology Inc. Device 2426
           |                               \-03.0-[2c]----00.0  ASMedia Technology Inc. Device 2425
           +-01.2-[45]----00.0  Innosilicon Co Ltd Fantasy II-M
           +-01.3-[46]----00.0  MAXIO Technology (Hangzhou) Ltd. NVMe SSD Controller MAP1602 (DRAM-less)
           +-01.5-[47]----00.0  Realtek Semiconductor Co., Ltd. RTL8111/8168/8211/8411 PCI Express Gigabit Ethernet Controller
           +-01.6-[48]----00.0  Realtek Semiconductor Co., Ltd. RTL8852BE PCIe 802.11ax Wireless Network Controller
           +-02.0  Chengdu Haiguang IC Design Co., Ltd. Device 14c2
           +-03.0  Chengdu Haiguang IC Design Co., Ltd. Device 14c2
           +-07.0  Chengdu Haiguang IC Design Co., Ltd. Device 14c2
           +-07.1-[49]--+-00.0  Chengdu Haiguang IC Design Co., Ltd. Device 14c5
           |            +-00.2  Chengdu Haiguang IC Design Co., Ltd. Device 14c6
           |            \-00.3  Chengdu Haiguang IC Design Co., Ltd. Device 14d8
           +-08.0  Chengdu Haiguang IC Design Co., Ltd. Device 14c2
           +-08.1-[4a]--+-00.0  Chengdu Haiguang IC Design Co., Ltd. Device 14c5
           |            +-00.1  Chengdu Haiguang IC Design Co., Ltd. Device 148c
           |            +-00.2  Chengdu Haiguang IC Design Co., Ltd. Device 148c
           |            \-00.6  Chengdu Haiguang IC Design Co., Ltd. Device 14c9
           +-0b.0  Chengdu Haiguang IC Design Co., Ltd. FCH SMBus Controller
           +-0b.3  Chengdu Haiguang IC Design Co., Ltd. FCH LPC Bridge
           +-18.0  Chengdu Haiguang IC Design Co., Ltd. Device 14d0
           +-18.1  Chengdu Haiguang IC Design Co., Ltd. Device 14d1
           +-18.2  Chengdu Haiguang IC Design Co., Ltd. Device 14d2
           +-18.3  Chengdu Haiguang IC Design Co., Ltd. Device 14d3
           +-18.4  Chengdu Haiguang IC Design Co., Ltd. Device 14d4
           +-18.5  Chengdu Haiguang IC Design Co., Ltd. Device 14d5
           +-18.6  Chengdu Haiguang IC Design Co., Ltd. Device 14d6
           \-18.7  Chengdu Haiguang IC Design Co., Ltd. Device 14d7

