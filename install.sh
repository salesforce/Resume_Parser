#!/usr/bin/env bash
#
# Résumé Parser — one-command installer.
#
# Installs the whole solution into a target org using one explicitly selected app track:
#   1a. with a package id: install that exact package. The current public Released package,
#       3.2.1-1 / 04tHu000004hhiJIAQ, retains its older hardcoded extraction schema.
#   1b. without a package id: deploy current 3.3.0.NEXT force-app source, which contains the
#       bounded generic CMDT runtime but is not yet a newly built/promoted package.
#   2. publish/activate the separate Agentforce agent and reconcile its access. This agent step
#      never upgrades the app runtime selected in step 1 — see deploy-agent.sh and
#      grant-agent-access.sh.
#      The agent installs separately because it is an Agent Script agent, which the platform
#      cannot package (sf agent generate template doesn't support Agent Script agents).
#
# Usage:
#   ./install.sh <target-org-alias-or-username> [package-version-id 04t...]
#
# Omit the package version id only for a source deployment to an appropriately enabled
# non-production org. For production package installation, build, validate, and promote a new
# package version from exact 3.3 source, then pass that new 04t id to this script.

set -euo pipefail

ORG="${1:?Usage: ./install.sh <target-org> [04t-package-version-id]}"
PKG_VERSION="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "▸ Installing Résumé Parser into: $ORG"

# ── 1. Full app ──────────────────────────────────────────────────────────────
if [[ -n "$PKG_VERSION" ]]; then
  echo "▸ [1/2] Installing exact app package $PKG_VERSION ..."
  echo "  Note: public Released package 3.2.1-1 uses its older hardcoded extraction schema;"
  echo "  installing it does not install the current-source bounded generic CMDT runtime."
  # --apex-compile package: compile ONLY this package's Apex, not every class in the org.
  # "compile all" rolls the install back if any unrelated org class has a pre-existing error.
  sf package install --package "$PKG_VERSION" --target-org "$ORG" --apex-compile package --wait 20 --no-prompt --publish-wait 20
else
  echo "▸ [1/2] Deploying current 3.3.0.NEXT app as source (no package id supplied) ..."
  echo "  This source contains the bounded generic CMDT runtime and is not a promoted package."
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

Distribution check:
  • Package id 04tHu000004hhiJIAQ installs Released 3.2.1-1 with older hardcoded-schema behavior.
  • Omitting a package id deploys current 3.3.0.NEXT source with the bounded generic CMDT runtime.
  • Publishing the agent does not convert or upgrade one app distribution into the other.

Remaining one-time manual steps (platform can't automate these):
  • In Setup → Agentforce Agents, open Resume Parser Agent and verify the exact version printed
    by deploy-agent.sh is Active and available in the Lightning Agentforce panel your users use.
    If needed, configure the supported employee-agent panel/channel for your org and release.
  • Add the "Resume Data" related list to the Contact page layout
      Setup → Object Manager → Contact → Page Layouts → (your layout) → Related Lists
  • Agent access is reconciled idempotently after publication by deploy-agent.sh because the
    packaged permission set cannot reference an agent that does not exist yet. If you publish
    separately, run: ./grant-agent-access.sh <target-org>
  • Assign "Resume Parser User" to your end users. Existing assignments automatically inherit
    the post-publish agent-access update.
  • Current 3.3.0.NEXT source only: Candidate Website field/FLS/layout ship without a CMDT mapping.
    After a 3.3 source deploy—or a future package built/promoted from that source—grant FLS, create
    exactly one compatible active mapping with an extraction hint and optional type-compatible
    Default Value, then close/reopen the wizard and confirm disclosure. Released package 3.2.1-1
    does not include this generic admin workflow.

Then open the Agentforce panel and say: "I want to add a resume."
DONE
