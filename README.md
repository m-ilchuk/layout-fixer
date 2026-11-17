# Layout Fixer

A small menu bar app for macOS that fixes text typed in the wrong keyboard layout, between English and your
language (Ukrainian, Polish, Greek, Bulgarian, Hebrew, German, …), then switches the layout for you:
`ghbdsn` → `привіт`, `руддщ` → `hello`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/m-ilchuk/layout-fixer/main/get.sh | bash
```

It downloads the source of the latest release, builds it on your Mac (it needs Apple's free command line tools and offers to install them),
puts **LayoutFixer** in `~/Applications`, starts it and prints the layouts it found, for example
`Switches ABC ↔ Ukrainian`. Then:

1. Allow it in System Settings › Privacy & Security › **Accessibility**. It starts working within a few seconds.
2. Optional: menu bar item › **Open at login**.

To update, use **Install version X.Y.Z** in its menu (it checks GitHub Releases once a day, or on **Check for
Updates…**; it restarts by itself), or run the same command again. To try the newest unreleased code, put
`LAYOUT_FIXER_REF=main` before `bash`. macOS sees each new build as a new app, so remove LayoutFixer from the Accessibility list
with **–** and add `~/Applications/LayoutFixer.app` again with **+**.

To uninstall, quit it from its menu, delete `~/Applications/LayoutFixer.app` and remove it from the Accessibility list.

Needs macOS 13 or newer, on Apple silicon or Intel.

## Use

**Select the text and tap the right ⌥ key** (on its own). It is converted to the other layout, stays selected, and
the keyboard layout switches with it. Tap again to convert it back exactly as it was.

Apps that don't share their selection with macOS (some browsers) get it copied and pasted instead; your clipboard
is put back afterwards.

After each fix a small badge such as `UK → EN` shows under the text cursor for a moment (menu › **Show a flash
when fixing** turns it off).

## Layouts

Layout Fixer uses the keyboard layouts you have turned on (System Settings › Keyboard › Text Input › Input Sources),
reading each layout's keys from macOS, so any language works without setup. Text typed on your language's layout
goes to English, and English goes to your language. With several languages turned on (say Ukrainian and Polish),
English goes to the one you used last, and text goes back from whichever layout can type it. The menu
shows the pair it uses now.

Fix-while-typing checks words with the macOS dictionaries (40+ languages, including uk, pl, bg, el, he, de, fr,
cs). For a language without one, it still fixes words that should be English; the hotkeys work for every language.

## Menu bar

The ⌨ icon in the menu bar holds the settings. macOS already shows the current layout, so you can hide the icon
(menu › **Hide menu bar icon**); open LayoutFixer again from Spotlight to bring it back. It shows ⚠ instead, even when
hidden, while Accessibility is not allowed.

The menu also has **Fix automatically while typing (beta)**, off by default. When you finish a word with Space and it
only makes sense on the other layout (checked with the macOS spell checker, typos allowed), it retypes that word and
the words before it typed in the same wrong layout, then switches the layout: `рун умукщту рщц` → `hey everone how`.

## Privacy

Layout Fixer needs Accessibility because it reads the keys you press and types the fixed text for you. It keeps the
keys only in memory (at most 300, cleared on every click, Enter or app switch) and never writes them anywhere. Its only
network call is the update check to GitHub (`api.github.com`), which sends only the version it was built from; turn it
off with menu › **Check for updates automatically**. The whole app is the seven files in `Sources/`.

## How it works

- It remembers the **keys** you pressed, not the characters. Fixing a word deletes it and types the same keys again on
  the other layout. The key maps come from macOS (`UCKeyTranslate`), so nothing is hard-coded and the result matches
  the layouts you have enabled (`'` → `є`, `s` → `і`, `]` → `ї`).
- For selected text, which has no key presses to replay, it reads the selection through Accessibility (or copies it
  with ⌘C where an app doesn't share it), works out the layout from the characters, pastes the converted text over
  it and restores your clipboard. Punctuation that is punctuation on both layouts stays as you see it.
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

### Release

Versions follow [semantic versioning](https://semver.org): **MAJOR** when something people rely on changes or goes
away (a hotkey, a setting), **MINOR** for new features, **PATCH** for fixes.

```bash
./release.sh 1.2.0
```

It checks that `main` is clean and pushed, runs the tests, sets the version in `Info.plist`, commits, tags `v1.2.0`,
pushes, and creates the GitHub Release with notes from the commits since the last one. Installed copies offer it
within a day, and the installer installs it from then on.
