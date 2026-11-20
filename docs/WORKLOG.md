# WORKLOG：Agent 工作日志（只追加，新条目放最上面）

> 每次会话结束追加一条。格式：`## 日期 · Agent · 一句话标题`，下面 3~6 行：做了什么、提交范围、CI 结果、留给谁的事。
> 当前状态看 `docs/HANDOFF.md`，这里只记历史。

---

## 2026-11-20 · Claude · 普通模式「程序库」：点开就能玩，技术细节收进高级模式

- 用户反馈界面露了太多技术细节。新增默认的程序库界面：封面卡片、双击启动、卡片上显示运行中 / 停止、底部浮动提示。
- 拖入 `.exe` / `.msi` 自动判断安装包还是免安装程序；首次使用自动创建默认环境；安装后自动把新程序加进程序库。
- 一键准备环境（Rosetta / Homebrew / Wine / winetricks 合成一条终端脚本，回到 App 自动刷新）；运行出问题时弹出白话问题助手 + 一键修复；日志、转译链路折叠在「技术详情」。
- 原工作台保留为高级模式（⇧⌘A）。另：打包工作流 `package.yml`（PR artifact / nightly / 标签 Release）；去掉 Homebrew 已移除的 `--no-quarantine`（L-019）。
- 提交 `d9a5c05`..`a345425`；macOS CI 一次通过，Linux 191/192（1 个按平台跳过）。

## 2026-11-20 · Claude · 接棒：CI 转绿、图标卡片墙、转译链路、运行库安装器

- 修实时日志阻塞（`read(2)` 替代 `read(upToCount:)`，L-017）与 `/private/var` 路径、Linux 信号差异（L-018）；新增 `core-linux` CI 任务。
- Core：Clean-Room `PEIconExtractor` + `ProgramIconCache`、`WineLogClassifier`、`TranslationPipeline`、`Winetricks` 目录与计划；CLI 新增 `vermouth icon`。
- App：品牌图标与色板、程序卡片墙（真实 `.exe` 图标）、转译链路、彩色日志与级别筛选、三步引导、运行库安装器 + 诊断一键安装。
- 提交 `2de80e4`..`6e8ed7d` + 文档提交；CI run 44714569487 全绿，Linux 169/169。
- 留给真机持有者：冒烟与界面观感确认（见 HANDOFF §2）。

## 2026-11-20 · Claude · 云端环境、项目文档与双 Agent 协作机制

- 在 Linux 云端装好 Swift 6.3.3（`Scripts/setup-cloud-linux.sh`，官方站不可达时从 mirror.gcr.io 拉官方镜像层），Core + CLI 编译通过，Linux 上 148 个测试中 146 个通过。
- 定位 CI 红灯根因：`LiveCommandRunner` 用 `read(upToCount:)` 导致日志要等进程退出才出现；环境继承测试的 `/private/var` 路径比较错误。写入 `docs/HANDOFF.md` §3，未改 Antigravity 正在修改的源码。
- 新增 `AGENTS.md`（唯一真相源）+ 自动生成的 `CLAUDE.md` / `GEMINI.md` + `Scripts/sync-agent-docs.sh` + CI 同步检查。
- 新增 `docs/HANDOFF.md`、`docs/WORKLOG.md`、`docs/STATUS.md`、`docs/ROADMAP.md`、`docs/UI_PROPOSALS.md`。
- 分支：`claude/project-thread-wsp3r9`（只加文件，PR 目标 `feat/v0.1-mvp`）。

## 2026-11-20 · Antigravity · v0.1 Phase 0 → Round 4（据 git 历史整理）

- `b77c7ba` Phase 0：架构、接口、教训治理文档。
- `932d8b6` / `0f77fb5` Round 1：SwiftPM 底座、模型、PE/.lnk 解析、引擎与容器管理、macOS 打包 CI；修复 8 项对抗审查缺陷（L-012 ~ L-016）。CI #1、#2 绿灯。
- `6b4c936` 完成 Core / CLI / SwiftUI App 全部 v0.1 功能；`dbf0dbd`、`05ff25d` 修编译与测试问题。CI #3 ~ #5 红灯，最后一次只剩 2 个测试失败。
