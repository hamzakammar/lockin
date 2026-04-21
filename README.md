# LockIn 🔴

A macOS menubar app that watches your [Sentience](https://sentience.com) screen memories and calls you out when you're procrastinating.

---

## Install

```bash
brew install --cask hamzakammar/tap/lockin
```

Click the 🟢 in your menubar → **⚙️ Settings** → paste your Sentience API key → Save.

## Getting your API key

Sentience app → Settings → Connections → API Key → **Generate API Key**

---

## How it works

LockIn polls your Sentience memories every 2.5 minutes. When it detects `Entertainment` or `Social Media` activity, it starts a count. After 2 consecutive bad polls (~5 min of confirmed procrastination), it sends a notification. It escalates every 2 polls if you stay on the distraction. When you get back to work, it confirms it.

### Escalation

| Polls off-task | Alert |
|---|---|
| 2 | "You've been on YouTube for ~5 min. Lock in." |
| 4 | "Wasted 10 min. Get back to work." |
| 6 | "12 MINUTES GONE. Close it. Now." |
| 8+ | "LOCK IN. Every minute is a minute you don't have." |

### Focus Deadline

Set a deadline (e.g. exam at 4pm) and every alert includes a countdown — "2h 15m left."

---

## Menubar

| Icon | Meaning |
|---|---|
| 🟢 | Focused |
| 🔴 | Procrastinating detected |
| ⏸️ | Paused |

Click the icon for full menu: pause monitoring, set deadline, open log, settings, quit.

---

## Settings

| Setting | Default | Description |
|---|---|---|
| Poll interval | 2.5 min | How often to check Sentience |
| Alert threshold | 2 polls | Consecutive bad polls before alerting |

---

## Requirements

- macOS 13.0+
- [Sentience](https://sentience.com) with screen capture enabled
- Sentience API key

---

## Install from source

```bash
git clone https://github.com/hamzakammar/lockin
cd lockin
swift build -c release
```

---

## License

MIT
