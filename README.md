# pr-review

An Agent Skill that reviews a GitHub pull request and posts the findings back to
the PR as line-anchored comments — the same shape a human reviewer's comments
take.

It fetches the PR's metadata and diff, ranks what it finds by severity, shows
you the review in chat, and submits it through the GitHub reviews API. The
comments land on the **Files changed** tab, each with a *Resolve conversation*
button, and the summary lands on the **Conversation** tab as one review event.

Works with any repository and any programming language.

## Install

In Git Bash, from the root of the repository you want the skill in:

```
git clone https://github.com/viknesh-ai/ai-skills.git .github/skills/pr-review
```

Git creates `.github/skills/pr-review/` for you. That is the whole install.
Checked in, the skill is picked up by everyone working in the repository.

## Configure

Set your repository in `.github/skills/pr-review/config.json`:

```json
{
  "github": {
    "host": "sgithub.fr.world.socgen",
    "repo": "your-org/your-repo"
  }
}
```

`repo` is the owner and name from the URL path, not the full URL. The host is
already set. Nothing else is required.

## Use

Ask in plain language:

> Review PR 482

The agent fetches the PR, reviews the changed lines, and writes the findings in
chat:

```
PR #482 — Add per-tenant rate limiting
dupont · feat/rate-limit → main · 4 files · +182 / -31
Reviews: 0 approved, 0 changes requested · CI: SUCCESS

[🟠 CRITICAL] Refill happens outside the lock
src/limiter.ts — line 16
Two concurrent requests can both pass the capacity check because the token
count is decremented outside the critical section, so the bucket goes negative
under load and the limiter stops limiting.
Fix: move the decrement inside the lock, or use an atomic compare-and-swap.
```

Then it posts them to the pull request itself and gives you the review link —
you do not have to ask, and the findings do not stay in the terminal. Each one
becomes an inline comment on the line it refers to, with a *Resolve
conversation* button.

Tell it not to post and it will keep the review in chat instead.

A PR URL works too, and carries its own repository, so you can review a PR in a
repo you have not configured:

> Review https://sgithub.fr.world.socgen/your-org/your-repo/pull/482

## Requirements

Windows, with Git Bash.

- `gh`, authenticated: `gh auth login --hostname sgithub.fr.world.socgen`
- `jq`: `envinstall jq`

## Optional configuration

Only `github.repo` needs setting. Everything else has a working default —
diff budget, skipped paths, findings cap, severity floor for posting, and
`teamRules` for conventions specific to your repository.
[`config.example.json`](config.example.json) documents every key inline, with
per-team profiles for repositories shared by more than one team. Copy the
pieces you want into `config.json`.

## License

MIT — see [LICENSE](LICENSE).
