---
name: prepare-workspace
description: One-time setup for an application whose code spans several repositories placed side by side under one application root. Classifies and links the repositories, moves retired and excluded folders aside, builds per-repository codebase maps, generates and cleans the source map at the application root, and generates the app profile — so that /trace-variable runs with the application root as its codebase root and no other change.
---

# Prepare Workspace — Multi-Repository Setup Pipeline

Run once per application, and again whenever a repository is re-downloaded. When it
finishes, `/trace-variable {Variable} {AppName}` works with the repositories' parent
folder as `{CodebaseRoot}`: the three setup files it expects (`codebase-map.md`,
`source-map.json`, `app-profile.md`) are in `artifacts/{AppName}/` and already describe
every repository.

This skill spawns agents; it does not read code itself. The only actions it performs
directly are moving folders in Step 2 and running gates.

**Rule: do not silently continue past a failed gate.**

---

# Step 0 — Resolve inputs

Determine:

1. **Codebase root** — the folder whose children are the repositories
   (e.g. `codebase/Liqor/`). The user gives it, or list `codebase/*/` and ask which.
2. **Application name** — short name (e.g. `Liqor`). The artifacts folder is
   `artifacts/{AppName}/`; create it if missing.
3. **Org/project/service** — natural key prefix (e.g. `socgen/liqor/liqor-flash`).
4. **Source list (optional)** — explicit source names; otherwise the generator discovers them.
5. **Repository hints (optional)** — `{folder, kind, live}` overrides from the user.
6. **Rebuild (optional)** — if `workspace.json` exists, the default keeps hand-set fields
   and refreshes computed ones; `--rebuild` starts from scratch.

Resolved variables:

- `{CodebaseRoot}` — e.g. `codebase/Liqor/`
- `{Artifacts}` — `artifacts/{AppName}/`
- `{AppName}` — e.g. `Liqor`
- `{OrgProjectService}` — e.g. `socgen/liqor/liqor-flash`
- `{Excluded}` — `codebase/_excluded/{AppName}/`
- `{WorkspaceMap}` — `{Artifacts}/workspace-map.md`
- `{SourceMap}` — `{Artifacts}/source-map.json`

Confirm `{CodebaseRoot}` exists and has at least one child directory.

---

# Step 1 — Map the workspace

Spawn one `workspace-mapper` agent (`subagent_type: "workspace-mapper"`).

The agent receives:

- Pass: `map`
- Codebase root: `{CodebaseRoot}`
- Artifacts folder: `{Artifacts}`
- Application name: `{AppName}`
- Org/project/service: `{OrgProjectService}`
- Repository hints: the user's list, inline, if any
- Existing workspace.json: `{Artifacts}/workspace.json` if it exists and `--rebuild` was not given
- Instruction: write `{Artifacts}/workspace.json` and `{WorkspaceMap}`, then run
  `bash validate-workspace.sh {Artifacts} map` and report the result

## Gate M — workspace.json

```text
bash validate-workspace.sh {Artifacts} map
```

Read `{Artifacts}/validate-map.txt` and present it.

- **PASS / WARN:** continue. Show every WARN to the user — revision gaps, unresolved
  duplicates, unknown kinds are decisions for a person, not errors.
- **FAIL:** stop and report. The layout is not repositories-as-children, or the mapper
  did not finish writing.

---

# Step 2 — Move retired and excluded folders aside

Read `{Artifacts}/workspace.json`. Using `mkdir -p` and `mv` only — never `rm`:

- For each `wrappers[]` entry: move `inner` up to `{CodebaseRoot}/{name}` and remove the
  now-empty `outer`.
- For each `retired[]` entry: move `{CodebaseRoot}/{folder}` to `{Excluded}/{folder}`.
- For each `duplicates[]` entry: the side that is not `live` is already in `retired`;
  nothing extra.
- For each `excluded[]` glob: move each matching top-level folder to `{Excluded}/`.
- `vendored[]` entries stay where they are — they are inside a live repository; the
  cleanup pass keeps them out of the source map.

If any `repositories[].folder` changed because a wrapper was flattened, re-run Step 1
so `workspace.json` reflects the final layout. Print what was moved; if nothing, say so.

---

# Step 3 — Per-repository codebase maps (batched, 6 at a time)

For every entry in `repositories` with `live: true` and `kind` not `docs`, spawn one
`codebase-cartographer` agent (`subagent_type: "codebase-cartographer"`). Launch up to 6
in a single message so they run concurrently; wait for the batch; repeat.

Each agent receives:

- A target codebase: `{CodebaseRoot}/{folder}`
- Depth level: `standard` (`quick` for `tests` and `reports`)
- Instruction: write the map to `{Artifacts}/codebase-map-{folder}.md`

Report progress per batch: `Batch {B}/{Total} complete — {N}/{Repos} maps written`.

After the last batch, confirm each `{Artifacts}/codebase-map-{folder}.md` exists. A missing
one is a WARN; continue.

---

# Step 4 — Source map at the application root

Spawn one `source-map-generator` agent (`subagent_type: "source-map-generator"`).

