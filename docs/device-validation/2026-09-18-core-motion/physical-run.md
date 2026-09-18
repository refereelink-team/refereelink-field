# Core Motion 实体机验证（2026-09-18）

本记录来自 Xcode 在 `Cayson's iPhone` 上启动的真实 iPhoneOS 运行会话，不是模拟器 Mock。

## 启动信息

- 运行目标：Cayson's iPhone
- 系统：iOS 27.0
- Launch session：`77600f8480`
- 进程：`RefereeLink`，PID `9682`
- 应用路径：`/private/var/containers/Bundle/Application/.../RefereeLink.app`
- Core Motion 参照系：`xArbitraryZVertical`
- 采样频率：60 Hz

## 视频流

- 首帧：1920×1080
- 首帧 presentation timestamp：56553.912235
- 帧计数持续增长：60、120、180、240、300、360、420、480、540
- 丢帧：0

## Core Motion 姿态与角速度

### 初始与低运动段

```text
first: timestamp=56553.952889
pitch=0.033019, yaw=0.000128, roll=-0.007723
rateXYZ=(0.000267, -0.001034, 0.000480)

sample=60:  timestamp=56554.842031
pitch=0.032677, yaw=-0.000237, roll=-0.007782
rateXYZ=(0.000324, 0.000582, 0.000341)

sample=120: timestamp=56555.746264
pitch=0.030939, yaw=0.077974, roll=-0.008818
rateXYZ=(0.001537, -0.002256, -0.000930)

sample=180: timestamp=56556.650517
pitch=0.031573, yaw=0.078735, roll=-0.009277
rateXYZ=(-0.000869, -0.000063, 0.000931)
```

### 动作段

```text
sample=540: timestamp=56562.076178
pitch=1.092821, yaw=0.152628, roll=0.461908
rateXYZ=(-2.011319, -0.992550, -0.161796)

sample=600: timestamp=56562.980465
pitch=0.573347, yaw=0.625147, roll=-0.119539
rateXYZ=(0.914718, 3.811572, 0.105388)

sample=660: timestamp=56563.884755
pitch=0.745702, yaw=0.417043, roll=0.034348
rateXYZ=(0.097240, -1.679747, 0.347765)
```

## 结论

- iPhone Core Motion 首帧成功到达，且样本数持续增长。
- 姿态角和三轴角速度在实体机动作前后出现显著变化；本次“iPhone 相机姿态采集”验收通过。
- 视频流同时持续产生 1920×1080 帧，丢帧保持 0。
- 这证明的是 iPhone/相机设备姿态，不是 DJI 云台电机轴参数。
- 本次日志只确认 DockKit source 已启动；未将 DockKit `motionStates` 作为三轴数据来源。

## 备注

启动时出现少量系统 `AVFCapture` `err=-12710` 日志，但随后首帧和持续视频帧均正常产生，因此未阻断本次采集。实体机 UI 截图未通过当前 Device Interaction 会话导出，保留了 Xcode Console 运行证据。
