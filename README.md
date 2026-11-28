<p align="center">
  <img src="docs/icon.png" width="128" alt="">
</p>

<h1 align="center">upaa</h1>

<p align="center">A terminal emulator for macOS</p>

<p align="center">
  <a href="https://github.com/Matuyuhi/upaa/actions/workflows/test.yml"><img src="https://github.com/Matuyuhi/upaa/actions/workflows/test.yml/badge.svg" alt="test"></a>
</p>

The UI and rendering are written in Swift (AppKit, Metal), the core in Zig, and terminal emulation is handled by [libghostty-vt](https://lib.ghostty.org/vt/).

![upaa with tabs in the sidebar and a split pane](docs/images/light.png)

![upaa with a dark color scheme and the changes panel showing a diff](docs/images/dark.png)

## Requirements

- macOS 13 or later
- Apple Silicon (arm64)

## Status

Works today:

- Running a shell, keyboard input, window resizing
- 16-color, 256-color and 24-bit color, inverse and underline
- Japanese and other full-width text (two cells wide), and text committed from an input method
- Selecting text with the mouse (double-click for a word, triple-click for a line, Option-drag for a rectangle), Cmd-C and Cmd-A
- Pasting with Cmd-V, asking first when the text could run a command
- 10 MB of scrollback, scrolled with the wheel or trackpad
- Mouse input for programs that ask for it (vim with `mouse=a`, htop); hold Shift to select instead
- A config file for the font, colors and window size (see Configuration)
- Windows and tabs named after the title the program sets (Cmd-N, Cmd-T, Cmd-Shift-T to reopen a closed tab, Cmd-Shift-[ and Cmd-Shift-], Cmd-1 to Cmd-9); the tabs are a panel down the left side, or a row at the top (Cmd-B)
- A right panel with the changed files of the current shell's git repository and their diffs (Cmd-J)
- A links panel with the web addresses the current tab printed, GitHub and Notion first, to open with a click (Shift-Cmd-J)
- Split panes (Cmd-D to the right, Cmd-Shift-D below, Cmd-[ and Cmd-] to move, Cmd-W to close); a new pane or tab starts in the current shell's directory

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Matuyuhi/upaa/main/install.sh | sh
```

- Installs `~/Applications/upaa.app` and `~/.local/bin/upaa`. No administrator rights are needed.
- The download is verified against its SHA-256 checksum before it is unpacked.
- To install a specific version, set `UPAA_VERSION=v0.1.0`.

## Usage

```sh
upaa            # open the app
upaa update     # reinstall the latest release
upaa --version
```

On launch, upaa asks GitHub at most once a day whether a newer release exists. It only tells you; it never updates on its own. Set `UPAA_NO_UPDATE_CHECK=1` to turn the check off.

## Configuration

upaa reads `~/.config/upaa/config` (or `$XDG_CONFIG_HOME/upaa/config`) at launch. Each line is `key = value`; lines starting with `#` are comments (a `#` later in a line is part of the value). The keys and color syntax are Ghostty's, so these lines can be copied from a Ghostty config.

```
font-family = JetBrains Mono
font-size = 14
# window size in cells
window-width = 100
window-height = 30
foreground = #cdd6f4
background = #1e1e2e
# how much the background covers what is behind the window, 0 to 1 (default 0.8)
background-opacity = 0.8
# one of the 256 colors; repeat the line for others
palette = 1=#f38ba8
```

Colors are `#rrggbb`, `#rgb` or an X11 name. Without `foreground`, `background` and palette 2 to 5, the colors follow light and dark mode. A line that cannot be read keeps the default, and is shown at the bottom of the window and in Settings until the file is fixed. Changes take effect when the file is saved, except the window size, which is for new windows.

## Development

You need Xcode 27 (with the Metal Toolchain) and minisign. CI and releases build with the Zig that `scripts/fetch-zig.sh` fetches; use the same one.

```sh
sh scripts/fetch-ghostty-vt.sh   # download libghostty-vt (signature and SHA-256 are verified)
sh scripts/fetch-zig.sh          # download the pinned Zig into vendor/zig (signature and version are verified)
export PATH="$PWD/vendor/zig:$PATH"
sh scripts/build-app.sh          # build build/upaa.app
sh scripts/test.sh               # run all tests
```

| Path | Contents |
|---|---|
| `core/src/` | Zig core: PTY, calls into libghostty-vt, fonts and glyphs, building the data to draw |
| `Sources/UpaaKit/` | Swift: UI, keyboard input, Metal rendering |
| `Shaders/` | Metal shaders |
| `tests/` | Inputs and reference images for the screenshot tests |

The version lives only in `.version` in `build.zig.zon`. To release, run the `release` workflow in GitHub Actions; it creates the tag and the release, then bumps `main` to the next patch version. Run the `bump-version` workflow with `minor` or `major` to change that.

Project conventions are in `CLAUDE.md`. Progress and remaining work are tracked in [Issues](https://github.com/Matuyuhi/upaa/issues).

## License

MIT (`LICENSE`). Licenses of the bundled libghostty-vt and its dependencies are in `THIRD_PARTY_LICENSES.md`.
