# Reviewing pull requests

How Claude reviews a pull request to upaa. `.github/workflows/review.yml` runs it on every push to a pull request that is not a draft. The project's rules are in `CLAUDE.md`; read it first.

Be strict. Most pull requests here are written by Claude and merged by Claude when this review says no human is needed, so this review is the last look before `main`. When in doubt, report it.

## What to look for

- Bugs: wrong behavior, crashes, races between the PTY read thread and the main thread, leaks, errors that are dropped.
- Broken rules from `CLAUDE.md`, above all:
  - Code added where changing, removing, or hooking into existing code would do, or code left behind after its premise changed.
  - Launch options, public functions, or hooks added only for checking or measuring.
  - A workaround stacked on a problem instead of a fix at its cause. Also a fix whose cause is only guessed ("probably", "seems", "might") with nothing in the pull request that confirms it, or a second or third attempt at the same symptom that changes the guess instead of finding the cause.
  - Swift and Zig crossing per cell instead of per frame or per chunk, an `export fn` outside `core/src/root.zig`, or `root.zig` changed without the header in `Sources/CUpaaCore/`.
  - The cell layout changed in only some of `core/src/render/Cell.zig`, `UpaaCell`, and the shader `Cell`.
  - A libghostty-vt function that is not in the `vt-1.0.2` headers.
  - The version number written anywhere other than `build.zig.zon`.
  - References in `tests/snapshots/` replaced without a drawing change that explains them.
  - UI text not written through `String(localized:)`, or an English string without its Japanese entry in `Resources/ja.lproj/Localizable.strings` in the same change. Text shown in the UI that comes from Zig counts too.
  - Remaining work written as a TODO in code or in a file instead of a GitHub Issue.
- Design. The approved screen design is issue #22 (`gh issue view 22`); where the M5 design was chosen over it, the pull request or its issue says so. Report a size, color, radius, spacing, font, or wording that differs from it without a reason in the description. Liquid Glass goes on the control layer only (buttons, tab panel, toolbars, bars floating over the terminal); glass inside glass is a finding.
- macOS behavior. Compare with what Terminal.app, Xcode, and other standard Mac apps do: keyboard shortcuts, menu items (and whether they are disabled when they do nothing), close and quit confirmations, drag and drop, focus, Escape and Return. Report a difference the description does not explain.
- Animation. Something that appears, disappears, moves, or is reordered on screen (tabs, panels, bars, sheets) should animate the way macOS does. A missing animation is a finding.
- Tests and CI pictures:
  - A change in the Zig core's behavior without a test in `zig build test` or a `tests/fixtures/*.vt` screen.
  - A change people can see without a picture of it: either a launch screenshot in `.github/workflows/test.yml` that shows it, or a line in the description saying what CI cannot photograph (menus, sheets, hover, drag, animation).
- The pull request itself:
  - The title is Japanese, and the description is short, plain English.
  - Claims in the description that the diff does not back: something said to work that was not run, wrong line counts, or a missing `Closes #N` (or `Part of #N` when the issue stays open on purpose).
  - `README.md` is in English and does not list languages the app supports. Pictures in it show the app, not the Settings window.

Skip style, naming taste, and formatting.

## Severity

Tag each finding with one of these:

- **重大**: a bug that loses data, crashes, breaks a feature that worked, or a broken rule above that must be fixed before merging.
- **要修正**: should be fixed in this pull request, but nothing breaks if it is not.
- **軽微**: worth knowing; fixing it can wait.

## Reviews after a push

When the pull request has earlier reviews from this workflow (`gh pr view --comments` shows them), review the whole pull request at its latest commit, but do not post a finding again that is already posted and not fixed. Say in the summary which earlier findings are fixed and which are still open. `git log` and `git diff` show what changed since the commit of the last review.

## The verdict

End the summary with exactly one line that starts with `判定:`, as the last line:

- `判定: マージ可` when nothing below applies.
- `判定: 人の判断が必要（<reasons, separated by 、>）` when any of these applies:
  - Something only a person on the Mac can confirm: how it looks beyond what the CI pictures show, animation, drag, hover, scrolling, typing with an input method, or how it feels to use.
  - A choice of design or behavior: two reasonable ways to do it, a difference from issue #22 or M5, or a new setting, shortcut, or default.
  - Repository settings, workflows under `.github/`, `CLAUDE.md`, releases, versions, install scripts, secrets, or tokens.
  - Deleting the user's files or settings, or a change that can lose data.
  - A finding tagged 重大, or a 要修正 finding still open.
  - Anything this review could not check.

The workflow reads this line and puts the label `ready-to-merge` or `needs-human` on the pull request. It adds `needs-human` by itself for some paths, whatever the line says.

## How to post

- One inline comment per finding, on its line, starting with its tag, saying what goes wrong and when.
- Then one summary as a review: each finding in a line with its tag, or "指摘なし", then a short list of things noticed outside the diff (a missing feature, something unnatural to use) as 気づいたこと, then the verdict line.
- Write in Japanese. Do not change any file.
