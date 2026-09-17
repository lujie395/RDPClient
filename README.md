# RDPClient — iOS RDP 远程桌面客户端

一个使用 **FreeRDP 3.x** 连接局域网 Windows 电脑的 iOS App（iPhone / iPad 通用，目标系统 iOS 18.x）。

- 仅需 **用户名 + 密码** 认证（NLA / TLS / 标准 RDP 安全层自动协商）
- 密码保存在 **Keychain**，主机列表保存在本地 JSON
- GDI 软渲染 + 视频工具箱（VideoToolbox）解码 H.264（无需 FFmpeg）
- 完整触控手势 + iPad 指针 / Magic Trackpad 支持

---

## 一、环境要求（Mac）

| 工具 | 版本要求 | 安装 |
|---|---|---|
| Xcode | 16+（含 iOS 18 SDK） | App Store |
| cmake | ≥ 3.13 | `brew install cmake` |
| xcodegen | 任意近期版本 | `brew install xcodegen`（bootstrap 会自动装） |
| Apple 开发者账号 | 免费账号即可真机调试 | Xcode → Settings → Accounts |

## 二、一键构建

```bash
cd RDPClient
./bootstrap.sh        # 克隆 FreeRDP → 编译 OpenSSL → 编译 FreeRDP → 生成 Xcode 工程
open RDPClient.xcodeproj
```

然后在 Xcode 里：

1. 选中 RDPClient target → Signing & Capabilities → 选择你的 **Team**
2. 连接 iPhone / iPad，选择设备，**Run**
3. 首次在真机运行：设置 → 通用 → VPN 与设备管理 → 信任开发者证书

> 首次 bootstrap 约需 20~50 分钟（OpenSSL + FreeRDP 两次编译）。
> 之后重新构建 App 不需要重跑 bootstrap。

### 常用变量

```bash
FREERDP_REF=3.31.1 ./bootstrap.sh   # 指定 FreeRDP 版本（默认 3.31.1）
MIN_IOS=18.0                        # 最低部署版本（scripts 内默认 18.0）
```

## 三、使用

1. 首页点 **+** 新建连接：填 IP / 主机名、端口（默认 3389）、用户名、密码、域（可选）、分辨率（可留空自动协商）
2. 列表里点一下主机即开始连接
3. 首次连接局域网设备时，iOS 会弹「本地网络」权限，请允许

## 四、手势与操作

| 操作 | iPhone 触屏 | iPad 指针 / Magic Trackpad |
|---|---|---|
| 移动光标 | 单指拖动 | 移动指针（自动同步） |
| 左键 | 单击（即时发送；快速两次单击 = 双击，由 Windows 判定） | 点按 / 单击 |
| 右键 | 长按约 0.5s；或两指轻点 | 鼠标右键 / 双指点按 |
| 左键拖动 | —（暂不支持） | 按住拖动 |
| 右键拖动 | —（暂不支持） | — |
| 滚轮 | 双指拖动 | 双指滚动 |
| 缩放画面 | 捏合 | 捏合 |
| 平移视口（放大后） | ✋ 模式单指拖动，或三指拖动 | 三指拖动 |
| 键盘 | 底部 ⌨️ 按钮 | 底部 ⌨️ 按钮（软/硬键盘都走这里） |

**快捷键栏**：Ctrl / Alt / Shift / Win 为 sticky 键（点亮后再输入字符即组合键），
另有 Ctrl+C/V/X/Z/A/S/W、方向键、Home/End/PgUp/PgDn、Ctrl+Alt+Del。

**分辨率说明**：分辨率留空时，App 按当前屏幕方向的逻辑分辨率协商远程桌面大小；
画面默认**铺满屏幕**（cover：短边对齐、长边裁切，可平移查看），捏合可缩小到完整显示。

## 五、架构

