# ai-skills

Agent Skills for Claude Code.

| Skill | What it does |
| --- | --- |
| [`code-review`](code-review/) | Reviews a GitHub pull request and posts the findings back to the PR as inline comments. |

## Install

Clone this repository and run the install script. It copies the skills into
`~/.claude/skills`, so they work in every repository you open.

```bash
git clone https://sgithub.fr.world.socgen/your-org/ai-skills.git
cd ai-skills
./install.sh
```

Then set your repository in `~/.claude/skills/pr-review/config.json`:

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

Claude fetches the pull request, reviews the diff, and shows you the findings
ranked by severity. If you say yes, it posts them back to the PR as inline
comments on the **Files changed** tab.

## Requirements

`gh` (authenticated against your host) and `jq`.

See [`code-review/README.md`](code-review/README.md) for optional configuration.
