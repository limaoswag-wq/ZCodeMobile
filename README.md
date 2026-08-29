# ZCode Mobile

电脑上的 ZCode 控制器。不是套网页，是原生 iOS 客户端。

- SwiftUI 做壳：首页、任务列表、设置
- UIKit 做聊天：`UITableView` 气泡、TextKit Markdown、`UITextView` 输入栏
- 长代码和 Mermaid 才嵌 `WKWebView`，不包 ZCode 网页远程控制

任务完成时默认弹 App 自己的系统横幅。Bark 在设置里可开关，打开后电脑还会再推一条。

## 它做什么

- 扫描电脑 ZCode「移动端远程控制」二维码，或粘贴复制出来的 `https://zcode.z.ai/remote/v4?...` 地址
- 连上后用原生界面看任务、发消息，不嵌官方网页
- 圆润按钮、暖色 Claude 风
- 电脑 ZCode 必须开着，活还是在 Windows 上跑

## 电脑桥

```powershell
cd C:\Users\58499\ZCodeProject\ZCodeMobile\bridge
python zcode_bridge.py
```

第一次会写出 `bridge/config.json`，终端里会打印：

- 端口，默认 `18765`
- 配对令牌
- 局域网地址

把这三项填进手机 App 的设置。手机和电脑要在同一 Wi-Fi。Windows 防火墙如果拦了，给 Python 放行 18765。

可选：在 ZCode 桌面端建一个 Webhook 机器人，把 Callback URL、botId、secret 填进 `config.json` 的 `zcodeCallbackUrl` / `zcodeBotId` / `zcodeWebhookSecret`。这样发消息会走官方 bot 通道。不填则写入 ZCode 的 `session_input` 队列。

出站 Webhook 可填：

```
http://<电脑IP>:18765/zcode/outbound
```

任务结束时如果开了 Bark，`bridge/notify_stop.py` 会再推一条。把这个脚本接到 ZCode 的 `Stop` hook 即可。

## 手机

Codemagic workflow：`zcode-mobile-unsigned-ipa`  
产物：`ZCode.ipa`，用巨魔安装。

打开 App → 扫描二维码连接，或点「粘贴远控地址」。

同一时间这个二维码只能被一个手机端占用；网页远控开着时，App 会提示被踢。

局域网桥仍然可用：设置里填电脑 IP、端口、令牌。扫码是主路径。

通知：

- App 横幅：默认开。手机 App 连着桥的时候，任务从进行中变成完成/出错会弹系统横幅
- Bark：默认关。打开后填 `https://api.day.app/<key>`，电脑在任务结束时再推一条，杀 App 也能响

## 和 Kimi 的关系

按钮、气泡、输入条按 Kimi 的圆润信息架构来，暖色按 Claude。没有去改 Kimi 的包。聊天主路径是 UIKit，不是把 ZCode 网页塞进 WebView。
