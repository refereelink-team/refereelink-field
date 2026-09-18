# RefereeLink iOS 第一步：实机验证前交付清单

本阶段停止点：完成本清单后，不安装、不启动实体 iPhone，不连接或操作 DockKit 云台。以下内容只证明代码、Mock、Preview、Simulator 和 iPhoneOS 编译链路已就绪，不等同于 DockKit 实机验证。

## 已完成

- [x] iOS App target 接入 AVCaptureSession、AVCaptureVideoPreviewLayer 和 AVCaptureVideoDataOutput。
- [x] iPhone 摄像头权限说明保留；本阶段不使用的本地网络权限说明移除。
- [x] DockKit 真实实现由 #if canImport(DockKit) 隔离；Simulator 使用确定性 Mock。
- [x] 读取 DockKit 身份、连接状态、型号、固件、三轴角位置、三轴角速度和 UNIX 时间戳。
- [x] 仅启用 Apple system tracking；未调用 track、setOrientation 或 setAngularVelocity。
- [x] 使用 Date 完成最新视频帧与最新云台状态的实时对齐，同时保留视频 presentation timestamp。
- [x] 实现视频帧丢弃计数、视频/云台 age、stale 判定、断开/错误状态和可取消生命周期。
- [x] 主 test plan RefereeLink 已包含 RefereeLinkTests 与 RefereeLinkUITests；Watch 测试未纳入。
- [x] Swift Testing 单元测试和 XCTest UI 测试已完成。
- [x] Preview 覆盖初始等待、云台等待、视频运行、视频 stale、云台 stale 和错误状态。
- [x] Simulator Mock UI 已验证页面启动、可访问标识符、连接参数和错误态不崩溃。
- [x] Any iOS Device (arm64) 构建通过，真实 DockKit 分支已完成编译检查。
- [x] 未新增后端、网络、WatchConnectivity、第三方依赖、厂商 SDK 或 entitlements。

## 验证记录

- Xcode scheme：RefereeLink
- Simulator：iPhone 18 Pro / iOS 27.0
- RunAllTests：10 passed, 0 failed
- RenderPreview：初始等待、视频运行、错误状态均成功渲染
- iPhoneOS：Any iOS Device (arm64) BuildProject 成功，无 warning
- Simulator UI hierarchy：运行态参数区与底部 Mock 相机提示无重叠
- 以上结果不包含实体设备或真实 DockKit 连接证据。

## 下一阶段：实体设备验证

开始前确认实体 iPhone 已连接且目标 scheme/签名正确，然后逐项记录结果：

- [ ] 摄像头授权：允许、拒绝、再次授权后的状态正确。
- [ ] DockKit 云台连接：等待、连接、断开和重连状态正确。
- [ ] 身份信息：UUID、名称、型号、固件显示正确。
- [ ] 视频预览：画面来自 iPhone 摄像头，预览方向和尺寸正确。
- [ ] 三轴角位置更新：pitch/yaw/roll 映射和单位为弧度。
- [ ] 三轴角速度更新：单位为弧度/秒，时间戳为 UNIX epoch 转换后的 Date。
- [ ] 视频与云台时间差、age 和 stale 状态符合预期。
- [ ] 前后台切换：采集与 motion subscription 可取消并恢复。
- [ ] 重复订阅检查：重复启动/停止不会产生重复状态更新或重复 motion consumer。
- [ ] 云台断开和 motion stream 结束后无崩溃、无过期数据误显示。
