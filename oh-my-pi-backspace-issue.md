Title: Backspace ignored in interactive input on tmux + QTerminal (Lubuntu), while Delete works

## Summary
In `omp` interactive mode, Backspace is ignored in the prompt input, but Delete works.
This happened specifically under `tmux` inside `QTerminal` on Lubuntu.
Outside `omp`, Backspace behaves normally in shell/readline.

## Environment
- oh-my-pi: `13.17.1`
- Bun: `1.3.9`
- tmux: `3.5a`
- Terminal emulator: `QTerminal 2.2.1`
- Distro: `Ubuntu 25.10` (Lubuntu session)
- Shell TERM inside tmux: `tmux-256color`
- tmux client term: `xterm-256color`
- tmux server options:
  - `extended-keys on`
  - `extended-keys-format csi-u`
  - `backspace C-?`

## Reproduction
1. Open QTerminal.
2. Start tmux session.
3. Run `omp`.
4. Type text in prompt input.
5. Press Backspace.

## Expected
Backspace removes the previous character.

## Actual
Backspace does nothing in `omp` input. Delete still works.

## Additional evidence
A raw key capture script in the same tmux session shows Backspace as `0x7f` and Delete as `\x1b[3~`.

Backspace capture:
- raw-json: `""` (DEL byte)
- hex: `7f`
- parseKey: `backspace`
- matches backspace: `true`

Delete capture:
- raw-json: `"\u001b[3~"`
- hex: `1b 5b 33 7e`
- parseKey: `delete`
- matches delete: `true`

Also instrumenting TUI input logging during the failure shows repeated Backspace events arriving as `7f` and parsed as `backspace`.

## Notes
This looks like an input-path handling issue under tmux/QTerminal rather than terminal emission, because the correct Backspace byte arrives (`7f`) but is not always applied by the editor behavior.

## Potential direction
- Consider a tmux-safe path that avoids enhanced keyboard negotiation (Kitty/modifyOtherKeys) by default under `TMUX`, or make it configurable.
- Consider a TUI boundary normalization for Backspace so focused components always receive a consistent representation.
- Ensure app/custom key handlers cannot swallow editor deletion keys before editor processing.
