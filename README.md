# pr-review

An [Agent Skill](https://agentskills.io) that reviews GitHub pull requests. It fetches a PR's metadata and diff, produces a severity-ranked review, and can post the findings back as line-anchored comments a developer can resolve — the same shape a human reviewer's comments take.

Works with any repository, any GitHub host including Enterprise, and any programming language.

## What it does

- Fetches PR metadata and a **line-numbered diff**, with lockfiles, minified bundles and generated code already filtered out
- Reviews changed lines against correctness, failure paths, resource handling, concurrency, trust boundaries, secrets, contract compatibility, tests, observability, performance and clarity
- Delivers the review in chat, ranked BLOCKER / CRITICAL / MAJOR / MINOR
- Optionally posts it as an inline review — findings land on the *Files changed* tab with a *Resolve conversation* button, the summary lands on the *Conversation* tab
- Verifies every path and line against the real diff **before** posting, so a wrong line number is caught locally instead of GitHub rejecting the review

## Requirements

- [GitHub CLI](https://cli.github.com) (`gh`), authenticated against your host
- `jq`
- Bash 4+ (macOS, Linux, WSL, or Git Bash on Windows)

## Install

Clone it straight into a skills directory:

```bash
# Repository scope — checked in, picked up by everyone working in the repo
git clone <repo-url> .github/skills/pr-review

# Personal scope — available in every repository you work on
git clone <repo-url> ~/.copilot/skills/pr-review
```

Or download the repository and copy its contents into `.github/skills/pr-review/`.

The skill follows the [Agent Skills](https://agentskills.io) format, so the same folder also works in any other client that supports it — drop it in that client's skills directory instead.

Then set your target in `config.json`:

```json
{
  "github": {
    "host": "github.com",
    "repo": "your-org/your-repo"
  }
}
```

`host` ships as `github.com`; change it to your GitHub Enterprise hostname if you are reviewing repositories on an internal instance. `repo` is the owner and name from the URL path. That is the entire required configuration.

Verify the CLI is authenticated:

```bash
gh auth status --hostname <your-host>
```

## Use

Ask in plain language:

> Review PR 482
>
> Review https://github.com/your-org/your-repo/pull/482
>
> What's wrong with #482?

A PR URL carries its own host and repository, so anyone can review a PR in a repo they have not configured. After the review, you will be offered the option to post it back; nothing is written to GitHub without an explicit confirmation, and always after a dry run that shows you the exact payload.

The script also runs standalone:

```bash
bash scripts/pr-review.sh fetch --pr 482
bash scripts/pr-review.sh post  --pr 482 --comments findings.json --dry-run
```

`bash scripts/pr-review.sh --help` lists every flag.

## Configuration

Only `github.host` and `github.repo` are required. [`config.example.json`](config.example.json) documents every other key inline — JSON has no comments, so notes live in `_`-prefixed keys that the script ignores. Copy the pieces you want into `config.json`.

### Different teams, different requirements

Config resolves in four layers, each overriding the one before:

1. **`config.json`** — the committed baseline everyone shares
2. **A profile** — named overrides for one team, selected by `--profile <name>`, the `PR_REVIEW_PROFILE` environment variable, or a `defaultProfile` key
3. **`config.local.json`** — gitignored, for one developer or one machine
4. **Command-line flags** — `--repo`, `--max-diff-lines` and friends, for one run

Objects merge key by key, so a profile only states what differs. Arrays replace wholesale, so an `excludePaths` override is taken exactly as written. The exception is `review.teamRulesAdd`, which appends to the inherited rules so a team can extend the baseline without restating it.

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

```bash
bash scripts/pr-review.sh fetch --pr 482 --profile platform
```

The platform team gets a bigger diff budget, a higher bar for inline comments, and its migration rule on top of the shared ones. The frontend team inherits everything and caps findings at ten. Neither maintains its own copy of the config, so a change to the baseline reaches both.

## Design notes

**Deterministic work stays in the script.** Path filtering, line-number mapping, comment validation and error classification are handled in Bash, not by the model. The diff arrives with each line's new-file line number already attached, so the reviewer never derives one from a hunk header — the most common cause of a rejected review. This is what makes the skill behave predictably on smaller and cheaper models.

**Two guards before any write.** The dry run rejects malformed entries, paths the PR does not touch, and lines absent from the diff, naming each offender. Nothing reaches GitHub until those pass and the user says yes.

**Language-agnostic by construction.** The review criteria are properties of programs, not of syntax. Ecosystem-specific rules live in configuration, so one skill serves a Go service, a React app and a Terraform module without forking.

## Contributing

Issues and pull requests welcome. Two things to keep in mind: `SKILL.md` should stay well under 500 lines so it remains cheap to load, and nothing environment-specific — a hostname, an owner, a repo name — belongs anywhere outside `config.json`.

## License

MIT — see [LICENSE](LICENSE).
