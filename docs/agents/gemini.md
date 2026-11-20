## Antigravity / Gemini 专属补充

- 运行环境：用户的 Mac（Apple Silicon，macOS 26，Swift 6.3.3，Homebrew，无完整 Xcode），可以本机 `swift build`、`swift test`、`./Scripts/bundle-app.sh` 并真机启动 `Vermouth.app`。
- 你是目前唯一能**真机验证 GUI 与真实 Wine 启动**的 Agent：涉及 UI 观感、Wine 实机行为的结论，请在 `docs/HANDOFF.md` 里写清楚「本机实测过 / 仅 CI 验证」。
- 额度即将耗尽时，优先执行 `AGENTS.md` §5 收尾协议的第 1、2 步（推送 + 更新 HANDOFF），并把 `baton_holder` 改为 `claude`。
- 开发分支：持棒时直接推送主开发分支；不持棒时用 `ag/` 前缀分支并开 PR。
