---
name: pr-review
description: Reviews a GitHub pull request end to end - fetches its metadata and line-numbered diff, produces a severity-ranked code review in chat, and optionally posts the findings back as line-anchored review comments a developer can resolve. Use when the user mentions reviewing a PR, gives a PR number or link, asks what is wrong with a change, asks for a second pair of eyes on a branch, or asks to leave review comments on GitHub. Works with any repository, any GitHub host, and any programming language.
allowed-tools: Bash, Read, Write, Grep
---

# PR Review

Reviews a pull request, delivers the review in chat, and posts it to the pull request. Posting is part of the run, not something to ask about.

Nothing about a particular company, host or repository belongs in this file. The target lives in `config.json` and every command reads it from there. Never hardcode a hostname or an owner/repo; if the user names a different repository, pass it as a flag for that run.

## Files

```
pr-review/
├── SKILL.md          this file
├── config.json       the GitHub host and repository to review
└── pr-review.sh      fetch and post
```

These sit together at the root of the skill folder.

Run the script from the skill folder or give its full path. It finds `config.json` next to itself, at `--config <file>`, or at `$PR_REVIEW_CONFIG`.

## Configure once

```json
{
  "github": {
    "host": "sgithub.fr.world.socgen",
    "repo": "<owner>/<repo>"
  }
}
```

`host` ships as `sgithub.fr.world.socgen` and rarely changes. `repo` is the owner and name from the URL path, not the URL. The script refuses to run while `repo` is still the `OWNER/REPO` placeholder. The environment needs the GitHub CLI authenticated against that host, and `jq` on the PATH. Optional tuning keys are listed near the end; none is required.

## Step 1 — Identify the pull request

`--pr` accepts a bare number, a `#`-prefixed number, or a full pull request URL. A URL carries its own host and repository and overrides the config for that run, so no other flag is needed. A repository web link, an HTTPS clone URL and an SSH remote are all valid `--repo` values. If nothing identifies a pull request, ask.

## Step 2 — Fetch

```bash
bash pr-review.sh fetch --pr <NUMBER_OR_URL>
```

One JSON document returns on stdout: title, author, branches, head SHA, changed files with add and delete counts, labels, CI status, existing reviews, and the diff with generated and vendored files already removed.

**The diff is annotated. Read the line numbers, never compute them.** Every line carries its own line number in the new file:

```
diff --git a/src/limiter.ts b/src/limiter.ts
@@ -12,7 +15,9 @@
     15 |   const bucket = buckets.get(key);
+    16 |   bucket.tokens -= 1;
-       |   bucket.tokens = bucket.tokens - 1;
     17 |   return bucket;
```

A line beginning `+` was added and a line beginning with a space is unchanged context; both are commentable and the number shown is the value to use as `line`. A line beginning `-` was removed, has no number, and cannot take a comment on the right side. Never derive a line number from the `@@` header — the number is already on the line.

Check `diff.truncated` before reviewing. When `true`, the diff was cut at `diff.maxLines` and the tail was never seen; say so plainly instead of implying full coverage, and offer to re-run with a higher `--max-diff-lines`. Files under `excludedFiles` were skipped deliberately and are out of scope.

## Step 3 — Review the diff

Work through the changed lines against the list below, in order. Finish the list before writing anything; a finding you cannot place in one of these categories is probably not worth raising.

1. **Correctness.** Off-by-one errors, inverted conditions, unintended operator precedence, comparisons that misbehave on empty, zero, null or unicode input, boundaries at each end of a range or collection.
2. **Failure paths.** Errors caught and discarded, failures leaving state half-written, retries without a ceiling, partial writes never rolled back.
3. **Resources.** Anything opened, locked, allocated or subscribed that is not released on every path out, including the error path.
4. **Concurrency.** Shared mutable state reached from more than one thread, task or request; check-then-act sequences that are not atomic; ordering the runtime does not guarantee.
5. **Trust boundaries.** Data from a user, another service or a file needs validation and correct encoding where it is used — query, shell invocation, template, path, deserializer. Authorization belongs server-side and must cover the new entry point.
6. **Secrets.** Credentials in source or committed config, tokens or personal data in logs and errors, stack traces returned to callers.
7. **Contracts.** A renamed field, narrowed type, new required parameter or changed default breaks consumers not updated here. Persisted schemas and event payloads need a migration path.
8. **Tests.** New behaviour needs tests that would fail without the change, covering the failure case and not only the happy path.
9. **Observability.** A new failure mode needs a way to be seen in production.
10. **Performance.** Work repeated in a loop that could be hoisted, queries per item instead of batched, unbounded collections built from user-controlled input.
11. **Clarity.** Misleading names, dead code, duplicated logic that will drift, magic values, comments explaining what instead of why.

