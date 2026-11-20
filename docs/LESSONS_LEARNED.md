# Vermouth 迭代复盘与教训约束文档（Lessons Learned & Engineering Constraints）

> **使用规则（强制）**：
> 1. **每轮开发启动前**：所有参与开发的 Agent 必须先通读本文档中的「生效约束清单」，并在实现与代码审查中逐条核对。
> 2. **每轮开发完成后**：必须执行全量编译、单测、边界测试与对抗审查，并将发现的问题、根因与新约束追加到本文档。
> 3. **约束只能收紧或演进，不可静默删除**；若某条约束被后续架构变更取代，需标记 `SUPERSEDED` 并注明原因。

---

## 一、生效约束清单（Active Constraints）

### Phase 0 种子教训与 Phase 0 架构对抗审查沉淀

| 编号 | 领域 | 问题/踩坑事实 | 强制约束规则 |
|---|---|---|---|
| **L-001** | 图形层（DXMT） | `3Shain/dxmt` 最新版（v0.80）仅发布 `-Dwine_builtin_dll=true` 的 `builtin` 包（含 `x86_64-unix/winemetal.so`）：① 对其 DLL 设置 `=n,b` 会导致加载失败；② `winemetal.so` 不能复制到 `drive_c/windows/system32` 生效。 | `wineBuiltin` 图形包**仅允许**在 `supportsWineDLLPathPrepend == true` 的引擎上通过 `WINEDLLPATH_PREPEND` 零拷贝加载，并对包内 DLL 显式输出 `=b` 以屏蔽旧注册表 `n,b` 残留；不支持该能力的引擎必须快速失败并给出切换引导，严禁静默降级复制进 `system32`。 |
| **L-002** | 图形层（DXVK） | `Gcenx/DXVK-macOS` 最新 repack 已移除 `d3d9.dll` 与 `dxgi.dll`（macOS 上 MoltenVK 的 DX9 存在兼容问题，交由 WineD3D 兜底）。 | 部署 `nativeDLLs` 图形包时必须**基于归档内实际存在的 DLL 列表**动态生成部署清单与 `=n,b` override，禁止硬编码 `d3d9` 或 `dxgi`。 |
| **L-003** | Wine 同步机制 | 当容器 `wineserver` 已在 `WINEMSYNC=1`（或 `WINEESYNC=1`）下运行时，任何使用不同同步环境变量连入同一 `WINEPREFIX` 的命令（含 `winecfg`/`regedit`/`wineboot`/预注入终端）都会在 `msync_init` 崩溃；且容器无运行进程时 `wineserver -k` 返回非零退出码。 | 所有容器内 Wine 命令与预注入终端脚本必须统一通过 `EnvironmentBuilder` 生成；切换 `syncMode` 或图形层前调用 `killWineServer`，并将“无运行中 wineserver”的退出状态视为安全 no-op。 |
| **L-004** | Wine 引擎演进 | `Gcenx/homebrew-wine` 已移除 `wine-crossover` Cask，主力转向新 WoW64 的 `wine-stable` (11.x) / `wine@staging`（单 `bin/wine` 同时跑 32/64 位，且设 `WINEARCH=win32` 会破坏 WoW64）。 | `EngineManager` 必须同时兼容单 `bin/wine`（新 WoW64）与双 `bin/wine`+`bin/wine64`，兼容扫描 `Wine Crossover.app`/`Wine Stable.app`/`Wine Staging.app`/`Wine Devel.app`/Homebrew/自定义路径；对新 WoW64 引擎**禁止设置 `WINEARCH=win32`**。 |
| **L-005** | 系统 Wine 与外部前缀保护 | ① 直接覆盖 `/Applications/Wine *.app` 内部文件会被 Homebrew 升级冲掉并污染其他容器；② 以“引用模式”导入的外部 `WINEPREFIX` 若在删除容器时一并删除会误删用户原有 CrossOver/Whisky 数据。 | 严禁写入外部 Wine 引擎目录；`Bottle` 必须显式记录 `isExternalPrefix`，为 `true` 时删除容器严禁删除外部 `WINEPREFIX` 目录。 |
| **L-006** | macOS 隔离属性 | 浏览器下载的 `.exe`/`.msi`/引擎默认带 `com.apple.quarantine`，可能被 Gatekeeper 静默拦截。 | 启动预检与崩溃诊断均需检测 `com.apple.quarantine`；解除隔离必须由用户显式触发且限定最小作用域（单文件或容器目录，严禁递归扫 `~/Downloads`）。 |
| **L-007** | Swift 6 并发与云端 CI | ① Swift 6 `StrictConcurrency` 下将 `@MainActor` 属性作为 `inout` 传入 `async` 函数会直接报编译错；② 当前云端开发机为 Linux x86_64，无本地 Swift 工具链。 | ① 所有 `async` 服务协议**禁止使用 `inout`**，改用值语义返回结构（如 `GraphicsApplyResult`）；② 严禁盲写不验证，每轮必须推送分支触发 **GitHub Actions `macos-15` (arm64)** 执行 `swift build` + `swift test` +（从 Round 1 起）`Scripts/bundle-app.sh` 实机打包校验，绿灯后方可复盘。 |
| **L-008** | 开源合规与 Clean-Room | Whisky、Highball 为 GPL-3.0，Apple D3DMetal 为专有协议，而 Vermouth 为 MIT。 | 严禁复制任何 GPL 代码或打包任何 Apple `D3DMetal`/游戏/Wine 二进制；所有核心解析器（PE、`.lnk`、SHA-256、注册表、日志诊断）必须独立 Clean-Room 实现并附单测证明。 |
| **L-009** | `.msi`、CJK `.reg` 与进程流陷阱 | ① `msiexec /i /Users/...` 会把开头 `/` 当参数开关报错，且 `.msi` 不是 PE 文件；② 含中文键名（如 `宋体`）的 `.reg` 必须用 UTF-16LE + BOM，`FontLink\SystemLink` 必须为 `REG_MULTI_SZ`；③ `Foundation.Process` 不并发排空 `stdout`/`stderr` 会 64KB 死锁，`terminationHandler` 可能早于管道 EOF 截断最后崩溃日志。 | ① `.msi` 必须转为 `wine msiexec /i Z:\...`（或 `C:\...`）并跳过 `PEInspector`；② `RegistryPatcher` 强制输出 UTF-16LE BOM、`REG_MULTI_SZ` (`hex(7)`) 与 `"Key"=-` 清除语法；③ `LiveCommandRunner` 必须并发读取双管道、按 `\n` 缓冲并容错解码非 UTF-8、等待管道 EOF 后再发 `.exited`、并绑定流取消到 `process.terminate()`。 |
| **L-010** | 非 Xcode 打包与资源定位 | 非 Xcode 的 `swift build` 生成的 `*.bundle` 资源若未复制进 `Vermouth.app/Contents/Resources/`，`Bundle.module` 运行时会直接 `fatalError`，而放在 `.app` 根目录会导致 `codesign` 失败。 | 从 **Round 1** 起即落地最小 `VermouthApp` + `Scripts/bundle-app.sh` 并在 `macos-15` CI 中跑通 `codesign --verify` + `plutil -lint` + 资源包定位测试，严格践行 PRD §7 前置打包冒烟验证。 |
| **L-011** | JSON 精度、规范化与快照回滚安全 | ① 标准 `.iso8601` 丢毫秒会导致 `Date` 往返单测不等；② `DllOverride` 大小写未规范化会导致 SwiftUI `ForEach` ID 冲突；③ 快照回滚若未校验 SHA-256 或直接覆盖目标目录，中途失败会清空存档。 | ① 全局使用 `VermouthJSON`（含毫秒 ISO-8601 + 原子写盘）；② `DllOverride` 在 `init` 与 `init(from:)` 统一小写去 `.dll`；③ `SnapshotManager.rollback` 必须先校验 SHA-256 与防路径穿越，再自动做保底快照并用同父目录临时目录原子替换。 |

