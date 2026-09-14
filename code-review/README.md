# pr-review

Reviews a GitHub pull request and posts the findings back to the PR as
line-anchored comments — the same shape a human reviewer's comments take.

It fetches the PR's metadata and diff, ranks what it finds by severity, shows
you the review in chat, and — only if you say yes — submits it through the
GitHub reviews API. The comments land in the GitHub web UI on the
**Files changed** tab, each with a *Resolve conversation* button, and the
summary lands on the **Conversation** tab as a single review event.

Works with any repository, any GitHub host including Enterprise, and any
programming language.

## Requirements

- `gh`, authenticated against your host
- `jq`
- Bash — macOS, Linux, or WSL / Git Bash on Windows

## Install

This is a plain Agent Skills folder, so it works in any agent that supports
skills. Copy it into whichever skills directory your agent reads.

```bash
# Checked into the repository, so everyone working in it picks the skill up
mkdir -p .github/skills
cp -r code-review .github/skills/pr-review
chmod +x .github/skills/pr-review/pr-review.sh
```

Common personal locations, if you would rather have the skill everywhere you
work: `~/.config/skills`, `~/.claude/skills`, `~/.copilot/skills`. Only the
destination changes.

Then set your repository in the skill's `config.json`:

```json
{
  "github": {
    "host": "github.com",
    "repo": "your-org/your-repo"
  }
}
```

`host` is `github.com` for public GitHub, or your GitHub Enterprise hostname.
`repo` is the owner and name from the URL path — not the full URL. Nothing else
is required.

## Use

Ask in plain language:

> Review PR 482

The agent fetches the PR, reviews the changed lines, and writes the findings in
chat like this:

```
PR #482 — Add per-tenant rate limiting
acoulton · feat/rate-limit → main · 4 files · +182 / -31
Reviews: 0 approved, 0 changes requested · CI: SUCCESS

[🟠 CRITICAL] Refill happens outside the lock
src/limiter.ts — line 16
Two concurrent requests can both pass the capacity check because the token
count is decremented outside the critical section, so the bucket goes negative
under load and the limiter stops limiting.
Fix: move the decrement inside the lock, or use an atomic compare-and-swap.
```

Then it offers to post the review. Nothing is written to GitHub without an
explicit yes, and always after a dry run that shows you the exact payload.

A PR URL works too, and carries its own host and repository, so you can review
a PR in a repo you have not configured:

> Review https://github.com/your-org/your-repo/pull/482

## Optional configuration

Only `github.host` and `github.repo` are required.
[`config.example.json`](config.example.json) documents every other key inline —
JSON has no comments, so the notes live in `_`-prefixed keys the script ignores.
Copy the pieces you want into `config.json`.

The keys worth knowing:

| Key | What it does |
| --- | --- |
| `fetch.maxDiffLines` | Truncate the diff at N lines. Default 800, `0` for unlimited. |
| `fetch.excludePaths` | Replaces the built-in skip list (lockfiles, bundles, `dist/`, `vendor/`, generated code). |
| `review.maxFindings` | Hard cap on findings in one review. Default 25. |
| `review.minSeverityToPost` | Findings below this go in the summary instead of becoming inline comments. |
| `review.teamRules` | Conventions specific to your repository, applied on top of the built-in checks. |

### Per-team settings

Config resolves in four layers, each overriding the one before:

1. `config.json` — the committed baseline everyone shares
2. A profile — named overrides selected by `--profile <name>`, the
   `PR_REVIEW_PROFILE` environment variable, or a `defaultProfile` key
3. `config.local.json` — gitignored, for one developer or one machine
4. Command-line flags — for one run

Objects merge key by key, so a profile only states what differs. Arrays replace
wholesale. The exception is `review.teamRulesAdd`, which appends to the
inherited rules so a team can extend the baseline without restating it.

```json
{
  "github": { "host": "github.com", "repo": "your-org/your-repo" },
  "review": { "maxFindings": 25, "minSeverityToPost": "MAJOR" },

  "profiles": {
    "platform": {
      "fetch": { "maxDiffLines": 2500 },
      "review": {
        "minSeverityToPost": "CRITICAL",
        "teamRulesAdd": [
          {
            "id": "migration-needs-rollback",
            "appliesTo": ["*/migrations/*"],
            "severity": "BLOCKER",
            "rule": "Every forward migration needs a tested rollback path."
          }
        ]
      }
    },
    "frontend": {
      "review": { "maxFindings": 10 }
    }
  }
}
```

The platform team gets a bigger diff budget, a higher bar for inline comments,
and its migration rule on top of the shared ones. The frontend team inherits
everything and caps findings at ten. Neither keeps its own copy of the config.

## Running the script directly

```bash
bash pr-review.sh fetch --pr 482
bash pr-review.sh post  --pr 482 --comments findings.json --body "Summary" --dry-run
```

`bash pr-review.sh --help` lists every flag.

## Why it is built this way

**The deterministic work stays in the script.** Path filtering, line-number
mapping, comment validation and error classification happen in Bash, not in the
model. The diff arrives with each line's new-file line number already attached,
so the reviewer never derives one from a hunk header — the most common cause of
a rejected review.

**Two guards before any write.** The dry run rejects malformed entries, paths
the PR does not touch, and lines absent from the diff, naming each offender.
Nothing reaches GitHub until those pass and you say yes.

**Language-agnostic by construction.** The review criteria are properties of
programs, not of syntax. Ecosystem-specific rules live in configuration, so one
skill serves a Java service, a React app and a Terraform module.

## License

MIT — see [LICENSE](LICENSE).
