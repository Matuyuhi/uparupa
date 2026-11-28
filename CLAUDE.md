# upaa

A homemade terminal emulator for macOS only. Written in Swift (AppKit) and Zig. Terminal emulation itself is left to libghostty-vt (stable C ABI). The goal is to be usable for daily work.

Progress, remaining work, and unconfirmed items are tracked in GitHub Issues (labels `feature`, `investigation`, `needs-mac`, `design`, and `M5` / `M6` for the milestone). Read the related issue before starting, link a PR to it with `Closes #N`, and open an issue for new remaining work or unconfirmed items instead of writing them in a file. The approved screen design (A3) is #22. The design notes up to 2026-11-27 are `docs/handoff.md` at commit e9c7a16 in the history.

## Decided

- Target is macOS 13 or later on Apple Silicon (arm64) only. No cross-platform support.
- The language is a mix of Swift and Zig. UI, IME, and Metal calls are in Swift. The rest of the core (PTY, libghostty-vt calls, building drawing data, glyph cache) is in Zig. Zig is 0.17.x.
- Zig was chosen because the user wants to write in it. If the mix costs noticeable performance or effort, say so plainly; the fallback is a core in C.
- Build uses SwiftPM and `scripts/build-app.sh` (`zig build` → `swift build` → `build/upaa.app`).
- The prebuilt libghostty-vt XCFramework is fetched by `scripts/fetch-ghostty-vt.sh`. It is not included in the repository.
- Use libghostty-vt 1.0.x. The full libghostty, including drawing and fonts (such as GhosttyKit), is not used because its API is not yet stable.
- Drawing uses Metal. Glyph generation uses CoreText.
- Display of Japanese text and IME are not postponed.

## Layout

- `core/src/` — Zig core. Functions exported to C (`export fn`) go only in `root.zig`. The implementation goes in folders by role.
  - `c/` headers imported with translate-c, `term/` terminal session (PTY, read thread, libghostty-vt), `font/` font and glyph atlas, `render/` building cell data for Metal.
- `Sources/CUpaaCore/` — C headers for the Zig functions. Edit them together with `root.zig`.
- Swift and Zig cross per frame or per chunk read from the PTY, never per cell. Zig writes the cell data straight into the Metal buffer Swift passes in. Callbacks from Zig to Swift are only for rare events (title, bell, redraw request).
- `Sources/UpaaKit/` — Swift implementation (`App/`, `Terminal/`, `Render/`). `Sources/upaa/` only launches the app.
- UI text is written in English in the Swift code, through `String(localized:)`. Its Japanese goes in `Resources/ja.lproj/Localizable.strings`, keyed by the English text; add both in the same change. `scripts/build-app.sh` copies `Resources/*.lproj` into the `.app`.
- `Resources/shell-integration/zsh/` — zsh startup files. A zsh login shell starts with `ZDOTDIR` pointing there (`Pty.spawn`); they put the user's `ZDOTDIR` back and mark the prompt with OSC 133, so libghostty-vt clears the prompt on a resize instead of rewrapping it.
- `Shaders/` — Metal shaders. `scripts/build-app.sh` compiles them and puts them into the `.app`. The layout of cell data must match in three places: `core/src/render/Cell.zig`, the C header `UpaaCell`, and the shader `Cell`.
- To check drawing, write one frame to a PNG with `build/upaa.app/Contents/MacOS/upaa --snapshot <png> [--input <string>]` and view it.
- Tests: `sh scripts/test.sh` (Zig tests, comparison of the screens in `tests/fixtures/*.vt` against the reference images in `tests/snapshots/`, lower and upper bounds on speed). When a drawing change is intended, replace the references with `UPDATE_SNAPSHOTS=1 sh scripts/test.sh`, and commit only after checking the images. GitHub Actions (`.github/workflows/test.yml`) calls the same script.
- `swift build` and tests that use a PTY (`zig build test`) do not run inside the Claude Code sandbox.

## Implementation approach

Do not proceed by just piling on code. Avoid increasing the amount of code itself.

- Before adding code, look for a way that needs no addition. First consider whether changing or removing existing code, or hooking into an existing mechanism, can solve the problem.
- Do not add launch options, public functions, or hooks only for checking or measuring. Verify with tests or a throwaway local script. If one must stay, state the reason and get confirmation before adding it.
- When a problem occurs, do not stack workarounds. Identify the cause and fix it at the source. If a workaround must go in before the cause is identified, consult first.
- Remove code that is no longer needed because the premise changed, in the same change.
- Reports of changes state how many lines were added and how many were removed.