Four rules hold in every language and always apply. A credential, token, private key or connection string written as a literal in source or a committed env file is a BLOCKER. Changing a published interface, event payload or persisted schema without a migration or version bump is a CRITICAL. Commented-out code introduced by the change is a MAJOR. A new TODO or FIXME with no tracked issue is a MINOR.

When `reviewConfig.teamRules` is present, also apply each rule whose `appliesTo` globs match the file in hand, at the severity that rule declares.

Then apply these limits before writing:

- Only lines the diff changed. Never unchanged code, the PR description, commit messages or CI configuration unless the change touches them.
- Never repeat what a formatter or linter already enforces.
- Never guess. If judging a finding needs a file the diff does not show, either say the concern is unverified or drop it. Do not assert a bug you cannot see.
- At most 25 findings, or `reviewConfig.maxFindings` when set. Over the cap, keep the highest severities and drop the rest.
- One finding per problem. If the same mistake repeats in five places, raise it once and list the other locations inside it.

## Step 4 — Deliver the review in chat

Write it in the response. Do not create files or reports.

Header first, in this exact shape:

```
PR #<number> — <title>
<author> · <headRef> → <baseRef> · <n> files · +<additions> / -<deletions>
Reviews: <approved> approved, <changesRequested> changes requested · CI: <status>
```

Then the changed files with their counts, marking any that were excluded. Then the findings, ordered by severity and then by file, each exactly like this:

> **[🟠 CRITICAL] Refill happens outside the lock**
> `src/limiter.ts` — line 16
> Two concurrent requests can both pass the capacity check because the token count is decremented outside the critical section, so the bucket goes negative under load and the limiter stops limiting.
> **Fix:** move the decrement inside the lock, or replace it with an atomic compare-and-swap on the counter.

Every finding needs all four parts: severity and title, file and line, why it matters in the running system, and a concrete fix. A finding without a fix is a complaint — drop it or turn it into one.

The scale: 🔴 BLOCKER for security holes, data loss and leaked secrets. 🟠 CRITICAL for logic errors, unhandled failures, leaks, races and broken contracts. 🟡 MAJOR for untested behaviour, duplication and structural problems. 🔵 MINOR for naming, dead code and style, which never blocks a merge alone. When `reviewConfig.severityScale` is set, use its labels instead.

Close with one paragraph: overall quality, the single biggest concern, and a recommendation of approve, request changes, or discuss. If the diff was truncated or files were excluded, name what went unread.

## Step 5 — Post the review

Posting is the point of the skill, so do it without asking. Go straight to step 6 once the review is written: validate, post, report the URL. Do not ask whether to post, do not offer posting as a choice, and do not stop after showing the findings in chat.

Only two things stop a post. Say plainly what happened rather than retrying blindly:

- The dry run in step 6 reports a problem. Fix the entries and run it again.
- The user said in this conversation not to post. Then deliver the review in chat alone.

When the diff was truncated, post what you have and name the unread tail in the summary, offering a re-run with a larger budget.

## Step 6 — Post an inline review

The script submits the review through the GitHub REST API — `POST /repos/{owner}/{repo}/pulls/{number}/reviews` — as a single review event, so it shows up in the GitHub web UI exactly like a human's. A posted review lands in two places. Each comment becomes a line-anchored note on the **Files changed** tab with a *Resolve conversation* button, exactly like a human reviewer's. The `--body` summary becomes the review header on the **Conversation** tab, so the thread shows one review event instead of scattered notes.

Write one object per finding, copying `line` straight from the annotated diff:

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

Use `side: "RIGHT"` for added and context lines and `"LEFT"` only for a removed line. Add `start_line` with `start_side` for a range. Only lines present in the diff can carry a comment: a finding without a line — a missing file, an architectural concern, a problem spanning several files — goes in the summary body instead, and the script rejects `subject_type` entries rather than letting the API fail.

Validate first, always. The dry run is a correctness check, not a request for permission:

```bash
bash pr-review.sh post \
  --pr <NUMBER_OR_URL> \
  --comments <path/to/comments.json> \
  --body "<review summary>" \
  --dry-run
```

