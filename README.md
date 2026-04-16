# LockIn 🔴

macOS menubar agent that watches your Sentience screen memories and yells at you when you're procrastinating.

## How It Works

1. Every 2.5 minutes, polls `GET /v1/memories` on the Sentience API for the last 5 minutes of screen activity
2. Scans the natural-language descriptions for procrastination apps (Instagram, TikTok, Reddit, Twitter, etc.)
3. Educational YouTube is explicitly excluded — tutorials, lectures, CS content won't trigger it
4. After **2 consecutive bad polls** (~5 min of wasted time) → first notification
5. Continues escalating every 2 polls with increasingly aggressive messages
6. When you go back to productive work → "Back on track. Keep going." and resets
7. Set a focus deadline (exam time, etc.) and every notification includes a countdown

## Setup

### 1. Build

```bash
cd lockin
swift build -c release
```

### 2. Copy binary

```bash
cp .build/release/LockIn /usr/local/bin/LockIn
```

### 3. Set your API key

Create a config file (simplest approach — works with launchd too):
```bash
mkdir -p ~/.lockin
echo "LOCKIN_API_KEY=your_key_here" > ~/.lockin/config
```

Or set it as an env var in the plist (see `com.hamza.lockin.plist`).

### 4. Optional: set a deadline

Uncomment and set `LOCKIN_DEADLINE` in the plist (ISO8601 format, local time):
```xml
<key>LOCKIN_DEADLINE</key>
<string>2025-04-16T16:00:00</string>
```

### 5. Install as launch agent (auto-start at login)

```bash
cp com.hamza.lockin.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.hamza.lockin.plist
```

### 6. Start it now (without rebooting)

```bash
launchctl start com.hamza.lockin
```

### 7. Check it's running

```bash
launchctl list | grep lockin
# Should show a PID
```

## Menubar

- **🟢** = Focused
- **🔴** = Procrastinating detected
- Click the icon to:
  - See current status
  - Set/clear focus deadline
  - Pause monitoring (kill switch)
  - Open the procrastination log
  - Quit

## Procrastination Log

Saved to: `~/Library/Logs/LockIn/procrastination.log`

Contains timestamped entries of every detection and notification.

## Config (in `main.swift`)

| Variable | Default | Description |
|---|---|---|
| `pollIntervalSeconds` | 150 | How often to poll (seconds) |
| `procrastinationThreshold` | 2 | Consecutive bad polls before first alert |
| `escalationThreshold` | 5 | After this many bad polls, full escalation mode |
| `procrastinationKeywords` | see code | Apps that trigger detection |
| `educationalKeywords` | see code | YouTube keywords that bypass detection |

## Stopping / Uninstalling

```bash
# Pause (from menubar) or:
launchctl stop com.hamza.lockin

# Uninstall completely
launchctl unload ~/Library/LaunchAgents/com.hamza.lockin.plist
rm ~/Library/LaunchAgents/com.hamza.lockin.plist
rm /usr/local/bin/LockIn
```

## Notifications Permission

On first launch, macOS will ask for notification permissions. Allow them or nothing will show up.
If you missed the prompt: System Settings → Notifications → LockIn → Allow.
