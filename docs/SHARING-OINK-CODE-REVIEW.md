# 跨屏光标与 Oink 的链路对照

**范围：**只读对照 [Oink 0.3.6 / c15f275](https://github.com/oinkvm/oink/tree/c15f2754f0469a25920eb389c97eacbe9b2c529a) 和 Untitled 0.12.16 的实现；不移植 GPL 代码。这次没有安装共享更新、操作实体光标、录屏或更改系统配置。

## 现场证据

- 80 已运行带 0.12.16 共享逻辑的宿主，最近一次本机光标取得成功，约 **50.48 ms**；之后仍有网络输入发送。该值是本机取得光标的总耗时，不是端到端延迟。
- 81 的共享运行版本仍为 **0.12.15**，最近一次在接收输入后未完成光标停放，约 **210.87 ms**（含清理）。状态仍连通、共享未停用，`hide`、`detach`、`show`、`reattach` 和归还区域返回成功；没有成功取得面板后会写出的 `balanceHide` / `ownerHide`。这是本机确认失败，不是断线，也不能从现有记录确定是命中还是回执失败。失败路径重新显示光标，没有把它保持在停放态；与用户看到旧屏边缘残留吻合。
- 81 回到 80 从右缘离开，而 81 的 Dock 也设在右边。该位置关系是检查系统边缘竞争的线索，**不是**已证明 Dock 拦截了该次命中。尚未记录命中点是否在实际 Dock 范围内，也没有同构建的 81 回执数据。

## 代码中的差异

| 环节 | Oink | 当前 Untitled |
| --- | --- | --- |
| 首次过屏 | 路由器在碰边分配新焦点 epoch，产生 `FocusEnter` 和源端冻结请求。Driver 优先提交能立即应用的模式请求，然后发焦点消息；macOS 设置模式的 native 工作依队列执行，先隐藏/解耦，后台面板另行取得光标。正常 `FocusEnter` 不等待目标发回一次确认才能开始路由后续运动。[路由](https://github.com/oinkvm/oink/blob/c15f2754f0469a25920eb389c97eacbe9b2c529a/crates/oink-routing/src/router.rs#L3833-L3889) · [Driver](https://github.com/oinkvm/oink/blob/c15f2754f0469a25920eb389c97eacbe9b2c529a/crates/oink-agent/src/threads/input/driver.rs#L1970-L2031) · [macOS 冻结](https://github.com/oinkvm/oink/blob/c15f2754f0469a25920eb389c97eacbe9b2c529a/crates/oink-input/src/macos/tap.rs#L780-L827) | 发 `begin`，目标准备；正常路径同时等 `accepted` 和本地**完整**面板命中、同位置事件回执、透明指针与二次隐藏，再发 `commit` 和第一笔输入。两个准备并行，不是简单相加，但较慢的一项实实在在挡住第一帧。见 `PeripheralSharingController.swift` 的 `requestControl`、`commitPreparedControl` 和 `SharingCursorCapture.swift` 的 `acquire`。 |
| 返回和旧屏停放 | 离开的屏幕（即使它的指针由远端驱动）切为冻结。普通边缘保持原位；对 Dock、顶端菜单及生效热角做专门处理。在原位置的后台面板取得透明光标后，只有需要时才用有代次的移动离开系统区域；面板覆盖有关区域。系统隐藏状态恢复使用平衡的 show/hide，不反复累加计数。[边缘规则](https://github.com/oinkvm/oink/blob/c15f2754f0469a25920eb389c97eacbe9b2c529a/crates/oink-input/src/warp_delta.rs#L402-L487) · [面板/事件](https://github.com/oinkvm/oink/blob/c15f2754f0469a25920eb389c97eacbe9b2c529a/crates/oink-input/src/macos/cursor_owner.rs#L335-L408) · [恢复隐藏](https://github.com/oinkvm/oink/blob/c15f2754f0469a25920eb389c97eacbe9b2c529a/crates/oink-input/src/macos/cursor.rs#L169-L229) | 接收端先排空回放、确认实际位置，然后在原地等同一个面板确认；成功之后才发带返回位置的 `end`，否则发取消并恢复本机光标。面板只覆盖冻结点附近，没有针对 Dock/菜单/热角的额外停放，也没有同样的持有期可见性恢复。见 `SharingInput.swift` 的 `parkAfterReturn`、`SharingNativeCursorSurface.swift` 和 `PeripheralSharingController.swift` 的 `returnAcrossEdge`。 |
| 落点及第一笔位移 | `RestoreLocal` 把定位、清理旧指针形状和显示视为一个原生过渡。warp 前降低原生本机事件抑制间隔；过滤旧 warp 前的硬件移动，核对后续位移是否包含人工定位；已有本机面板移动尚在途时仍有有界等待，不是所有归还都无等待。[原生定位](https://github.com/oinkvm/oink/blob/c15f2754f0469a25920eb389c97eacbe9b2c529a/crates/oink-input/src/macos/cursor.rs#L293-L345) · [旧事件栅栏](https://github.com/oinkvm/oink/blob/c15f2754f0469a25920eb389c97eacbe9b2c529a/crates/oink-input/src/macos/tap.rs#L977-L1003) · [在途回放等待](https://github.com/oinkvm/oink/blob/c15f2754f0469a25920eb389c97eacbe9b2c529a/crates/oink-input/src/macos/tap.rs#L707-L734) | 0.12.16 的合成事件源设为零抑制，**不等于**单独调用 `CGWarpMouseCursorPosition` 也调整了其抑制间隔。返回位移尾部补偿只保存运动，不能消除交接本身的等待，也没有为 warp 前后第一笔物理移动做相应的时间戳围栏。 |

## 0.12.19 复查

Oink 的 `check_frozen` 只记录新的漂移，不修正坐标，也不撤销焦点；后台窗口等待未命中时保留原生冻结。其隐藏状态调节是外观工作，不控制输入路由。Untitled 0.12.18 则在停放 API 成功后立即以 0.5 pt 验证目标，并在持有期间持续查询；81 的一次 **0.964 pt** 读回偏差足以暂停两端键鼠，TLS 和布局并没有断开。

0.12.19 把原生租约与外观任务分开。没有窗口命中或可见性证据也按协商协议正常交接；一次后台透明光标尝试按租约代次撤销，失败不会 show/re-hide、回退协议或关闭共享。与 Oink 不同，本版不投递用于探测、移位的标记运动：离开的接收端在面板覆盖两点后最多一次同步移位，避免异步光标事件晚于回位。窗口命中和位移顺序仍需真机复核。详见 [0.12.19 验证记录](SHARING-0.12.19-VALIDATION.md)。

## 旧版审查的优先顺序

1. **先把逻辑交接和光标外观确认拆开设计。** 保留经过认证的会话、有效权限/布局、接管代次和物理冻结门槛；比较一次有序边缘交接与目前等待往返确认的路径。外观恢复可在本机独立运行，但不得用 `CGDisplayHideCursor == success` 当作显示器上的真实隐藏证据；无可靠隐藏能力时按保守路径处理，不抢前台。不能仅删除授权或确认。
2. **给 Dock 等活跃边缘独立路径。** 确认窗口命中、标记回执和旧光标消失是三个不同阶段。验证原位置取得所有权后安全离开活跃区域；禁止在控制已归还后让迟到的标记事件把指针带回去，也不在失败时强行隐藏用户光标。
3. **归还采用有界的输入栅栏。** 把已提交事件的顺序、隐藏状态下定位、释放和恢复后首笔物理移动一起验证。只记录本机单调钟耗时和阶段，不用设备间未经同步的墙钟相减，不保存按键、轨迹或屏幕。

验收：同一签名构建装到两端后，在不改 Dock 位置的情况下，分别从 Dock 区域和普通边缘做多轮往返，核对每一方向首帧的可见性、旧屏箭头是否残留和首笔移动是否跟手；再核对急停、权限变化与断线的资源清理。只有真机视觉能回答“有没有旧光标”和“跟手”；单元测试及后台 API 状态不能替代。