```
RDPClient/
├── App/                 SwiftUI 入口
├── Models/              RDPHost、HostStore（hosts.json）
├── Services/            KeychainService
├── Bridge/              RDPBridge.h/.mm —— FreeRDP 3.x 桥接（核心）
├── Views/               HostListView / ConnectionFormView / RemoteScreenView / RDPViewController
├── Input/               ScancodeMap / TouchInputMapper / KeyboardBarView
├── Info.plist           含 NSLocalNetworkUsageDescription（本地网络权限）
└── PrivacyInfo.xcprivacy
scripts/
├── build_openssl.sh     OpenSSL 3.3 静态库（iphoneos + iphonesimulator）
└── build_freerdp.sh     libfreerdp.a / libwinpr.a（VideoToolbox H.264，关 FFmpeg）
project.yml              XcodeGen 工程定义
bootstrap.sh             一键构建入口
```

**桥接层关键设计**（`RDPBridge.mm`）：

- 后台线程执行 `freerdp_connect` + 事件泵（`freerdp_get_event_handles` → `WaitForMultipleObjects` → `freerdp_check_event_handles`）
- `gdi_init(BGRA32)` 软渲染；包装 GDI 默认 `EndPaint` / `DesktopResize` 回调，
  把 `primary_buffer` 节流（约 30 FPS）拷贝为 CGImage 派发到主线程 CALayer
- 配置写入统一走 `freerdp_settings_set_value_for_name`（FreeRDP 3.x 稳定 API；
  布尔值只接受 `TRUE` / `FALSE` 字面量）
- 输入：`freerdp_input_send_mouse_event`（含 9 位二进制补码滚轮编码）、
  `freerdp_input_send_keyboard_event`（Set-1 扫描码 + 扩展位）、
  `freerdp_input_send_unicode_keyboard_event`（文本/中文路径）

## 六、安全说明（重要）

- **证书校验被关闭**（`FreeRDP_IgnoreCertificate=TRUE`）。局域网自用可以接受，
  但请注意这会允许中间人攻击。如需开启校验，把 `RDPBridge.mm` 中
  `FreeRDP_IgnoreCertificate` 一行改为 `FALSE` 并自行实现证书确认回调。
- 密码存于 Keychain（`kSecAttrAccessibleAfterFirstUnlock`），主机列表 JSON 不含密码。
- 本 App 不收集任何数据，隐私清单为空声明。

## 七、排错

| 现象 | 处理 |
|---|---|
| `bootstrap.sh` 报缺 cmake/brew | `brew install cmake xcodegen` |
| OpenSSL `Configure` 找不到 target | 确认 OpenSSL ≥ 3.0（脚本默认 3.3.2，可用 `OPENSSL_VERSION=x.y.z` 覆盖） |
| FreeRDP CMake 报找不到 SSL | 确认 `third-party/openssl/{iphoneos,iphonesimulator}` 已生成（先跑 OpenSSL 脚本） |
| 链接错误 `library not found for -lfreerdp` | 确认 `build/dist-{iphoneos,iphonesimulator}` 存在；清理 DerivedData 重试 |
| 模拟器跑不了、真机可以 | 模拟器库架构问题：脚本按 `SIMULATORARM64` 编译（Apple Silicon）。Intel Mac 需把 `build_freerdp.sh` 中平台改为 `SIMULATOR64` |
| 连接报「本地网络」被拒 | 设置 → 隐私与安全性 → 本地网络 → 允许本 App |
| 连接失败 CREDSSP / 认证错误 | 检查用户名（可带 `机器名\用户` 形式时，把机器名填到「域」）；目标机器需开启远程桌面 |
| 画面卡顿 | 降低远程分辨率；确认 Windows 端未开 4K 多屏 |
| Windows 提示 CredSSP 加密Oracle修正 | 目标机打齐系统更新，或按微软文档调整组策略 `Encryption Oracle Remediation` |

## 八、已知限制

- 不支持：剪贴板同步、文件/驱动器重定向、音频重定向、多显示器（均按需求裁剪）
- 左键/右键拖动（按住按键移动）暂未实现触屏手势路径；用硬件指针
- 旋转屏幕后桌面方向不变（RDP 桌面尺寸连接时固定），App 会自动铺满适配
- 非 US 键盘布局的硬件键盘：字符类输入走 Unicode 通道（正常），控制键正常；
  布局差异极端场景可能有键位偏差
- 软件渲染下高分辨率（>2K）画面在低端设备可能掉帧

## 九、License

本工程代码按 MIT 发布。依赖：FreeRDP（Apache-2.0）、OpenSSL（Apache-2.0）。
