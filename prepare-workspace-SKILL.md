---
name: prepare-workspace
description: One-time setup for an application whose code sits in several repositories placed side by side under one codebase root. Classifies the repositories, resolves the references that cross between them (stored procedures, tables, file imports, HTTP APIs, message topics, project references), builds the per-repository codebase maps, then generates the source map and app profile with those cross-references injected — so /trace-variable runs unchanged.
---

# Prepare Workspace — Multi-Repository Setup

Run once per application, and again whenever a repository is re-downloaded. When it
finishes, `/trace-variable {Variable} {AppName}` works with no change: the setup files it
expects are in the artifacts folder and already describe every repository.

This skill spawns agents; it does not read code itself. The only thing it does directly is
run the gates.

**Rule: do not silently continue past a failed gate.**

---

# Step 0 — Resolve inputs

Determine:

1. **Codebase root** — the folder whose children are the repositories
   (e.g. `codebase/Application/`). The user gives it, or list `codebase/*/` and ask.
2. **Application name** — short name (e.g. `Liqor`). The artifacts folder is
   `artifacts/{AppName}/`; create it if missing.
3. **Org/project/service** — natural key prefix (e.g. `socgen/liqor/liqor-flash`).
4. **Source list (optional)** — explicit source names; otherwise the generator discovers them.
5. **Repository hints (optional)** — `{folder, kind}` overrides from the user.

Resolved variables:

- `{CodebaseRoot}` — e.g. `codebase/Application/`
- `{Artifacts}` — `artifacts/{AppName}/`
- `{AppName}`, `{OrgProjectService}`
- `{WorkspaceMap}` — `{Artifacts}/workspace-map.md`
- `{SourceMap}` — `{Artifacts}/source-map.json`

Confirm `{CodebaseRoot}` exists and has at least one child directory. If it has exactly
one, say so — a single-repository application does not need this skill.

---

# Step 1 — Map the workspace

Spawn one `workspace-mapper` agent (`subagent_type: "workspace-mapper"`).

The agent gets:

- Pass: `map`
- Codebase root: `{CodebaseRoot}`
- Artifacts folder: `{Artifacts}`
- Application name: `{AppName}`
- Org/project/service: `{OrgProjectService}`
- Repository hints: the user's list, inline, if any
- Instruction: write `{Artifacts}/workspace.json` and `{WorkspaceMap}`, then run
  `bash validate-workspace.sh {Artifacts} map` and report the result

## Gate M — workspace.json

```text
bash validate-workspace.sh {Artifacts} map
```

Read `{Artifacts}/validate-map.txt` and present it.

- **PASS / WARN:** continue. Show every WARN — an unresolvable reference or an unknown
  repository kind is a decision for a person, not an error.
- **FAIL:** stop and report. Either the layout is not repositories-as-children, or a
  declared folder or a cross-reference path does not exist on disk.

---

# Step 2 — Per-repository codebase maps (batched, 6 at a time)

For every repository in `workspace.json` whose `kind` is not `docs`, spawn one
`codebase-cartographer` agent (`subagent_type: "codebase-cartographer"`). Launch up to 6 in
a single message so they run concurrently; wait for the batch; repeat.

Each agent gets:

- A target codebase: `{CodebaseRoot}/{folder}`
- Depth level: `standard` (`quick` for `tests` and `reports`)
- Instruction: write the map to `{Artifacts}/codebase-map-{folder}.md`

Report progress per batch: `Batch {B}/{Total} — {N}/{Repos} maps written`.

After the last batch, confirm each `{Artifacts}/codebase-map-{folder}.md` exists. A missing
one is a WARN; continue.

---

# Step 3 — Source map at the codebase root

Spawn one `source-map-generator` agent (`subagent_type: "source-map-generator"`).

The agent gets:

- Codebase root: `{CodebaseRoot}`
- Application name: `{AppName}`
- Source list: the user's list, inline, if any
- Codebase map path: `{WorkspaceMap}`
- Instruction: write `{SourceMap}`

