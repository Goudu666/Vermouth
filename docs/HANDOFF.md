# HANDOFF：Agent 接力棒

> **这是「此刻的快照」，不是日志**。每次会话结束时由当前 Agent **整份覆盖更新**（历史写进 `docs/WORKLOG.md`）。
> 接棒者开工第一件事：读本文件 → `docs/LESSONS_LEARNED.md` → `git fetch && git log origin/<branch> -5` 核对下面的提交号是否还是最新。
> 若远端比这里写的更新，说明上一个 Agent 没来得及更新本文件：以远端代码 + CI 为准，并在 WORKLOG 记一笔。

```yaml
baton_holder: claude             # 当前持棒者：antigravity | claude。只有持棒者可以推送主开发分支
next_holder: antigravity         # 需要 Mac 真机验证时交还 Antigravity（或由用户本人验证）
main_dev_branch: claude/project-thread-wsp3r9   # 基于 feat/v0.1-mvp 继续开发，经 PR #1 合入 main
last_known_commit: 6e8ed7d       # 最后一个代码提交（运行库安装器）；其后只有文档提交
last_ci_run: 44714569487         # macos-15 ✅ + core-linux ✅ + agent-docs ✅
updated_at: 2026-11-20T10:20Z
updated_by: claude
```

---

## 1. 现在停在哪

- v0.1 代码全部落地且 **CI 全绿**：实时日志阻塞（L-017）与跨平台测试问题（L-018）已修，Linux 169/169。
- 已完成 M2 第一批界面：App 图标与品牌色板、`.exe` 真实图标卡片墙（Clean-Room `PEIconExtractor` + 磁盘缓存）、转译链路可视化、彩色日志与级别筛选、三步引导。
- 已提前完成 M3 运行库安装器（winetricks 卡片 + 诊断卡片一键安装），README 门面已更新。
- 新增 `.github/workflows/package.yml`：PR 上传 `Vermouth-macos-arm64.zip` artifact，合并 main 后滚动发布 `nightly` 预发布，`v*` 标签发正式 Release；README 有「下载安装」与 Gatekeeper 放行说明。
- **所有 UI 只在 macOS CI 上编译通过，还没有人在真机上看过观感。**

## 2. 下一步（按优先级）

| # | 任务 | 说明 | 建议执行者 |
|---|---|---|---|
| P0 | 真机冒烟（PRD §7） | `./Scripts/bundle-app.sh --configuration debug --output dist` 后双击 `dist/Vermouth.app`：建容器 → 装 `.exe` → 看实时日志与卡片图标 → 触发一次诊断卡片 | 用户 / Antigravity（需要 Mac） |
| P0 | 界面观感确认 | 截图回传，按 `docs/UI_PROPOSALS.md` 1–5 逐项改 ✅ 或记录问题 | 同上 |
| P1 | README 真机截图 / GIF | 截图放 `Branding/screenshots/`，替换 README 里的链路图占位 | 任一 |
| P1 | 一键导出 `.app` 快捷方式 | ROADMAP M3，Dock / Launchpad 直开 | Claude |
| P2 | 黑屏检测 / 图形后端 A/B 对比 | ROADMAP 创意储备池 #1 / #3，作品集亮点 | Claude |
| P2 | 合并 PR #1 → `main`，打 `v0.1.0` | 用户决定时机 | 用户 |

## 3. 已知问题

1. **UI 观感未验证**：云端无法渲染 SwiftUI，卡片墙间距、转译链路在窄窗口下的横向滚动、深色模式下的品牌色对比度都可能需要微调。
2. **运行库安装进度只有日志**：winetricks 没有结构化进度输出，目前在控制台看日志；逐项进度需解析其输出，未做。
3. **Linux 专属**：`LiveHTTPFetcher` 下载测试在 Linux 上以 SIGILL 崩溃（FoundationNetworking 差异），已 `XCTSkipIf`；取消子进程在 Linux 上改发 SIGKILL（L-018）。产品只面向 macOS。

## 4. 给下一个 Agent 的提醒

- Claude 云端环境：`sudo ./Scripts/setup-cloud-linux.sh && export PATH=/opt/swift/usr/bin:$PATH`；App 文件可用 `swiftc -parse` 做语法检查，但类型检查只能靠 macOS CI。
- 新的视觉组件统一放 `Sources/VermouthApp/VermouthDesign.swift`，色值只从 `VermouthTheme` 取。
- 新的 winetricks verb 加到 `WinetricksCatalog.verbs`；测试会检查诊断规则建议的 verb 都在目录里。
- 改规则请改 `AGENTS.md`，然后运行 `./Scripts/sync-agent-docs.sh`，不要直接改 `CLAUDE.md` / `GEMINI.md`。
- 无未推送内容。

---

## 附：交棒模板（复制后覆盖上面的内容）

```markdown
baton_holder / next_holder / main_dev_branch / last_known_commit / last_ci_run / updated_at / updated_by
## 1. 现在停在哪        —— 2~4 句话：完成了什么、卡在什么
## 2. 下一步（按优先级）  —— 表格：P0/P1/P2、任务、说明、建议执行者
## 3. 已知问题           —— 现象 / 根因 / 修法（没查到根因就写「未定位」，不要猜）
## 4. 给下一个 Agent 的提醒 —— 环境、坑、未推送的东西（理想情况：无）
```
