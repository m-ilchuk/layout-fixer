# Layout Fixer

A small menu bar app for macOS that fixes text typed in the wrong keyboard layout (ABC/US ↔ Ukrainian),
then switches the layout for you.

| Keys | What it does |
|---|---|
| **Tap right ⌥** (alone) | Convert the **selected** text; with nothing selected, the last word you typed |
| ⌥Space | Retype the last word in the other layout (`ghbdsn` → `привіт`) and switch the layout |
| ⌥⇧Space | Convert the **selected** text; with nothing selected, the whole phrase since the last click / Enter / arrow key |
| same key again | Flip it back |

The menu also has **Fix automatically while typing (beta)**, which is off by default. When you finish a word with Space,
if the word is not a real word in the current language but the same keys spell a real word in the other layout
(checked with the macOS spell checker), it retypes the word and switches the layout.

## How it works

- It remembers the **keys** you pressed since the last click, Enter, arrow key or app switch, not the characters.
  Fixing a word deletes it and types the same keys again on the other layout. The key maps come from macOS
  (`UCKeyTranslate`), so nothing is hard-coded and the result matches your real layouts (`'` → `є`, `s` → `і`, `]` → `ї`).
- For selected text, which has no key presses to replay, it reads the selection through Accessibility (or copies it
  with ⌘C where an app doesn't share it), works out the layout from the characters, pastes the converted text over
  it and restores your clipboard. Punctuation that is punctuation on both layouts stays as you see it.
- Logs (counts only, never your text): `/usr/bin/log stream --info --predicate 'subsystem == "io.local.layoutfixer"'`
- It never stores what you type: the key buffer lives only in memory, holds at most 300 keys and is cleared on every
  click.

## Build and install

```bash
./build.sh --test   # conversion tests against the layouts enabled on this Mac
./install.sh        # build, copy to ~/Applications, start
```

On first launch, allow **Layout Fixer** in System Settings › Privacy & Security › **Accessibility** and
**Input Monitoring**. It retries every 3 seconds, so it starts working once you allow it. A menu bar title with ⚠︎ means
it is still waiting. Turn on **Open at login** from its menu.

## Keep permissions across rebuilds

macOS ties the permissions to the app's signature. An ad-hoc signature changes on every build, so each new build has
to be allowed again. A local certificate fixes that (one time, about a minute):

1. Keychain Access › menu **Keychain Access › Certificate Assistant › Create a Certificate…**
2. Name `LayoutFixer Local Signing`, Identity Type **Self-Signed Root**, Certificate Type **Code Signing** › Create.
3. In the **login** keychain, double-click the new certificate › **Trust** › Code Signing: **Always Trust**.
4. `./install.sh` (it prints `signed with LayoutFixer Local Signing`), then allow LayoutFixer one last time.

From then on every build keeps its permissions. Without the certificate, `build.sh` signs ad-hoc: remove LayoutFixer
from both lists and add it again after each install.

Needs macOS 13+ and the Xcode command line tools (`xcode-select --install`).
