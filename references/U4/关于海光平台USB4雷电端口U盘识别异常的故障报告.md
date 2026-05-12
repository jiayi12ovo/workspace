### **关于海光平台USB4/雷电端口U盘识别异常的故障报告**

## **1. 问题概述**

在NH55笔记本平台上， ROOT BRIDGE进行一次D3->D0低功耗恢复后，出现**PME中断异常**。
具体表现为：当开机USB4链路进入D3状态后，在其中一个端口连接USB4设备，等待十几秒后，另一个端口以及USB3控制器（`2b:00.0`）会自动进入D3状态。此时，在另一个端口接入U盘，**系统无法接收到PME中断，设备无法识别**。

## **2. 复现步骤**

- **复现步骤**：
  1. 系统启动后，等待所有PCIe设备进入空闲状态（约15s），USB4链路自动进入D3。
  2. 在雷电端口 **`02:00.0`** 接入一个USB4设备（如USB4移动硬盘）。
  3. 观察到另一个雷电端口 **`02:00.1`** 及其关联的USB3控制器 **`2b:00.0`** 进入Suspend（D3）状态。
  4. 在 **`02:00.1`** 端口接入U盘。
  5. **结果**：U盘无法被系统识别，无PME中断触发。

## 3. 问题分析

### **3.1 PCIe拓扑结构**

```
+-01.1（海光root bridge）-[01-44]----00.0-[02-2c]--+-00.0-[03-16]--
 |                                                +-01.0-[17-2a]--
 |                                                +-02.0-[2b]----00.0  ASMedia 2426 (USB3.0控制器)
 |                                                +-03.0-[2c]----00.0  ASMedia 2425（NHI控制器）
```

### 3.2 对比验证

由于该问题本质是root bridge在执行过低功耗恢复流程后，处于D0时，接入**设备未上报PME中断**。因此下面将根据这一点做对比验证。测试前在BIOS下-芯片组- RAS设置，修改PCIE错误上报为操作系统优先。

#### 3.2.1 正常情况

- **步骤：**
  1. 开机后，立马执行echo on > /sys/bus/pci/devices/0000:00:01.1/power/control。确保01.1 root brige还没有进D3状态。
  2. 此时01.1将一直保持在D0状态。
  3. 执行lspci -s 01.1 -vvv，输出root bridge配置空间。
  4. 测试一个口插USB4，另一个口插U盘可以识别。

#### 3.2.2 异常情况

- **步骤：**
  1. 开机后，等待半分钟，u4链路均进入D3。
  2. 执行echo on > /sys/bus/pci/devices/0000:00:01.1/power/control。
  3. 此时01.1将一直保持在D0状态。
  4. 执行lspci -s 01.1 -vvv，输出root bridge配置空间。
  5. 测试接设备均不识别。

#### 3.2.3 **核心分析与发现**

通过 `lspci -vvv` 对比两份配置空间，发现异常情况下 PCIe根端口（`00:01.1`）存在设备异常，以及**PME Status位未清除**的现象。

<img src="/home/jiayi/.config/Typora/typora-user-images/image-20260107153801900.png" alt="image-20260107153801900" style="zoom:150%;" />

###### **3.2.3.1. AER错误**

- **AER错误源**：AER寄存器显示存在 **`ERR_FATAL/NONFATAL: 0009`** 错误。
- **设备状态异常**：`DevSta`报告 **`NonFatalErr+`** 与 **`UnsupReq+`**。

###### **3.2.3.2. PME状态异常**

- **PME状态无法清除**：根端口的PME状态寄存器始终显示 **`PMEStatus+ PMEPending+`**。这表示有一个PME事件已发生但**未被系统正确处理和清除**。
- **直接影响**：当PME处于这种“待处理”的异常状态时，根据 PCIe 规范，当 PME Status 已经被置位时，新的 PME 事件（如后续插入 U 盘产生的中断请求）将不会触发新的中断信号（MSI/INTx），导致操作系统**无法感知热插拔事件，从而不执行设备枚举**。

### 3.3 **临时解决方案与验证**

- **手动清除操作**：在问题复现后，通过 `setpci` 命令直接向根端口（`00:01.1`）的PME状态寄存器写入特定值清除待处理状态。

  ```
  setpci -s 00:01.1 0x78.L=0x00010000
  ```

  *注：该操作向 `Root Status Register` (偏移 `0x78`) 的 `PME Status` 位写1以清除它。*

