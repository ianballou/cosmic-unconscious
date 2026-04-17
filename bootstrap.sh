#!/bin/bash
# cosmic-unconscious bootstrap
# Usage: ./bootstrap.sh                    # Global only
#        ./bootstrap.sh katello            # Global + Katello
#        ./bootstrap.sh katello foreman    # Global + Katello + Foreman
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "cosmic-unconscious: deploying goose configuration..."
echo ""

# --- Always deploy global ---
echo "=== Global ==="

mkdir -p ~/.agents/skills ~/.config/goose ~/.local/share/goose/recipes

cp "$SCRIPT_DIR/global/config.yaml" ~/.config/goose/config.yaml
echo "  - config.yaml"

cp "$SCRIPT_DIR/global/guardrails.md" ~/.config/goose/guardrails.md
echo "  - guardrails.md"

cp "$SCRIPT_DIR/global/goosehints" ~/.config/goose/.goosehints
echo "  - global .goosehints"

for skill_dir in "$SCRIPT_DIR"/global/skills/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")
    rm -rf ~/.agents/skills/"$skill_name"
    cp -r "$skill_dir" ~/.agents/skills/"$skill_name"
    echo "  - skill: $skill_name"
done

for recipe_dir in "$SCRIPT_DIR"/recipes/*/; do
    [ -d "$recipe_dir" ] || continue
    recipe_name=$(basename "$recipe_dir")
    rm -rf ~/.local/share/goose/recipes/"$recipe_name"
    cp -r "$recipe_dir" ~/.local/share/goose/recipes/"$recipe_name"
    echo "  - recipe: $recipe_name"
done

# --- Deploy requested projects ---
for project in "$@"; do
    project_dir="$SCRIPT_DIR/projects/$project"
    if [ ! -d "$project_dir" ]; then
        echo ""
        echo "  WARNING: Project '$project' not found in projects/, skipping"
        continue
    fi

    echo ""
    echo "=== Project: $project ==="

    # Project-specific recipes → global recipes dir
    if [ -d "$project_dir/recipes" ]; then
        for recipe in "$project_dir"/recipes/*/; do
            [ -d "$recipe" ] || continue
            recipe_name=$(basename "$recipe")
            rm -rf ~/.local/share/goose/recipes/"$recipe_name"
            cp -r "$recipe" ~/.local/share/goose/recipes/"$recipe_name"
            echo "  - recipe: $recipe_name"
        done
    fi

    # Detect project path on this VM
    PROJECT_PATH=$(find /home/vagrant -maxdepth 2 -type d -name "$project" 2>/dev/null | head -1)

    if [ -n "$PROJECT_PATH" ]; then
        # Deploy .goosehints to project directory
        if [ -f "$project_dir/goosehints" ]; then
            cp "$project_dir/goosehints" "$PROJECT_PATH/.goosehints"
            echo "  - .goosehints → $PROJECT_PATH/"
        fi

        # Deploy project-level skills
        if [ -d "$project_dir/skills" ]; then
            mkdir -p "$PROJECT_PATH/.agents/skills"
            for skill_dir in "$project_dir"/skills/*/; do
                [ -d "$skill_dir" ] || continue
                skill_name=$(basename "$skill_dir")
                rm -rf "$PROJECT_PATH/.agents/skills/$skill_name"
                cp -r "$skill_dir" "$PROJECT_PATH/.agents/skills/$skill_name"
                echo "  - project skill: $skill_name"
            done
        fi
    else
        echo "  WARNING: $project directory not found on this VM, skipped local deployment"
    fi
done

# --- Shell environment ---
GOOSE_ENV_FILE=~/.goose_env
cat > "$GOOSE_ENV_FILE" << 'EOF'
export GOOSE_MOIM_MESSAGE_FILE="$HOME/.config/goose/guardrails.md"
export GOOSE_RECIPE_PATH="$HOME/.local/share/goose/recipes"
EOF

if ! grep -q "goose_env" ~/.bashrc 2>/dev/null; then
    echo "" >> ~/.bashrc
    echo 'source ~/.goose_env  # goose_env' >> ~/.bashrc
    echo ""
    echo "  - shell environment added to .bashrc"
fi

source "$GOOSE_ENV_FILE"

echo ""
echo "Done! Start a new session: goose session"
echo "   Slash commands: /bug  /design  /explore  /capture"
