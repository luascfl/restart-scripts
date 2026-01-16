# Repository Guidelines

## project structure and module organization
This repository is a collection of Bash utilities and helper scripts. Most files live in the root directory:
- `restart-network-manager.sh` and `restart-pcmanfm-qt.sh` handle desktop troubleshooting.
- `gerenciar_rclone.sh` and `gerenciar_warp.sh` manage systemd services for rclone and Cloudflare WARP.
- `create_and_push_repo.sh` bootstraps a GitHub repository and pushes changes.
- `package.json` exists only for a single Node dependency; there is no app build output here.

No dedicated `src/` or `tests/` folders are present today.

## build, test, and development commands
There is no build pipeline. Scripts are run directly from the root folder:
- `./restart-network-manager.sh` restarts NetworkManager and toggles Wi-Fi.
- `./restart-pcmanfm-qt.sh /path/to/dir` restarts the file manager and opens a target directory.
- `./gerenciar_rclone.sh on|off|restart|status|list [service...]` manages rclone user services.
- `./gerenciar_warp.sh on|off|status` manages Cloudflare WARP services.
- `./create_and_push_repo.sh [action]` initializes and pushes a GitHub repository (requires `GITHUB_TOKEN`).

## coding style and naming conventions
- Use Bash with `set -euo pipefail` and `#!/usr/bin/env bash` for new scripts.
- Prefer lowercase, hyphenated filenames for scripts (example: `restart-network-manager.sh`).
- Keep functions small and focused; add short comments only when logic is non-obvious.
- Follow `.gitignore` patterns for secrets and build artifacts (for example, `GITHUB_TOKEN.txt`, `node_modules/`).

## testing guidelines
There is no automated test suite. Validate changes by running the affected script in a safe environment and noting side effects (systemd services, sudo usage, GUI process restarts). Keep logs or output handy when reporting issues.

## commit and pull request guidelines
Current Git history uses short, generic messages (for example, `push`). If you add new commits, prefer imperative summaries like `Add rclone status output` or `Fix warp restart flow`. For pull requests, include:
- a clear description of the change and why it is needed
- exact commands run for manual verification
- any risks, especially if the script touches system services or requires sudo
