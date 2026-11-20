# STATUS：项目现状（2026-11-20）

> 「做到哪了、靠不靠谱」的一页纸总览。代码层面的细节以 `docs/ARCHITECTURE.md` / `docs/INTERFACES.md` 为准；
> 正在进行的工作与接力信息看 `docs/HANDOFF.md`。每完成一个里程碑更新一次本文件。

## 1. 一句话现状

v0.1 MVP 代码全部落地，**CI 三项全绿**（macOS 完整编译 + 测试 + 打包、Linux Core 快检、Agent 文档同步）；
在此基础上已完成 M2 第一批界面打磨（品牌图标、`.exe` 真实图标卡片墙、转译链路、日志着色、三步引导）和 M3 的运行库安装器。
距离「可以发给别人用」还差：**真机跑通一条 32 位 DX9 和一条 DXMT 链路**，以及在 Mac 上肉眼确认界面观感。

## 2. PRD v0.1 模块完成度

| PRD 模块 | 代码位置 | 实现 | 单测 | 真机验证 |
|---|---|---|---|---|
| A 环境预检与引擎管理 | `Engines/EngineManager`、`Platform/LiveSystemProber` | ✅ 新 WoW64 单 `wine` / 双二进制 / 多来源扫描、能力探测 | ✅ | ⏳ |
| B 容器全生命周期 | `Bottles/BottleStore`、`Bottles/RegistryPatcher` | ✅ 新建/重命名/克隆/导入/删除、Win 版本、同步模式、DPI、虚拟桌面、Metal HUD、中文补全 | ✅ | ⏳ |
| C 图形转译层（核心） | `Graphics/GraphicsStackManager` | ✅ WineD3D / DXVK-macOS / DXMT，GitHub Releases 拉取 + 本地导入，`WINEDLLPATH_PREPEND` 零拷贝与 DLL 备份覆盖双模式 | ✅ | ⏳ 最关键的待验项 |
| D 安装、启动、发现、配方 | `Runner/*`、`Discovery/ExecutableScanner`、`Recipes/RecipeEngine` | ✅ `.exe`/`.msi`、`.lnk` 解析、Program Files 扫描、2 个内置配方、脱敏导出 | ✅ | ⏳ |
| E 实时日志与崩溃诊断 | `Platform/LiveCommandRunner`、`Diagnostics/CrashDiagnoser`、`Diagnostics/WineLogClassifier` | ✅ 真·实时流式（`read(2)`，L-017）、日志级别/通道识别、诊断卡片一键装运行库 | ✅ 含 <1s 首行延迟测试 | ⏳ |
| F 高级覆写与快照 | `Runner/DllOverrideFormatter`、`Snapshots/SnapshotManager` | ✅ 可视化 DLL Override + Mod 预设、SHA-256 原子快照回滚 | ✅ | ⏳ |
| 原生界面 | `Sources/VermouthApp/*`（12 个文件） | ✅ NavigationSplitView + 4 个分区 + 预检/引擎/快照弹窗；品牌色板、程序卡片墙、转译链路、彩色日志、三步引导 | 无（UI），macOS CI 编译通过 | ⏳ 观感待确认 |
| 程序图标（新增） | `Inspection/PEIconExtractor`、`Inspection/ProgramIconCache` | ✅ Clean-Room 解析 `RT_GROUP_ICON` → 重建 `.ico`，按路径+大小+mtime 磁盘缓存；`vermouth icon` | ✅ 10 个 | ⏳ |
| 运行库安装器（M3 提前） | `Runner/Winetricks`、`App/RuntimeInstallerSheet` | ✅ 19 个常用 verb 分类卡片、推荐预设、命令预览，经 `LaunchPlan` 执行（L-003） | ✅ | ⏳ |
| CLI | `Sources/VermouthCLI/*` | ✅ preflight / engine / bottle / graphics / run / scan / diagnose / snapshot / recipe / icon | 由 CI 冒烟覆盖 | ✅ Linux 冒烟通过 |
| 打包 | `Scripts/bundle-app.sh` | ✅ 无 Xcode 打包 + ad-hoc 签名 + App 图标（`Branding/AppIcon.icns`） | CI 校验图标存在 | ⏳ |

规模：源码约 20,500 行，测试约 8,400 行、169 个测试用例。零第三方依赖。

## 3. 测试与 CI

| 环境 | 结果 | 说明 |
|---|---|---|
| GitHub Actions `macos-15` arm64（run 44714569487，提交 `6e8ed7d`） | ✅ | 完整编译 Core / CLI / App、全部测试、`bundle-app.sh` 打包与冒烟 |
| GitHub Actions `core-linux`（同一 run） | ✅ | `swift:6.3.3-noble` 容器，Core + CLI 编译、测试、CLI 冒烟，约 1 分钟 |
| Linux x86_64 云端，Swift 6.3.3 | ✅ 169/169 | 仅 Linux 不成立的 1 个 HTTP 下载测试用 `XCTSkipIf` 标注（L-018） |
| 真机 Wine 冒烟（PRD §7） | ⏳ | 需要用户的 Mac |

## 4. 质量亮点（值得在 README / 简历里讲的）

- **零依赖 Clean-Room**：自研 PE32/PE32+ 解析、Windows `.lnk` 解析、纯 Swift SHA-256、UTF-16LE 注册表生成，全部有单测。
- **透明可复现**：所有 Wine 进程都由同一个 `LaunchPlan` 生成，UI 里看到的命令就是实际执行的命令。
- **Clean-Room 图标提取**：不依赖 Wine 也不调用任何工具，直接从 `.exe` 资源段三级目录树里取出图标组并重建 `.ico`，程序库像游戏库一样有封面。
- **转译链路透明可视**：`64 位程序 → Rosetta 2 → Wine 11.0 → DXMT → Metal`，未就绪的环节以橙色警示。
- **教训驱动开发**：`LESSONS_LEARNED.md` 把 18 个真实踩坑沉淀为强制约束（如 APFS 大小写碰撞导致主程序被 CLI 覆盖、`ISO8601DateFormatter` 毫秒截断），每轮对抗审查。

## 5. 文档地图

| 文档 | 用途 | 维护方式 |
|---|---|---|
| `PRD.md` | 需求与边界 | 需求变化时改 |
| `docs/ARCHITECTURE.md` | 技术栈、分层、不变量 | 架构变化时改 |
| `docs/INTERFACES.md` | 协议、模型、JSON Schema、CLI 契约 | 接口变化时改 |
| `docs/LESSONS_LEARNED.md` | 生效约束 L-xxx + 每轮复盘 | 每轮追加 |
| `docs/STATUS.md` | 本文件：完成度与测试现状 | 里程碑时更新 |
| `docs/ROADMAP.md` | 接下来做什么 | 规划变化时改 |
| `docs/UI_PROPOSALS.md` | 界面与体验改进提案 | 提案 / 落地时改 |
| `docs/HANDOFF.md` | Agent 接力棒（快照） | 每次会话结束覆盖 |
| `docs/WORKLOG.md` | Agent 工作日志（历史） | 每次会话结束追加 |
| `AGENTS.md` → `CLAUDE.md` / `GEMINI.md` | Agent 共享规则 | 改 `AGENTS.md` 后运行同步脚本 |
