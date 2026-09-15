---
name: pr-review
description: Reviews a GitHub pull request end to end - fetches its metadata and line-numbered diff, judges the change against its stated intent and the codebase's structure, produces a severity-ranked review in chat, and posts the findings back to the pull request as line-anchored comments a developer can resolve. Use when the user mentions reviewing a PR, gives a PR number or link, asks what is wrong with a change, asks for a second pair of eyes on a branch, or asks to leave review comments on GitHub. Works with any repository, any GitHub host, and any programming language.
allowed-tools: Bash, Read, Write, Grep
---

# PR Review

Reviews a pull request across three axes — does it do what was asked, is it built in the right place, and is the code correct — then posts the findings to the pull request as a `COMMENT` review.

This workflow writes review comments only. It does not modify source files, create commits, or push branches.

Nothing about a particular company, host or repository belongs in this file. The target lives in `config.json` and every command reads it from there. When the user names a different repository, pass it as a flag for that run rather than editing anything.

## Files

```text
.github/skills/pr-review/
├── SKILL.md          this file
├── config.json       the GitHub host and repository to review
└── pr-review.sh      fetch and post
```

Run the script from the skill folder or give its full path. It finds `config.json` beside itself, at `--config <file>`, or at `$PR_REVIEW_CONFIG`.

## Configure once

```json
{
  "github": {
    "host": "sgithub.fr.world.socgen",
    "repo": "<owner>/<repo>"
  }
}
```

`host` ships pre-set. `repo` is the owner and name from the URL path, not the URL. The script refuses to run while `repo` is still the placeholder. The environment needs the GitHub CLI authenticated against that host, and `jq` on the PATH. Optional tuning keys are listed near the end; none is required.

## Step 1 — Identify the pull request

`--pr` accepts a bare number, a `#`-prefixed number, or a full pull request URL. A URL carries its own host and repository and overrides the config for that run. A repository web link, an HTTPS clone URL and an SSH remote are all valid `--repo` values. When nothing identifies a pull request, ask for one.

When the PR is a draft, say so and ask whether to continue before spending a review on work in progress.

## Step 2 — Fetch

```bash
pr-review.sh fetch --pr <NUMBER_OR_URL>
```

One JSON document returns on stdout: title, description, author, branches, head SHA, changed files with add and delete counts, labels, CI status, existing reviews, and the diff with generated and vendored files already removed.

The diff is annotated. Read the line numbers rather than computing them. Every commentable line carries its own line number in the new file:

```text
diff --git a/src/limiter.ts b/src/limiter.ts
@@ -12,7 +15,9 @@
     15 |   const bucket = buckets.get(key);
+    16 |   bucket.tokens -= 1;
-       |   bucket.tokens = bucket.tokens - 1;
     17 |   return bucket;
```

A line beginning `+` was added and a line beginning with a space is unchanged context; both are commentable, and the number shown is the value to use as `line`. A line beginning `-` was removed, carries no number, and takes a comment only with `side: "LEFT"`. The `@@` header is there for orientation — the number you need is already on the line.

Check `diff.truncated` before reviewing. When `true`, the diff was cut at `diff.maxLines` and the tail went unread: state that plainly rather than implying full coverage, and offer to re-run with a higher `--max-diff-lines`. Files under `excludedFiles` were skipped deliberately and sit outside the review.

## Step 3 — Judge intent and design

Do this before reading a single line closely. It is the part a linter cannot do, and skipping it produces a review that is correct about everything except whether the change should exist.

**Intent.** Read the PR title and description as a statement of what the author set out to do. Then ask whether the diff delivers it: does every stated requirement appear somewhere in the change, and does the change carry work nobody asked for. A stated behaviour with no corresponding code, or a substantial addition the description never mentions, is worth raising even when every line of it is well written. When the description is empty or says nothing useful, say so once and review the remaining two axes.

**Design.** The file list and the paths themselves carry most of the signal here. Work through these five questions:

1. Is this the simplest shape that delivers the intent, or is there scaffolding for a requirement nobody has yet?
2. Does each piece sit in the right layer — business rules in the service rather than the controller, the entity or the view?
3. Does the change rebuild something the repository already has, judging by the surrounding paths and names?
4. Does it create coupling that will be expensive to unpick, such as a new dependency between modules that should not know about each other?
5. Is a new abstraction earned by more than one caller, or is it an interface with a single implementation?

Design findings usually have no single line to attach to, so they belong in the summary rather than as inline comments. Cap them at **MAJOR** unless the design choice breaks a published contract, because an architecture disagreement should not block a merge the way a security hole does.

Hold to what the fetch actually shows. When judging a design concern would need a file the diff does not contain, state it as a question for the author rather than a defect.

## Step 4 — Review the changed lines

Work through the categories in order. Finishing the list before writing anything keeps the review from becoming a list of whatever was noticed first.