Because its root is the parent of the repositories, every path it writes begins with a
repository folder name. `{WorkspaceMap}` tells it which folder holds DI registrations,
procedures, DDL, endpoints and workflows before its first search.

---

# Step 4 — Inject the cross-references

Spawn one `workspace-mapper` agent (`subagent_type: "workspace-mapper"`).

The agent gets:

- Pass: `link`
- Codebase root: `{CodebaseRoot}`
- Artifacts folder: `{Artifacts}`
- Application name: `{AppName}`
- Org/project/service: `{OrgProjectService}`
- Source map path: `{SourceMap}`
- Instruction: inject the cross-references into `{SourceMap}` in place, write
  `{Artifacts}/source-map.pre-link.json` and `{Artifacts}/source-map-links.md`, then run
  `bash validate-workspace.sh {Artifacts} link` and report the result

## Gate L — linked source-map.json

```text
bash validate-workspace.sh {Artifacts} link
```

Read `{Artifacts}/validate-link.txt` and present it with the injection summary from
`{Artifacts}/source-map-links.md`.

- **PASS:** continue.
- **WARN:** continue, and show the user every unresolvable reference carried through. Each
  one is a place a tracer will still report an external boundary — sometimes correctly
  (the system really is outside the codebase), sometimes because a name is assembled at
  runtime and someone should read that call site.
- **FAIL:** stop. Either the map does not parse, a referenced definition was not linked, or
  the backup is missing.

---

# Step 5 — Application profile

Spawn one `application-profiler` agent (`subagent_type: "application-profiler"`).

The agent gets:

- Codebase root: `{CodebaseRoot}`
- Application name: `{AppName}`
- Org/project/service: `{OrgProjectService}`
- Source map path: `{SourceMap}`
- Codebase map path: `{WorkspaceMap}`
- Instruction: write `{Artifacts}/app-profile.md`

Confirm it was written, and that its DI, pre-conditions and output-destination sections
cite paths in more than one repository where `{WorkspaceMap}` says they should. If every
path is in one repository while the workspace has a `sql-scripts` repository, report a WARN
— the profiler may not have used the map.

---

# Step 6 — Register and finish

1. If `{Artifacts}/codebase-map.md` does not exist, write a pointer:

   ```markdown
   # {AppName} — see workspace-map.md
   This application spans several repositories. The workspace map is at `workspace-map.md`;
   per-repository maps are at `codebase-map-{folder}.md`.
   ```

2. Confirm the lookup table in `trace-variable` points at `{CodebaseRoot}` for
   `{AppName}`. If the repositories were placed inside the folder the table already names,
   no edit is needed — say so. If not, print the row the user should set:

   > `| {AppName} | {CodebaseRoot} | {OrgProjectService} |`

3. Print the summary:

   ```text
   Workspace ready: {CodebaseRoot}   (artifacts in {Artifacts})
     Repositories:  {N}
     Cross-references: {P} procedures, {T} tables, {A} API routes, {M} topics, {F} imports
     Unresolvable:  {U}   (see workspace.json → cross_references.unresolvable)
   Next: /trace-variable {Variable} {AppName}
   ```

---

# Important Notes

- **Existing agents run unchanged.** `codebase-cartographer`, `source-map-generator` and
  `application-profiler` get the inputs they already accept; the two that take an optional
  codebase map path get `{WorkspaceMap}` in it.
- **`/trace-variable` is unchanged.** Stages 1–6 and gates 1–6 never learn the word
  "repository" — it is simply the first segment of every path.
- **Sub-agents cannot spawn sub-agents.** The per-repository fan-out in Step 2 is why this
  skill exists as the orchestrator, and why it is not part of `trace-variable`.
- **Batches of 6**, each in a single message, wait, then the next — the same pattern as the
  trace pipeline.
- **Each agent prompt is self-contained.** Copy the values in; do not point an agent at
  this skill for context.
- **Re-running** after a repository is re-downloaded: run this skill again. Everything is
  rebuilt from what is on disk. Existing `lineage-traces/` output is untouched.
- **An application with one repository does not need this skill.** Run the three setup
  agents as before.
