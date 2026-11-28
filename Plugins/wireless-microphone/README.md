# 无线麦

无线麦 2.0.1 适用于 Untitled 0.13.55+ 和 macOS 14+。在插件里查找、配对和连接小米蓝牙遥控器 2（RC001）或 2 Pro（RC003）。按住遥控器语音键收音，松开结束。插件提供输入电平，并可把声音送给选用了 **Untitled Microphone** 的录音、会议或听写应用。

## 配对与使用

1. 打开 Untitled 的「我的插件 → 无线麦」，点击「查找遥控器」。首次使用时，在 Untitled 权限管理允许蓝牙，然后重新查找。
2. 首次配对时，同时长按遥控器的主页键和菜单键以进入配对模式。设备可能显示为 **MI RC** 或「小米蓝牙语音遥控器」。点击设备旁的「连接」，如出现配对码提示，请核对后确认。
3. 显示「已连接」后，按住遥控器语音键讲话，查看插件的输入电平。松开时收音结束。
4. 要把声音送入其他应用，在无线麦中点「复制安装命令」，在终端运行并重启 Mac。在目标应用的输入设置中选择 **Untitled Microphone**。电平试音可在安装驱动前使用。

在「插件商店 → 从 ZIP 安装」选择 2.0.1 插件包可升级旧版。沿用原插件标识、启用状态和自定义操作。

## 实现与资源

插件通过 CoreBluetooth 和 IOBluetooth 查找用户可选的小米遥控器。首次连接由 macOS 配对接口完成，然后通过 CoreBluetooth 协商 ATVV v1.0。安装、启用和打开面板时保持空闲。查找、配对和语音连接分别有 20、35、20 秒期限，候选列表最多显示 12 台设备。候选句柄和配对码仅在当前操作期间保存在内存中。取消、断连、锁屏、睡眠、停用、更新、卸载和退出会停止扫描或配对，并释放语音会话。

16 kHz IMA ADPCM 在内存解码，虚拟输入只写入 Untitled 自己的 Feed。单条音频通知、协商帧均限制为 512 字节。队列保存至多 200 ms PCM。松键后输出最多保留 260 ms 尾音。收音时电平最多每秒更新 10 次。语音会话在两秒没有音频或达到 65 秒时结束。连接和音频都在这台 Mac 处理。

参考 [SayAll 技术文档](https://github.com/HD838A/remote-mic-app/blob/main/TECHNICAL.md)、[RC001 兼容记录](https://github.com/HD838A/remote-mic-app/blob/main/Bugs/2026-08-08-rc001-voice-remote-compatibility.md) 和 [MiRemoteVoice 的 ATVV 资料](https://github.com/VincentKingHsu/MiRemoteVoice)。Untitled 原生实现使用本仓库的 MIT 许可。虚拟麦克风使用随宿主提供的 [Untitled HAL 驱动](../peripheral-sharing/Tools/SharingMicrophone/README.md)。

自动测试覆盖设备名称、配对确认和取消、发现多个候选时由用户选择、协商、ADPCM 分片、启动门禁、松键尾音、无驱动试音、权限拒绝、停用和从 1.0.0 升级。未配对设备发现、蓝牙配对、实物按键收音与实际 HAL 输入仍需要在 RC001 或 RC003 上验证。
