#!/usr/bin/env bash
# Installs Claude Code hooks that POST marker events to Phospor's
# recording server. Run once — hooks persist in your global settings.
#
# Hooks read the port from ~/Library/Application Support/Phospor/marker-port
# at runtime. If Phospor isn't recording, the request fails silently.

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
HOOK_SCRIPT="$HOME/.claude/phospor-marker-hook.sh"

if ! command -v jq &>/dev/null; then
  echo "jq is required: brew install jq"
  exit 1
fi

mkdir -p "$HOME/.claude"

# Write a small helper script that both hooks call.
cat > "$HOOK_SCRIPT" << 'HOOKEOF'
#!/usr/bin/env bash
# Called by Claude Code hooks. $1 = event name (claude_start or claude_stop)
EVENT="${1:-manual}"
LABEL="${2:-$EVENT}"
PORT_FILE="$HOME/Library/Application Support/Phospor/marker-port"
PORT=$(cat "$PORT_FILE" 2>/dev/null) || exit 0
[ -z "$PORT" ] && exit 0
curl -sf -m 2 -X POST "http://127.0.0.1:$PORT/marker" \
  -H "Content-Type: application/json" \
  -d "{\"event\":\"$EVENT\",\"label\":\"$LABEL\"}" >/dev/null 2>&1
exit 0
HOOKEOF
chmod +x "$HOOK_SCRIPT"

# Build the hooks JSON as a proper file.
TMPFILE=$(mktemp)
cat > "$TMPFILE" << EOF
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_SCRIPT claude_start 'User submitted prompt'",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_SCRIPT claude_stop 'Claude finished'",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
EOF

if [ -f "$SETTINGS" ]; then
  MERGED=$(jq -s '.[0] * .[1]' "$SETTINGS" "$TMPFILE")
  echo "$MERGED" > "$SETTINGS"
  echo "Merged Phospor hooks into existing $SETTINGS"
else
  cp "$TMPFILE" "$SETTINGS"
  echo "Created $SETTINGS with Phospor hooks"
fi
rm -f "$TMPFILE"

echo ""
echo "Installed:"
echo "  Helper script: $HOOK_SCRIPT"
echo "  UserPromptSubmit → claude_start marker"
echo "  Stop             → claude_stop marker"
echo ""
echo "To verify: run /hooks in Claude Code."
