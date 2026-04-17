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

    # Detect project path -- check sibling to this repo, then under $HOME
    if [ -d "$SCRIPT_DIR/../$project" ]; then
        PROJECT_PATH="$(cd "$SCRIPT_DIR/../$project" && pwd)"
    else
        PROJECT_PATH=$(find "$HOME" -maxdepth 2 -type d -name "$project" 2>/dev/null | head -1)
    fi

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

# --- GCP configuration ---
echo ""
echo "=== GCP Configuration ==="

# Pull existing values from goose_env if present
GOOSE_ENV_FILE=~/.goose_env
if [ -f "$GOOSE_ENV_FILE" ]; then
    _existing_project=$(grep '^export GCP_PROJECT_ID=' "$GOOSE_ENV_FILE" 2>/dev/null \
        | sed 's/^export GCP_PROJECT_ID="//' | sed 's/"$//')
    _existing_location=$(grep '^export GCP_LOCATION=' "$GOOSE_ENV_FILE" 2>/dev/null \
        | sed 's/^export GCP_LOCATION="//' | sed 's/"$//')
fi

if [ -n "$_existing_project" ]; then
    echo "  GCP Project ID: $_existing_project (from existing config)"
    GCP_PROJECT_ID="$_existing_project"
else
    read -rp "  GCP Project ID: " GCP_PROJECT_ID
fi

if [ -n "$_existing_location" ]; then
    echo "  GCP Location:   $_existing_location (from existing config)"
    GCP_LOCATION="$_existing_location"
else
    read -rp "  GCP Location:   " GCP_LOCATION
fi

if [ -z "$GCP_PROJECT_ID" ] || [ -z "$GCP_LOCATION" ]; then
    echo ""
    echo "  WARNING: GCP Project ID and Location are required."
    echo "           Re-run bootstrap.sh to set them."
fi

# --- Shell environment ---
cat > "$GOOSE_ENV_FILE" << EOF
export GOOSE_MOIM_MESSAGE_FILE="\$HOME/.config/goose/guardrails.md"
export GOOSE_RECIPE_PATH="\$HOME/.local/share/goose/recipes"
export GCP_PROJECT_ID="$GCP_PROJECT_ID"
export GCP_LOCATION="$GCP_LOCATION"
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
