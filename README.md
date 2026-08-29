# ZCode Mobile

电脑上的 ZCode 官方网页远控，打包成 iPhone App。**界面就是官方原版网页，我们不画 UI**；App 本体只做两件事：

1. **承载官方网页**：扫码 / 相册 / 粘贴 `https://zcode.z.ai/remote/v4?...` 链接后，全屏加载官方远控界面，原汁原味
2. **任务通知**：退到后台后，App 用官方协议接管连接，轮询任务状态，任务**完成 / 出错**时弹系统横幅；可开 Bark 双保险

## 前后台交接

官方限制一个二维码同时只能有一个终端连接，所以：

- 前台：官方网页持有连接，正常操作
- 退后台：网页连接断开，原生监控接管，静音保活让进程不死
- 回前台：监控断开，网页自动重连

## 通知

- App 横幅：默认开，后台监控到任务从「运行中」变为「完成 / 出错」时弹
- Bark：设置里可开关，打开后填 `https://api.day.app/你的Key`，手机直接推

## 构建

Codemagic workflow：`zcode-mobile-unsigned-ipa`，产物 `ZCode.ipa`，巨魔安装。

```bash
python3 scripts/gen_xcodeproj.py   # 生成 Xcode 工程
```

电脑端可选（Bark 双保险）：`bridge/zcode_bridge.py` + `notify_stop.py` 挂到 ZCode 的 Stop hook。不用电脑端，手机后台监控也够用。

## 目录

```
App/Web/RemoteWebView.swift      官方网页容器
App/Chat/QRScanner…              扫码 / 相册识别
App/Session/OfficialRelay.swift  官方 relay 协议（配对 / bootstrap / 任务列表）
App/Session/MonitorController.swift  后台通知监控
App/UI/RootView.swift            连接页 + 设置
```
