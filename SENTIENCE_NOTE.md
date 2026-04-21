# LockIn — built on Sentience

Hey — I built a small macOS menubar app called LockIn that uses the Sentience API to catch me procrastinating in real time.

It polls my Sentience memories every 2.5 minutes, reads the `category` field, and when it detects Entertainment or Social Media activity for more than ~5 minutes straight, it sends an escalating series of notifications. First a gentle nudge, then progressively more aggressive reminders until I get back to work. It also supports a focus deadline (e.g. "exam at 4pm") and every alert includes a countdown.

I'm a CS student at Waterloo — built this during midterm season because I kept losing hours to YouTube without realizing it. Sentience was the only tool I found that could actually tell *what* I was doing, not just that I was at my computer.

The app is open source and installable via Homebrew:
```
brew install --cask hamzakammar/tap/lockin
```

Source: https://github.com/hamzakammar/lockin

Would love to know if the `/v1/memories` API is the right endpoint to be hitting for this use case, and whether there's a webhook or push model that would let me react faster than polling. Happy to share more if useful.

— Hamza
