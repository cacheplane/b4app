#!/bin/sh
# Put `agent-workspace` on PATH as a symlink to the CLI inside the installed app, so the CLI and the
# app always run the same version and the CLI finds the bundled coordinator.
#
#   ./Scripts/install-cli.sh            links into ~/.local/bin
#   ./Scripts/install-cli.sh /usr/local/bin
set -eu
TARGET_DIR="${1:-$HOME/.local/bin}"
for candidate in "/Applications/Agent Workspace.app" "$HOME/Applications/Agent Workspace.app" "$(dirname "$0")/../dist/Agent Workspace.app"; do
  if [ -x "$candidate/Contents/Helpers/agent-workspace" ]; then
    APP="$candidate"
    break
  fi
done
if [ -z "${APP:-}" ]; then
  echo "Agent Workspace.app with Contents/Helpers/agent-workspace not found in /Applications, ~/Applications, or dist/. Run Scripts/package.sh and copy the app first." >&2
  exit 1
fi
mkdir -p "$TARGET_DIR"
ln -sf "$APP/Contents/Helpers/agent-workspace" "$TARGET_DIR/agent-workspace"
echo "linked $TARGET_DIR/agent-workspace -> $APP/Contents/Helpers/agent-workspace"
case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *) echo "note: $TARGET_DIR is not on your PATH" ;;
esac
