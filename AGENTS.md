# AGENTS.md：Vermouth 多 Agent 协作总则（唯一真相源）

> `AGENTS.md` 是所有 AI 编码 Agent（Google Antigravity / Gemini、Claude Code，以及今后加入的其他 Agent）共享的**唯一规则来源**。
> `CLAUDE.md` 与 `GEMINI.md` 由 `Scripts/sync-agent-docs.sh` 从本文件 + `docs/agents/<agent>.md` 自动生成，**请勿直接编辑那两个文件**。
> 修改规则 → 改本文件（或对应 Agent 的 overlay）→ 运行 `./Scripts/sync-agent-docs.sh` → 一起提交。CI 会检查三者是否同步。

---

## 1. 项目一句话

Vermouth 是面向 Apple Silicon Mac 的开源、原生 macOS Windows 应用与游戏转译启动器（开源 Wine + DXMT / DXVK-macOS / WineD3D 编排外壳）。
纯 Swift 6 + SwiftUI，纯 SwiftPM 构建，零第三方依赖，MIT 许可。

## 2. 开工前必读（按顺序，不可跳过）

1. **`docs/HANDOFF.md`**：接力棒。当前谁持有主开发分支、上一个 Agent 停在哪、下一步做什么、已知问题。
2. **`docs/LESSONS_LEARNED.md`**：生效约束清单（L-001 起）。实现与代码审查必须逐条核对；约束只能收紧，不能静默删除。
3. `docs/STATUS.md`（模块完成度与测试现状）与 `docs/ROADMAP.md`（接下来做什么）。
4. 需要时再查：`PRD.md`（需求）、`docs/ARCHITECTURE.md`（架构与不变量）、`docs/INTERFACES.md`（协议、模型、CLI 契约）。

## 3. 构建、测试与验证

| 场景 | 命令 | 说明 |
|---|---|---|
| macOS 本机 / CI | `swift build && swift test --parallel` | 编译全部三个目标（Core / CLI / App） |
| macOS 打包 | `./Scripts/bundle-app.sh --configuration debug --output dist` | 生成并 ad-hoc 签名 `dist/Vermouth.app` |
| Linux 云端（Claude 等） | `sudo ./Scripts/setup-cloud-linux.sh && export PATH=/opt/swift/usr/bin:$PATH` | 安装 Swift 6.3.3；之后可 `swift build` / `swift test`，**只覆盖 Core + CLI** |
| 权威验证 | GitHub Actions `CI`：`core-linux`（约 2 分钟）+ `macos-15` arm64（完整编译、测试、打包） | 推送 `main` / `feat/**` / `fix/**` 或向 `main` 开 PR 时触发。`claude/**`、`ag/**` 分支请开**草稿 PR** 来跑 CI；**以 CI 绿灯为准** |

- `VermouthApp`（SwiftUI/AppKit）只能在 macOS 编译。Linux 上改了 App 代码无法本地验证，必须推分支看 CI。
- Linux 与 macOS 的 Foundation 有差异：只在一个平台成立的测试用 `#if os(...)` + `XCTSkipIf` 标明原因，不要删测试。
- 严禁盲写不验证（L-007）：每一轮结束必须拿到 CI 结果再写复盘。

## 4. 分支与所有权（防止两个 Agent 互相覆盖）

- **主开发分支**：以 `docs/HANDOFF.md` 里的 `main_dev_branch` 为准。同一时刻**只有 `baton_holder` 写明的 Agent** 可以向它推送代码。
- 不持棒的 Agent 只能在**自己的分支**上工作并开 PR：
  - Claude：`claude/<topic>`；Antigravity：`ag/<topic>`。
  - 只改不冲突的文件（新文件、文档），或在 PR 里写明需要持棒者合并。
- 交接（换棒）= 持棒者把工作提交并推送 → 更新 `docs/HANDOFF.md`（`baton_holder` 改成下一个 Agent）→ 推送。接棒者从远端最新状态开始，不依赖任何本地未推送内容。
- `main` 只通过 PR 合并，由用户（Goudu）决定何时合并。

## 5. 会话收尾协议（每次会话结束前必须做）

1. 所有改动提交并推送到远端（云端容器随时可能被回收，未推送 = 丢失）。
2. **覆盖更新 `docs/HANDOFF.md`**：它是「此刻的快照」，不是日志。按其中模板填写：持棒者、分支与最新提交、CI 状态、进行中的工作、下一步（带优先级）、已知问题、给下一个 Agent 的提醒。
3. **追加一条到 `docs/WORKLOG.md` 顶部**：日期、Agent、做了什么、提交范围、CI 结果。只追加，不改历史。
4. 本轮踩到的新坑 → 追加到 `docs/LESSONS_LEARNED.md`（新编号 L-0xx，含根因与强制约束）。
5. 如修改了 `AGENTS.md` 或 overlay，运行 `./Scripts/sync-agent-docs.sh` 并一起提交。

额度快用完时：**先做第 1、2 步**，其余可以简写。一份写清楚「停在哪、下一步是什么」的 HANDOFF 比多写 100 行代码更值钱。

## 6. 提交规范

- Conventional Commits：`feat(scope): …`、`fix(scope): …`、`docs: …`、`test: …`、`chore: …`。
- 提交信息末尾加一行 `Agent: antigravity` 或 `Agent: claude`，方便在 `git log` 里区分是谁写的。
- 一个提交只做一件事；大功能拆成多个可独立通过 CI 的提交。

## 7. 工程红线（摘要，完整版见 LESSONS_LEARNED）

- 合规：绝不复制 GPL 代码（Whisky / Highball 等只借鉴思路，Clean-Room 实现）；绝不打包 D3DMetal / GPTK / Wine / 游戏二进制；不做反作弊绕过（L-008）。
- 外部 Wine 引擎目录只读；外部导入的 `WINEPREFIX` 删除容器时不得删除（L-005）。
- 所有 Wine 子进程统一经 `EnvironmentBuilder` 生成的 `LaunchPlan` 启动（L-003）。
- Swift 6 严格并发：`async` 协议不用 `inout`（L-007）；持久化 Store 的读改写放在单次无挂起点的 `mutate` 里（L-015）。
- 持久化统一用 `VermouthJSON`（毫秒 ISO-8601 + 原子写盘，L-011 / L-014）。
- 子进程：并发排空双管道、等待 EOF 再发 `.exited`（L-009）。

## 8. 沟通语言

- 面向用户的文档、注释、UI 文案用**简体中文**；代码标识符、提交前缀用英文。
- 用户偏好：重视审美与"拿得出手"的成果，欢迎有创意的提案，但先给结论、少堆砌术语。
