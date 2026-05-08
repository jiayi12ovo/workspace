# 第21章 配置电源管理支持

> 翻译自：https://download.nvidia.com/XFree86/Linux-x86_64/570.211.01/README/powermanagement.html
> NVIDIA驱动版本：570.211.01
> 翻译日期：2026-04-23

---

## 背景

NVIDIA Linux驱动支持系统挂起（suspend-to-RAM）和休眠（suspend-to-disk）电源管理操作，例如x86_64平台上的ACPI S3和S4。当系统挂起或休眠时，NVIDIA内核驱动会为正在使用的GPU准备睡眠周期，保存必要的状态信息，以便系统后续恢复时将这些GPU恢复正常运行。如果平台和NVIDIA GPU均支持，NVIDIA Linux驱动还支持基于S0ix的s2idle系统挂起（挂起到空闲）。

NVIDIA内核驱动保存的GPU状态包括显存中的分配。然而，这些分配总量很大，通常无法被驱逐。由于驱动在挂起时可用的系统内存通常不足以容纳大块显存数据，NVIDIA内核驱动被设计为保守运作，通常只保存必要的显存分配。

由此导致的显存内容丢失会由用户空间NVIDIA驱动和部分应用程序进行部分补偿，但可能导致渲染损坏和应用程序在电源管理周期退出时崩溃等问题。

为了更好地支持此类应用程序的电源管理，NVIDIA Linux驱动提供了一个自定义电源管理接口，用于与 **systemd** 等系统管理工具集成。该接口仍被视为实验性质。默认情况下不使用，但可以按照本章所述进行配置启用。

## 概述

NVIDIA Linux驱动通过两种不同的机制支持挂起和休眠电源管理操作。本节对每种机制的功能和要求进行简要说明：

### 内核驱动回调

当使用此机制时，NVIDIA内核驱动接收来自Linux内核的回调，对每个注册了Linux PCI驱动程序的GPU执行挂起、休眠和恢复操作。这是默认机制：无需显式配置即可启用和使用。

虽然此机制没有特殊要求，在许多工作负载下效果良好，且NVIDIA内核驱动多年来一直以类似形式支持该机制，但它存在一些局限性。值得注意的是，它只能可靠地保存相对较少的显存数据，且无法在使用高级CUDA功能时支持电源管理。

### `/proc/driver/nvidia/suspend`

此机制不使用来自Linux内核的回调，而是依赖系统管理工具（如 **systemd**）通过 `/proc/driver/nvidia/suspend` 接口向NVIDIA内核驱动发送挂起、休眠和恢复命令。该机制仍被视为实验性质，需要显式配置才能使用。

如果正确配置，此机制旨在消除内核驱动回调机制的限制。它支持在使用高级CUDA功能（如UVM）时进行电源管理，并且能够保存和恢复所有显存分配。

## 保存所有显存分配

为了保存可能占用大量空间的显存数据，NVIDIA驱动支持以下两种方法：

### 在未命名临时文件中保存分配

NVIDIA驱动使用未命名临时文件来保存可能占用大量空间的显存数据。默认情况下，此文件在系统挂起期间创建于 `/tmp` 目录。可以通过 `NVreg_TemporaryFilePath` nvidia.ko内核模块参数更改此位置，例如 `NVreg_TemporaryFilePath=/run`。目标文件系统需要支持未命名临时文件，并且需要有足够的空间来容纳电源管理周期期间所有使用的显存副本。

确定显存备份存储的合适大小时，建议以系统中安装的GPU支持的显存总量为起点。例如：

```bash
nvidia-smi -q -d MEMORY | grep 'FB Memory Usage' -A1
```

此命令返回的每个 `Total` 行反映一个GPU的显存容量（单位：MiB）。这些数值的总和加上5%的余量，是显存备份存储大小的保守起点。

请注意，`/tmp` 和 `/run` 等文件系统通常为 `tmpfs` 类型，容量可能相对较小。通常，所用文件系统类型的大小由 **systemd** 控制。更多信息请参见 https://www.freedesktop.org/wiki/Software/systemd/APIFileSystems 。目前建议使用 `tmpfs` 以外的文件系统类型以获得最佳性能。

此外，要解锁该接口的全部功能，需要使用 `NVreg_PreserveVideoMemoryAllocations=1` 模块参数加载NVIDIA Linux内核模块 `nvidia.ko`。这会将默认的显存保存/恢复策略更改为保存和恢复所有显存分配。同时，使用此接口时必须配合 `/proc/driver/nvidia/suspend` 电源管理机制（以及 **systemd** 等系统管理工具）。

### 基于S0ix的电源管理

如果平台和NVIDIA GPU均支持基于S0ix的电源管理，则NVIDIA Linux驱动会在 **s2idle** 系统挂起期间将GPU显存置于自刷新模式。基于S0ix的挂起比传统S3系统挂起消耗更多电量，但进入和退出挂起/恢复的速度更快。而且，无论GPU显存使用量如何，挂起/恢复延迟都是恒定的。

要检查平台的S0ix状态支持和所需配置，请遵循 how-achieve-s0ix-states-linux 中提到的步骤。

要检查NVIDIA GPU是否支持基于S0ix的电源管理，安装NVIDIA驱动后运行以下命令：

```bash
grep 'Video Memory Self Refresh' /proc/driver/nvidia/gpus/<domain>\<bus>\<device>.0/power
```

例如：

```bash
grep 'Video Memory Self Refresh' /proc/driver/nvidia/gpus/0000\:01\:00.0/power
```