1. **Correctness.** Off-by-one errors, inverted conditions, unintended operator precedence, comparisons that misbehave on empty, zero, null or unicode input, boundaries at each end of a range or collection.
2. **Failure paths.** Errors caught and discarded, failures leaving state half-written, retries without a ceiling, partial writes never rolled back.
3. **Resources.** Anything opened, locked, allocated or subscribed that is released on the happy path but not the error path.
4. **Concurrency.** Shared mutable state reached from more than one thread, task or request; check-then-act sequences that are not atomic; ordering the runtime does not guarantee.
5. **Trust boundaries.** Data from a user, another service or a file needs validation and correct encoding where it is used — query, shell invocation, template, path, deserializer. Authorization belongs server-side and covers the new entry point too.
6. **Secrets.** Credentials in source or committed config, tokens or personal data in logs and errors, stack traces returned to callers.
7. **Contracts.** A renamed field, narrowed type, new required parameter or changed default breaks consumers not updated here. Persisted schemas and event payloads need a migration path.
8. **Tests.** New behaviour arrives with tests that would fail without the change, covering the failure case rather than only the happy path.
9. **Observability.** A new failure mode needs some way to be seen in production.
10. **Performance.** Work repeated in a loop that could be hoisted, queries per item instead of batched, unbounded collections built from user-controlled input.
11. **Clarity.** Misleading names, dead code, duplicated logic that will drift, magic values, comments explaining what instead of why.

Four rules hold in every language and always apply. A credential, token, private key or connection string written as a literal in source or a committed config file is a **BLOCKER**. Changing a published interface, event payload or persisted schema without a migration or version bump is a **CRITICAL**. Commented-out code introduced by the change is a **MAJOR**. A new TODO or FIXME with no tracked issue is a **MINOR**.

When `reviewConfig.teamRules` is present, apply each rule whose `appliesTo` globs match the file in hand, at the severity that rule declares.

### Scope

- Confine findings to lines the diff changed. Unchanged code, commit messages and CI configuration stay out unless the change touches them.
- Leave alone anything a formatter or linter already enforces.
- Report only what the fetched material supports. When judging a finding would need a file the diff does not show, mark the concern unverified or drop it.
- Keep at most 25 findings, or `reviewConfig.maxFindings` when set. Over the cap, keep the highest severities.
- Raise each problem once. When the same mistake repeats across five places, report it once and list the other locations inside it.
- When the PR already carries review comments, skip findings that repeat a point someone has already made.

### Verify before writing

Take each candidate finding and try to argue it is wrong — that the guard exists further up, that the caller already validates, that the test covers it. Drop the ones that survive the argument only by assumption. A review of eight defensible findings is worth more than twenty that need defending, and this pass is where a generic reviewer becomes a trusted one.

### Severity scale

- 🔴 **BLOCKER** — security holes, data loss, leaked secrets.
- 🟠 **CRITICAL** — logic errors, unhandled failures, leaks, races, broken contracts.
- 🟡 **MAJOR** — untested behaviour, duplication, structural and design problems.
- 🔵 **MINOR** — naming, dead code, style. Never blocks a merge alone.

When `reviewConfig.severityScale` is set, use its labels instead.

## Step 5 — Deliver the review in chat

Write it in the response. Create no files or reports.

Header first, in this exact shape:

```text
PR #<number> — <title>
<author> · <headRef> → <baseRef> · <n> files · +<additions> / -<deletions>
Reviews: <approved> approved, <changesRequested> changes requested · CI: <status>
```

Then the changed files with their counts, marking any that were excluded.

Then **Intent and design** as two or three sentences of prose: whether the change delivers what the description promised, and anything structural worth saying. When both are clean, one sentence saying so is enough — this section earns its place by being short when there is nothing wrong.

Then the findings, ordered by severity and then by file, each exactly like this:

> 🟠 **CRITICAL** Refill happens outside the lock — `src/limiter.ts` line 16
> The token count is decremented outside the critical section, so two concurrent requests can both pass the capacity check, the bucket goes negative under load, and the limiter stops limiting.
> **Fix:** move the decrement inside the lock, or replace it with an atomic compare-and-swap on the counter.

Every finding carries all four parts: severity and title, file and line, what it costs in the running system, and a concrete fix. A finding without a fix is a complaint — give it one or drop it.

Close with one paragraph: overall quality, the single biggest concern, and a recommendation of approve, request changes, or discuss. When the diff was truncated or files were excluded, name what went unread.

## Step 6 — Post the review

Post automatically once the review is written. "Posting" means submitting review comments through the GitHub API; it never touches code or branches.

The script submits to `POST /repos/{owner}/{repo}/pulls/{number}/reviews`, so the result appears in the web UI exactly as a human's review does. Each comment becomes a line-anchored note on the Files changed tab with a *Resolve conversation* button, and the `--body` summary becomes the review header on the Conversation tab, so the thread shows one review event rather than scattered notes.

Build one object per finding, copying `path` and `line` straight from the annotated diff:

```json
[
  {
    "path": "src/limiter.ts",
    "line": 16,
    "side": "RIGHT",
    "body": "🟠 **CRITICAL — refill happens outside the lock**\n\nTwo concurrent requests can both pass the capacity check, so the bucket goes negative under load.\n\n**Fix:** move the decrement inside the lock, or use an atomic compare-and-swap."
  }
]
```

