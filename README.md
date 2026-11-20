# Vermouth

面向 Apple Silicon Mac 的**开源、原生 macOS Windows 应用与游戏转译启动器**（对标轻量现代版 CrossOver）。

> **当前版本**：`v0.1.0`（MVP 核心转译闭环已完成：包含 `VermouthCore` 核心库、`vermouth` 命令行工具与原生 SwiftUI `Vermouth.app` 桌面应用）。完整架构与契约见 [PRD.md](./PRD.md)、[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)、[docs/INTERFACES.md](./docs/INTERFACES.md) 与复盘约束录 [docs/LESSONS_LEARNED.md](./docs/LESSONS_LEARNED.md)。

---

## 核心特性（v0.1）

- **环境预检与多源引擎管理**：只读检测 Apple Silicon、macOS 14+、Rosetta 2、Homebrew、Winetricks 与多套本机 Wine 引擎（平等支持新 WoW64 单二进制 `wine-stable` 11.x、`wine@staging`、`Wine Crossover.app` 与自定义引擎目录），自动识别 32/64 位、`MSync` 与 `WINEDLLPATH_PREPEND` 能力。
- **容器全生命周期管理**：每个容器由独立 `WINEPREFIX` 与人类可读 `bottle.json` 组成，支持新建、重命名、APFS 克隆、外部前缀安全导入（防误删隔离保护）、Windows 目标版本切换、Retina DPI 缩放、虚拟桌面、Apple **Metal Performance HUD** 开关与**中文环境（UTF-8 Locale + CJK 字体链接）一键补全**。
- **容器级图形转译层切换**：支持按容器无损切换 `WineD3D`（DX7/8/9 兜底）、`DXVK-macOS`（Vulkan → MoltenVK → Metal）与 `DXMT`（DX10/11 → Metal 直译）；支持官方 GitHub Releases 在线拉取与本地归档导入，自动识别 `WINEDLLPATH_PREPEND` 零拷贝模式与容器 DLL 备份覆盖/回滚模式。
- **程序安装、扫描与社区配方**：支持拖入或选择 `.exe` / `.msi` 安装器直接安装，自动解析 Start Menu / Desktop `.lnk` 快捷方式与 `Program Files` 可执行程序；内置 `GTA: San Andreas (PC 1.0)`（32 位 DX9 标杆）与 `DirectX 11 Modern 64-bit Default` 配方，支持社区 `.recipe.json` 导入与脱敏导出。
- **实时流式日志与崩溃诊断**：捕获 Wine 输出流并做规则化故障翻译（缺失 DLL 运行库映射、`com.apple.quarantine` 拦截、32/64 位架构不匹配、图形后端初始化失败、`wineserver` MSync 冲突），提供一键修复快捷动作。
- **高级 DLL 覆写与原子快照**：可视化管理 `WINEDLLOVERRIDES`（内置 `dinput8` / `vorbisfile` / `winhttp` / `version` 等 Mod 钩子预设，自动检测 DXMT `builtin` 覆写冲突），并提供带 SHA-256 完整性校验的存档/配置目录时间戳快照与安全原子回滚。

---

## 环境要求

- **操作系统**：Apple Silicon Mac（推荐 macOS 14 Sonoma 及以上；实测兼容 macOS 15 Sequoia / macOS 26）
- **构建工具**：仅需 **Apple Command Line Tools**（Swift 6 / SwiftPM，**无需安装 15GB 完整 Xcode**）
- **运行依赖**：
  1. Rosetta 2：`softwareupdate --install-rosetta --agree-to-license`
  2. 开源 Wine 引擎（推荐通过 Homebrew 安装）：
     ```bash
     brew install --cask --no-quarantine gcenx/wine/wine-stable
     ```
     *（同时兼容本机已有的 `Wine Staging.app`、`Wine Crossover.app` 或任意自定义 Wine 目录）*

---

## 快速构建与打包（无需 Xcode）

```bash
# 1. 编译核心库、CLI 与原生 SwiftUI 应用
swift build -c release

# 2. 运行全套单元测试
swift test --parallel

# 3. 打包签名原生 Vermouth.app（输出至 dist/Vermouth.app）
./Scripts/bundle-app.sh --configuration release --output dist

# 4. 启动应用
open dist/Vermouth.app
```

---

## 命令行工具（`vermouth`）速览

`vermouth` CLI 与图形界面共享同一套 `VermouthCore`，所有查询命令均支持 `--json` 输出：

```bash
# 环境预检与引擎查看
swift run vermouth preflight
swift run vermouth engine list

# 创建容器、补全中文环境并应用配方
swift run vermouth bottle create "MyGames" --win win10 --graphics dxmt --sync msync
swift run vermouth bottle chinese-fix "MyGames"
swift run vermouth recipe list
swift run vermouth recipe apply "MyGames" dx11-modern-default

# 预览完整透明启动命令（Dry Run）或直接运行 .exe / .msi
swift run vermouth run "MyGames" ~/Downloads/Setup.msi --dry-run
swift run vermouth run "MyGames" "C:\Program Files\MyGame\Game.exe"

# 扫描已装程序、创建存档快照与日志诊断
swift run vermouth scan "MyGames"
swift run vermouth snapshot create "MyGames" "drive_c/users/crossover/Documents" --label "装Mod前备份"
swift run vermouth diagnose /path/to/wine.log
```

---

## 合规声明

Vermouth 仅作为开源编排与管理外壳，**绝不打包或分发**任何游戏本体、商业软件、商业版 Wine 或 Apple 专有组件（如 `D3DMetal` / Game Porting Toolkit 二进制），亦不提供任何绕过在线反作弊系统（EAC / BattlEye / Vanguard 等）的功能。

---

## 许可证

本项目基于 [MIT License](./LICENSE) 开源。
