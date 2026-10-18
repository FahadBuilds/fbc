# fbc

Feedback Assistant stats from your terminal.

![fbc showing Feedback Assistant stats](screenshot.png)

## Install

Run this in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/FahadBuilds/fbc/main/install.sh | sh
```

Requires macOS and the Swift compiler, available with Xcode or the Xcode Command Line Tools.


## Data freshness

Feedback Assistant does not always cache every report's platform metadata locally until the report has been opened. If `fbc` shows an `Unknown` platform followed by an FB number, open that report in Feedback Assistant while online, wait for it to load, then run `fbc` again.

Opening a report usually hydrates the missing local metadata, but an unknown value can also mean that the report's form does not contain a platform answer.

## Disclaimer

`fbc` is an unofficial project and is not affiliated with Apple.

It reads Feedback Assistant's local Core Data SQLite store directly. The on-disk schema is undocumented and may change without notice, which can break `fbc`.
