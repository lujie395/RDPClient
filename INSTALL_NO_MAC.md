# 无 Mac 安装指南（只有 Windows 电脑 + iPhone）

本工程编译 iOS 应用 normally 需要 Mac + Xcode。没有 Mac 时有两条路：

---

## 路线 A：直接用微软官方 App（5 分钟，先试这个）

如果目的只是「手机控制 Windows 电脑」，没必要自己编译——App Store 直接搜
**Windows App**（微软官方，原名 Microsoft Remote Desktop / RD Client），免费安装：

1. Windows 电脑：设置 → 系统 → 远程桌面 → 打开
2. `Win + R` → `cmd` → `ipconfig`，记下 **IPv4 地址**
3. iPhone 和电脑连**同一个 Wi-Fi**，打开 Windows App → ＋ → 填 IP、Windows 账号密码 → 连接

> 建议先用路线 A 验证你的电脑能被远程连接。确认能用后，如果还想要
> 我们自己做的这个 App（界面更顺手、手势定制），再走路线 B。

---

## 路线 B：把我们做的 App 装上手机（免费，首次约 1~2 小时）

思路：**借 GitHub 免费的苹果云电脑编译出 IPA，再在 Windows 上签名安装**。

### 第 1 步：把工程传到 GitHub

1. 注册/登录 [github.com](https://github.com)
2. Windows 上安装 [GitHub Desktop](https://desktop.github.com)
3. GitHub Desktop → `File → Add Local Repository` → 选择 `RDPClient` 文件夹
   （提示不是仓库时选 `Create a Repository`，名字填 `RDPClient`）
4. `Publish repository` 发布，**选 Public（公开）**——公开仓库的 Actions 编译时长**完全免费不限量**
   （本工程不含任何密码和隐私，公开没有问题）

### 第 2 步：云端编译出 IPA

1. 打开你仓库的网页 → 顶部 **Actions** 标签 → 若提示启用，点 `I understand...` 启用
2. 左侧选 **Build IPA (unsigned)** → 右侧 `Run workflow` → `Run workflow`
3. 等待约 **30~60 分钟**（在云端编译 OpenSSL 和 FreeRDP）
4. 完成后点进该次运行 → 页面底部 **Artifacts** → 下载 `RDPClient-unsigned-ipa`
5. 解压得到 **RDPClient-unsigned.ipa**

> 失败了？点进失败的运行看红色步骤的日志，把报错内容发给 AI 助手即可修复。

### 第 3 步：在 Windows 上签名并安装到 iPhone

1. Windows 装 [iTunes](https://www.apple.com/itunes/)（**必须官网下载版**，商店版缺驱动），
   数据线连接 iPhone，首次连接手机上点「信任」
2. 下载安装 [Sideloadly](https://sideloadly.io)（Windows 版）
3. 打开 Sideloadly：
   - 把 `RDPClient-unsigned.ipa` 拖进窗口
   - **Apple ID** 处填你自己的 Apple ID（普通免费账号即可）
   - `Start` → 输入该 Apple ID 的密码 → 等待完成
4. iPhone 上：**设置 → 通用 → VPN 与设备管理 → 信任** 你的 Apple ID（开发者证书）
5. 桌面出现 RDPClient 图标，打开即用（首次会弹「本地网络」权限，**必须允许**）

### 第 4 步：7 天有效期（免费账号的限制）

免费 Apple ID 签名的 App **7 天后无法打开**，两种处理：

| 方式 | 操作 |
|---|---|
| **手动重签** | 7 天后用数据线连 Windows，重新跑一遍 Sideloadly（不用重新编译，IPA 还在） |
| **自动续签（推荐）** | 改用 [AltStore](https://altstore.io)：Windows 装 AltServer（常驻），iPhone 装 AltStore，之后**手机和电脑在同一 Wi-Fi 时自动续签**，无需干预 |

> 免费账号其他限制：最多同时签 3 个自装 App；推送等高级能力不可用（本 App 用不到，无影响）。
> 想彻底解除限制需要 Apple 开发者计划（¥688/年），可在任意设备网页办理，依然不需要 Mac。

### 常见问题

| 问题 | 处理 |
|---|---|
| Sideloadly 报「iTunes not found」 | 装官网版 iTunes 后重启电脑 |
| 安装后打开闪退/无法验证 | 重新走一遍「VPN 与设备管理 → 信任」 |
| 连不上电脑 | 见 README「排查」一节；先用路线 A 确认 Windows 端远程桌面正常 |
| 想更新 App（改了代码） | 重新跑第 2 步 Actions 编译 → 用新 IPA 重签安装 |

---

## 两条路线对比

| | 路线 A：官方 Windows App | 路线 B：自建 RDPClient |
|---|---|---|
| 耗时 | 5 分钟 | 首次 1~2 小时，之后 10 分钟 |
| 费用 | 免费 | 免费 |
| 需要 Mac | 否 | 否（GitHub 云端代替） |
| 定制/学习价值 | 无 | 完全自己的 App，可随意改 |
