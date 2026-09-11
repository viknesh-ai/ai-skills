# ai-skills

Agent Skills for use with Claude Code.

| Skill | What it does |
| --- | --- |
| [`code-review`](code-review/) | Reviews a GitHub pull request against a configurable severity rubric and can post the review back to the PR. |

## Install a skill

Copy the skill folder into your skills directory — repository scope so everyone
working in the repo picks it up, or personal scope to have it everywhere:

```bash
# Repository scope
mkdir -p .claude/skills && cp -r code-review .claude/skills/

# Personal scope
mkdir -p ~/.claude/skills && cp -r code-review ~/.claude/skills/
```

See each skill's own README for configuration.
