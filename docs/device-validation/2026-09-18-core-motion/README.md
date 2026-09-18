# Core Motion 模拟器验证（2026-09-18）

本目录记录 RefereeLink 改用 iPhone Core Motion 作为主相机姿态数据源后的模拟器验证证据。

## 结论

- 模拟器 Mock 运行成功，应用保持运行。
- `相机姿态` 区域显示 `iPhone Core Motion` 和 `启动相对坐标`。
- Mock 姿态流持续更新，样本数增长；视频帧持续增长，丢帧为 0。
- 视频与相机姿态同步区域可见，UI 层级和截图未发现崩溃、重叠或异常裁切。
- 这不是 Core Motion 实机传感器验证，也不是 DockKit 云台电机轴验证。

## 验证环境

- 设备：iPhone 18 Pro Simulator
- 系统：iOS 27.0
- 启动参数：`--mock`
- 数据源：`MockCameraMotionSource`、`MockCameraCaptureService`、`MockDockKitSource`

## 关键观察

- 相机姿态状态：采集中
- 样本数：持续增长（截图时 383）
- 同步时间差：0.000 s（Mock 时钟）
- 视频数据 age：约 0.105 s
- 相机姿态数据 age：约 0.105 s
- 帧 / 尺寸：385 / 1280×720
- 丢帧：0

## 文件

- `simulator-mock-run.png`：Mock 运行截图（在最后一次 Mock 有界波形修正前采集，但 UI 链路相同）
- `simulator-mock-run-hierarchy.txt`：UI 层级
- `simulator-mock-run-logs.txt`：运行日志
- `preview-initial-wait.png`：Preview 截图
- `test-summary.txt`：最终 Xcode test plan 摘要，21/21 通过
- `test-summary-final.txt`：加入实机诊断日志后的最终 Xcode test plan 摘要，21/21 通过
- `physical-run.md`：实体 iPhone Core Motion 与视频流验收记录

## 实体机状态

实体机验证已完成；详见 `physical-run.md`。本目录中的实体机结论是“iPhone 相机姿态采集成功”，不是“DockKit 云台电机轴采集成功”。
