# LockIn 🔴

macOS menubar agent that watches your [Sentience](https://sentience.com) screen memories and notifies you when you're procrastinating.

> Requires macOS 13+ and [Sentience](https://sentience.com) with screen capture enabled.

---

## Install

```bash
brew install --cask hamzakammar/tap/lockin
```

Then click the 🟢 in your menubar → **⚙️ Settings** → paste your Sentience API key → Save.

That's it. LockIn runs in the background and monitors your screen activity automatically.

## Getting your API key

Sentience app → Settings → Connections → API Key → **Generate API Key**

## How it works

- Polls your Sentience memories every 2 minutes
- Reads the `category` field from each memory — `Entertainment` or `Social Media` = procrastination
- After **2 consecutive bad polls** (~4 min of confirmed procrastination) → first notification
- Escalates every 2 polls if you stay on the distraction
- When you get back to work → "Back on track. Keep going." ✅
- Set a focus deadline (e.g. exam at 4pm) and every alert includes a countdown

## Menubar

| Icon | Meaning |
|------|---------|
| 🟢 | Focused |
| 🔴 | Procrastinating detected |
| ⏸️ | Paused |

Click the icon for:
- **Status** — current state + last poll time
- **⏱ Set Focus Deadline** — adds countdown to all notifications
- **Launch at Login** — toggle auto-start
- **⏸ Pause Monitoring** — kill switch
- **⚙️ Settings** — API key, poll interval, alert threshold
- **📋 Open Log** — full procrastination history

## Log

`~/Library/Logs/LockIn/procrastination.log`

## Uninstall

Drag `LockIn.app` from Applications to Trash. That's all.
