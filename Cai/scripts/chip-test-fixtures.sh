#!/bin/bash
# Drops capability-chip test proposals into Cai's pending-changes directory.
#
# Each one exercises a different chip path on the approval sheet. They queue, so
# the sheet shows "1 of N" and the arrow keys step through them.
#
#   ./chip-test-fixtures.sh          # drop all fixtures
#   ./chip-test-fixtures.sh clean    # remove them again
#
# The Debug build ignores pending-changes/ unless CAI_MCP_PENDING=1 is set in the
# run scheme (Product > Scheme > Edit Scheme > Run > Arguments > Environment).
# Without it nothing appears and the script is not at fault.

set -euo pipefail

DIR="$HOME/Library/Application Support/Cai/pending-changes"
PREFIX="chip-test-"

if [ "${1:-}" = "clean" ]; then
    rm -f "$DIR/$PREFIX"*.json
    echo "Removed $PREFIX*.json from $DIR"
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# drop <slug> <json-for-the-action-object>
drop() {
    local slug="$1" action="$2"
    local file="$DIR/$PREFIX$slug.json"
    cat > "$file" <<JSON
{
  "schemaVersion": 1,
  "id": "$(uuidgen)",
  "createdAt": "$NOW",
  "provenance": {"source": "mcp", "client": "Claude Code", "authoredAt": "$NOW"},
  "op": "create",
  "action": $action
}
JSON
    chmod 600 "$file"
    echo "  $slug"
}

echo "Dropping fixtures into $DIR:"

# 1. The honest floor. Expect: "Runs a shell command" + the tail
#    "plus anything else the command does". NO host chip, even though the
#    command plainly contains one.
drop "01-shell-floor" '{
  "name": "Star count",
  "type": "shell",
  "value": "curl -s https://api.github.com/repos/cai/cai | jq -r .stargazers_count"
}'

# 2. Shell + secrets. Expect the floor chip AND "Uses secret API_KEY" /
#    "Uses secret SLACK_WEBHOOK" in SF Mono. Still non-exhaustive.
drop "02-shell-secrets" '{
  "name": "Post to Slack",
  "type": "shell",
  "value": "curl -H \"Auth: {{secrets.API_KEY}}\" -d @- {{secrets.SLACK_WEBHOOK}}"
}'

# 3. url with %s. Expect "Sends to github.com" (sends, not opens: the
#    selection rides in the URL).
drop "03-url-sends" '{
  "name": "Search GitHub",
  "type": "url",
  "value": "https://github.com/search?q=%s"
}'

# 4. url without %s. Expect "Opens github.com".
drop "04-url-opens" '{
  "name": "Open notifications",
  "type": "url",
  "value": "https://github.com/notifications"
}'

# 5. Templated authority. Expect "Sends somewhere Cai can'\''t name" and the tail
#    "the address is built when it runs". NOT an empty chip row.
drop "05-url-unknown-host" '{
  "name": "Dynamic endpoint",
  "type": "url",
  "value": "https://{{host}}/search?q=%s"
}'

# 6. Prompt + replace. Expect the AI chip naming your configured engine
#    ("Runs on-device AI" / "On-device AI via LM Studio" / "Sends to Anthropic")
#    plus "Replaces your selection". Exhaustive: no tail.
drop "06-prompt-replace" '{
  "name": "Fix grammar",
  "type": "prompt",
  "value": "Fix the grammar. Return only the corrected text.",
  "autoReplaceSelection": true
}'

# 7. Chain into Cai'\''s own built-ins. Expect "Writes to Notes" and
#    "Opens a Mail draft", exhaustive, and NO orange terminal-commands callout.
#    This is the de-escalation change — verify the callout really is absent.
drop "07-builtin-chain" '{
  "name": "Summarise to Notes",
  "type": "prompt",
  "value": "Summarise this in three bullets.",
  "next": [{"action": {"name": "Save to Notes"}}, {"action": {"name": "Email"}}]
}'

# 8. Unresolved chain step. Expect "Runs Ghost Action (not installed)" — the
#    NAME must appear — and no tail (the chip already says it).
drop "08-unresolved" '{
  "name": "Chain to nothing",
  "type": "prompt",
  "value": "Summarise this.",
  "next": [{"action": {"name": "Ghost Action"}}]
}'

# 9. Hostile name length. The chain-step name is 400 chars. Expect it CAPPED at
#    ~60 in the chip, one line, and the sheet must NOT grow: the orange callout
#    and Approve/Reject stay on screen.
LONGNAME=$(printf 'A%.0s' {1..400})
drop "09-hostile-long-name" '{
  "name": "Long step name",
  "type": "prompt",
  "value": "Summarise this.",
  "next": [{"action": {"name": "'"$LONGNAME"'"}}]
}'

# 10. Chip flood. 40 distinct secrets => 40 chips. Expect the chip row to SCROLL
#     inside a bounded band, and Approve/Reject + the callout to stay visible.
#     This is the header-overflow fix; without it the buttons go off-screen.
FLOOD=""
for i in $(seq -w 1 40); do FLOOD="$FLOOD {{secrets.TOKEN_$i}}"; done
drop "10-chip-flood" '{
  "name": "Secret flood",
  "type": "shell",
  "value": "deploy'"$FLOOD"'"
}'

echo
echo "Done. Launch the Debug build with CAI_MCP_PENDING=1 and step the queue with the arrow keys."
echo "Clean up with: $0 clean"