Use `side: "RIGHT"` for added and context lines, `"LEFT"` for a removed line, and add `start_line` with `start_side` for a range. Only lines present in the diff can carry a comment, so a finding without one — a design concern, a missing file, a problem spanning several files — goes into the summary body. The script rejects `subject_type` entries rather than letting the API fail on them.

The summary body carries the header, the intent and design prose, and any finding that had no line. Write it to a file and pass `--body-file`, which avoids quoting problems with multi-line text.

Validate first, every time:

```bash
pr-review.sh post \
  --pr <NUMBER_OR_URL> \
  --comments <path/to/comments.json> \
  --body-file <path/to/summary.md> \
  --dry-run
```

The dry run checks each entry's shape, confirms every path is a file the PR touches, and confirms every line exists in the diff, so a wrong number is caught locally instead of GitHub rejecting the whole review. Fix anything it reports and validate again.

Once it passes, post immediately by dropping `--dry-run`:

```bash
pr-review.sh post \
  --pr <NUMBER_OR_URL> \
  --comments <path/to/comments.json> \
  --body-file <path/to/summary.md> \
  --event COMMENT
```

Post findings of MAJOR and above, or at `reviewConfig.minSeverityToPost` when set, and fold the rest into the summary. `--commit-id` defaults to the current head. The script prints the review URL on success — give it to the user.

Use `--event COMMENT`. `APPROVE` and `REQUEST_CHANGES` are the user's call: submit either one only when they ask for it in so many words.

When `reviewConfig.autoPost` is `false`, stop after the dry run, show the payload, and wait for the user to confirm.

## Failure modes

Exit `1` usage, `2` missing dependency, `3` authentication, `4` not found, `5` invalid input, `6` API error. Every failure prints a tag first.

| Tag | What to do |
|---|---|
| `GH_NOT_FOUND`, `JQ_NOT_FOUND` | Install the missing tool. |
| `GH_AUTH_FAILED`, `GH_AUTH_ERROR` | Authenticate the CLI against the configured host, or the account lacks access. |
| `REPO_NOT_CONFIGURED`, `INVALID_REPO` | Set `github.repo` in `config.json`, or pass `--repo`. |
| `PR_NOT_FOUND` | Wrong number, wrong repository, or wrong host. |
| `PROFILE_NOT_FOUND` | The named profile is not defined under `profiles` in the config. |
| `INVALID_COMMENT_ENTRY` | The listed entries are malformed; fix them and validate again. |
| `INVALID_PATH` | A comment names a file the pull request does not touch. |
| `INVALID_LINE` | The line is not in the diff; copy the number from the annotated diff. |
| `MISSING_BODY` | A `COMMENT` or `REQUEST_CHANGES` review needs a summary; pass `--body` or `--body-file`. |
| `EMPTY_COMMENTS` | No findings to post; submit the summary alone or say the PR is clean. |

## Optional configuration

Add a key only when a default is wrong for the repository. `config.example.json` documents every key with inline `_`-prefixed notes; copy from it rather than memorising the schema.

Config resolves in layers, lowest precedence first: the committed `config.json`, then the selected profile, then a `config.local.json` beside it, then command-line flags. Objects merge key by key and arrays replace wholesale, so an `excludePaths` override is taken exactly as written. `review.teamRulesAdd` is the exception — it appends to the inherited rules, while `review.teamRules` replaces them.

Select a profile with `--profile <name>`, the `PR_REVIEW_PROFILE` environment variable, or a `defaultProfile` key, in that order of precedence. An unknown name fails with `PROFILE_NOT_FOUND` rather than silently falling back to the baseline.

Under `fetch`: `maxDiffLines` sets the truncation budget (default 800, `0` for unlimited), `includeDiff` set to `false` fetches metadata only, and `excludePaths` replaces the built-in exclusion list, which already covers lockfiles, minified bundles, source maps, snapshots, images, `dist/`, `build/`, `vendor/`, `node_modules/`, `*/generated/` and common protobuf output. Patterns are shell globs matched against both the full path and the bare filename; an empty array disables exclusion.

Under `review`: `autoPost` set to `false` restores the confirmation step, `defaultEvent` sets what `post` submits without `--event`, `maxFindings` caps the review, `maxCommentsPerFile` stops one file collecting every comment, `minSeverityToPost` is the floor for a finding to become an inline comment, `designPass` and `intentCheck` set to `false` skip Step 3, `skipCategories` drops numbered categories from Step 4, `commentLanguage` sets the language of posted comments, `severityScale` relabels the four levels, and `teamRules` carries conventions specific to the repository. Language-specific and house rules belong there, which is what keeps this file language-agnostic.

## Safety

`fetch` only reads. `post` writes review comments after local validation, and never edits source files, creates commits, or pushes branches. Keep tokens out of the output, and submit `APPROVE` or `REQUEST_CHANGES` only on an explicit request from the user.