The agent receives:

- Codebase root: `{CodebaseRoot}`
- Application name: `{AppName}`
- Source list: the user's list, inline, if any
- Codebase map path: `{WorkspaceMap}`
- Instruction: write `{SourceMap}`

Because its root is the parent of the repositories, every path the generator writes
begins with a repository folder name. `{WorkspaceMap}` tells it which folder holds DI registrations,
procedures, DDL and workflows before its first search.

---

# Step 5 — Clean the source map

Spawn one `workspace-mapper` agent (`subagent_type: "workspace-mapper"`).

The agent receives:

- Pass: `cleanup`
- Codebase root: `{CodebaseRoot}`
- Artifacts folder: `{Artifacts}`
- Application name: `{AppName}`
- Org/project/service: `{OrgProjectService}`
- Source map path: `{SourceMap}`
- Per-repository cap: `20` unless the user set another
- Instruction: correct `{SourceMap}` in place, write `{Artifacts}/source-map.pre-cleanup.json`
  and `{Artifacts}/source-map-cleanup.md`, then run `bash validate-workspace.sh {Artifacts} cleanup`
  and report the result

## Gate C — cleaned source-map.json

```text
bash validate-workspace.sh {Artifacts} cleanup
```

Read `{Artifacts}/validate-cleanup.txt` and present it with the coverage table from
`{Artifacts}/source-map-cleanup.md`.

- **PASS:** continue.
- **WARN:** continue, and list every `GAP` (source × repository) to the user — each one
  is a place a tracer would otherwise report "external — outside this codebase" for a
  file in the workspace. The cleanup has injected every cross-reference it could; the
  remaining gaps point at `cross_references.unresolvable` in `workspace.json`.
- **FAIL:** stop. The map does not parse, a path points at a retired or excluded folder,
  or the backup is missing.

---

# Step 6 — Application profile

Spawn one `application-profiler` agent (`subagent_type: "application-profiler"`).

The agent receives:

- Codebase root: `{CodebaseRoot}`
- Application name: `{AppName}`
- Org/project/service: `{OrgProjectService}`
- Source map path: `{SourceMap}`
- Codebase map path: `{WorkspaceMap}`
- Instruction: write `{Artifacts}/app-profile.md`

Confirm `app-profile.md` was written and that its DI, Global Pre-conditions and Output
Destinations sections cite paths in more than one repository where `{WorkspaceMap}` says
they should. If every path is in one repository while the workspace has a `database`
repository, report a WARN.

---

# Step 7 — Register and finish

1. If `{Artifacts}/codebase-map.md` does not exist, write a pointer:

   ```markdown
   # {AppName} — see workspace-map.md
   This application spans several repositories. The workspace map is at `workspace-map.md`;
   per-repository maps are at `codebase-map-{folder}.md`.
   ```

   `/trace-variable` checks for `codebase-map.md` at the root and passes it to agents as
   orientation; the pointer keeps that check satisfied and sends them to the real map.

2. State the one edit `/trace-variable` needs, verbatim:

   > In `trace-variable-SKILL.md` Step 0 "Known mapping", set the row for `{AppName}` to
   > `| {AppName} | {CodebaseRoot} | {OrgProjectService} |`.

   And the recommended second line:

   > In Step 0, after `{OutputFolder}` is created: "If `{Artifacts}/workspace.json`
   > exists, copy it to `{OutputFolder}/workspace.snapshot.json`."

3. Print the summary:

   ```text
   Workspace ready: {CodebaseRoot}  (artifacts in {Artifacts})
     Repositories: {N} live, {M} retired, {K} excluded
     Moved aside: {list or none}
     Setup files: workspace.json, workspace-map.md, source-map.json (cleaned), app-profile.md
     Coverage gaps for a person: {count}  (source-map-cleanup.md)
     Notices: {count}  (workspace.json → notices)
   Next: /trace-variable {Variable} {AppName}
   ```

---

# Important Notes

- **Existing agents run unchanged.** `codebase-cartographer`, `source-map-generator` and
  `application-profiler` receive the inputs they already accept; the two that take an
  optional codebase map path receive `{WorkspaceMap}` in it.
- **`/trace-variable` needs the one mapping row.** Stages 1–6 and gates 1–6 do not
  change; the repository name is the first segment of every path.
- **Sub-agents cannot spawn sub-agents.** The per-repository fan-out in Step 3 is why
  this skill exists as the orchestrator.
- **Batches of 6**, each in a single message, wait, then the next — the same pattern as
  the trace pipeline.
- **Every agent prompt is self-contained.** Copy the values in; do not point an agent at
  this skill for context.
- **Re-running** after a repository is re-downloaded: run this skill again. Hand-set
  `kind`, `live`, `retired`, `excluded` and `holds` survive; revisions, cross-references,
  the source map and the profile are rebuilt. Existing `lineage-traces/` output is untouched.
- **Absent `workspace.json` in the artifacts folder means single-repository behaviour.** An application that has
  not been through this skill is handled by `/trace-variable` exactly as today.
