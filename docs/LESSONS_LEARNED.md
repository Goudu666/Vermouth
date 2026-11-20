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
| **L-012** | macOS APFS 打包碰撞（Round 1 复盘） | macOS 默认采用大小写不敏感 APFS（含 `macos-15` CI）。在 `Contents/MacOS/` 下同时放入 `Vermouth` 与 `vermouth` 会静默覆写主程序为 CLI，且 `codesign --verify` 与 CLI 冒烟均无法检出！ | `.app` 包内主程序与伴随 CLI 必须使用大小写无关也唯一的文件名（`Vermouth` 与 `vermouth-cli`）；打包脚本与 CI 必须校验二者 inode 不同且 `otool -L` 确认主程序链接 `SwiftUI`/`AppKit`；复制资源包必须按名显式复制，严禁通配 `*Tests.bundle`。 |
| **L-013** | 资源定位冒烟防假绿（Round 1 复盘） | 在源码检出目录运行 `.app` 内 CLI 冒烟时，`#filePath` 源码树兜底会掩盖损坏或缺失的 `Contents/Resources/*.bundle`，导致 CI 假绿而用户真机崩溃。 | 运行于 `.app` 包内时严禁回退至 `#filePath` 源码目录或 `Bundle.module`；CI 必须断言打包产物实际解析出的资源路径严格位于 `Vermouth.app/Contents/Resources/Vermouth_VermouthCore.bundle` 内；对 `executableURL` 必须 `resolvingSymlinksInPath()`。 |
| **L-014** | ISO-8601 毫秒精度与往返相等（Round 1 复盘） | `ISO8601DateFormatter` 对毫秒执行向零截断，非二进制精确小数（如 `.100`）会被截断为 `.099Z`；裸 `Date()` 含微秒精度也会导致 `create` 后立即 `load` 判等失败。 | `VermouthJSON` 编码时间戳必须四舍五入至整数毫秒后确定性输出 `.%03dZ`；所有持久化模型生成当前时间戳统一使用 `VermouthJSON.currentTimestamp()`；单测必须覆盖 `.001`/`.100`/`.999` 与 `create`→`load` 严格相等。 |
| **L-015** | Shell 预览防注入与 Actor 原子事务（Round 1 复盘） | ① `ShellQuoting.formatCommand` 未校验 env key，恶意配方 key 可注入终端命令，`zsh` 下 `=` 开头 token 会触发路径展开；② 将 Actor 读改写拆为独立 `load()`/`save()` 并在中间 `await` 会引发并发丢写（TOCTOU）。 | ① env key 进入 shell 字符串前必须校验 `^[A-Za-z_][A-Za-z0-9_]*$`，非法 key 通过 `env 'K=V'` 安全转义，含 `=` 命令名及 `=` 开头参数必须单引号包裹；② 所有持久化 Store（如 `EngineConfigStore`、`GraphicsIndexStore`、`SnapshotIndexStore`）的读改写必须收敛在单次无挂起点的原子 `mutate` 事务中。 |
| **L-016** | 符号链接解引用与子进程退出码门禁（Round 1 复盘） | ① `FileManager.copyItem` 对顶层符号链接目录仅复制链接本身而非目录内容，破坏克隆/复制隔离（L-005）；Homebrew Cask 在 `/opt/homebrew/bin/wine` 的符号链接会产出缺少 `lib/wine/` 的幽灵重复引擎；② 忽略 `exitCode != 0` 回读 `stderr` 会把 `dyld[1234]` 误判为 Wine 版本号。 | ① 复制/克隆前缀前必须对顶层源目录执行 `resolvingSymlinksInPath()` 并禁止祖先向子孙递归复制；引擎探测在缺少 `lib/wine` 时需沿 `bin/wine` 符号链接定位真实根并按规范路径去重；② 任何命令探测（如 `wine --version`）必须先校验 `exitCode == 0`，严禁将非零退出 `stderr` 当正常输出解析。 |
| **L-017** | 流式子进程读取（Claude 接棒复盘） | `FileHandle.read(upToCount:)` 对管道会**阻塞到凑满指定字节数或 EOF**：16KB 缓冲下 Wine 日志要等进程退出才一次性出现，「实时日志」形同虚设，取消测试也因收不到首行而等满 30 秒。原有单测只断言最终内容，未断言**到达时机**，因此没发现。 | 流式读取管道必须用单次 POSIX `read(2)`（有字节即返回、`EINTR` 重试、0 为 EOF）或 `availableData`；所有流式接口的单测必须包含「子进程仍在运行时首行已到达」的时延断言（见 `testLiveCommandRunnerStreamsFirstLineBeforeChildExits`）。 |
| **L-018** | 跨平台路径与信号差异（Claude 接棒复盘） | ① macOS 临时目录 `/var/folders/...` 是 `/private/var` 的符号链接，而 Foundation `URL.resolvingSymlinksInPath()` 会**主动去掉 `/private`**，与 `/bin/pwd`、`realpath` 返回的物理路径永远不等；② Linux 上 swift-corelibs-foundation 从 libdispatch 工作线程 `posix_spawn`，子进程继承屏蔽 SIGTERM 的信号掩码，`Process.terminate()` 无效。 | ① 需要与子进程/内核对比的物理路径一律用 `realpath(3)` 求值，不用 `resolvingSymlinksInPath()`；② 取消子进程在 Linux 上发送 SIGKILL（macOS 保持 SIGTERM）；只在单一平台成立的测试用 `#if os(...)` + `XCTSkipIf` 注明原因，严禁删除。 |

