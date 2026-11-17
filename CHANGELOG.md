# Changelog

What changed in each release, newest first. Versions follow [semantic versioning](https://semver.org).

Add what you change under **Unreleased** as you go. `./release.sh X.Y.Z` turns that section into the release's
heading and uses it as the GitHub release notes, which the app's update dialog shows.

## Unreleased

### Fixes
- Fix while typing checks the screen before fixing a word: right after you switch the layout, macOS can still report
  the old one for a few keys, so a word was recorded half on each layout and left alone ("sometimes works,
  sometimes not"). It now reads the text before the cursor (in apps that share it) and goes by what's shown; in
  apps that don't, a word on two layouts goes by its last key.
- When the screen doesn't show the keys you typed (an app closed a bracket, made a quote curly or autocorrected),
  the word is left alone instead of erasing the wrong characters.
- A short word typed right after you switch the layout is fixed too (`як справи oj робиш` → `що робиш`): when
  macOS reports a switch late, the keys typed just before it are read again on the new layout. `що` and a few
  other short Ukrainian words were missing from its list.
- Fixing a word no longer leaves stray letters behind (`ghпройшла`, `jо десятій`): apps could drop some of the
  quick backspaces. Where the app allows it, the word is now replaced in one step through Accessibility and read
  back; elsewhere the keystrokes are slower.
- A word that's a near miss in both languages stays as typed: `тікет` (one letter from `пікет`) no longer turns into
  `nsrtn` because macOS's English spell checker offers `nsrtf` for it.
- `Хмм...` stays as typed instead of turning into `{vv///`: a word that would start or end with a bracket or a
  slash on the other layout isn't a word there.
- **Export Debug Log…** keeps the whole day: Layout Fixer's log lines are now kept on disk by macOS, not only
  briefly in memory.

## 0.2.6 — 2026-11-17

### Fixes
- Fix while typing no longer trusts the character inside the key event to tell the layout: right after it switched
  the layout itself, that character could stay on the old layout for whole words, so `ghjqikf` after `Stripe`, or the
  first word of a line, could be left as typed even when typed slowly.
- Short words at the start of a line are fixed along with the next word when they're only a word on the other layout:
  `Z просто` → `Я просто`, `Ш фь just` → `I am just`, `Nb зробив` → `Ти зробив`. Real short words stay
  (`синхронізацію з Constant`).
- Fix while typing no longer changes correct words when it fixes the one after them: an English word with a comma
  (`staging,`), a name no dictionary knows (`Jira`), or a word it fixed a moment before (`для` turning into `lkz`).
- Short words in a sentence mostly in the other language are fixed too: `login yf mobile` → `login на mobile`,
  `export e CSV` → `export у CSV`. In an English message, `db` or `f` stays.
- Checked against about 100 everyday sentences in Ukrainian, English and mixed, typed with and without switching.

## 0.2.5 — 2026-11-17

### Fixes
- Fix while typing no longer misses words right after it switched the layout itself (for example `ghjqikf` after
  `Stripe`, which worked only some of the time).

### Faster updates
- Builds only for your Mac's chip and reuses the compiler's cache: updates take seconds instead of about a minute.

## 0.2.4 — 2026-11-17

### Fixes
- Fix while typing could believe the wrong keyboard layout was on (for example Ukrainian while ABC was), and then
  leave words like `];fr` and `syntuhfwsz` as typed. It now checks the layout on every key.
- If it ever disagrees with macOS about the layout, the debug log says so.

## 0.2.3 — 2026-11-17

### Fixes
- Fix while typing converts words that start or end with letter keys: `];fr` → їжак, `` `fyre `` → ґанку.
- Short words like `з` stay as typed when only the word after them is fixed (no more "синхронізацію p Constant").

### New
- **Export Debug Log…** in the window and the right-click menu: when a word doesn't convert, the log says why. It
  never contains your text.
- Updates show their progress in the window.

## 0.2.2 — 2026-11-17

### Updates keep the Accessibility permission
- From this version on, updates keep Layout Fixer allowed in Accessibility: no more dialog after each update.
- After installing this one, allow it a last time: remove Layout Fixer from Accessibility with –, then open it and
  allow it when asked.

## 0.2.1 — 2026-11-17

### Fixes
- Punctuation converts by key, like letters: `руддщ,` becomes `hello?` (that key types `?` in English), and back.
- Characters typed with ⌥ convert too (`ы` ↔ `ß`, `«` and more).
- Fix while typing handles punctuation keys: `k.,k.` becomes `люблю`.
- The update dialog shows the release notes formatted, in a box that scrolls.

## 0.2.0 — 2026-11-17

### New
- Settings window: click the keyboard icon in the menu bar, or open Layout Fixer from Spotlight. It shows whether
  Layout Fixer is allowed in Accessibility, how to use it, and every setting. Right-click the icon for a short menu.
- New name and icon: LayoutFixer is now Layout Fixer.
- Faster install, with a progress line.

### Updating from 0.1.0
- Allow it again in Accessibility (remove the old LayoutFixer, add Layout Fixer), and turn Open at login on again if
  you used it.

## 0.1.0 — 2026-11-17

### Changed
- Everything is on the right ⌥ key (tap it on its own): text selected is converted and stays selected, tap again to
  put back exactly what was there; with nothing selected, the last word you typed is converted.
- **Breaking:** the ⌥Space and ⌥⇧Space shortcuts are gone, so ⌥Space works normally in your apps again.

### Fixes
- Quick repeated taps no longer paste the text twice in apps that don't share their selection.
- With nothing selected, a tap no longer copies the whole line in code editors.

## 0.0.1 — 2026-11-17

First release.
- Fixes text typed in the wrong keyboard layout and switches the layout, between English and your language.
- Fix while typing (optional), a flash after each fix, a small menu bar icon that can be hidden.
- One-line installer that builds on your Mac; update check against GitHub releases.
