# 产品需求文档（PRD）：Vermouth

> **版本**：v1.1（定位校准：以通用 Windows 转译引擎管理为核心，Mod/DLL 辅助为轻量附加能力）  
> **项目名称**：`Vermouth`  
> **默认标识**：仓库 `Goudu666/Vermouth` · Bundle ID `io.github.goudu666.vermouth` · 数据目录 `~/Library/Application Support/Vermouth`  
> **目标平台**：Apple Silicon macOS（建议最低支持 macOS 14 Sonoma；开发机实测为 `macOS 26.5.1 arm64`，Swift 6.3.3，Homebrew 已就绪，无完整 Xcode）

---

## 1. 产品定位与核心价值

### 1.1 一句话定位
**Vermouth** 是一款面向 Apple Silicon Mac 的**开源、原生 macOS Windows 应用与游戏转译启动器**（对标轻量现代版 CrossOver）。它基于开源 Wine 与开源图形转译栈（DXMT / DXVK-macOS / WineD3D），专注把「配置容器、切换图形转译层、安装运行 Windows `.exe`、排障调优」做到开箱即用、配置透明；同时在高级设置里顺手提供友好的 DLL 覆写与目录/快照辅助，方便有需要时折腾 Mod。

### 1.2 解决的核心问题
| 现状痛点 | Vermouth 的定位与解法 |
|---|---|
| **CrossOver 付费订阅，免费替代断档或偏旧** | 完全开源免费，原生 SwiftUI 体验；引擎与外壳解耦，随时跟进最新开源 Wine 与图形层 |
| **图形转译栈复杂、难切换** | 容器级可视化切换 `WineD3D` / `DXVK-macOS` / `DXMT`、同步模式（ESync/MSync）、Metal HUD 与 Retina 缩放，一键验证哪种组合帧率最稳 |
| **Windows 装完软件找不到入口 / 中文乱码** | 支持直接运行 `.exe` / `.msi` 安装包并自动扫描容器内可启动程序；内置**中文字体与 Locale 补全**，解决常见方块乱码 |
| **闪退黑盒、配置不透明** | 实时捕获日志并做规则化崩溃诊断（缺 DLL、32/64 位不匹配、隔离属性拦截）；所有容器配置存为人类可读 JSON |
| **偶尔改 DLL 覆写 / 打 Mod 还要翻 `winecfg`** | 作为轻量附加项，提供可视化 `WINEDLLOVERRIDES` 面板与快捷目录/快照入口，不喧宾夺主但用起来极顺手 |

---

## 2. 目标用户与非目标（边界红线）

### 2.1 目标用户
- 想在 Apple Silicon（M1–M5）Mac 上免费、轻量运行 Windows 经典或现代单机游戏、小型 Windows 桌面工具的用户。
- 希望清楚看到底层跑的是哪个 Wine、哪个图形转译层、注入了哪些环境变量的技术友好型玩家与开源社区用户。

### 2.2 明确非目标（Non-Goals）
1. **不从零重写 Wine 或显卡驱动**：基于成熟开源转译栈做编排、管理、封装与排障体验。
2. **绝不打包分发 Apple `D3DMetal` / GPTK 二进制**：严守开源协议红线；后续仅支持用户自备路径（BYO 模式）。
3. **不分发任何游戏或商业软件本体，不绕过在线反作弊系统**（EAC / BattlEye / Vanguard）。
4. **不强依赖 15GB 完整 Xcode**：纯 **SwiftPM + 轻量 `.app` 打包脚本**，只需 Apple Command Line Tools 即可编译、测试与打包。

---

## 3. 开源转译技术栈与合规矩阵

| 层级 | 选用方案 | 许可证 / 分发方式 | 核心职责 |
|---|---|---|---|
| **桌面端与编排层** | Swift 6 + SwiftUI + AppKit 桥接（纯 SwiftPM） | MIT（推荐） | 原生 macOS UI、容器与配方管理、子进程调度、日志诊断 |
| **Windows API 兼容层** | 优先支持 `gcenx/wine/wine-crossover`（Homebrew Cask），同时允许绑定任意本机 Wine 引擎（如 Wine Staging） | LGPL-2.1（外部安装，不入仓分发二进制） | 同时支持 32 位与 64 位 Windows 程序 |
| **DirectX 图形转译层** | 容器级自由切换：<br>1. `WineD3D`（Wine 内置，老 DX7/8/9 兜底）<br>2. `DXVK-macOS`（`Gcenx/DXVK-macOS`，DX9/10/11 → MoltenVK → Metal）<br>3. `DXMT`（`3Shain/dxmt`，DX10/11 → Metal 直译，性能主力） | 均为开源协议（从官方 GitHub Releases 按需下载至应用支持目录，按容器部署/卸载） | 核心图形性能与画面兼容保障 |
| **指令集转译** | macOS 系统内置 Rosetta 2 | 系统组件（启动预检提示） | x86_64 → ARM64 透明转译 |
| **Windows 运行库辅助** | 可选调用本机 `winetricks` | LGPL | 补充 VC++、DirectX 辅助库、字体等常见依赖 |

