# HANDOFF：Agent 接力棒

> **这是「此刻的快照」，不是日志**。每次会话结束时由当前 Agent **整份覆盖更新**（历史写进 `docs/WORKLOG.md`）。
> 接棒者开工第一件事：读本文件 → `docs/LESSONS_LEARNED.md` → `git fetch && git log origin/<branch> -5` 核对下面的提交号是否还是最新。
> 若远端比这里写的更新，说明上一个 Agent 没来得及更新本文件：以远端代码 + CI 为准，并在 WORKLOG 记一笔。

```yaml
baton_holder: claude             # 当前持棒者：antigravity | claude。只有持棒者可以推送主开发分支
next_holder: antigravity         # 需要 Mac 真机验证时交还 Antigravity
main_dev_branch: claude/project-thread-wsp3r9   # 基于 feat/v0.1-mvp 继续开发，经 PR 合入 main
last_known_commit: 05ff25d       # fix(tests): move await outside XCTUnwrap synchronous autoclosure
last_ci_run: 44710039726         # macos-15，结论：failure（编译通过，148 个测试中 2 个失败）
updated_at: 2026-11-20T09:40Z
updated_by: claude               # Antigravity 已于 2026-11-20 交棒（未留 HANDOFF，本版由 Claude 基于远端代码与 CI 日志整理）
```

---

## 1. 现在停在哪

- v0.1 全部代码已落地：`VermouthCore`（Round 1–3 模块）、`VermouthCLI`（全命令）、`VermouthApp`（完整 SwiftUI 界面），约 1.9 万行源码 + 7.9 千行测试。
- 最近 3 次 CI（run #3–#5）都是红灯，Antigravity 正在逐个修：#3 编译错 → #4 修 CLI 三元表达式歧义 → #5 编译通过，**仅剩 2 个测试失败**。
- `docs/LESSONS_LEARNED.md` 只写到 Round 1 复盘，Round 2–4 的复盘还没写。

## 2. 下一步（按优先级）

| # | 任务 | 说明 | 建议执行者 |
|---|---|---|---|
| P0 | 修 `LiveCommandRunner` 实时日志阻塞 | 根因与修法见 §3-1，修完 `testLiveCommandRunnerCancellationTerminatesChildPromptly` 应转绿 | 持棒者 |
| P0 | 修 `testLiveCommandRunnerEnvironmentInheritanceToggleAndWorkingDirectory` | 测试自身的问题，见 §3-2 | 持棒者 |
| P1 | CI 全绿后补写 Round 2–4 复盘到 `LESSONS_LEARNED.md` | 把 §3 的两个坑沉淀为 L-017 / L-018 | 持棒者 |
| P1 | 本机真机冒烟（PRD §7） | 用 `wine-stable` 实测一条 32 位 DX9 + 一条 DXMT 链路，结果写进 STATUS | 只能 Antigravity（需要 Mac） |
| P2 | `ci.yml` 增加 `claude/**`、`ag/**` 分支触发 | 让非持棒 Agent 的分支也能跑 macOS CI | 持棒者 |
| P2 | 开 `feat/v0.1-mvp → main` 的 PR | 由用户决定合并时机 | 任一 |

## 3. 已知问题（附根因，已在 Linux 上复现验证）

1. **实时日志其实不实时**（影响产品功能「实时日志」，不只是测试）
   - 现象：`LiveCommandRunner.stream` 在子进程退出前收不到任何一行输出；CI 中取消测试等满 30 秒才结束。
   - 根因：`FileHandleBox.readChunk` 用的 `FileHandle.read(upToCount: 16384)` 对管道会**一直阻塞到凑满 16KB 或 EOF**，所以 Wine 日志只会在进程退出时一次性吐出。
   - 修法（已在 Linux 副本中验证，修后 6 个 `LiveCommandRunner` 测试中 5 个通过，第 6 个见第 3 条）：把 `readChunk` 换成单次 POSIX `read(2)`（有任何字节就返回，`EINTR` 重试，0 表示 EOF），或改用 `FileHandle.availableData`。
2. **环境继承测试在 macOS 上的路径比较错误**（测试 bug，不是产品 bug）
   - `PlatformBoundariesTests.swift:279` 期望 `PWD == tempRoot.resolvingSymlinksInPath().path`。macOS 上临时目录是 `/var/folders/...`，它是 `/private/var/...` 的符号链接，而 Foundation 的 `resolvingSymlinksInPath()` 会**主动去掉 `/private` 前缀**，`/bin/pwd` 却返回带 `/private` 的真实路径，二者永远不等。Linux 上无此问题，所以该测试在 Linux 通过。
   - 修法：用 `realpath(3)` 求期望值，或比较时把两边都去掉 `/private` 前缀。
3. **Linux 专属**：取消后子进程收不到 SIGTERM
   - swift-corelibs-foundation 的 `Process` 从 libdispatch 工作线程 `posix_spawn`，子进程继承了**屏蔽 SIGTERM 的信号掩码**（实测 `/proc/<pid>/status` 中 `SigBlk: fffffffe3bfbea27`）。macOS 不受影响。产品只面向 macOS，可不修；若要 Linux 测试全绿，可在取消时改发 `SIGKILL`，或给该测试加 `#if os(macOS)`。
4. **Linux 专属**：`testLiveHTTPFetcherDownloadReportsProgressWritesAtomicallyAndPreservesFileOnHTTP500` 在 Linux 上以 SIGILL 崩溃（FoundationNetworking 差异），macOS 正常。

## 4. 给下一个 Agent 的提醒

- Claude 在云端的环境：`sudo ./Scripts/setup-cloud-linux.sh && export PATH=/opt/swift/usr/bin:$PATH`，约 1 分钟装好 Swift 6.3.3，Core + CLI 编译约 10 秒。
- `docs/ARCHITECTURE.md` §4 的目录树没有列出 `UIComponents.swift`、`AdvancedOverridesView.swift`、`CLICommands.swift`，下次动架构文档时顺手补上。
- 改规则请改 `AGENTS.md`，然后运行 `./Scripts/sync-agent-docs.sh`，不要直接改 `CLAUDE.md` / `GEMINI.md`。

---

## 附：交棒模板（复制后覆盖上面的内容）

```markdown
baton_holder / next_holder / main_dev_branch / last_known_commit / last_ci_run / updated_at / updated_by
## 1. 现在停在哪        —— 2~4 句话：完成了什么、卡在什么
## 2. 下一步（按优先级）  —— 表格：P0/P1/P2、任务、说明、建议执行者
## 3. 已知问题           —— 现象 / 根因 / 修法（没查到根因就写「未定位」，不要猜）
## 4. 给下一个 Agent 的提醒 —— 环境、坑、未推送的东西（理想情况：无）
```
