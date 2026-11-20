## Claude Code 专属补充

- 运行环境：通常是 Linux x86_64 云端容器（claude.ai/code），仓库每次会话重新克隆，**会话结束即回收**，所以收尾协议第 1 步（推送）最重要。
- 会话开始先装工具链：`sudo ./Scripts/setup-cloud-linux.sh && export PATH=/opt/swift/usr/bin:$PATH`，然后 `swift build` 确认 Core + CLI 可编译。
- GitHub 操作用 GitHub MCP 工具；看 CI 用 Actions 相关工具读取 `macos-15` 任务日志，不要猜测结果。
- 开发分支：Claude 的工作分支以 `claude/` 开头；只有在 `docs/HANDOFF.md` 中 `baton_holder: claude` 时才直接推送主开发分支。
- 改了 `Sources/VermouthApp/` 的代码时，本地无法编译 SwiftUI，必须在 PR / CI 结果里确认。
