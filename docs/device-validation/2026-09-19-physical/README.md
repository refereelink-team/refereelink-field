# RefereeLink 实体机验收记录

日期：2026-09-19

设备：Cayson’s iPhone / iPhone 15 Pro

设备标识：实体 iPhone（设备 UUID 已脱敏）
iOS：27.0（24A437）

## 已通过

- `testPhysicalSmokeStatusSectionsStart`：在实体 iPhone 上通过，确认真实设备页面、DockKit 区域、相机指标、同步区域和相机预览可访问。
- `testPhysicalOfflineCaptureStartsAndStops`：在实体 iPhone 上通过，未传入 `--mock`；实际点击离线采集、等待 3 秒、停止，并确认保存后出现导出控件。
- App 运行截图中可见真实摄像头画面和 `iPhone Core Motion` 姿态数据。姿态角与角速度均出现非空数值，Core Motion 样本数持续增长。

## 当前观察

- DockKit 区域显示“等待连接”，型号、固件为空，DockKit motion sample count 为 0。当前不能报告 DockKit accessory identity 或 `motionStates` 实机通过。
- Core Motion 采集成功；本次截图中相机姿态流显示“采集中”。
- 实体机离线采集开始/停止和保存后的导出入口通过；ZIP 分享动作尚未单独点击验证。
- 本次补测已配置本机轻量 receiver-only 后端，并通过 Tailscale HTTPS/WSS 完成实体机通信：能力查询 200、会话注册 201、WSS 接受，后端收到真实 iPhone 的 1 个视频帧元数据和 4 个 Core Motion 样本。
- 本机 `/opt/homebrew/bin/ffmpeg` 不包含 `srt` 协议，实时分配返回 503；因此本次不能报告 SRT listener、MPEG-TS 解码或 PTS 接收通过。
- 测试结束后 CoreDevice 通道再次变为 `unavailable`，因此未能追加停止后的截图。

## 再次启动记录（13:08）

- Xcode 已将运行目的地切换为实体 `Cayson’s iPhone`，`RunProject` 返回启动成功；本次启动会话 PID 为 `16845`。
- 相机首帧日志为 `1920x1080`；约 30 秒内视频帧计数从 0 增长到 900，丢帧始终为 0。
- Core Motion 以 `xArbitraryZVertical`、60 Hz 启动；首个样本成功，约 30 秒内样本数增长到 2040，pitch/yaw/roll 和 XYZ 角速度持续产生数值。
- 本次 DockKit 日志仍只有 `DockKit source started`，未出现 DS508 身份、连接状态或 `motionStates` 样本，因此仍不能报告 DockKit 三轴运动流成功。
- 本次未配置后端 endpoint，未执行 WSS/SRT 实时传输验收。

## Tailnet/WSS 接收补测（13:29）

- 本机 receiver-only 后端监听 `0.0.0.0:8000`，通过内部 Tailscale Serve 暴露 HTTPS。
- 本机和 iPhone 均使用同一 Tailnet；具体地址、内部主机名和实体机会话标识不写入仓库。
- 已确认：`GET /capabilities` 返回 200、`POST /sessions` 返回 201、`WSS /ws/v1/field/sessions/{id}` accepted；状态曾记录 `frame_count=1`、`motion_count=4`、`client_sequence=1`、`gap_count=0`。
- SRT allocation 返回 503，原因是本机 FFmpeg 未声明 `srt` protocol。该环境阻塞只影响 SRT 视频接收，不影响上述 HTTPS/WSS 会话注册与首批遥测接收证据。
- 未将 WSS 首批接收或本地 Core Motion 成功误报为生产后端联调、连续实时视频或推理通过。

## 证据

- `physical-running-camera-core-motion.png`：运行中的真实摄像头画面、Core Motion 姿态和 DockKit 等待状态。
- `physical-running-after-3s.png`：约 3 秒后的运行画面，姿态值发生更新。
- `physical-core-motion-running.png`：Core Motion 运行画面。
- `physical-lock-screen-before-unlock.png`：设备重新连接前的锁屏状态。

## PTS 修复后最终闭环（2026-09-19）

- 本机与 iPhone 通过同一 Tailnet 的 HTTPS Serve 连接；具体网络地址和临时凭据不写入仓库。
- receiver-only 后端能力检查返回 `receiver_available=true`、`transport.srt=true`、`srt_reason=null`；本轮使用的 FFmpeg 明确声明 `srt` 协议。
- 最终实体机会话已完成 WSS/SRT 闭环：WSS 的 frame 与 Core Motion 计数持续增长，最终观测 `frame_count=3871`、`motion_count=8563`、`gap_count=0`。
- SRT epoch 1 处于 `listening`，FFmpeg 已解码 `3845` 帧，`last_error=null`；MPEG-TS `time_base=1/90000`、持续时长约 `128.24 s`。
- PTS：SRT 首帧 `first_pts90k=0`；iOS 遥测首帧 `transport_pts90k=0`，后续单调递增，检查样本 `3876` 个，无下降。
- UI 最终截图显示“实时参数：已连接”；同时可见真实相机画面和 `iPhone Core Motion` 姿态/角速度数值。
- 本轮修复解决了旧遥测在 SRT epoch 建立后被延迟批量误标的问题，以及瞬时发送失败后 UI 永久显示“重连中”的状态恢复问题。

关键截图：

- `physical-field-ingest-connected.png`：PTS 修复与状态修复后的实体机实时采集页面。

本轮仅归档上述关键截图和稳定结果摘要；原始 MPEG-TS、完整 NDJSON、完整日志和临时凭据保留在本机临时目录，不提交 Git。

XCTest 结果包保存在本机临时路径：

- `/private/tmp/refereelink-physical-ui.xcresult`
- `/private/tmp/refereelink-physical-capture.xcresult`

后续需要补测：配置 libsrt-enabled FFmpeg 后的 SRT listener/解码/PTS 闭环、WSS 连续计数、DockKit 连接身份/诊断、ZIP 分享，以及较长时段的本地录制和素材完整性。