## Pull requests and merging

- The title is in Japanese, and the description is short, plain English.
- Every push to a pull request that is not a draft gets a Claude review (`.github/workflows/review.yml`, guidelines in `.github/review.md`). It ends with a verdict and puts the label `ready-to-merge` or `needs-human` on the pull request.
- Claude merges its own pull request without asking when all of these hold: on the latest commit the `review` workflow finished and `test` passed, the label `ready-to-merge` was put there by the review workflow (never by hand), and the user has asked for nothing on it that is still open. This is the one exception to asking before publishing (see "Rules to follow"). Then it checks that `test` passes on `main`.
- Otherwise the user decides. Ask with the reasons from the verdict. Fix findings and push, so the review runs again, rather than asking about them.

## Version and release

- The version is written only in `.version` of `build.zig.zon`. Zig code, Swift (`upaa --version`, update check), and the `.app`'s `Info.plist` take it from there. Do not write the number anywhere else.
- For a release, run `.github/workflows/release.yml` by hand (`gh workflow run release.yml`). It reads the number from `build.zig.zon`, runs the tests, and creates the `v<number>` tag and the Release (zip and `SHA256SUMS`). Do not type the tag by hand. The release notes are written by Claude (`anthropics/claude-code-action`) from the commits since the previous tag (needs the `CLAUDE_CODE_OAUTH_TOKEN` repository secret; without it the release has only GitHub's generated notes). After the release it calls `.github/workflows/bump-version.yml`, which moves `main` to the next patch version. For a new minor or major version, run `gh workflow run bump-version.yml -f part=minor` (or `major`) before releasing.
- Install is via `install.sh` (`curl ... | sh`). It places `~/Applications/upaa.app` and `~/.local/bin/upaa`. The contents of the `upaa` command come from `scripts/upaa-launcher.sh`.
- The update check at startup is `Sources/UpaaKit/App/UpdateCheck.swift`. It queries GitHub once a day. It only notifies; it does not update.

## Rules to follow

- Function names and usage for libghostty-vt follow the header at tag `vt-1.0.2` (`include/ghostty/vt/`) and `example/c-vt-*`, which are authoritative (docs: https://lib.ghostty.org/vt/). Ghostling is pinned to a commit from before 1.0 and calls functions that do not exist in 1.0.2.
- In reports, separate confirmed facts from guesses. Do not write that something "works" if it was not run.
- For operations involving external downloads, publishing, deletion, or overwriting, show the target and impact and get the user's confirmation before doing them.
- Do not have the user enter credentials such as private keys or tokens.

## Status labels and waiting for CI

Each open pull request, and each open issue that is worked on without a pull request, has one `status:` label, so its state shows in the list without reading the thread. An open issue with none is not started.

- `status: in-progress`: being written or fixed.
- `status: wait-review`: waiting for CI or the Claude review.
- `status: wait-owner`: waiting for the user (a choice, a check on the Mac, or an OK to merge). The last comment says what.
- `status: blocked`: waiting on something else, such as another pull request. The last comment says what.

- While a pull request is open, the label is on it, not on its issue. Closed items need no change.
- Change the label in the same step that changes the state. Use `gh api repos/Matuyuhi/upaa/issues/<N>/labels` (POST to add, DELETE `.../labels/<name>` to remove); a tool that sets the whole list must keep the other labels.
- All open items by state, in one command:

  ```
  gh api --paginate 'repos/Matuyuhi/upaa/issues?state=open&per_page=100' --jq '.[] | "\([.labels[].name|select(startswith("status: "))][0] // "not started")\t#\(.number) \(if .pull_request then "PR" else "issue" end) \(.title)"' | sort
  ```

- After a push, wait for CI and the review in the same turn instead of ending it. The runs take a few seconds to appear; run the command again if it times out. Then check that each run's conclusion is `success`; a draft's review is `skipped`.

  ```
  sha=$(git rev-parse HEAD); sleep 30; while gh run list -c "$sha" --json status --jq '.[].status' | grep -qv completed; do sleep 20; done; gh run list -c "$sha"
  ```

  `gh pr checks <N> --watch` does the same on the Mac, but not in Claude Code cloud sessions, which have no GitHub GraphQL.
- If a run fails, read it (`gh run view <id> --log-failed`), fix the cause, push, and wait again. Ask the user only when the fix needs them.
