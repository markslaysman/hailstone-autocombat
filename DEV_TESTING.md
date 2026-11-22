# AutoCombat DEV — side-by-side Hailstone test branch

This branch is **for local testing only**. The upstream-ready feature remains in `feature/named-combat-profiles`, retaining the normal `autocombat` name.

## Installing alongside working AutoCombat

1. Back up `scripts/autocombat/` and `scripts/config/autocombat/`; do not delete or replace either.
2. Download this branch as a ZIP. Extract and copy **only** its `autocombat_dev` folder into your Hailstone `scripts/` folder.
3. Keep the original add-on installed. The dev build is a separate manually installed script, not an update to the managed original.
4. Do **not** add `autocombat_dev` to autoload or Autorun while testing. Start it manually using `/lua run autocombat_dev`.
5. Open settings using `/autocombatdev settings` and inspect the **Auto Combat DEV** UI; test `/autocombatdev profile list`.
6. When testing combat, make sure the other version is stopped. You can stop the dev build using `/lua stop autocombat_dev`, and start the original using `/lua run autocombat`.

## Isolated identities

| Component | Original | Development |
|---|---|---|
| Script folder | `scripts/autocombat/` | `scripts/autocombat_dev/` |
| Script command | `/lua run autocombat` | `/lua run autocombat_dev` |
| Slash controls | `/autocombat` | `/autocombatdev` |
| Menu/window | Auto Combat | Auto Combat DEV |
| UI | `ui/modern/autocombat.lua` | `ui/modern/autocombat_dev.lua` |
| Settings prefix | `autocombat/<server>_<character>.lua` | `autocombat_dev/<server>_<character>.lua` |

The dev copy's Lua files have distinct contents/hashes so they do not inherit permission ceilings assigned to identical files from a separately managed add-on. **This does not override server policy**: Hailstone still applies the server's permission rules.

## Test commands

```text
/lua run autocombat_dev
/autocombatdev profile list
/autocombatdev profile save hunter
/autocombatdev profile load hunter
/autocombatdev profile load default
/autocombatdev off
/lua stop autocombat_dev
```

Profile changes do **not** change memorized spell gems. The profile switch pauses dev automation and does not resume combat automatically.

## Tests and release

Run `texlua tests/run.lua` or `lua5.5 tests/run.lua` from the repository root to test dev modules. The Hailstone UI and its permission behavior still require in-game verification.

**Do not use the repository's existing `tools/release.sh` for this dev branch**: it is targeted at the official AutoCombat packaging. Before upstream release, keep the generic Profile Manager changes in the upstream-ready feature branch, not this renamed copy.
