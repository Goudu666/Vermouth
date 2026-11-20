# STATUS：项目现状（2026-11-20）

> 「做到哪了、靠不靠谱」的一页纸总览。代码层面的细节以 `docs/ARCHITECTURE.md` / `docs/INTERFACES.md` 为准；
> 正在进行的工作与接力信息看 `docs/HANDOFF.md`。每完成一个里程碑更新一次本文件。

## 1. 一句话现状

v0.1 MVP 的**代码已全部写完**（Core + CLI + SwiftUI App），能编译；**测试还差 2 个没过，真机 Wine 冒烟还没做**。
距离「可以发给别人用」还差：CI 全绿 → 真机跑通一条 32 位 DX9 和一条 DXMT 链路 → 打包 `.app` 自测。

## 2. PRD v0.1 模块完成度

| PRD 模块 | 代码位置 | 实现 | 单测 | 真机验证 |
|---|---|---|---|---|
| A 环境预检与引擎管理 | `Engines/EngineManager`、`Platform/LiveSystemProber` | ✅ 新 WoW64 单 `wine` / 双二进制 / 多来源扫描、能力探测 | ✅ | ⏳ |
| B 容器全生命周期 | `Bottles/BottleStore`、`Bottles/RegistryPatcher` | ✅ 新建/重命名/克隆/导入/删除、Win 版本、同步模式、DPI、虚拟桌面、Metal HUD、中文补全 | ✅ | ⏳ |
| C 图形转译层（核心） | `Graphics/GraphicsStackManager` | ✅ WineD3D / DXVK-macOS / DXMT，GitHub Releases 拉取 + 本地导入，`WINEDLLPATH_PREPEND` 零拷贝与 DLL 备份覆盖双模式 | ✅ | ⏳ 最关键的待验项 |
| D 安装、启动、发现、配方 | `Runner/*`、`Discovery/ExecutableScanner`、`Recipes/RecipeEngine` | ✅ `.exe`/`.msi`、`.lnk` 解析、Program Files 扫描、2 个内置配方、脱敏导出 | ✅ | ⏳ |
| E 实时日志与崩溃诊断 | `Platform/LiveCommandRunner`、`Diagnostics/CrashDiagnoser` | ⚠️ 诊断规则 ✅；**流式日志有阻塞 bug**（见 §3） | ⚠️ | ⏳ |
| F 高级覆写与快照 | `Runner/DllOverrideFormatter`、`Snapshots/SnapshotManager` | ✅ 可视化 DLL Override + Mod 预设、SHA-256 原子快照回滚 | ✅ | ⏳ |
| 原生界面 | `Sources/VermouthApp/*`（11 个文件） | ✅ NavigationSplitView + 4 个分区 + 预检/引擎/快照弹窗 | 无（UI） | ⏳ |
| CLI | `Sources/VermouthCLI/*` | ✅ preflight / engine / bottle / graphics / run / scan / diagnose / snapshot / recipe | 由 CI 冒烟覆盖 | ✅ Linux 冒烟通过 |
| 打包 | `Scripts/bundle-app.sh` | ✅ 无 Xcode 打包 + ad-hoc 签名 | CI 校验 | ⏳ |

规模：源码约 18,900 行，测试约 7,900 行、148 个测试用例。零第三方依赖。

## 3. 测试与 CI

| 环境 | 结果 | 说明 |
|---|---|---|
| GitHub Actions `macos-15`（run 44710039726，提交 `05ff25d`） | ❌ 146/148 | 编译通过；`testLiveCommandRunnerCancellationTerminatesChildPromptly`、`testLiveCommandRunnerEnvironmentInheritanceToggleAndWorkingDirectory` 失败 |
| Linux x86_64 云端，Swift 6.3.3（同一提交） | ❌ 146/148 | 取消测试失败（与 macOS 同根因 + Linux 信号掩码差异）；HTTP 下载测试 SIGILL（仅 Linux） |
| CLI 端到端冒烟（Linux） | ✅ | `recipes`、`bottle create`、`recipe apply`、`diagnose` 输出正确；`run` 在无 Wine 时给出清晰报错 |

失败的根因与修法都写在 `docs/HANDOFF.md` §3，其中**实时日志阻塞是真实的产品 bug**：Wine 日志要等进程退出才出现，「实时日志」功能形同虚设。

## 4. 质量亮点（值得在 README / 简历里讲的）

- **零依赖 Clean-Room**：自研 PE32/PE32+ 解析、Windows `.lnk` 解析、纯 Swift SHA-256、UTF-16LE 注册表生成，全部有单测。
- **透明可复现**：所有 Wine 进程都由同一个 `LaunchPlan` 生成，UI 里看到的命令就是实际执行的命令。
- **教训驱动开发**：`LESSONS_LEARNED.md` 把 16 个真实踩坑沉淀为强制约束（如 APFS 大小写碰撞导致主程序被 CLI 覆盖、`ISO8601DateFormatter` 毫秒截断），每轮对抗审查。

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