---

## 4. 功能需求与里程碑规划

### 4.1 v0.1 MVP —— 「完整的开源转译闭环」

#### 模块 A：环境预检与引擎管理（Engine Manager）
- 启动时只读检测：Apple Silicon 架构、Rosetta 2、Homebrew、已安装 Wine 引擎（自动扫描 `/Applications/Wine Crossover.app`、`/opt/homebrew` 及用户自定义目录）。
- 支持登记多套 Wine 引擎并查看版本与 32/64 位支持状态；缺失时提供清晰的一键复制/引导安装步骤，不静默修改系统环境。

#### 模块 B：容器全生命周期管理（Bottle Manager）
- 容器操作：新建、重命名、克隆、导入已有 `WINEPREFIX`、删除。
- 透明配置存储：每个容器由独立的 `WINEPREFIX` + 人类可读的 `bottle.json` 构成。
- 容器核心调优项：
  - Windows 目标版本（`winxp` / `win7` / `win10` / `win11`）
  - 同步机制（`MSync` / `ESync` / 关闭）
  - 显示与性能开关（Retina DPI 缩放、虚拟桌面分辨率、Apple **Metal Performance HUD** 帧率监控开关）
  - **中文环境一键补全**（补齐中文字体映射与 UTF-8/Locale 预设，避免中文界面乱码）
  - 常用容器工具：在 Finder 打开 `drive_c`、拉起 `winecfg` / `regedit` / `cmd`、打开预注入环境变量的终端、一键终止容器残留进程（`wineserver -k`）。

#### 模块 C：图形转译层管理（Graphics Stack —— 核心模块）
- 支持按容器一键切换并注入/恢复对应 DLL：
  - **WineD3D**（内置默认，卸载外部图形 DLL 即回退）
  - **DXVK-macOS**（面向 DX9/10/11）
  - **DXMT**（面向 DX10/11，Apple Silicon 现代游戏优先）
- 管理本地已下载的图形层版本（支持从官方 GitHub Releases 拉取或本地导入 `.tar.gz`），清晰展示当前容器生效的图形后端状态。

#### 模块 D：程序安装、启动与快捷方式发现（Launcher）
- **运行安装包**：拖入或选择 `.exe` / `.msi` 安装程序直接在该容器内安装。
- **程序列表管理**：自动扫描 `drive_c/Program Files*` 及开始菜单/桌面快捷方式，或手动固定任意 `.exe` 为启动卡片，支持自定义启动参数、工作目录与独立环境变量。
- **社区配方基础（Recipes）**：支持导入/应用 `.recipe.json` 推荐转译组合；首版内置两个实测标杆验证：
  1. **32 位 DX9 老游戏标杆**：`GTA: San Andreas (PC)`（验证 32 位 WoW64 + DX9 + 手柄/宽屏与 Mod 钩子）
  2. **64 位 DX11 通用模板**（验证 DXMT / DXVK-macOS 现代游戏链路）

#### 模块 E：实时日志与崩溃诊断（Live Diagnostics）
- 启动程序时流式捕获 Wine 日志（默认只收关键错误通道防刷屏，支持按需开启 `+loaddll` 等调试通道）。
- **规则化故障诊断引擎**：自动高亮并翻译高频报错：
  - 缺失 DLL（`import_dll Library xxx.dll not found`）→ 提示缺失文件与对应常见运行库。
  - macOS `com.apple.quarantine` 隔离拦截 → 提示并提供一键解除隔离动作。
  - 32 位 PE 程序误选纯 64 位 Wine → 明确报警并提示切换支持 32 位的引擎。
  - 图形层初始化失败 → 建议快速回退至 `WineD3D` 或切换 `DXVK-macOS` / `DXMT`。

#### 模块 F：高级覆写与轻量 Mod 辅助（附带加分项）
- **可视化 DLL Override（`WINEDLLOVERRIDES`）**：勾选配置 `native,builtin` / `builtin,native` / `disabled`，实时预览最终环境变量字符串；内置少量高频快捷预设（如 `dinput8`、`vorbisFile`、`winhttp`、`version`，覆盖常见 ASI/CLEO/ModLoader/BepInEx 场景）。
- **快捷备份**：支持为单个程序指定配置或存档目录，提供一键时间戳快照与回滚（改配置或装 Mod 前保底）。

---

