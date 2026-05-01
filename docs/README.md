# cosmic-unconscious

Personal agentic development kit powered by [Goose](https://github.com/aaif-goose/goose). One repo, deployable to any VM.

## Quick Start

```bash
git clone <your-repo-url> ~/cosmic-unconscious
cd ~/cosmic-unconscious

# Global config only
./bootstrap.sh

# Global + specific projects
./bootstrap.sh katello foreman
```

## Structure

```
cosmic-unconscious/
├── bootstrap.sh              # Deploy to any VM
├── global/                   # Always deployed
│   ├── config.yaml           # Goose provider, extensions, slash commands
│   ├── guardrails.md         # Persistent instructions (injected every turn)
│   ├── goosehints            # Global developer preferences
│   └── skills/               # Cross-project methodology
├── projects/                 # Deployed per-project
│   ├── katello/
│   │   ├── goosehints        # Project context
│   │   ├── skills/           # Domain knowledge
│   │   └── docs/             # Gotchas, patterns (growing knowledge base)
│   └── foreman/
│       ├── goosehints
│       ├── skills/
│       └── docs/
├── recipes/                  # Cross-project reusable workflows
└── docs/                     # This README and meta-docs
```

## Recipes

Recipes are reusable workflows that can be run interactively (slash commands)
or headless from the CLI.

### Available Recipes

| Recipe | Description | Parameters |
|--------|-------------|------------|
| `code-review` | Collaborative code review | `project_name`, `project_path`, `review_context` |
| `design-feature` | Feature design with requirements interview | `project_name`, `project_path`, `requirements` |
| `find-code` | Navigate and explain code | `project_name`, `project_path`, `question` |
| `fix-bug` | Systematic bug fixing | `project_name`, `project_path`, `bug_description` |
| `investigate-bug` | Systematic bug investigation | `project_name`, `project_path`, `bug_description` |
| `capture-learning` | Capture session learnings into skills/docs | (none) |

### CLI Usage

Run a recipe headless with all parameters inline:

```
goose run --recipe code-review \
  --params project_name=katello \
  --params project_path=/home/user/katello \
  --params review_context="Review https://github.com/org/repo/pull/123"
```

Omit a required parameter and goose will prompt for it interactively:

```
goose run --recipe find-code \
  --params project_name=foreman \
  --params project_path=/home/user/foreman
# goose will prompt for "question"
```

### Slash Commands

Slash commands (defined in `global/config.yaml`) launch recipes
interactively inside a session.

| Command | What it does |
|---------|-------------|
| `/bug` | Start a bug investigation |
| `/design` | Feature design with requirements interview |
| `/explore` | Navigate and explain code |
| `/capture` | Capture session learnings into skills/docs |

## Adding a New Project

1. Create `projects/<name>/goosehints` with project context
2. Create `projects/<name>/skills/<skill>/SKILL.md` for domain knowledge
3. Create `projects/<name>/docs/gotchas.md` and `patterns.md`
4. Run `./bootstrap.sh <name>` to deploy
5. Add project-specific recipes in `projects/<name>/recipes/` if needed

## Growing the Knowledge Base

After every meaningful session, run `/capture` to update skills and docs.
Then commit:

```bash
cd ~/cosmic-unconscious && git add -A && git commit -m "learnings: <what you learned>"
```

## Gotchas

### Recipe file structure

Goose discovers recipes by scanning for `*.yaml` / `*.json` files directly
inside `GOOSE_RECIPE_PATH` directories (and `~/.config/goose/recipes/`).
It does NOT recurse into subdirectories.

This means recipes must be deployed as flat files:

```
~/.local/share/goose/recipes/
  find-code.yaml          # CORRECT -- goose finds this
  investigate-bug.yaml

  find-code/
    recipe.yaml           # WRONG  -- goose ignores subdirectories
```

The bootstrap script copies `recipes/<name>/recipe.yaml` as
`~/.local/share/goose/recipes/<name>.yaml`. If you add a new recipe,
keep the repo structure (`recipes/<name>/recipe.yaml`) and bootstrap
handles the flattening.

Slash commands in `global/config.yaml` must reference the flat path too:

```yaml
- command: "explore"
  recipe_path: "~/.local/share/goose/recipes/find-code.yaml"   # flat
```

## Where Things Deploy

| Source | Destination |
|--------|------------|
| `global/config.yaml` | `~/.config/goose/config.yaml` |
| `global/guardrails.md` | `~/.config/goose/guardrails.md` |
| `global/goosehints` | `~/.config/goose/.goosehints` |
| `global/skills/*` | `~/.agents/skills/` |
| `recipes/*` | `~/.local/share/goose/recipes/` |
| `projects/<p>/goosehints` | `<project_dir>/.goosehints` |
| `projects/<p>/skills/*` | `<project_dir>/.agents/skills/` |
| `projects/<p>/docs/*` | `<project_dir>/.agents/skills/<p>-docs/` (auto-generated skill) |
