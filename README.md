# ai-skills

Agent Skills for AI coding agents.

| Skill | What it does |
| --- | --- |
| [`code-review`](code-review/) | Reviews a GitHub pull request and posts the findings back to the PR as inline comments. |

Each skill is a plain folder in the Agent Skills format — a `SKILL.md` plus the
files it needs — so it works in any agent that supports skills. Nothing in it is
tied to one client.

## Install

Clone the repository and copy the skill into your agent's skills directory.

```bash
git clone https://github.com/your-org/ai-skills.git
```

Pick the directory your agent reads:

```bash
# Checked into the repository, so everyone working in it picks the skill up
mkdir -p .github/skills
cp -r ai-skills/code-review .github/skills/pr-review
chmod +x .github/skills/pr-review/pr-review.sh
```

Common personal locations, if you would rather have the skill everywhere you
work: `~/.config/skills`, `~/.claude/skills`, `~/.copilot/skills`. The copy is
the same either way — only the destination changes.

Then set your repository in the skill's `config.json`:

```json
{
  "github": {
    "host": "github.com",
    "repo": "your-org/your-repo"
  }
}
```

That is the whole setup.

## Use

Just ask:

> Review PR 482

The agent fetches the pull request, reviews the diff, and shows you the findings
ranked by severity. If you say yes, it posts them back to the PR as inline
comments on the **Files changed** tab.

## Requirements

- `gh`, authenticated against your host
- `jq`
- Bash — macOS, Linux, or WSL / Git Bash on Windows

See [`code-review/README.md`](code-review/README.md) for optional configuration.
