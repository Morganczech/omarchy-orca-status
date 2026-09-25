# Orca Status for Omarchy

Traffic-light status for [Orca](https://orca.dev) agents in the Omarchy bar, with a panel for projects and workspaces.

## Features

- **Bar semaphore** — green (working), yellow (waiting), red (blocked) without opening the panel
- **Projects** — durable Orca projects with active workspace counts
- **Workspaces** — worktrees with agent state, preview text, and expandable agent details
- **Actions** — focus a workspace in Orca (`orca terminal switch`) or open its path

## Requirements

- Omarchy with shell plugins
- Orca IDE running locally with CLI on `PATH` (or at `~/.config/orca/linux-orca-cli-shim/orca`)
- Python 3

## Install

```bash
omarchy plugin add https://github.com/Morganczech/omarchy-orca-status.git --enable --yes
omarchy bar move gruut.orca-status --section right
```

Manual install:

```bash
git clone https://github.com/Morganczech/omarchy-orca-status.git ~/.config/omarchy/plugins/gruut.orca-status
omarchy-shell shell rescanPlugins
omarchy plugin enable gruut.orca-status --section right
```

## Configuration

In `~/.config/omarchy/shell.json` under the widget entry:

| Setting | Default | Description |
|---------|---------|-------------|
| `refreshIntervalSec` | 12 | Background refresh while panel is closed |
| `orcaCliPath` | `""` | Custom path to `orca` binary |
| `showWhenIdle` | `false` | Keep bar icon visible when no agents are active |

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| `↑↓` | Move selection |
| `Enter` | Expand agents or focus workspace in Orca |
| `f` | Focus workspace in Orca |
| `o` | Open workspace path |
| `e` | Toggle agent details |
| `/` | Filter workspaces |
| `r` | Refresh |

## Development

```bash
python3 test_orca_status.py
python3 orca-status.py
omarchy plugin validate ~/.config/omarchy/plugins/gruut.orca-status
```

## License

MIT