---

## 二、逐轮复盘记录（Round Retrospectives）

> 每轮结束时按以下模板追加记录：
> - **轮次与交付范围**
> - **测试结果**（编译状态、单测总数/通过率、边界场景覆盖、CI 状态）
> - **暴露的问题与根因分析**
> - **新增约束条目**（编号延续并同步补充到上方「生效约束清单」）

### Phase 0（架构、技术栈与接口定型 + 对抗审查）
- **交付范围**：完成成熟项目调研（Whisky/Highball/Barrel/Sikarugir/DXMT/DXVK-macOS）与 Phase 0 三份治理文档（`docs/ARCHITECTURE.md`、`docs/INTERFACES.md`、`docs/LESSONS_LEARNED.md`）。
- **对抗审查结果**：独立 Phase 0 Reviewer Subagent 检出 5 个未定义契约类型、Swift 6 `async` + `inout` 编译阻断点、DXMT `wineBuiltin` 不能降级 `system32` 复制、`.msi` `msiexec` 路径斜杠陷阱、CJK `.reg` UTF-16LE BOM / `REG_MULTI_SZ` 要求、`Process` 管道死锁与 EOF 截断风险、以及应将 `.app` 打包冒烟提前至 Round 1。
- **处理与沉淀**：全部问题已在进入编码前修订入 `ARCHITECTURE.md` 与 `INTERFACES.md`，并沉淀为约束 **L-009 ~ L-011**。

### Round 1（底座、模型、二进制解析、引擎与容器存储 + 非 Xcode 打包冒烟）
- **交付范围**：`Package.swift`、`.github/workflows/ci.yml`、`Scripts/bundle-app.sh`、最小 `VermouthApp` & `VermouthCLI`、内置双配方、`Common`（`VermouthPaths`/`VermouthJSON`/`PureSHA256`/`ShellQuoting`/`VermouthResourceLocator`/`VermouthError`）、全套 `Models` & `Protocols`、`PEInspector`、`ShellLinkParser`、`EngineManager`、`BottleStore`。
- **首轮 CI 验证（Run `44695636063` on `macos-15` arm64）**：Apple Swift 6.1.2 零错误零警告编译通过，80/80 单元测试并行全通，`bundle-app.sh` 与 `codesign --verify` 绿灯。
- **对抗审查暴露的 8 项阻塞级缺陷（CI 绿灯但对抗审查抓出的真隐患！）**：
  1. **B-1（P0）**：macOS 大小写不敏感 APFS 下 `Contents/MacOS/Vermouth` 被 `Contents/MacOS/vermouth` 静默覆写，导致 GUI App 启动即退出！
  2. **B-2（P0）**：`.app` 内未禁用 `#filePath` 源码回退，CI 在仓库内跑冒烟时掩盖潜在的资源包损坏。
  3. **B-3（安全）**：`ShellQuoting.formatCommand` 未校验 env key 存在命令注入风险，且 `=` 开头 token 在 `zsh` 触发路径展开。
  4. **B-4（并发）**：`EngineManager` 的 `EngineConfigStore` 将 `load`/`save` 拆跨 `await`，存在并发丢写 TOCTOU。
  5. **B-5（精度）**：`ISO8601DateFormatter` 毫秒向零截断 `.100` → `.099Z`，且 `BottleStore` 用裸 `Date()` 破坏 `create` 后立即 `load` 的 `==` 相等。
  6. **B-6（macOS 探测）**：Quarantine 提示路径指向内部 `wine` 目录而非外层 `.app`；`probeWineVersion` 未校验 `exitCode == 0` 误把 `stderr` 当版本号；Homebrew Cask `/opt/homebrew/bin/wine` 符号链接未解引用产生幽灵重复引擎。
  7. **B-7（数据安全）**：`BottleStore` 复制/克隆符号链接前缀时 `copyItem` 仅复制链接本身而非目录内容。
  8. **B-8（二进制解析）**：`ShellLinkParser` 在 `VolumeIDAndLocalBasePath == 0` 时返回孤立 `commonPathSuffix` 阻断 `relativePath` 回退。
- **修复与沉淀**：全部 8 项阻塞级缺陷 + 9 项细节优化已于 Round 1 返修补齐，补充针对性回归测试并沉淀为约束 **L-012 ~ L-016**，直接约束 Round 2 ~ Round 4 开发。

### Claude 接棒（Antigravity Round 2–4 收尾，2026-11-20）
- **背景**：Antigravity 在 `6b4c936` 一次性提交 Round 2–4 全部代码后额度耗尽，CI #3–#5 红灯，未留复盘。
- **测试结果**：macOS CI #5 编译通过，148 个测试中 2 个失败；Linux（Swift 6.3.3）146/148。
- **根因**：① `LiveCommandRunner` 用 `read(upToCount:)` 读管道导致日志不实时（真实产品 bug）；② 环境继承测试用 `resolvingSymlinksInPath()` 求期望路径，在 macOS 上被 `/private` 前缀差异坑；③ Linux 专属的 SIGTERM 掩码与 FoundationNetworking 下载任务 stub 崩溃。
- **处理与沉淀**：改为 `read(2)` 并新增首行时延回归测试；测试改用 `realpath(3)`；Linux 取消改发 SIGKILL，HTTP 下载 stub 测试在 Linux 跳过并注明原因；CI 新增 `core-linux` 快速任务。沉淀为 **L-017、L-018**。

