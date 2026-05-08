**一、 问题现象**
Bug#525775，曙光T50P工作站（Hygon C86-4G + NVIDIA RTX 4000 Ada），银河麒麟桌面V11（内核6.6.0-63-generic，NVIDIA驱动570.211.01），执行 `echo mem > /sys/power/state` 进入S3睡眠时提示"输入输出错误"。经验证，通过 `systemctl suspend` 触发睡眠可正常进入S3并成功唤醒，仅直接写 `/sys/power/state` 时失败。

**二、 问题分析**
通过dmesg日志定位，NVIDIA驱动在suspend回调（nv_pmops_suspend）中检测到模块参数 `NVreg_PreserveVideoMemoryAllocations` 已启用（默认值），但未通过 `/proc/driver/nvidia/suspend` procfs接口预先通知驱动，因此主动返回 `-EIO`（错误码-5）拒绝suspend。使用 `systemctl suspend` 时，systemd会先调用 `nvidia-suspend.service` 通过procfs接口通知驱动保存显存，再写 `/sys/power/state`，因此正常。直接写 `/sys/power/state` 跳过了systemd的协调步骤，属于NVIDIA驱动的设计行为，不是系统缺陷。

**三、 后续计划**
- 方案一（推荐）：使用 `systemctl suspend` 替代 `echo mem > /sys/power/state` 触发睡眠，为NVIDIA驱动官方推荐的标准操作方式。
- 方案二（软件规避）：在 `/etc/modprobe.d/nvidia.conf` 中设置 `NVreg_PreserveVideoMemoryAllocations=0`，禁用后直接写sysfs也可睡眠，但显存内容会丢失。
- 方案三（保留两种方式）：直接写sysfs前手动调用 `echo suspend > /proc/driver/nvidia/suspend`，唤醒后调用 `echo resume > /proc/driver/nvidia/suspend`。
