# pr-review

Reviews a GitHub pull request and posts the findings back to the PR as
line-anchored comments — the same shape a human reviewer's comments take.

It fetches the PR's metadata and diff, ranks what it finds by severity, shows
you the review in chat, and — only if you say yes — submits it through the
GitHub REST API so the comments appear in the GitHub web UI on the
**Files changed** tab, each with a *Resolve conversation* button.

Works with any repository and any programming language.

## Requirements

- Windows, with Windows PowerShell 5.1 (built in) or PowerShell 7
- GitHub CLI (`gh`), authenticated against your host

Nothing else — no `jq`, no other tooling. The script handles JSON itself.

```powershell
winget install --id GitHub.cli
gh auth login --hostname sgithub.fr.world.socgen
```

## Install

Copy this folder into a skills directory.

```powershell
# Personal — available in every repository you work on
Copy-Item -Recurse code-review "$HOME\.claude\skills\pr-review"

# Repository — checked in, so everyone working in the repo picks it up
Copy-Item -Recurse code-review ".claude\skills\pr-review"
```

## Configure

Set your repository in `config.json`:

```json
{
  "github": {
    "host": "sgithub.fr.world.socgen",
    "repo": "your-org/your-repo"
  }
}
```

`host` is already set to `sgithub.fr.world.socgen`. `repo` is the owner and
name from the URL path — not the full URL. That is the whole required setup.

## Use

Ask in plain language:

> Review PR 482
>
> Review https://sgithub.fr.world.socgen/your-org/your-repo/pull/482
>
> What's wrong with #482?

A PR URL carries its own host and repository, so you can review a PR in a repo
you have not configured.

After the review you are offered the option to post it back. Nothing is written
to GitHub without an explicit yes, and always after a dry run that shows you the
exact payload first.

### Running the script directly

```powershell
.\pr-review.ps1 fetch --pr 482
.\pr-review.ps1 post  --pr 482 --comments findings.json --body "Summary" --dry-run
```

`.\pr-review.ps1 --help` lists every flag.

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
  "github": { "host": "sgithub.fr.world.socgen", "repo": "your-org/your-repo" },
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

```powershell
.\pr-review.ps1 fetch --pr 482 --profile platform
```

The platform team gets a bigger diff budget, a higher bar for inline comments,
and its migration rule on top of the shared ones. The frontend team inherits
everything and caps findings at ten. Neither keeps its own copy of the config.

## Why it is built this way

**The deterministic work stays in the script.** Path filtering, line-number
mapping, comment validation and error classification happen in PowerShell, not
in the model. The diff arrives with each line's new-file line number already
attached, so the reviewer never derives one from a hunk header — the most common
cause of a rejected review.

**Two guards before any write.** The dry run rejects malformed entries, paths
the PR does not touch, and lines absent from the diff, naming each offender.
Nothing reaches GitHub until those pass and you say yes.

**Language-agnostic by construction.** The review criteria are properties of
programs, not of syntax. Ecosystem-specific rules live in configuration, so one
skill serves a Java service, a React app and a Terraform module.

## License

MIT — see [LICENSE](LICENSE).
