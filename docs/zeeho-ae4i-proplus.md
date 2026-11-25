# 极核 AE4i Pro+ 6.2 寸（2048×968）输出

2026 款极核 AE4i Pro+ 的 6.2 寸仪表在 PXC 媒体配置（TCP 10711，命令 `0x10`）里上报的尺寸是 **2048×968**，而 v1.0.4 的「极核 6.2 寸」只接受 1024×480 / 1024×488，于是连接在这里中断：

```
极核连接失败：媒体控制 TCP10711：台铃协议：仪表媒体尺寸 2048×968 与 极核 配置不符
```

2048×968 = 1024×484 的 2 倍，属于 6.2 寸 2 倍屏的上报方式。

## 改了什么

- 新增输出方式 **「极核 AE4i Pro+ 6.2 寸」**（`HeadUnitOutput.zeehoAE4i`，持久化 ID 12，追加在既有 0–11 之后，旧设置的 ID 不变）。
- 新 profile `TailingDisplayProfile.zeehoAE4i`：
  - `preferredSize` = 2048×968，于是本机 CarPlay 也按 2048×968 渲染，投屏时不需要放大，文字才清晰。
  - `outputSize(for:)` 接受 1024…2048 × 480…1080 内宽高为偶数的横屏上报尺寸，并原样编码（与 SE+ / AE2 的做法一致）；老款 1024×480 的 6.2 寸仪表选到这一项也能用，编码时再缩到仪表尺寸。
  - `bitrateScale` = 4：25 FPS 从 2.5 Mbit/s 提到 10 Mbit/s，30 FPS 封顶 12 Mbit/s，与 6.2 寸旧款「每像素码率」保持一致。
- 走的是通用 PXC 连接（`App/TailingConnection.swift` + `App/ZeehoOutput.swift`），不是被冻结的 `Zeeho62Legacy` 原版协议副本，因此 `Tools/verify_legacy62.py` 的原版校验仍然成立。
- 「极核 6.2 寸」（AE4 MAX2+）的行为没有任何变化。

## 怎么用

1. 「当前输出」选择「极核 AE4i Pro+ 6.2 寸」，然后点「输出设置」确认「自动查找仪表 IP」打开（默认关闭手动地址即可）。
2. iPhone 加入仪表 Wi-Fi，点「启动 CarPlay」。日志应出现「媒体身份回显校验通过，仪表报告 2048×968」和「极核首帧已发送 · 2048×968 · 兼容转码 · 目标 25 FPS · 码率 10.0 Mbit/s」。
3. 如果仪表没有出画，先切回「极核 6.2 寸」确认旧路径的现象，再把日志（诊断与实验）反馈出来。

## 还没有验证的部分

- 没有实机：这套改动只根据上报尺寸和既有协议实现推导，未在 AE4i Pro+ 上验证出画。
- 2048×968 的 CarPlay 虚拟画面是 App 自己声明的显示器，代码里浏览器输出本来就允许到 4K，但没有在真机上确认 CarPlay 接受 2.116:1 的 2048×968。
- 仪表侧解码器能否稳定吃 10 Mbit/s 的 2048×968 H.264 未知；若卡顿或花屏，可先切回「极核 6.2 寸」。

## 构建

- 有 Mac：Xcode 打开 `TDSCarKit.xcodeproj`，选择自己的团队签名后构建；不签名也能编出 `.app`。
- 没有 Mac：`.github/workflows/build-unsigned-ipa.yml` 会在 GitHub 的 `macos-14` 运行器上跑 `xcodebuild`（关闭签名），产出 `CarWithin-1.0.5-unsigned.ipa` 构件，下载后用 Sideloadly / AltStore / TrollStore 按自己的方式签名安装。

```sh
xcodebuild -project TDSCarKit.xcodeproj -scheme TDSCarKit -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" DEVELOPMENT_TEAM="" build
```

本分支的版本号为 1.0.5（build 17），装好后 App 内显示 1.0.5 即说明是这份构建。