如果平台和GPU均支持基于S0ix的电源管理，则可以通过将 `nvidia.ko` 内核模块参数 `NVreg_EnableS0ixPowerManagement` 设置为 "1" 来在NVIDIA Linux驱动中启用S0ix支持。在 `NVreg_EnableS0ixPowerManagement` 设置为 "1" 且系统挂起状态设置为 **s2idle** 的情况下，NVIDIA Linux驱动会在系统挂起时计算显存使用量。

- 在S0ix挂起期间，如果显存使用量低于某个阈值，驱动会将显存内容复制到系统内存，并关闭显存和GPU的电源。这有助于节省电力。
- 在S0ix挂起期间，如果显存使用量超过某个阈值，显存将保持在自刷新模式，而GPU的其余部分将被断电。

默认情况下，此阈值为256 MB，可以通过 `nvidia.ko` 的 `NVreg_S0ixPowerManagementVideoMemoryThreshold` 模块参数进行更改。

所有模块参数都可以在加载NVIDIA Linux内核模块 `nvidia.ko` 时通过命令行设置，或通过发行版的内核模块配置文件（如 `/etc/modprobe.d` 下的文件）设置。

## **systemd** 配置

本节专门针对 `/proc/driver/nvidia/suspend` 接口。如果使用 `NVreg_PreserveVideoMemoryAllocations=1` 内核模块参数或高级CUDA功能（如UVM），则此配置是必需的。如果使用默认电源管理机制，NVIDIA Linux内核驱动无需配置。

为了利用 `/proc` 接口，需要配置 **systemd** 等系统管理工具，在电源管理序列的适当时机访问该接口。具体而言，需要在写入Linux内核的 `/sys/power/state` 接口请求进入目标睡眠状态之前，使用该接口挂起或休眠NVIDIA内核驱动。该接口还需要在从睡眠状态返回后立即恢复NVIDIA内核驱动，以及在任何挂起或休眠尝试失败后立即使用。

以下示例配置记录了与 **systemd** 系统和服务管理器的集成，该管理器在现代GNU/Linux发行版中常用于管理系统启动和运行的各个方面。对于不使用 **systemd** 的系统，提供的配置文件可作为参考。

**systemd** 配置使用以下文件：

### `/usr/lib/systemd/system/nvidia-suspend.service`
systemd服务描述文件，用于指示系统管理器在访问 `/sys/power/state` 挂起系统之前，立即向 `/proc/driver/nvidia/suspend` 接口写入 `suspend`。

### `/usr/lib/systemd/system/nvidia-suspend-then-hibernate.service`
systemd服务描述文件，用于指示系统管理器在访问 `/sys/power/state` 挂起系统之前，立即向 `/proc/driver/nvidia/suspend` 接口写入 `suspend`。

**suspend-then-hibernate** 挂起方法需要systemd 248或更高版本。

### `/usr/lib/systemd/system/nvidia-hibernate.service`
systemd服务描述文件，用于指示系统管理器在访问 `/sys/power/state` 休眠系统之前，立即向 `/proc/driver/nvidia/suspend` 接口写入 `hibernate`。

### `/usr/lib/systemd/system/nvidia-resume.service`
systemd服务描述文件，用于指示系统管理器在从系统睡眠状态返回后，立即向 `/proc/driver/nvidia/suspend` 接口写入 `resume`。

### `/lib/systemd/system-sleep/nvidia`
systemd-sleep脚本文件，用于指示系统管理器在通过 `/proc/driver/nvidia/suspend` 接口尝试挂起或休眠系统失败后，立即向该接口写入 `resume`。

对于 **suspend-then-hibernate** 系统睡眠方法，如果系统因低电量警告而唤醒，此脚本负责恢复GPU然后使其进入休眠。此功能需要systemd 248或更高版本。

### `/usr/bin/nvidia-sleep.sh`
systemd服务描述文件和systemd-sleep文件使用的Shell脚本，用于与 `/proc/driver/nvidia/suspend` 接口交互。该脚本还管理X服务器的VT切换，这目前是NVIDIA X驱动支持电源管理操作所需的。

这些文件在检测到systemd时由nvidia-installer自动安装和启用。可以通过指定 **--no-systemd** 安装选项来禁用systemd单元的安装。

## 使用 **systemd** 执行电源管理

本节专门针对按上述方式配置的 `/proc/driver/nvidia/suspend` 接口。当使用默认电源管理机制，或者在不使用 **systemd** 的情况下使用 `/proc` 接口时，不需要使用 `systemctl`。

要分别执行挂起（suspend-to-RAM）或休眠（suspend-to-disk），请使用以下命令：

- `sudo systemctl suspend`
- `sudo systemctl hibernate`

有关 **systemd** 支持的睡眠操作的完整列表，请参见 systemd-suspend.service(8) 手册页。

## 已知问题与规避方法

- 在某些默认挂起模式为 `"s2idle"` 的系统上，由于内核中已知的时序问题，系统可能无法正常恢复。可以通过读取 `/sys/power/mem_sleep` 文件的内容来验证挂起模式。以下上游内核补丁已被提出用于修复此问题：
  - https://lore.kernel.org/linux-pci/20190927090202.1468-1-drake@endlessm.com/
  - https://lore.kernel.org/linux-pci/20190821124519.71594-1-mika.westerberg@linux.intel.com/
  - 在过渡期间，受影响系统的默认挂起模式应使用内核命令行参数 `"mem_sleep_default"` 设置为 `"deep"`：
  - **mem_sleep_default=deep**
