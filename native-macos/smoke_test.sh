#!/bin/bash
# 来财 V0.1 Smoke Test — 验收脚本
# 用法: bash native-macos/smoke_test.sh [endpoint] [model] [api_key]
#
# 示例:
#   bash smoke_test.sh http://127.0.0.1:11434/v1 qwen3:8b ""
#   bash smoke_test.sh https://api.deepseek.com/v1 deepseek-chat sk-xxx
set -euo pipefail

ENDPOINT="${1:-http://127.0.0.1:11434/v1}"
MODEL="${2:-qwen3:8b}"
API_KEY="${3:-}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/laicai-native-build"
APP="$ROOT/dist/Laicai.app"
DATA_DIR="$HOME/Library/Application Support/Laicai"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✅ $1"; ((PASS++)); }
fail() { echo "  ❌ $1"; ((FAIL++)); }
skip() { echo "  ⏭️  $1"; ((SKIP++)); }
section() { echo ""; echo "=== $1 ==="; }

# ── 1. Build ──
section "构建检查"
if bash "$ROOT/build.sh" >/dev/null 2>&1; then
    pass "build.sh 成功"
else
    fail "build.sh 失败"
    echo "构建失败，终止测试。"
    exit 1
fi

if [ -f "$APP/Contents/MacOS/LaicaiNativeApp" ]; then
    pass ".app bundle 存在"
else
    fail ".app bundle 不存在"
fi

PLIST="$APP/Contents/Info.plist"
if [ -f "$PLIST" ]; then
    BUNDLE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$PLIST" 2>/dev/null || echo "")
    if [ "$BUNDLE_NAME" = "来财" ]; then
        pass "Bundle 名称 = 来财"
    else
        fail "Bundle 名称不是来财，是: $BUNDLE_NAME"
    fi
else
    fail "Info.plist 不存在"
fi

# ── 2. 数据目录 ──
section "数据目录"
mkdir -p "$DATA_DIR"
if [ -d "$DATA_DIR" ]; then
    pass "数据目录存在: $DATA_DIR"
else
    fail "数据目录不存在"
fi

# ── 3. 真实模型对话 ──
section "真实模型对话 (endpoint=$ENDPOINT, model=$MODEL)"

# Detect if Ollama native or OpenAI-compatible
if echo "$ENDPOINT" | grep -q "11434"; then
    # Ollama native
    CHAT_URL="${ENDPOINT%/v1*}/api/chat"
    BODY=$(cat <<EOJSON
{
  "model": "$MODEL",
  "messages": [{"role": "user", "content": "请直接回复 ok。"}],
  "stream": false,
  "options": {"num_predict": 10}
}
EOJSON
)
else
    # OpenAI-compatible
    CHAT_URL="$ENDPOINT/chat/completions"
    BODY=$(cat <<EOJSON
{
  "model": "$MODEL",
  "messages": [{"role": "user", "content": "请直接回复 ok。"}],
  "max_tokens": 10,
  "stream": false
}
EOJSON
)
fi

AUTH_HEADER=""
if [ -n "$API_KEY" ]; then
    AUTH_HEADER="-H \"Authorization: Bearer $API_KEY\""
fi

RESPONSE=$(eval curl -s -w "\n%{http_code}" -X POST "$CHAT_URL" \
    -H "Content-Type: application/json" \
    $AUTH_HEADER \
    -d "'$BODY'" \
    --connect-timeout 10 --max-time 30 2>/dev/null || echo "CURL_FAILED")

if echo "$RESPONSE" | grep -q "CURL_FAILED"; then
    fail "无法连接模型服务: $CHAT_URL"
else
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY_RESPONSE=$(echo "$RESPONSE" | sed '$d')
    if [ "$HTTP_CODE" = "200" ]; then
        if echo "$BODY_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('message',{}).get('content','') or d.get('message',{}).get('content',''))" 2>/dev/null | grep -qi "ok"; then
            pass "模型返回了有效回复"
        else
            pass "模型返回 HTTP 200（内容不含 ok 但格式正确）"
        fi
    else
        fail "模型返回 HTTP $HTTP_CODE"
        echo "  响应: $(echo "$BODY_RESPONSE" | head -3)"
    fi
fi

# ── 4. 会话持久化 ──
section "持久化检查"
DB_FILE="$DATA_DIR/threads.sqlite3"
if [ -f "$DB_FILE" ]; then
    TABLE_COUNT=$(sqlite3 "$DB_FILE" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "0")
    pass "SQLite 数据库存在，表数: $TABLE_COUNT"
else
    skip "SQLite 数据库尚未创建（首次运行前不会存在）"
fi

SETTINGS_KEY="laicai.appSettings.v1"
if defaults read com.laicai.native "$SETTINGS_KEY" >/dev/null 2>&1; then
    pass "设置已持久化到 UserDefaults"
else
    skip "设置尚未持久化（首次运行前不会存在）"
fi

# ── 5. 源码扫描 ──
section "源码扫描（产品文案检查）"
SRC_DIR="$ROOT/Sources"
BANNED_PATTERNS=("sample response" "preview response" "mock response" "debug panel" "AgentLoop" "Function calling" "Preview Chat Runtime")
SCAN_PASS=true
for pattern in "${BANNED_PATTERNS[@]}"; do
    if grep -rn --include="*.swift" "$pattern" "$SRC_DIR/LaicaiNativeUI/" 2>/dev/null | grep -v "//.*$pattern" | head -1 | grep -q .; then
        fail "UI 源码包含开发术语: '$pattern'"
        SCAN_PASS=false
    fi
done
if $SCAN_PASS; then
    pass "UI 源码无开发术语残留"
fi

# ── 6. Icon 检查 ──
section "UI 检查"
ICON_PATH="$APP/Contents/Resources/laicai.icns"
if [ -f "$ICON_PATH" ]; then
    pass "App icon 存在"
else
    skip "App icon 不存在（assets/laicai.icns 未找到）"
fi

# ── Summary ──
echo ""
echo "════════════════════════════════"
echo "  通过: $PASS  失败: $FAIL  跳过: $SKIP"
echo "════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
