# fbc

Feedback Assistant stats from your terminal.

![fbc showing Feedback Assistant stats](screenshot.png)

## Install

Run this in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/FahadBuilds/fbc/main/install.sh | sh
```

Requires macOS and Command Line Tools. If the tools aren’t installed, macOS will prompt you to install them.

## Commands

```bash
# Dashboard
fbc

# All category counts
fbc categories

# Reports in a category, with titles
fbc list --category "SwiftUI" --titles

# Closed reports as JSON
fbc list --closed --json

# Report details and cached replies
fbc show FB24490370
```

Use `fbc --help` or `fbc <command> --help` for options. `list` outputs IDs by default; add `--titles` for titles or `--json` for structured output.

Totals, categories, and streaks work without opening individual reports. For missing type or platform details, `fbc` identifies which reports to open in Feedback Assistant. Opening a report also makes its cached text and replies available to `fbc`.

## Database access

`fbc` reads Feedback Assistant’s cached database in read-only mode. It makes no network requests or API calls.

Some report details are cached only after opening the report in Feedback Assistant.

Full Disk Access is required for your terminal app to read Feedback Assistant’s database.

## Disclaimer

`fbc` is an unofficial project and is not affiliated with Apple.

Feedback Assistant’s database schema is undocumented and may change without notice, which can break `fbc`.