### 4.2 v0.2 —— 日常体验补齐与分发
- **运行库可视化安装器**：包装 `winetricks` 常用项（`vcrun2022`、`d3dx9`、`d3dcompiler_47`、核心字体等）并显示安装进度。
- **一键导出独立 `.app` 快捷方式**：把容器里的单个 Windows 程序打包为可直接放进 Dock / Launchpad 双击启动的轻量 `.app`。
- **完整社区配方导入/导出**：支持把调通的容器配置一键脱敏导出为 `.recipe.json` 分享给他人。
- **Steam 常用容器模板**与 GitHub Actions 自动构建 DMG 发布流。

### 4.3 v0.3 —— 进阶扩展
- 可选 **BYO `D3DMetal`** 支持（用户自行指定本地 Apple GPTK 路径，解锁更多 DX12 游戏，零开源合规风险）。
- 图形层版本自动检查更新与多容器共享缓存优化。
- 可选插件接口（供社区或个人按需挂接单游戏工具，如特定游戏存档编辑等）。

---

## 5. 架构与目录设计

保持**核心转译逻辑（`VermouthCore`）与原生 UI（`VermouthApp`）彻底解耦、顶层平铺**，纯 SwiftPM 即可构建与测试：

```text
Vermouth/
├── Package.swift                    # Swift 6，目标 macOS 14+，零重型第三方依赖
├── Sources/
│   ├── VermouthCore/                # 纯 Swift 核心层（可无界面单测）
│   │   ├── EngineManager.swift      # 探测 Rosetta 2 / Homebrew / 多版本 Wine 引擎
│   │   ├── BottleModels.swift       # Bottle / AppEntry / GraphicsBackend / DllOverride 模型
│   │   ├── BottleStore.swift        # 容器 CRUD、bottle.json 读写、克隆与导入
│   │   ├── GraphicsStack.swift      # WineD3D / DXVK-macOS / DXMT 拉取、部署与切换
│   │   ├── WineRunner.swift         # 环境变量拼装（MSync/HUD/DLL覆写）、子进程调度与日志流
│   │   ├── ExecutableScanner.swift  # 扫描容器内已安装的 .exe 与快捷方式
│   │   ├── CrashDiagnoser.swift     # Wine 日志规则匹配与人话排障建议
│   │   ├── SnapshotManager.swift    # 轻量配置/存档目录快照与回滚
│   │   └── Recipe.swift             # 兼容配方 JSON 解析与应用
│   └── VermouthApp/                 # 原生 macOS SwiftUI 界面层
│       ├── VermouthApp.swift        # 入口与 NavigationSplitView 主框架
│       ├── PreflightSheet.swift     # 首次启动环境预检与引擎引导
│       ├── BottleDetailView.swift   # 程序启动卡片、安装器入口、容器快捷工具栏
│       ├── BottleConfigView.swift   # 图形转译层、同步模式、HUD、字体、DLL 覆写配置
│       ├── ConsoleLogView.swift     # 实时日志流与置顶诊断卡片
│       └── EngineSettingsView.swift # Wine 引擎与 DXVK/DXMT 版本库管理
├── Recipes/
│   ├── gtasa-pc-1.0.json            # 32 位 DX9 实测标杆配方
│   └── dx11-modern-default.json     # 64 位 DX11 通用配方
├── Scripts/
│   └── bundle-app.sh                # swift build + Info.plist + 本地 ad-hoc 签名打包 Vermouth.app
├── Tests/
│   └── VermouthCoreTests/           # 环境变量拼装、图形层部署回滚、诊断规则、配方解析单测
└── README.md
```

---

## 6. UI 与交互原则

- **纯正 macOS 原生工具质感**：采用 `NavigationSplitView`（左侧容器列表 + 底部引擎就绪状态，右侧分区：`程序` / `转译配置` / `运行日志` / `高级与覆写`），自动适配系统浅色/深色模式，使用标准系统控件与 SF Symbols。
- **开箱简洁、底层透明**：常规用户只需选图形层、点运行；进阶用户可随时一键展开查看实际生成的完整 `WINEPREFIX` + 环境变量 + 启动命令，方便复现与排查问题。

---

## 7. 开工前置最小冒烟验证

在铺开写全部界面之前，开工第一步先跑通两项硬验证：
1. **底层转译链路实测**：在当前 `macOS 26.5.1 (arm64)` 上用 `gcenx/wine/wine-crossover` 实测一条 32 位 DX9（GTASA）和一条图形转译层（`DXVK-macOS` / `DXMT`）的真实启动表现，把踩实的参数沉淀为默认配置。
2. **无 Xcode 原生打包实测**：跑通 `swift build` + `Scripts/bundle-app.sh` 输出 `Vermouth.app` 并完成本地 ad-hoc 签名，确认在 macOS 26 上正常弹窗、读写容器目录与拉起子进程。

---

## 8. 开源发布约定
- **许可证**：推荐 **MIT License**。
- **合规声明**：在 `README.md` 明确声明 Vermouth 仅做开源编排与管理外壳，不分发游戏本体、Wine 商业版或 Apple 专有组件。
