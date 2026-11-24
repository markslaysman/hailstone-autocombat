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

## Profile-first workflow (dev UI)

Open `/autocombatdev settings`. At the **top of the left sidebar**, above Spells and Abilities, the **Profile** dropdown selects which complete configuration is being edited. The **gear** beside it opens **Profile settings**. A **Save** button under the selector is available on every settings page.

- **Edit an existing profile:** choose it in the left dropdown, make changes on the usual settings pages, then click **Save**. Changes still auto-save after a short delay; Save forces an immediate write.
- **Copy any existing profile:** open the gear, enter a new profile name, choose its source in **Copy from**, then click **Copy existing as new**. The original is not modified; the new copy becomes active.
- **Create a blank profile:** enter a new name and click **Create blank**. Its settings start from AutoCombat defaults.
- **Switch profiles:** choosing one from the dropdown persists the previous edits, pauses AutoCombat DEV, clears combat state, and keeps it paused until you press Start.

Names are case-insensitive, 1–32 characters, using letters, digits, underscores or hyphens. Existing names cannot be overwritten by Copy/New. The original add-on and its settings remain untouched.

## Test commands

```text
/lua run autocombat_dev
/autocombatdev profile list
/autocombatdev profile savecurrent
/autocombatdev profile save hunter
/autocombatdev profile copy hunter_aoe hunter
/autocombatdev profile new clean_start
/autocombatdev profile load hunter
/autocombatdev profile load default
/autocombatdev off
/lua stop autocombat_dev
```

Profile changes do **not** change memorized spell gems. The profile switch pauses dev automation and does not resume combat automatically.

## Tests and release

Run `texlua tests/run.lua` or `lua5.5 tests/run.lua` from the repository root to test dev modules. The Hailstone UI and its permission behavior still require in-game verification.

**Do not use the repository's existing `tools/release.sh` for this dev branch**: it is targeted at the official AutoCombat packaging. Before upstream release, keep the generic Profile Manager changes in the upstream-ready feature branch, not this renamed copy.
