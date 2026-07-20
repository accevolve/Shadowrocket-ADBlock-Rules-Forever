#!/usr/bin/env bash
# sync-upstream.sh — 同步上游 lazy_group.conf 并保留本地定制
#
# 上游: Johnshall/Shadowrocket-ADBlock-Rules-Forever (release 分支)
# 本地相对上游保留 3 处定制:
#   1. bypass-system = true          (旁路 Apple 系统服务流量)
#   2. ipv6 = false                  (本机无 IPv6，关闭以避免回退延迟)
#   3. [Host] *.alipay.net           (内网 DNS 解析)
#
# 用法:
#   ./scripts/sync-upstream.sh            # 默认 dry-run，只展示待应用差异
#   ./scripts/sync-upstream.sh --apply    # 写入 lazy_group.conf
#
# 安全保证: --apply 前 stash 未提交改动；改动可经 git 回滚。
# 锚点说明: 定制基于段结构([General]/[Host])而非具体行内容，
#           上游若重命名段名需人工介入(脚本会告警)。

set -euo pipefail

UPSTREAM_URL="https://raw.githubusercontent.com/Johnshall/Shadowrocket-ADBlock-Rules-Forever/release/lazy_group.conf"
TARGET="lazy_group.conf"
TMP="$(mktemp -t upstream.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

# ---- 第一步:拉取上游最新 ----
echo "→ 拉取上游: $UPSTREAM_URL"
if ! curl -sfL -o "$TMP" "$UPSTREAM_URL"; then
  echo "✗ 拉取失败，请检查网络或上游 URL" >&2
  exit 1
fi
echo "  上游版本日期: $(grep -m1 -E '^# [0-9]{4}-[0-9]{2}-[0-9]{2}' "$TMP" || echo '未知')"

# ---- 第二步:应用 3 处定制(基于段结构) ----
python3 - "$TMP" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# 定制 1: 在 [General] 段后、第一条配置前插入 bypass-system
if 'bypass-system = true' not in s:
    marker = '[General]\n'
    i = s.find(marker)
    if i < 0:
        sys.stderr.write('⚠ 未找到 [General] 段，定制 1 未插入\n'); sys.exit(2)
    insert = ('# 旁路系统。如果禁用此选项，可能会导致一些系统问题，如推送通知延迟。\n'
              'bypass-system = true\n\n')
    s = s[:i + len(marker)] + '\n' + insert + s[i + len(marker):]

# 定制 2: ipv6 改 false (上游为 true)
s = s.replace('ipv6 = true', 'ipv6 = false')

# 定制 3: [Host] 段顶插入内网 DNS
if '*.alipay.net = server:30.64.127.127' not in s:
    marker = '[Host]\n'
    i = s.find(marker)
    if i < 0:
        sys.stderr.write('⚠ 未找到 [Host] 段，定制 3 未插入\n'); sys.exit(2)
    insert = '# 内网域名\n*.alipay.net = server:30.64.127.127\n\n'
    s = s[:i + len(marker)] + '\n' + insert + s[i + len(marker):]

open(p, 'w', encoding='utf-8').write(s)
PY

# ---- 第三步:对比与落地 ----
if diff -q "$TMP" "$TARGET" >/dev/null 2>&1; then
  echo "✓ 本地已是最新(含定制)，无需变更。"
  exit 0
fi

if [ "${1:-}" = "--apply" ]; then
  if ! git diff --quiet "$TARGET" 2>/dev/null || ! git diff --cached --quiet "$TARGET" 2>/dev/null; then
    echo "→ 检测到 $TARGET 有未提交改动，先 stash 保护"
    git stash push -m "sync-upstream auto-stash" -- "$TARGET" >/dev/null 2>&1 || true
  fi
  cp "$TMP" "$TARGET"
  echo "✓ 已写入 $TARGET (上游最新 + 本地定制)"
  echo "  查看变更: git diff $TARGET"
  echo "  回滚:     git checkout -- $TARGET"
else
  echo
  echo "── 这是 dry-run，以下为将要应用的差异(相对当前 $TARGET) ──"
  diff -u "$TARGET" "$TMP" || true
  echo
  echo "确认无误后执行: ./scripts/sync-upstream.sh --apply"
fi
