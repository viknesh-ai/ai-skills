# ai-skills

Agent Skills for GitHub Copilot.

| Skill | What it does |
| --- | --- |
| [`code-review`](code-review/) | Reviews a GitHub pull request and posts the findings back to the PR as inline comments. |

## Install

Clone the repository and copy the skill into `.github/skills/`.

```bash
git clone https://sgithub.fr.world.socgen/your-org/ai-skills.git
mkdir -p .github/skills
cp -r ai-skills/code-review .github/skills/pr-review
chmod +x .github/skills/pr-review/pr-review.sh
```

Checked into `.github/skills/`, the skill is picked up by everyone working in
the repository.

Then set your repository in `.github/skills/pr-review/config.json`:

```json
{
  "github": {
    "host": "sgithub.fr.world.socgen",
    "repo": "your-org/your-repo"
  }
}
```

That is the whole setup.

## Use

Just ask:

> Review PR 482

Copilot fetches the pull request, reviews the diff, and shows you the findings
ranked by severity. If you say yes, it posts them back to the PR as inline
comments on the **Files changed** tab.

## Requirements

`gh` (authenticated against your host) and `jq`.

See [`code-review/README.md`](code-review/README.md) for optional configuration.