---

## 二、逐轮复盘记录（Round Retrospectives）

> 每轮结束时按以下模板追加记录：
> - **轮次与交付范围**
> - **测试结果**（编译状态、单测总数/通过率、边界场景覆盖、CI 状态）
> - **暴露的问题与根因分析**
> - **新增约束条目**（编号延续 `L-012`... 并同步补充到上方「生效约束清单」）

### Phase 0（架构、技术栈与接口定型 + 对抗审查）
- **交付范围**：完成成熟项目调研（Whisky/Highball/Barrel/Sikarugir/DXMT/DXVK-macOS）与 Phase 0 三份治理文档（`docs/ARCHITECTURE.md`、`docs/INTERFACES.md`、`docs/LESSONS_LEARNED.md`）。
- **对抗审查结果**：独立 Phase 0 Reviewer Subagent 检出 5 个未定义契约类型、Swift 6 `async` + `inout` 编译阻断点、DXMT `wineBuiltin` 不能降级 `system32` 复制、`.msi` `msiexec` 路径斜杠陷阱、CJK `.reg` UTF-16LE BOM / `REG_MULTI_SZ` 要求、`Process` 管道死锁与 EOF 截断风险、以及应将 `.app` 打包冒烟提前至 Round 1。
- **处理与沉淀**：全部问题已在进入编码前修订入 `ARCHITECTURE.md` 与 `INTERFACES.md`，并沉淀为约束 **L-009 ~ L-011**。
- **状态**：Phase 0 定型完成，等待用户确认后启动 Swarm Round 1。
