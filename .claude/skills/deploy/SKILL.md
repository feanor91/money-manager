---
name: deploy
description: >
  Ship the current state of the Money Manager Flutter app (D:\Repos\MoneyManager\App):
  verify it, commit and push to GitHub, build the web release, and mirror it to the
  user's NAS at \\Excelsior\web\mmex. Use this whenever the user asks to "deploy",
  "publish", "ship", "commit et pousse", "mets a jour le site", "copie le web sur le
  nas", or otherwise wants their code changes committed/pushed and the live web
  version on the NAS refreshed - even if they only mention one half of that (e.g.
  just "pousse le code" or just "mets a jour le NAS"), since in this project the two
  are normally done together. Do NOT use for Android APK builds/releases (that's
  handled entirely by the GitHub Actions pipeline after push, not by this skill).
---

# Deploy Money Manager

A fixed five-step release routine for this one repo. Run the steps in order and
stop at the first failure - don't skip ahead "to see if the rest still works".

## 0. Where things are

- Repo: `D:\Repos\MoneyManager\App`
- NAS web deploy target: `\\Excelsior\web\mmex`
- GitHub remote: `feanor91/money-manager`, branch `main`

## 1. Verify before touching git

```bash
cd /d/Repos/MoneyManager/App
flutter analyze
flutter test
```

If either fails, stop and report the failure - don't commit or push broken code.
Fix it first (or ask the user how they want to proceed) rather than pushing anyway.

## 2. Commit any pending changes

```bash
git status
```

If the working tree is clean, skip straight to step 3.

Otherwise stage everything relevant (`git add -A`, or specific files if some
changes clearly shouldn't ship together) and write a commit message in this
repo's existing style - Conventional Commits, e.g. `feat(categories): ...`,
`fix(recurrence): ...`, `ci: ...`. Look at `git log --oneline -10` if unsure
what "this repo's style" looks like right now. Summarize *what* changed and,
where it's not obvious from the diff alone, *why* - the same way the last few
commits on this branch do.

## 3. Push (rebase first - this matters)

The GitHub Actions release pipeline (`.github/workflows/release.yml`) commits
its own version-bump + changelog commits straight to `main` after every push
that isn't doc-only. That means `origin/main` frequently has commits the local
checkout doesn't - a plain `git push` gets rejected more often than not here.
Always do:

```bash
git fetch origin main
git rebase origin/main
git push origin main
```

If the rebase hits a real conflict (not just "commits ahead"), stop and show
the user what's conflicting rather than resolving it blindly - these bot
commits only ever touch `CHANGELOG.md`/`pubspec.yaml`, so a conflict there
usually means something unexpected happened upstream.

Once this push lands, the release pipeline runs on its own in the background:
build, test, version bump, changelog, GitHub release with web+APK artifacts.
This skill does not need to wait for it or duplicate any of it - the NAS
deploy below is a separate, local-only distribution channel for the web
build, on top of (not instead of) that automated release.

## 4. Build the web release

```bash
flutter build web --release
```

Output lands in `D:\Repos\MoneyManager\App\build\web`.

## 5. Mirror it to the NAS

```powershell
robocopy "D:\Repos\MoneyManager\App\build\web" "\\Excelsior\web\mmex" /MIR /NFL /NDL /NJH
```

`/MIR` deletes anything at the destination that's no longer in the fresh
build, so the NAS always matches exactly what was just built - don't drop
`/MIR` for a partial copy, stale old files left behind is exactly what it's
there to prevent.

**Robocopy's exit codes are a bitmask, not a pass/fail flag** - this trips
people up. `0` = nothing needed copying, `1` = files copied successfully,
`2`/`3` = extra files also deleted, all still success. Only `8` and above
mean a real failure. Check the "Total / Copié / Echec" summary in the output
for the actual file counts rather than trusting a raw non-zero exit code.

If `\\Excelsior\web\mmex` isn't reachable, say so plainly - don't retry
silently or fall back to some other path.

## 6. Report back

One short summary covering:

- What got committed (or "nothing to commit" if the tree was already clean)
- The push result (and that the release pipeline is now running in the
  background, if this was a real push)
- The NAS copy result (files copied / already up to date), from the robocopy
  summary, not just its exit code
