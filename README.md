# Layout Fixer

A small menu bar app for macOS that fixes text typed in the wrong keyboard layout (ABC/US ↔ Ukrainian),
then switches the layout for you: `ghbdsn` → `привіт`, `руддщ` → `hello`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/m-ilchuk/layout-fixer/main/get.sh | bash
```

It downloads the source, builds it on your Mac (it needs Apple's free command line tools and offers to install them),
puts **LayoutFixer** in `~/Applications` and starts it. Then:

1. Allow it in System Settings › Privacy & Security › **Accessibility**. It starts working within a few seconds.
2. Optional: menu bar item › **Open at login**.

To update, run the same command again. macOS sees each new build as a new app, so remove LayoutFixer from the
Accessibility list with **–** and add `~/Applications/LayoutFixer.app` again with **+**.

To uninstall, quit it from its menu, delete `~/Applications/LayoutFixer.app` and remove it from the Accessibility list.

Needs macOS 13 or newer, on Apple silicon or Intel.

## Use

| Keys | What it does |
|---|---|
| **Tap right ⌥** (alone) | Convert the **selected** text; with nothing selected, the last word you typed |
| ⌥Space | Retype the last word in the other layout and switch the layout |
| ⌥⇧Space | Convert the **selected** text; with nothing selected, the whole phrase since the last click / Enter / arrow key |
| same key again | Flip it back |

The menu also has **Fix automatically while typing (beta)**, off by default. When you finish a word with Space and it
only makes sense on the other layout (checked with the macOS spell checker, typos allowed), it retypes that word and
the words before it typed in the same wrong layout, then switches the layout: `рун умукщту рщц` → `hey everone how`.

## Privacy

Layout Fixer needs Accessibility because it reads the keys you press and types the fixed text for you. It keeps the
keys only in memory (at most 300, cleared on every click, Enter or app switch), never writes them anywhere and makes
no network connections. The whole app is the four files in `Sources/`.

## How it works

- It remembers the **keys** you pressed, not the characters. Fixing a word deletes it and types the same keys again on
  the other layout. The key maps come from macOS (`UCKeyTranslate`), so nothing is hard-coded and the result matches
  the layouts you have enabled (`'` → `є`, `s` → `і`, `]` → `ї`).
- For selected text, which has no key presses to replay, it reads the selection through Accessibility (or copies it
  with ⌘C where an app doesn't share it), works out the layout from the characters, pastes the converted text over
  it and restores your clipboard. Punctuation that is punctuation on both layouts stays as you see it.
- It flips between your two enabled keyboard layouts. Tested with ABC and Ukrainian-PC.
- Logs (counts only, never your text): `/usr/bin/log stream --info --predicate 'subsystem == "io.github.m-ilchuk.layoutfixer"'`

## Develop

```bash
./build.sh --test   # conversion tests against the layouts enabled on this Mac
./install.sh        # build (Apple silicon + Intel), copy to ~/Applications, start
```

### Keep permissions across rebuilds

macOS ties the permissions to the app's signature. An ad-hoc signature changes on every build, so each new build has
to be allowed again. A local certificate fixes that (one time, about a minute):

1. Keychain Access › menu **Keychain Access › Certificate Assistant › Create a Certificate…**
2. Name `LayoutFixer Local Signing`, Identity Type **Self-Signed Root**, Certificate Type **Code Signing** › Create.
3. In the **login** keychain, double-click the new certificate › **Trust** › Code Signing: **Always Trust**.
4. `./install.sh` (it prints `signed with LayoutFixer Local Signing`), then allow LayoutFixer one last time.

`build.sh` uses the certificate whenever it finds it, and signs ad-hoc otherwise.
