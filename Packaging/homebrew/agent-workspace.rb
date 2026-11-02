# The Homebrew cask for the prod Mac app. Scripts/release-mac.sh copies this file into
# cacheplane/homebrew-tap as Casks/agent-workspace.rb when the tap has none yet, and rewrites the
# `version` and `sha256` lines below on every prod release; the zeros are a placeholder, never a real
# hash. Everything else is edited here and in the tap by hand (docs/release.md).
cask "agent-workspace" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/cacheplane/b4app/releases/download/mac-v#{version}/Agent-Workspace-#{version}.zip"
  name "Agent Workspace"
  desc "Workspace for Codex, Claude Code, and B4 agent conversations"
  homepage "https://b4.run/app/download"

  livecheck do
    url :url
    regex(/^mac-v(\d+(?:\.\d+)+)$/i)
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "Agent Workspace.app"
  binary "#{appdir}/Agent Workspace.app/Contents/Helpers/agent-workspace"

  uninstall launchctl: "com.cacheplane.b4app.coordinator",
            quit:      "com.cacheplane.b4app",
            delete:    "~/Library/LaunchAgents/com.cacheplane.b4app.coordinator.plist"

  zap trash: [
    "~/Library/Application Support/b4app",
    "~/Library/LaunchAgents/com.cacheplane.b4app.coordinator.plist",
  ]
end