- **直接效果**：执行两次此命令后，setpci -s 00:01.1 0x78.L读取到PME Status位为0 。此时再插U盘可以识别。

## **4. 附件**

### 4.1 正常情况下01.1配置空间

00:01.1 PCI bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c3 (prog-if 00 [Normal decode])
	Control: I/O+ Mem+ BusMaster+ SpecCycle- MemWINV- VGASnoop- ParErr- Stepping- SERR+ FastB2B- DisINTx+
	Status: Cap+ 66MHz- UDF- FastB2B- ParErr- DEVSEL=fast >TAbort- <TAbort- <MAbort- >SERR- <PERR- INTx-
	Latency: 0, Cache Line Size: 64 bytes
	Interrupt: pin ? routed to IRQ 28
	NUMA node: 0
	Bus: primary=00, secondary=01, subordinate=44, sec-latency=0
	I/O behind bridge: 00003000-0000cfff [size=40K]
	Memory behind bridge: b0000000-b3ffffff [size=64M]
	Prefetchable memory behind bridge: 0000034000000000-0000034fffffffff [size=64G]
	Secondary status: 66MHz- FastB2B- ParErr- DEVSEL=fast >TAbort- <TAbort- <MAbort+ <SERR- <PERR-
	BridgeCtl: Parity- SERR+ NoISA- VGA- VGA16- MAbort- >Reset- FastB2B-
		PriDiscTmr- SecDiscTmr- DiscTmrStat- DiscTmrSERREn-
	Capabilities: [50] Power Management version 3
		Flags: PMEClk- DSI- D1- D2- AuxCurrent=0mA PME(D0+,D1-,D2-,D3hot+,D3cold+)
		Status: D0 NoSoftRst- PME-Enable- DSel=0 DScale=0 PME-
	Capabilities: [58] Express (v2) Root Port (Slot+), MSI 00
		DevCap:	MaxPayload 512 bytes, PhantFunc 0
			ExtTag+ RBE+
		DevCtl:	CorrErr+ NonFatalErr+ FatalErr+ UnsupReq+
			RlxdOrd+ ExtTag+ PhantFunc- AuxPwr- NoSnoop+
			MaxPayload 128 bytes, MaxReadReq 512 bytes
		DevSta:	CorrErr- NonFatalErr- FatalErr- UnsupReq- AuxPwr- TransPend-
		LnkCap:	Port #0, Speed 16GT/s, Width x4, ASPM not supported
			ClockPM- Surprise- LLActRep+ BwNot+ ASPMOptComp+
		LnkCtl:	ASPM Disabled; RCB 64 bytes Disabled- CommClk+
			ExtSynch- ClockPM- AutWidDis- BWInt- AutBWInt-
		LnkSta:	Speed 16GT/s (ok), Width x4 (ok)
			TrErr- Train- SlotClk+ DLActive+ BWMgmt+ ABWMgmt-
		SltCap:	AttnBtn- PwrCtrl- MRL- AttnInd- PwrInd- HotPlug- Surprise-
			Slot #0, PowerLimit 0.000W; Interlock- NoCompl+
		SltCtl:	Enable: AttnBtn- PwrFlt- MRL- PresDet- CmdCplt- HPIrq- LinkChg-
			Control: AttnInd Unknown, PwrInd Unknown, Power- Interlock-
		SltSta:	Status: AttnBtn- PowerFlt- MRL- CmdCplt- PresDet+ Interlock-
			Changed: MRL- PresDet- LinkState+
		RootCap: CRSVisible+
		RootCtl: ErrCorrectable- ErrNon-Fatal- ErrFatal- PMEIntEna+ CRSVisible+
		RootSta: PME ReqID 0000, PMEStatus- PMEPending-
		DevCap2: Completion Timeout: Range ABCD, TimeoutDis-, NROPrPrP-, LTR-
			 10BitTagComp+, 10BitTagReq+, OBFF Not Supported, ExtFmt+, EETLPPrefix+, MaxEETLPPrefixes 1
			 EmergencyPowerReduction Not Supported, EmergencyPowerReductionInit-
			 FRS-, LN System CLS Not Supported, TPHComp-, ExtTPHComp-, ARIFwd+
			 AtomicOpsCap: Routing- 32bit+ 64bit+ 128bitCAS-
		DevCtl2: Completion Timeout: 65ms to 210ms, TimeoutDis-, LTR-, OBFF Disabled ARIFwd-
			 AtomicOpsCtl: ReqEn- EgressBlck-
		LnkCtl2: Target Link Speed: 16GT/s, EnterCompliance- SpeedDis-
			 Transmit Margin: Normal Operating Range, EnterModifiedCompliance- ComplianceSOS-
			 Compliance De-emphasis: -6dB
		LnkSta2: Current De-emphasis Level: -3.5dB, EqualizationComplete+, EqualizationPhase1+
			 EqualizationPhase2+, EqualizationPhase3+, LinkEqualizationRequest-
	Capabilities: [a0] MSI: Enable+ Count=1/1 Maskable- 64bit+
		Address: 00000000fee00000  Data: 0000
	Capabilities: [c0] Subsystem: Chengdu Haiguang IC Design Co., Ltd. Device 14c3
	Capabilities: [c8] HyperTransport: MSI Mapping Enable+ Fixed+
	Capabilities: [100 v1] Vendor Specific Information: ID=0001 Rev=1 Len=010 <?>
	Capabilities: [150 v2] Advanced Error Reporting
		UESta:	DLP- SDES- TLP- FCP- CmpltTO- CmpltAbrt- UnxCmplt- RxOF- MalfTLP- ECRC- UnsupReq- ACSViol-
		UEMsk:	DLP- SDES- TLP- FCP- CmpltTO- CmpltAbrt- UnxCmplt- RxOF- MalfTLP- ECRC- UnsupReq- ACSViol-
		UESvrt:	DLP- SDES+ TLP- FCP+ CmpltTO- CmpltAbrt- UnxCmplt- RxOF+ MalfTLP- ECRC- UnsupReq- ACSViol-
		CESta:	RxErr- BadTLP- BadDLLP- Rollover- Timeout- AdvNonFatalErr-
		CEMsk:	RxErr- BadTLP- BadDLLP- Rollover- Timeout- AdvNonFatalErr-
		AERCap:	First Error Pointer: 00, ECRCGenCap+ ECRCGenEn- ECRCChkCap+ ECRCChkEn-
			MultHdrRecCap- MultHdrRecEn- TLPPfxPres- HdrLogCap-
		HeaderLog: 00000000 00000000 00000000 00000000
		RootCmd: CERptEn+ NFERptEn+ FERptEn+
		RootSta: CERcvd- MultCERcvd- UERcvd- MultUERcvd-
			 FirstFatal- NonFatalMsg- FatalMsg- IntMsg 0
		ErrorSrc: ERR_COR: 0000 ERR_FATAL/NONFATAL: 0000
	Capabilities: [270 v1] Secondary PCI Express
		LnkCtl3: LnkEquIntrruptEn-, PerformEqu-
		LaneErrStat: 0
	Capabilities: [2a0 v1] Access Control Services
		ACSCap:	SrcValid+ TransBlk+ ReqRedir+ CmpltRedir+ UpstreamFwd+ EgressCtrl- DirectTrans+
		ACSCtl:	SrcValid+ TransBlk- ReqRedir+ CmpltRedir+ UpstreamFwd+ EgressCtrl- DirectTrans-
	Capabilities: [370 v2] L1 PM Substates
		L1SubCap: PCI-PM_L1.2+ PCI-PM_L1.1+ ASPM_L1.2+ ASPM_L1.1+ L1_PM_Substates+
			  PortCommonModeRestoreTime=0us PortTPowerOnTime=10us
		L1SubCtl1: PCI-PM_L1.2- PCI-PM_L1.1- ASPM_L1.2- ASPM_L1.1-
			   T_CommonMode=0us LTR1.2_Threshold=0ns
		L1SubCtl2: T_PwrOn=10us
	Capabilities: [390 v1] Downstream Port Containment
		DpcCap:	INT Msg #0, RPExt+ PoisonedTLP+ SwTrigger+ RP PIO Log 6, DL_ActiveErr+
		DpcCtl:	Trigger:1 Cmpl- INT+ ErrCor- PoisonedTLP- SwTrigger- DL_ActiveErr-
		DpcSta:	Trigger- Reason:00 INT- RPBusy- TriggerExt:00 RP PIO ErrPtr:1f
		Source:	0000
	Capabilities: [410 v1] Data Link Feature <?>
	Capabilities: [420 v1] Physical Layer 16.0 GT/s <?>
	Capabilities: [450 v1] Lane Margining at the Receiver <?>
	Capabilities: [4a0 v1] Extended Capability ID 0x2a
	Kernel driver in use: pcieport



