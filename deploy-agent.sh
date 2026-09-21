#!/usr/bin/env bash
#
# Publish and activate the Résumé Parser Agentforce agent.
#
# Publishing runs in a temporary DX project. Salesforce CLI retrieves the generated metadata into
# that temporary directory so this script can read the exact version it created; the files are never
# edited, redeployed, or written into the source checkout.
#
# Usage: ./deploy-agent.sh <target-org-alias-or-username>

set -euo pipefail

ORG="${1:?Usage: ./deploy-agent.sh <target-org>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_NAME="Resume_Parser_Agent"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJECT="$TMP/project"
mkdir -p "$PROJECT/agent/main/default/aiAuthoringBundles"
cp -R "$HERE/agent/main/default/aiAuthoringBundles/$API_NAME" \
  "$PROJECT/agent/main/default/aiAuthoringBundles/"

cat > "$PROJECT/sfdx-project.json" <<'JSON'
{
  "packageDirectories": [
    { "path": "agent", "default": true }
  ],
  "name": "Resume Parser Agent Publisher",
  "namespace": "",
  "sourceApiVersion": "66.0"
}
JSON

echo "▸ Publishing authoring bundle ..."
(
  cd "$PROJECT"
  # Verbose JSON includes the exact generated GenAiPlannerBundle name (…_vN). Generated metadata
  # remains isolated in the temporary project and is deleted on exit.
  sf agent publish authoring-bundle \
    --api-name "$API_NAME" \
    --target-org "$ORG" \
    --verbose \
    --json > "$TMP/publish.json"
)

PUBLISHED_VERSION="$(python3 - "$TMP/publish.json" "$API_NAME" <<'PY'
import json, re, sys
result = json.load(open(sys.argv[1])).get('result') or {}
if result.get('success') is not True:
    raise SystemExit('Agent publish did not report success.')
api_name = re.escape(sys.argv[2])
pattern = re.compile(r'^GenAiPlannerBundle:' + api_name + r'_v([0-9]+)$')
versions = [match.group(1) for item in result.get('retrievedComponents') or []
            if (match := pattern.match(item))]
if len(versions) != 1:
    raise SystemExit('Publish result did not identify exactly one generated agent version.')
print(versions[0])
PY
)"

if [[ -z "$PUBLISHED_VERSION" ]]; then
  echo "✗ Publish succeeded, but its exact generated version could not be identified." >&2
  echo "  No version was activated. Inspect Agentforce Agents in Setup." >&2
  exit 1
fi

echo "▸ Activating exact published version v${PUBLISHED_VERSION} ..."
sf agent activate \
  --api-name "$API_NAME" \
  --version "$PUBLISHED_VERSION" \
  --target-org "$ORG"

# The permission set ships in the package before the Agent Script agent exists, so it cannot carry
# this dependency in package/source metadata. Reconcile the exact agent access after publication;
# the helper retrieves the target permission set first and changes only this access row.
echo "▸ Reconciling post-publish agent access ..."
"$HERE/grant-agent-access.sh" "$ORG"

cat <<DONE

✓ Agent published, exact version v${PUBLISHED_VERSION} activated, and Resume Parser User agent access verified.

Manual Setup verification (required):
  1. In Setup, open Agentforce Agents and select Resume Parser Agent.
  2. Confirm version v${PUBLISHED_VERSION} is Active.
  3. Verify the agent is selectable in the Lightning Agentforce panel your users use.
     If that panel surface isn't available, configure it through the supported Agentforce Setup UI
     for your org/release. Do not edit or redeploy generated agent metadata.
  4. Assign Resume Parser User to the intended users; existing assignments inherit the verified
     agent-access update without being recreated.
  5. Candidate Website field/FLS/layout ship without a CMDT mapping. To enable it—or add a
     future supported field—grant FLS, create exactly one compatible mapping with a hint and
     optional Default Value, then close/reopen the wizard and confirm disclosure. Edit an existing
     target mapping instead of adding a duplicate.
DONE
