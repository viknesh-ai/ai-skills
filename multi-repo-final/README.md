# Multi-repository support — where to put things

## Placement in the tributary repo

    tributary/
      .claude/
        agents/
          workspace-mapper.md               <- new agent (next to source-tracer.md etc.)
        skills/
          prepare-workspace/
            SKILL.md                        <- new skill (same layout as the existing skills folder)
      validate-workspace.sh                 <- new gate script, next to validate-lineage.sh
      artifacts/
        Liqor/                              <- setup artifacts, same place app-profile.md already lives
          workspace.json
          workspace-map.md
          codebase-map.md                   (3-line pointer)
          codebase-map-liqor-api.md         (one per repo, written by codebase-cartographer)
          codebase-map-liqor-database.md
          source-map.json                   (generated, then cleaned)
          source-map.pre-cleanup.json
          source-map-cleanup.md
          app-profile.md
      codebase/
        Liqor/                              <- codebase root; repos are its children
          liqor-api/
          liqor-database/
          liqor-workflows/
        _excluded/
          Liqor/                            <- retired / excluded folders moved here

Put `validate-workspace.sh` wherever `validate-lineage.sh` is in your repo. If the skills
folder uses `{name}-SKILL.md` naming instead of `{name}/SKILL.md`, follow that.

## Edits to existing files

`trace-variable-SKILL.md`, Step 0 "Known mapping" — one row:

    | Liqor | `codebase/Liqor/` | `socgen/liqor/liqor-flash` |

`trace-variable-SKILL.md`, Step 0, after `{OutputFolder}` is created — one line (recommended):

    If `artifacts/{AppName}/workspace.json` exists, copy it to `{OutputFolder}/workspace.snapshot.json`.

`trace-variable-sourceless-SKILL.md`, Step 0 discovery — one line:

    Skip any directory under `codebase/` whose application has a `workspace.json` in `artifacts/{App}/`; offer the parent instead.

Nothing else changes. Applications without `workspace.json` behave exactly as before.

## One thing to confirm in the live repo

The zip you shared has the trace-variable skill reading setup files from the codebase root;
your live repo keeps them in `artifacts/{App}/`. These files assume the live layout. If the
live `trace-variable` resolves `{SourceMap}` / `{AppProfile}` from somewhere else, change the
`{Artifacts}` definition at the top of `prepare-workspace/SKILL.md` to match — it is the only
place the artifacts folder is defined.

## Run

    /prepare-workspace Liqor codebase/Liqor/ socgen/liqor/liqor-flash
    /trace-variable RateType Liqor

## Gate script

Pure bash — grep, sed, awk only — same helpers, output style, and exit codes as
`validate-lineage.sh`. Writes `validate-map.txt` / `validate-cleanup.txt` /
`validate-workspace.txt` into the artifacts folder.

    bash validate-workspace.sh artifacts/Liqor map
    bash validate-workspace.sh artifacts/Liqor cleanup
    bash validate-workspace.sh artifacts/Liqor all

Verified against a test tree in the live layout (artifacts separate from codebase):
Gate M 25 PASS / 1 WARN / 0 FAIL on a correct workspace; 4 FAIL on a broken one
(disallowed kind, nested repo, retired entry pointing at a non-existent live repo,
missing cross-reference path); Gate C 5 FAIL on the map as the unchanged generator
writes it, 8 PASS / 0 FAIL after the cleanup pass.