### 4.2 异常情况下01.1配置空间

00:01.1 PCI bridge: Chengdu Haiguang IC Design Co., Ltd. Device 14c3 (prog-if 00 [Normal decode])
	Control: I/O+ Mem+ BusMaster+ SpecCycle- MemWINV- VGASnoop- ParErr- Stepping- SERR+ FastB2B- DisINTx+
	Status: Cap+ 66MHz- UDF- FastB2B- ParErr- DEVSEL=fast >TAbort- <TAbort- <MAbort- >SERR+ <PERR- INTx-
	Latency: 0, Cache Line Size: 64 bytes
	Interrupt: pin ? routed to IRQ 28
	NUMA node: 0
	Bus: primary=00, secondary=01, subordinate=44, sec-latency=0
	I/O behind bridge: 00003000-0000cfff [size=40K]
	Memory behind bridge: b0000000-b3ffffff [size=64M]
	Prefetchable memory behind bridge: 0000034000000000-0000034fffffffff [size=64G]
	Secondary status: 66MHz- FastB2B- ParErr- DEVSEL=fast >TAbort- <TAbort- <MAbort+ <SERR- <PERR-
	BridgeCtl: Parity- SERR+ NoISA- VGA- VGA16- MAbort- >Reset- FastB2B-
		PriDiscTmr- SecDiscTmr- DiscTmrStat- DiscTmrSERREn-
	Capabilities: [50] Power Management version 3
		Flags: PMEClk- DSI- D1- D2- AuxCurrent=0mA PME(D0+,D1-,D2-,D3hot+,D3cold+)
		Status: D0 NoSoftRst- PME-Enable- DSel=0 DScale=0 PME-
	Capabilities: [58] Express (v2) Root Port (Slot+), MSI 00
		DevCap:	MaxPayload 512 bytes, PhantFunc 0
			ExtTag+ RBE+
		DevCtl:	CorrErr+ NonFatalErr+ FatalErr+ UnsupReq+
			RlxdOrd+ ExtTag+ PhantFunc- AuxPwr- NoSnoop+
			MaxPayload 128 bytes, MaxReadReq 512 bytes
		DevSta:	CorrErr- NonFatalErr+ FatalErr- UnsupReq+ AuxPwr- TransPend-
		LnkCap:	Port #0, Speed 16GT/s, Width x4, ASPM not supported
			ClockPM- Surprise- LLActRep+ BwNot+ ASPMOptComp+
		LnkCtl:	ASPM Disabled; RCB 64 bytes Disabled- CommClk+
			ExtSynch- ClockPM- AutWidDis- BWInt- AutBWInt-
		LnkSta:	Speed 16GT/s (ok), Width x4 (ok)
			TrErr- Train- SlotClk+ DLActive+ BWMgmt+ ABWMgmt+
		SltCap:	AttnBtn- PwrCtrl- MRL- AttnInd- PwrInd- HotPlug- Surprise-
			Slot #0, PowerLimit 0.000W; Interlock- NoCompl+
		SltCtl:	Enable: AttnBtn- PwrFlt- MRL- PresDet- CmdCplt- HPIrq- LinkChg-
			Control: AttnInd Unknown, PwrInd Unknown, Power- Interlock-
		SltSta:	Status: AttnBtn- PowerFlt- MRL- CmdCplt- PresDet+ Interlock-
			Changed: MRL- PresDet- LinkState+
		RootCap: CRSVisible+
		RootCtl: ErrCorrectable- ErrNon-Fatal- ErrFatal- PMEIntEna+ CRSVisible+
		RootSta: PME ReqID 0000, PMEStatus+ PMEPending+
		DevCap2: Completion Timeout: Range ABCD, TimeoutDis-, NROPrPrP-, LTR-
			 10BitTagComp+, 10BitTagReq+, OBFF Not Supported, ExtFmt+, EETLPPrefix+, MaxEETLPPrefixes 1
			 EmergencyPowerReduction Not Supported, EmergencyPowerReductionInit-
			 FRS-, LN System CLS Not Supported, TPHComp-, ExtTPHComp-, ARIFwd+
			 AtomicOpsCap: Routing- 32bit+ 64bit+ 128bitCAS-
		DevCtl2: Completion Timeout: 65ms to 210ms, TimeoutDis-, LTR-, OBFF Disabled ARIFwd-
			 AtomicOpsCtl: ReqEn- EgressBlck-
		LnkCtl2: Target Link Speed: 16GT/s, EnterCompliance- SpeedDis-
			 Transmit Margin: Normal Operating Range, EnterModifiedCompliance- ComplianceSOS-
			 Compliance De-emphasis: -6dB
		LnkSta2: Current De-emphasis Level: -3.5dB, EqualizationComplete+, EqualizationPhase1+
			 EqualizationPhase2+, EqualizationPhase3+, LinkEqualizationRequest-
	Capabilities: [a0] MSI: Enable+ Count=1/1 Maskable- 64bit+
		Address: 00000000fee00000  Data: 0000
	Capabilities: [c0] Subsystem: Chengdu Haiguang IC Design Co., Ltd. Device 14c3
	Capabilities: [c8] HyperTransport: MSI Mapping Enable+ Fixed+
	Capabilities: [100 v1] Vendor Specific Information: ID=0001 Rev=1 Len=010 <?>
	Capabilities: [150 v2] Advanced Error Reporting
		UESta:	DLP- SDES- TLP- FCP- CmpltTO- CmpltAbrt- UnxCmplt- RxOF- MalfTLP- ECRC- UnsupReq- ACSViol-
		UEMsk:	DLP- SDES- TLP- FCP- CmpltTO- CmpltAbrt- UnxCmplt- RxOF- MalfTLP- ECRC- UnsupReq- ACSViol-
		UESvrt:	DLP- SDES+ TLP- FCP+ CmpltTO- CmpltAbrt- UnxCmplt- RxOF+ MalfTLP- ECRC- UnsupReq- ACSViol-
		CESta:	RxErr- BadTLP- BadDLLP- Rollover- Timeout- AdvNonFatalErr-
		CEMsk:	RxErr- BadTLP- BadDLLP- Rollover- Timeout- AdvNonFatalErr-
		AERCap:	First Error Pointer: 14, ECRCGenCap+ ECRCGenEn- ECRCChkCap+ ECRCChkEn-
			MultHdrRecCap- MultHdrRecEn- TLPPfxPres- HdrLogCap-
		HeaderLog: 00000000 00000000 00000000 fee00000
		RootCmd: CERptEn+ NFERptEn+ FERptEn+
		RootSta: CERcvd- MultCERcvd- UERcvd- MultUERcvd-
			 FirstFatal- NonFatalMsg- FatalMsg- IntMsg 0
		ErrorSrc: ERR_COR: 0000 ERR_FATAL/NONFATAL: 0009
	Capabilities: [270 v1] Secondary PCI Express
		LnkCtl3: LnkEquIntrruptEn-, PerformEqu-
		LaneErrStat: 0
	Capabilities: [2a0 v1] Access Control Services
		ACSCap:	SrcValid+ TransBlk+ ReqRedir+ CmpltRedir+ UpstreamFwd+ EgressCtrl- DirectTrans+
		ACSCtl:	SrcValid+ TransBlk- ReqRedir- CmpltRedir- UpstreamFwd- EgressCtrl- DirectTrans-
	Capabilities: [370 v2] L1 PM Substates
		L1SubCap: PCI-PM_L1.2+ PCI-PM_L1.1+ ASPM_L1.2+ ASPM_L1.1+ L1_PM_Substates+
			  PortCommonModeRestoreTime=0us PortTPowerOnTime=10us
		L1SubCtl1: PCI-PM_L1.2- PCI-PM_L1.1- ASPM_L1.2- ASPM_L1.1-
			   T_CommonMode=0us LTR1.2_Threshold=0ns
		L1SubCtl2: T_PwrOn=10us
	Capabilities: [390 v1] Downstream Port Containment
		DpcCap:	INT Msg #0, RPExt+ PoisonedTLP+ SwTrigger+ RP PIO Log 6, DL_ActiveErr+
		DpcCtl:	Trigger:1 Cmpl- INT+ ErrCor- PoisonedTLP- SwTrigger- DL_ActiveErr-
		DpcSta:	Trigger- Reason:00 INT- RPBusy- TriggerExt:00 RP PIO ErrPtr:1f
		Source:	0000
	Capabilities: [410 v1] Data Link Feature <?>
	Capabilities: [420 v1] Physical Layer 16.0 GT/s <?>
	Capabilities: [450 v1] Lane Margining at the Receiver <?>
	Capabilities: [4a0 v1] Extended Capability ID 0x2a
	Kernel driver in use: pcieport