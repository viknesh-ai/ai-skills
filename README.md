# ai-skills

Agent Skills for AI coding agents.

| Skill | What it does |
| --- | --- |
| [`code-review`](code-review/) | Reviews a GitHub pull request and posts the findings back to the PR as inline comments. |

Each skill is a plain folder in the Agent Skills format — a `SKILL.md` plus the
files it needs — so it works in any agent that supports skills.

## Install

From the root of the repository you want the skill in:

```bash
curl -fsSL https://raw.githubusercontent.com/viknesh-ai/ai-skills/main/install.sh | bash
```

That creates `.github/skills/code-review/`, checked into your repository so
everyone working in it picks the skill up. Name a skill to install just that
one:

```bash
curl -fsSL https://raw.githubusercontent.com/viknesh-ai/ai-skills/main/install.sh | bash -s -- code-review
```

To install for yourself instead of the repository, point it somewhere else:

```bash
curl -fsSL https://raw.githubusercontent.com/viknesh-ai/ai-skills/main/install.sh | AI_SKILLS_DEST=~/.config/skills bash
```

Then set your repository in `.github/skills/code-review/config.json`:

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