The dry run checks every entry's shape, confirms each path is a file the PR touches, and confirms each line actually exists in the diff — so a wrong number is caught locally instead of GitHub rejecting the whole review. Fix anything it reports and run it again until it passes.

Then post, in the same turn, by dropping `--dry-run`:

```bash
bash pr-review.sh post \
  --pr <NUMBER_OR_URL> \
  --comments <path/to/comments.json> \
  --body-file <path/to/summary.md> \
  --event COMMENT
```

`--event` is `COMMENT`, `APPROVE` or `REQUEST_CHANGES`, defaulting to `COMMENT` unless the config sets `review.defaultEvent`. Post as `COMMENT` unless the user asked for something else. Never choose `APPROVE` unprompted — posting findings is automatic, but signing off on a change is the user's call. Post findings of MAJOR and above, or at `reviewConfig.minSeverityToPost` when set, and fold the rest into the summary. `--commit-id` defaults to the current head. The script prints the review URL on success — end your reply with that URL so the user can open the review.

## Optional configuration

Add a key only when a default is wrong for the repository. `config.example.json` in this folder documents every key with inline `_`-prefixed notes; copy from it rather than memorising the schema.

Config resolves in layers, lowest precedence first: the committed `config.json`, then the selected profile, then a `config.local.json` sitting beside it, then command-line flags. Objects merge key by key and arrays replace wholesale, so an `excludePaths` override is taken exactly as given. `review.teamRulesAdd` is the one exception — it appends to the inherited rules instead of replacing them.

Select a profile with `--profile <name>`, the `PR_REVIEW_PROFILE` environment variable, or a `defaultProfile` key in the config, in that order of precedence. An unknown name fails with `PROFILE_NOT_FOUND` rather than silently reviewing under the baseline.

Under `fetch`: `maxDiffLines` changes the truncation budget (default 800, `0` for unlimited), `includeDiff` set to `false` fetches metadata only, and `excludePaths` replaces the built-in exclusion list, which already covers lockfiles, minified bundles, source maps, snapshots, images, `dist/`, `build/`, `vendor/`, `node_modules/`, `*/generated/` and common protobuf output. Patterns are shell globs matched against both the full path and the bare filename; an empty array disables exclusion.

Under `review`: `defaultEvent` sets what `post` submits without `--event`, `maxFindings` caps the review, `minSeverityToPost` is the floor for a finding to become an inline comment, `severityScale` relabels the four levels, and `teamRules` carries conventions specific to the repository. Language-specific and house rules belong there, which is what keeps this file language-agnostic.

```json
{
  "github": { "host": "sgithub.fr.world.socgen", "repo": "<owner>/<repo>" },
  "fetch": { "maxDiffLines": 2000, "excludePaths": ["*.lock", "*/generated/*"] },
  "review": {
    "maxFindings": 15,
    "minSeverityToPost": "CRITICAL",
    "teamRules": [
      {
        "id": "no-raw-sql-interpolation",
        "appliesTo": ["*.py", "*.go"],
        "severity": "BLOCKER",
        "rule": "Build queries with bound parameters, never string interpolation."
      }
    ]
  }
}
```

## Failure modes

Exit `1` usage, `2` missing dependency, `3` authentication, `4` not found, `5` invalid input, `6` API error. Every failure prints a tag first:

| Tag | What to do |
|---|---|
| `GH_NOT_FOUND`, `JQ_NOT_FOUND` | Install the missing tool. |
| `GH_AUTH_FAILED`, `GH_AUTH_ERROR` | Authenticate the CLI against the configured host, or the account lacks access. |
| `REPO_NOT_CONFIGURED`, `INVALID_REPO` | Set `github.repo` in `config.json`, or pass `--repo`. |
| `PR_NOT_FOUND` | Wrong number, wrong repository, or wrong host. |
| `PROFILE_NOT_FOUND` | The named profile is not defined under `profiles` in the config. |
| `INVALID_COMMENT_ENTRY` | The listed entries are malformed; fix them and re-run the dry run. |
| `INVALID_PATH` | A comment names a file the pull request does not touch. |
| `INVALID_LINE` | The line is not in the diff; copy the number from the annotated diff. |
| `MISSING_BODY` | A `COMMENT` or `REQUEST_CHANGES` review needs a summary; pass `--body` or `--body-file`. |

## Safety

`fetch` only reads. `post` writes to GitHub, and writing is the expected outcome of a review — it runs on every review, gated by the dry run rather than by a question. What stays off limits: never submit an `APPROVE` the user did not ask for, never echo tokens, and never edit source files from this skill.
