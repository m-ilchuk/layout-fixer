# Changelog

What changed in each release, newest first. Versions follow [semantic versioning](https://semver.org).

Add what you change under **Unreleased** as you go. `./release.sh X.Y.Z` turns that section into the release's
heading and uses it as the GitHub release notes, which the app's update dialog shows.

## Unreleased

### Security
- Words whose fix you undid once or twice are kept only in memory: only the Exclusions list itself is written to
  Layout Fixer's settings. (In 0.3.0 they were saved for up to 30 days.)
- The app is built with macOS's hardened runtime: no other program can load code into it to use its Accessibility
  permission.
- Updates download the installer whole before running it (a cut-off download runs nothing) and fetch the release
  by its tag only, so no branch can stand in for it.
- Converting a selection marks the converted text so clipboard managers don't record it, and the clipboard is put
  back only if nothing else was copied in the meantime.
- Nothing is kept or fixed in password fields, or while macOS's secure input is on.
- A failed install leaves the installed app as it was; the update log no longer holds the release notes.

## 0.3.0 — 2026-11-21

### New
- **Statistics** in the window (General | Statistics at the top): words fixed while typing, converted with right ⌥,
  and automatic fixes you undid right after, for today, the last 7 days and since you started, plus how many of the
  automatic fixes you kept. Only counts are kept, never what you type. **Reset Statistics…** starts over.
- Undoing an automatic fix is understood: right ⌥ on the word just fixed, ⌘Z, or erasing it (⌫ or ⌥⌫) and typing
  the same keys again on the layout you meant. The word then stays as you typed it, and the next fix in the same
  line no longer takes it along.
- **Exclusions** in the window: words fix-while-typing leaves as you typed them. Undo the fix of the same word 3
  times (`csv` turning into `сім`) and it's added for good, with a short "won't fix again" under the cursor; add
  words yourself, or remove one to let it be fixed again. Tapping right ⌥ twice (undo, then back) doesn't count.
  The words stay on this Mac, in Layout Fixer's settings; one undone fewer than 3 times is forgotten after 30 days.

### Fixes
- Typing fast right after a fix no longer mixes your next keys into it: the fix is typed away from the keyboard
  handler, and keys you press meanwhile wait and follow it, in order. Long fixes no longer hold up typing on the
  whole Mac.
- When macOS pauses Layout Fixer's keyboard handler (it does when an app is slow), what it remembered is cleared, so
  the next fix can't erase the wrong characters. An app that doesn't answer can delay a fix by at most a quarter of
  a second, not six.
- Updates install exactly the release they offer, from that release's own code, never newer unreleased code. When
  GitHub can't say which release is latest, the installer stops with a message instead of building the newest code.

## 0.2.9 — 2026-11-18

### Fixes
- A comma or semicolon typed on its own stays as typed: after clicking behind a word and typing `, you`, the comma
  turned into `б` (`consistentб you`), since that key is `б` in Ukrainian. Punctuation with no letters is never
  read as a short word on the wrong layout.
- A word the English dictionary knows only as two words converts too: `цуирщщл` → `webhook` (macOS suggests
  `web hook`), and so do `hotfix` and `Datadog`.

## 0.2.8 — 2026-11-17

### Fixes
- Fix while typing works in Gmail and other web pages again: since 0.2.7 the word was left selected and unconverted
  there. Web pages (any browser, Slack and other Electron apps) get the fix as key presses again, as before; native
  apps keep the one-step replacement.

## 0.2.7 — 2026-11-17

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
