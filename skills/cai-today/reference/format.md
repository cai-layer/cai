# cai-today file formats (version 1)

Cai reads these files from the Today folder and checks every line. A line Cai can't read is left out and counted in the "items not shown" line, so follow the formats exactly. Every file carries `"v": 1`.

## items.jsonl

One JSON object per line. The first line is the header; every other line is one item.

### Header

```json
{"v": 1, "type": "header", "generated": "2026-11-02T08:58:12Z", "since": "2026-10-30T09:00:00Z", "sources": [{"name": "slack", "status": "read"}, {"name": "gmail", "status": "read"}, {"name": "github", "status": "read", "via": "gh"}, {"name": "linear", "status": "skipped", "reason": "needs sign-in"}]}
```

| Field | Type | Notes |
| --- | --- | --- |
| `v` | number | Always `1`. |
| `type` | string | Always `"header"`. |
| `generated` | string | When this list was written, ISO 8601 in UTC. |
| `since` | string | The start of the look-back window, ISO 8601 in UTC. |
| `sources` | array | One entry per source: `name`, `status` (`"read"` or `"skipped"`), optional `via` (`"gh"` or `"connector"`), and `reason` when skipped. |

### Item

```json
{"id": "slack-C0123-1730531000.123", "url": "https://example.slack.com/archives/C0123/p1730531000123", "source": "slack", "title": "Send the Q4 numbers for the board pack", "why": "Your manager asked directly, and the board pack goes out at 3 pm.", "who": "Alex Rivera", "priority": "P0", "created": "2026-11-02T07:40:00Z", "activity": "2026-11-02T08:15:00Z", "prompt": "Read the Slack thread at https://example.slack.com/archives/C0123/p1730531000123 and draft a reply to Alex with the Q4 numbers they asked for. Show me the draft; don't send it.", "links": ["https://example.slack.com/archives/C0123/p1730531000123", "https://mail.example.com/thread/abc"]}
```

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string | Stable across runs for the same subject: the source plus its own id. At most 200 characters. |
| `url` | string | The main link, `https://` only. Cai keys done, dismissed and snoozed state on it. |
| `source` | string | `slack`, `gmail`, `github`, `linear`, `notion`, or another short lowercase name. |
| `title` | string | What needs doing. At most 120 characters. |
| `why` | string | One line on why it matters now. At most 200 characters. |
| `who` | string | The person asking or waiting, as they appear in the source. |
| `priority` | string | `"P0"`, `"P1"`, `"P2"` or `"P3"`. |
| `created` | string | When the subject started, ISO 8601 in UTC. |
| `activity` | string | The latest message or change in the subject, ISO 8601 in UTC. A done item comes back when this moves. |
| `prompt` | string | A self-contained prompt for the user's agent. At most 2,000 characters. |
| `links` | array | All `https://` links for the subject, the main one first. At most 10. |

## candidates.json

The people and channels the run saw, so Cai can suggest them while the user edits their priorities.

```json
{"v": 1, "generated": "2026-11-02T08:58:12Z", "people": [{"name": "Alex Rivera", "email": "alex@example.com", "handle": "@alex", "sources": ["slack", "gmail"], "count": 14, "reason": "You reply to Alex most often"}], "channels": [{"name": "#release-planning", "source": "slack", "count": 9, "reason": "You post here most weeks"}]}
```

| Field | Type | Notes |
| --- | --- | --- |
| `people[]` | array | `name`, optional `email` and `handle`, `sources`, `count` (interactions in the window), and a one-line `reason`. Most frequent first, at most 100. |
| `channels[]` | array | `name` (with `#`), `source`, `count`, and a one-line `reason`. Most frequent first, at most 50. |
