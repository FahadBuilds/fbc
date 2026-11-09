# fbc

Feedback Assistant stats from your terminal.

![fbc showing Feedback Assistant stats](screenshot.png)

## Install

Run this in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/FahadBuilds/fbc/main/install.sh | sh
```

Requires macOS and Command Line Tools. If the tools aren’t installed, macOS will prompt you to install them.

Full Disk Access is required for your terminal app to read Feedback Assistant’s database. If access is denied, `fbc` shows instructions for enabling it.

## Commands

```bash
fbc                                   # Dashboard
fbc categories                        # All category counts
fbc list --category "SwiftUI" --titles  # Reports in a category, with titles
fbc list --closed --json               # Closed reports as JSON
fbc show FB24490370                    # Report details and cached replies
```

Use `fbc --help` or `fbc <command> --help` for options. `list` outputs IDs by default; add `--titles` for titles or `--json` for structured output.

## Database access

`fbc` reads Feedback Assistant’s cached database in read-only mode. It makes no network requests or API calls.

Totals, categories, and streaks work without opening individual reports. For missing type or platform details, `fbc` identifies which reports to open in Feedback Assistant. Opening a report also makes its cached text and replies available to `fbc`.

## Disclaimer

`fbc` is an unofficial project and is not affiliated with Apple.

Feedback Assistant’s database schema is undocumented and may change without notice, which can break `fbc`.
