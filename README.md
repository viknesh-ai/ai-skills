# ai-skills

Agent Skills for use with Claude Code on Windows.

| Skill | What it does |
| --- | --- |
| [`code-review`](code-review/) | Reviews a GitHub pull request against a severity rubric and posts the findings back to the PR as inline comments. |

## Requirements

- Windows, with Windows PowerShell 5.1 (built in) or PowerShell 7
- GitHub CLI (`gh`), authenticated against your host

```powershell
winget install --id GitHub.cli
gh auth login --hostname sgithub.fr.world.socgen
```

## Install a skill

Copy the skill folder into your skills directory — personal scope to have it
everywhere, or repository scope so everyone working in the repo picks it up.

```powershell
# Personal scope
New-Item -ItemType Directory -Force "$HOME\.claude\skills" | Out-Null
Copy-Item -Recurse code-review "$HOME\.claude\skills\pr-review"

# Repository scope
New-Item -ItemType Directory -Force ".claude\skills" | Out-Null
Copy-Item -Recurse code-review ".claude\skills\pr-review"
```

Then set `github.repo` in the skill's `config.json`. See
[`code-review/README.md`](code-review/README.md) for the rest.
