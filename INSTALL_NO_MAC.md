# 路线 B 详细操作手册：从零把 RDPClient 装上 iPhone

> **适用场景**：你只有一台 Windows 电脑和一部 iPhone，没有 Mac。
> **总耗时**：首次约 1.5~3 小时（其中 1 小时是电脑自己在云上干活，你只需等）。
> **费用**：0 元。
>
> 全程分 6 个阶段，按顺序做即可。每个阶段末尾有「✅ 检查点」，确认通过再往下走。

---

## 目录

- [阶段 0：准备工作（15 分钟）](#阶段-0准备工作15-分钟)
- [阶段 1：把工程传到 GitHub（15 分钟）](#阶段-1把工程传到-github15-分钟)
- [阶段 2：云端编译出 IPA（1 小时，主要是等待）](#阶段-2云端编译出-ipa1-小时主要是等待)
- [阶段 3：准备 iPhone 连接环境（20 分钟）](#阶段-3准备-iphone-连接环境20-分钟)
- [阶段 4：签名并安装到 iPhone（15 分钟）](#阶段-4签名并安装到-iphone15-分钟)
- [阶段 5：首次使用与 7 天续期（10 分钟）](#阶段-5首次使用与-7-天续期10-分钟)
- [附录 A：常见报错速查](#附录-a常见报错速查)
- [附录 B：AltStore 自动续签完整配置](#附录-baltstore-自动续签完整配置)
- [附录 C：付费开发者账号（可选，解除 7 天限制）](#附录-c付费开发者账号可选解除-7-天限制)

---

## 阶段 0：准备工作（15 分钟）

### 0.1 确认 Windows 电脑能被动远程连接

这一步**必须先做**，否则 App 装好了也连不上。

1. 电脑上打开：**设置（Win + I）→ 系统 → 远程桌面** → 把开关打开
2. **如果找不到这个开关**，说明你是 Windows 家庭版，不支持被远程连接。解决方法二选一：
   - 升级到 Windows 专业版
   - 改用其他方案（请告知 AI 助手，可换 VNC 等免费替代）
3. 查询电脑 IP：`Win + R` → 输入 `cmd` → 回车 → 输入 `ipconfig` → 回车
4. 在输出里找到 **「无线局域网适配器 WLAN」** 下的 **IPv4 地址**，类似 `192.168.1.100`，**抄下来**
   - ⚠️ 注意是 `192.168.x.x` 或 `10.0.x.x` 开头的内网地址，不是 `169.254.x.x`（那是没连上网）
5. 设置密码：**设置 → 账户 → 登录选项 → 密码**，确保账户有密码
   - 没有密码的账户无法用于远程桌面

**记下三样东西**：

| 项目 | 你的值 |
|---|---|
| 电脑 IP | `192.168.___.___` |
| Windows 用户名 | （本机账户：`whoami` 命令查看；微软账户：填完整邮箱） |
| Windows 密码 | （微软账户就是你的微软账户密码） |

> **怎么判断是微软账户还是本机账户？** 设置 → 账户 → 你的信息，如果显示邮箱地址就是微软账户。

### 0.2 确认 iPhone 与电脑在同一 Wi-Fi

- iPhone：设置 → 无线局域网，看连的是哪个 Wi-Fi
- 电脑：右下角网络图标，看连的是不是同一个 Wi-Fi 名字
- ⚠️ 必须同一个路由器。手机用 5G 流量、或电脑插网线连的是另一个网段都会连不上

### 0.3 下载必备工具（都在 Windows 上）

| 工具 | 用途 | 下载地址 | 注意 |
|---|---|---|---|
| **GitHub Desktop** | 管理代码、上传到 GitHub | [desktop.github.com](https://desktop.github.com) | 直接下载 Windows 版 |
| **iTunes** | 提供 USB 驱动和文件传输组件 | [apple.com/itunes](https://www.apple.com/itunes/) | ⚠️ **必须官网下载版**，微软商店版缺驱动，Sideloadly 认不到 |
| **Sideloadly** | 给 IPA 签名并安装到 iPhone | [sideloadly.io](https://sideloadly.io) | 选 Windows 版 |
| **7-Zip**（可选） | 解压 zip | [7-zip.org](https://www.7-zip.org) | Windows 自带解压也能用 |

### ✅ 检查点 0

- [ ] Windows 远程桌面开关已打开
- [ ] 已抄下电脑 IPv4 地址
- [ ] Windows 账户有密码
- [ ] 手机和电脑连的同一个 Wi-Fi
- [ ] 4 个工具已下载（iTunes 装好并重启过电脑）

---

## 阶段 1：把工程传到 GitHub（15 分钟）

### 1.1 注册 GitHub 账号

1. 打开 [github.com](https://github.com) → `Sign up`
2. 填邮箱、密码、用户名（用户名会出现在仓库地址里，随便取）
3. 完成邮箱验证

> 已经有账号的跳过这步。

### 1.2 下载并解压工程

1. 在这个对话里，点击之前给你的 **`RDPClient.zip`** 卡片上的下载按钮
2. 浏览器下载到「下载」文件夹
3. 右键 zip → 「全部解压缩」，得到 `RDPClient` 文件夹
4. 建议把它移到桌面或 `D:\RDPClient`，**路径不要带中文和空格**（避免后续脚本出问题）

解压后应该是这样：

```
RDPClient\
├── .github\              ← 隐藏文件夹（关键！）
│   └── workflows\
│       └── build-ipa.yml
├── scripts\
│   ├── build_freerdp.sh
│   └── build_openssl.sh
├── RDPClient\            ← App 源码
│   ├── App\
│   ├── Bridge\
│   ├── Input\
│   ├── Models\
│   ├── Services\
│   ├── Views\
│   ├── Assets.xcassets\
│   ├── Info.plist
│   └── PrivacyInfo.xcprivacy
├── bootstrap.sh
├── project.yml
├── README.md
└── INSTALL_NO_MAC.md
```

### 1.3 ⚠️ 关键：确认 `.github` 文件夹存在

Windows 默认隐藏以点开头的文件夹。先打开显示隐藏文件：

**Windows 11**：文件资源管理器 → 顶部「查看」→「显示」→ 勾选「隐藏的项目」
**Windows 10**：文件资源管理器 → 顶部「查看」标签页 → 勾选「隐藏的项目」

现在应该能看到 `.github` 文件夹了。**如果看不到它，云端编译绝对会失败**（因为没有工作流文件）。

### 1.4 用 GitHub Desktop 发布仓库

1. 打开 GitHub Desktop → 首次使用会让你登录，登录你的 GitHub 账号
2. 菜单 `File` → `Add Local Repository...`
3. `Local path` 选择你的 `RDPClient` 文件夹 → 点 `Add Repository`
4. 会弹出提示「这个目录不是 Git 仓库，是否创建？」→ 点 **`create a repository`**
5. 在创建界面：
   - `Name`：填 `RDPClient`
   - `Local Path`：保持默认（不要动）
   - `Git ignore`：`None`（工程自带 `.gitignore`，不要用模板覆盖）
   - `License`：`None`
   - 点 **`Create Repository`**
6. 左上角点 **`Publish repository`**
7. 弹窗里：
   - `Name`：`RDPClient`
   - ⚠️ **取消勾选 `Keep this code private`** → 必须是 **Public（公开）**
     - 公开仓库的 Actions 云编译**免费不限时长**；私有仓库每月只有 2000 分钟额度
     - 工程里不含任何密码或隐私数据，公开没有风险
8. 点 `Publish Repository`

### ✅ 检查点 1

- [ ] 浏览器打开 `https://github.com/你的用户名/RDPClient` 能看到代码
- [ ] 页面上能看到 `.github/workflows/build-ipa.yml` 这个文件（点进 `.github` → `workflows` 查看）
- [ ] 仓库是 Public（页面标题旁有 `Public` 标签）

---

## 阶段 2：云端编译出 IPA（1 小时，主要是等待）

### 2.1 启用 Actions

1. 打开你的仓库页面 → 顶部标签栏点 **`Actions`**
2. 首次进入会显示一片介绍页，点绿色按钮 **`I understand my workflows, go ahead and enable them`**
3. 左侧列表会出现 **`Build IPA (unsigned)`**（我刚给你加的工作流）

> 如果左侧列表是空的，或者提示「Workflows aren't being run on this forked repository」之类的：
> 说明 `.github/workflows/build-ipa.yml` 没上传成功，回到阶段 1.3 检查隐藏文件夹。

### 2.2 手动触发编译

1. 左侧点 **`Build IPA (unsigned)`**
2. 右上角会出现一个下拉按钮 **`Run workflow`** → 点它
3. 弹出小窗，分支选 `main` → 再点绿色 **`Run workflow`**
4. 刷新页面，几秒后会出现一条新的运行记录，黄色圆点表示正在跑

### 2.3 等待并观察进度

点击那条运行记录，能看到 6 个步骤依次执行：

| 步骤 | 说明 | 大致耗时 |
|---|---|---|
| 检出代码 | 拉取你的仓库 | 10 秒 |
| 安装构建工具 | 装 cmake / xcodegen / ldid | 2 分钟 |
| 编译依赖与工程 | **编译 OpenSSL + FreeRDP** | **30~50 分钟** |
| xcodebuild 编译 | 编译 App 本身 | 3~5 分钟 |
| 打包未签名 IPA | 打包成 ipa 文件 | 30 秒 |
| 上传 IPA | 存成可下载的产物 | 30 秒 |

- 页面可以关掉，云端继续跑，**不影响**
- 想回来看进度：仓库 → Actions → 点那条运行记录
- 一个绿勾 ✅ = 成功；红叉 ❌ = 失败，看 [附录 A](#附录-a常见报错速查)

### 2.4 下载 IPA

编译成功后：

1. 停留在那次运行记录的页面
2. 拉到**页面最底部**，找到 **`Artifacts`** 区域
3. 点击 **`RDPClient-unsigned-ipa`** 下载（得到一个 `.zip`）
4. 解压这个 zip → 里面是 **`RDPClient-unsigned.ipa`**
   - ⚠️ 注意：解压出来的 ipa 可能套了一层文件夹，确保 ipa 文件本身在你的下载目录里

### ✅ 检查点 2

- [ ] Actions 里那次运行显示绿色 ✅
- [ ] 已下载并解压得到 `RDPClient-unsigned.ipa`（大小约 15~40 MB）
- [ ] 文件名后缀确实是 `.ipa`

> **IPA 体积说明**：本工程静态链接了 FreeRDP 和 OpenSSL，未压缩约 30~60 MB，
> 再加上启用 bitcode 剥离后有波动，属正常范围。如果只有几百 KB，说明下载错了。

---

## 阶段 3：准备 iPhone 连接环境（20 分钟）

### 3.1 安装并配置 iTunes

1. 如果你之前装的是「微软商店版 iTunes」，**先卸载**（商店版不含 Apple Mobile Device 驱动）
2. 从 [apple.com/itunes](https://www.apple.com/itunes/) 下载 Windows 版，安装
3. **重启电脑**（必须，让驱动生效）

### 3.2 用数据线连接 iPhone

1. 用 **原装或 MFi 认证** 数据线连接 iPhone 和电脑
   - ⚠️ 只充电的劣质线传不了数据，Sideloadly 会认不到设备
2. iPhone 屏幕会弹「要信任此电脑吗？」→ 点 **`信任`** → 输入手机锁屏密码
   - ⚠️ 这一步必须点信任，否则电脑看不到手机
3. 打开 iTunes，确认左上角出现**手机图标**（能看到设备信息说明驱动正常）
   - 如果 iTunes 里看不到手机：换一根线 / 换一个 USB 口（用机箱后面的）/ 重新插拔

### 3.3 在 iPhone 上先关掉「查找我的 iPhone」相关限制（可选）

如果后续 Sideloadly 报签名失败，可临时关闭（装完再开回来）：

设置 → 顶部你的名字 → 查找 → 查找我的 iPhone → 关闭

### ✅ 检查点 3

- [ ] iTunes 里能看到你的 iPhone 设备
- [ ] iPhone 已信任此电脑
- [ ] 使用了能传数据的线

---

## 阶段 4：签名并安装到 iPhone（15 分钟）

### 4.1 打开 Sideloadly

1. 安装并打开 Sideloadly（Windows）
2. 确认左上角显示 **`iDevice: iPhone (已连接)`**（显示你的机型名）
   - 显示 `No device found` → 回到阶段 3 排查

### 4.2 加载 IPA 并填写 Apple ID

1. 把 **`RDPClient-unsigned.ipa`** 拖到 Sideloadly 窗口的 **`IPA`** 区域
   （或点 `IPA` 输入框右侧的文件夹图标选择文件）
2. 在 **`Apple ID`** 输入框填你的 Apple ID 邮箱
   - 普通免费 Apple ID 即可，不需要开发者账号
3. `Start` 按钮点击开始

### 4.3 输入密码并等待

1. 弹出密码框，输入你的 **Apple ID 密码**
   - ⚠️ 如果你开启了双重验证，可能会提示需要「App 专用密码」：
     去 [appleid.apple.com](https://appleid.apple.com) → 登录 → 安全 → App 专用密码 → 生成一个，
     把生成的一串密码填进 Sideloadly
2. 等待进度条走完（约 1~5 分钟）
3. 看到 `Done` 表示成功

### 4.4 在 iPhone 上信任证书（必须做，否则打不开）

1. iPhone → **设置 → 通用 → VPN 与设备管理**
2. 在「开发者 App」区域找到你的 **Apple ID 邮箱**
3. 点进去 → 点 **`信任"你的邮箱"`** → 弹窗再点 **`信任`**
4. 回到桌面，点开 RDPClient 图标

### ✅ 检查点 4

- [ ] iPhone 桌面出现 RDPClient 图标
- [ ] 已信任开发者证书
- [ ] App 能打开（不闪退）

> **打开就闪退？**
> - 90% 是没信任证书，回到 4.4
> - 也可能是 iOS 版本低于 18.0：设置 → 通用 → 关于本机 → 看「软件版本」

---

## 阶段 5：首次使用与 7 天续期（10 分钟）

### 5.1 首次连接

1. iPhone 连上和电脑**同一个 Wi-Fi**
2. 打开 RDPClient → 首次会弹「**允许 App 使用本地网络？**」→ **必须点允许**
   - 点了不允许：设置 → 隐私与安全性 → 本地网络 → 打开 RDPClient 的开关
3. 点右上角 **`+`**，填写：

| 字段 | 填什么 |
|---|---|
| 名称 | 随便取，如「我的电脑」 |
| 主机 | 阶段 0.1 抄下的 IPv4，如 `192.168.1.100` |
| 端口 | 保持 `3389` |
| 用户名 | 本机账户填用户名；微软账户填完整邮箱 |
| 密码 | Windows 登录密码 |
| 域 | 留空 |
| 分辨率 | 留空（自动适配手机屏幕） |

4. 保存后**点列表项**开始连接，几秒后就能看到 Windows 桌面

### 5.2 手机操作速查

| 想做什么 | 操作 |
|---|---|
| 移动鼠标 | 单指拖动 |
| 左键单击 / 双击 | 单击 / 快速双击 |
| 右键 | 长按 0.5 秒，或两指轻点 |
| 滚动 | 双指拖动 |
| 放大 / 缩小 | 捏合；放大后三指拖动平移 |
| 打字 | 底部 ⌨️ 按钮（支持中文） |
| Ctrl+C、Alt+Tab | 点亮快捷栏 Ctrl / Alt 再输字符 |
| Ctrl+Alt+Del | 快捷栏专用按钮 |
| 断开 | 右上角 ✕ |

### 5.3 7 天有效期怎么处理

免费 Apple ID 签名的 App，**安装后第 7 天会打不开**（提示「无法验证 App」）。两种方案：

**方案一：手动重签（简单，每 7 天一次）**

1. 数据线连电脑，打开 Sideloadly
2. 重新拖入 `RDPClient-unsigned.ipa`（**不用重新编译**，文件还在你电脑上）
3. 填 Apple ID → Start → 手机上重新信任（如果提示的话）
4. 重新打开 App，数据（保存的主机列表）不会丢

> 建议在手机上设个 6 天后的提醒。

**方案二：AltStore 自动续签（一劳永逸，推荐）**

配置一次，之后手机和电脑在同一 Wi-Fi 时自动续签，完全不用管。
详见 [附录 B](#附录-baltstore-自动续签完整配置)。

### ✅ 检查点 5

- [ ] 能看到并操作 Windows 桌面
- [ ] 已决定用哪种续签方案

---

## 附录 A：常见报错速查

### 编译阶段（GitHub Actions 报错）

| 现象 | 原因 | 处理 |
|---|---|---|
| Actions 里看不到 `Build IPA (unsigned)` | `.github` 文件夹没上传 | 让 GitHub Desktop 重新提交（确认隐藏文件夹可见） |
| 卡在「编译依赖与工程」失败 | FreeRDP 编译错误 | 点开失败步骤看红字，**把日志发给 AI 助手修** |
| `xcodebuild: error` 找不到库 | 静态库路径不匹配 | 同样把日志发我，通常是脚本里路径要调 |
| 运行超过 100 分钟被取消 | 云端编译超时 | 重新 Run 一次，GitHub 有构建缓存会快一些 |

> 编译失败不要自己硬试，直接把失败的**红色日志文字**复制给 AI 助手，我来改脚本。

### 安装阶段（Sideloadly 报错）

| 现象 | 原因 | 处理 |
|---|---|---|
| `No device found` | 驱动/线/信任问题 | 装官网版 iTunes → 重启 → 换线 → 手机点信任 |
| `iTunes not found` | 装的是商店版 | 卸载后装官网版 iTunes |
| `Provision.cpp:150` 之类签名错误 | Apple ID 问题 | 用 App 专用密码；或换一个 Apple ID 试 |
| `Unable to install` / 已存在同名 App | 冲突 | 先删掉手机上旧的同名 App 再装 |
| `This app contains an embedded provisioning profile...` | 描述文件问题 | Sideloadly 里勾选 `Remove app plugins`（如有时）|

### 使用阶段

| 现象 | 处理 |
|---|---|
| 连接失败 / 超时 | 确认手机电脑同一 Wi-Fi；确认 Windows 远程桌面已开；确认 IP 没变（重启路由器后 IP 可能变） |
| 认证失败 | 密码错；或微软账户机器用户名没填邮箱 |
| 微软账户被要求设 PIN | Windows 设置 → 账户 → 登录选项 → 关闭「仅允许对此设备上的 Microsoft 账户使用 Windows Hello 登录」 |
| 画面卡顿 | 手机离路由器近一点；降低分辨率设置；关掉电脑上的高负载程序 |
| App 打不开提示无法验证 | 7 天到期了，重新签名（阶段 5.3） |

---

## 附录 B：AltStore 自动续签完整配置

AltStore 能在手机和电脑处于同一 Wi-Fi 时自动续签，免去每 7 天手动操作。

### B.1 在 Windows 上装 AltServer

1. 打开 [altstore.io](https://altstore.io) → 下载 **AltServer for Windows**
2. 安装时**必须勾选** `iTunes` 和 `iCloud` 组件（它自带一套精简版驱动）
   - ⚠️ 如果电脑已装官网版 iTunes，可能提示冲突，按它的说明处理
3. 安装完成后，任务栏右下角会出现 AltServer 的小图标
4. 右键 AltServer 图标 → 勾选 `Launch at Login`（开机自启，保证续签不断）

### B.2 把 AltStore 装到 iPhone

1. 数据线连接 iPhone，确认手机已信任电脑
2. 右键任务栏 AltServer 图标 → `Install AltStore` → 选你的 iPhone
3. 输入 Apple ID 和密码（同样可能要用 App 专用密码）
4. iPhone 上：设置 → 通用 → VPN 与设备管理 → 信任该证书
5. 桌面出现 AltStore 图标，打开它

### B.3 用 AltStore 安装我们的 App

1. 把 `RDPClient-unsigned.ipa` 传到 iPhone 的「文件」App
   - 方法：用 iCloud 云盘 / 微信文件传输助手 / 邮件附件均可
   - 或者丢到电脑上共享文件夹，用「文件」App 连 SMB 访问
2. iPhone 打开 AltStore → 底部 `My Apps` → 左上角 `+`
3. 选择「文件」里的 `RDPClient-unsigned.ipa`
4. 等安装完成，桌面出现图标

### B.4 开启自动续签

1. iPhone：设置 → 通用 → 后台 App 刷新 → 打开（保证 AltStore 能在后台工作）
2. iPhone 保持连接和电脑同一个 Wi-Fi
3. AltServer 在电脑上保持运行（任务栏有图标）
4. 之后 AltStore 会在后台自动续签，7 天限制自动解除

> **偶尔要手动触发**：电脑开机时 AltServer 才在线，如果手机长时间没和电脑同网，
> 打开 AltStore → `My Apps` 手动点 `Refresh All`。

---

## 附录 C：付费开发者账号（可选，解除 7 天限制）

如果不想每 7 天折腾，也不想装 AltStore：

| 项目 | 说明 |
|---|---|
| 费用 | ¥688 / 年（个人开发者计划） |
| 好处 | 证书有效期 1 年，可签 100 台设备，无 7 天限制 |
| 需要 Mac 吗 | **不需要**，网页即可注册和付款 |
| 注册地址 | [developer.apple.com/programs](https://developer.apple.com/programs/) |
| 之后怎么用 | Sideloadly 里选 `Sideload with Apple Developer Account`，用开发者账号登录签名 |

> 注册后如果卡在需要「生成证书」的步骤，告诉 AI 助手，可以改用其他签名工具。

---

## 附：整个流程的一页速览

```
阶段 0  准备（15 分钟）
        └─ Windows 开远程桌面 → 抄 IP → 下载 4 个工具

阶段 1  上传代码（15 分钟）
        └─ 解压 zip → 确认 .github 存在 → GitHub Desktop 发布为 Public

阶段 2  云端编译（1 小时）
        └─ Actions → Run workflow → 等 → 底部 Artifacts 下载 IPA

阶段 3  连接准备（20 分钟）
        └─ 官网版 iTunes → 数据线连手机 → 点信任

阶段 4  签名安装（15 分钟）
        └─ Sideloadly 拖入 IPA → 填 Apple ID → 手机信任证书 → 打开

阶段 5  使用与续签（10 分钟）
        └─ 填 IP 连上 → 操作 → 7 天后重签 或 配置 AltStore 自动续签
```

**卡在哪一步都可以直接把报错或截图发给 AI 助手，我来帮你排查。**
