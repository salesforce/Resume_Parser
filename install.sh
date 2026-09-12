#!/usr/bin/env bash
#
# Résumé Parser — one-command installer.
#
# Installs the whole solution into a target org:
#   1. the unlocked FULL-APP package (objects, Apex, wizard LWC + custom Lightning type,
#      GenAI prompt template, GenAiFunction, flows, permission sets) — GenAI metadata
#      packages fine in 2GP with packageMetadataAccess + an Einstein-enabled scratch def
#   2. the Agentforce agent (publish + exact-version activate) — see deploy-agent.sh
#      The agent installs separately because it is an Agent Script agent, which the platform
#      cannot package (sf agent generate template doesn't support Agent Script agents).
#
# Usage:
#   ./install.sh <target-org-alias-or-username> [package-version-id 04t...]
#
# If you omit the package version id, the script deploys the app as source instead
# (handy for a dev/sandbox install without a promoted package).

set -euo pipefail

ORG="${1:?Usage: ./install.sh <target-org> [04t-package-version-id]}"
PKG_VERSION="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "▸ Installing Résumé Parser into: $ORG"

# ── 1. Full app ──────────────────────────────────────────────────────────────
if [[ -n "$PKG_VERSION" ]]; then
  echo "▸ [1/2] Installing app package $PKG_VERSION ..."
  # --apex-compile package: compile ONLY this package's Apex, not every class in the org.
  # "compile all" rolls the install back if any unrelated org class has a pre-existing error.
  sf package install --package "$PKG_VERSION" --target-org "$ORG" --apex-compile package --wait 20 --no-prompt --publish-wait 20
else
  echo "▸ [1/2] Deploying app as source (no package id supplied) ..."
  sf project deploy start --source-dir "$HERE/force-app" --target-org "$ORG"
fi

# ── 2. Agent (Agent Script — can't be packaged) ──────────────────────────────
echo "▸ [2/2] Deploying + activating the agent ..."
"$HERE/deploy-agent.sh" "$ORG"

# ── Permission set ───────────────────────────────────────────────────────────
echo "▸ Assigning the Resume Parser User permission set to you ($ORG running user) ..."
sf org assign permset --name "Resume_Parser_User" --target-org "$ORG"

cat <<'DONE'

✅ Install complete.

Remaining one-time manual steps (platform can't automate these):
  • In Setup → Agentforce Agents, open Resume Parser Agent and verify the exact version printed
    by deploy-agent.sh is Active and available in the Lightning Agentforce panel your users use.
    If needed, configure the supported employee-agent panel/channel for your org and release.
  • Add the "Resume Data" related list to the Contact page layout
      Setup → Object Manager → Contact → Page Layouts → (your layout) → Related Lists
  • Grant agent access (the agent isn't in the package, so the packaged permset can't
    reference it). Add to the Resume Parser User permission set, then re-assign:
      <agentAccesses><agentName>Resume_Parser_Agent</agentName><enabled>true</enabled></agentAccesses>
  • Assign "Resume Parser User" to your end users.

Then open the Agentforce panel and say: "I want to add a resume."
DONE
