#!/usr/bin/env bash
# 从唯一真相源 AGENTS.md + docs/agents/<agent>.md 生成 CLAUDE.md 与 GEMINI.md。
#
#   ./Scripts/sync-agent-docs.sh          # 重新生成
#   ./Scripts/sync-agent-docs.sh --check  # 只检查是否同步（CI 使用），不同步则退出码 1
#
# 采用「生成整份文件」而非 @import：Claude Code 与 Gemini/Antigravity 对 import 语法支持不一致，
# 生成后的文件任何工具都能原样读取，且 CI 能逐字节校验。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-write}"

render() {
    local agent="$1" title="$2"
    printf '<!-- 自动生成文件，请勿直接编辑。来源：AGENTS.md + docs/agents/%s.md；修改后运行 ./Scripts/sync-agent-docs.sh -->\n\n' "$agent"
    printf '# %s\n\n' "$title"
    printf '> 由共享总则 `AGENTS.md` + 本 Agent 专属补充（见文末）拼成。所有 Agent 的规则始终一致，只有文末补充不同。\n\n'
    # 去掉 AGENTS.md 自己的一级标题，避免重复
    sed '1,2{/^# /d;/^$/d;}' "$ROOT/AGENTS.md"
    printf '\n---\n\n'
    cat "$ROOT/docs/agents/$agent.md"
}

status=0
for pair in "claude:CLAUDE.md:CLAUDE.md（Claude Code）" "gemini:GEMINI.md:GEMINI.md（Antigravity / Gemini）"; do
    IFS=: read -r agent file title <<<"$pair"
    expected="$(render "$agent" "$title")"
    target="$ROOT/$file"
    if [[ "$MODE" == "--check" ]]; then
        if [[ ! -f "$target" ]] || [[ "$(cat "$target")" != "$expected" ]]; then
            echo "✗ $file 与 AGENTS.md / docs/agents/$agent.md 不同步，请运行 ./Scripts/sync-agent-docs.sh" >&2
            status=1
        else
            echo "✓ $file 已同步"
        fi
    else
        printf '%s\n' "$expected" >"$target"
        echo "已生成 $file"
    fi
done
exit "$status"
