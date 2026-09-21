#!/usr/bin/env bash
#
# Idempotently grant the separately published Résumé Parser agent to the existing
# Resume Parser User permission set. The packaged/source permission set intentionally
# has no pre-agent dependency; this helper runs only after agent publication.
#
# Usage: ./grant-agent-access.sh <target-org-alias-or-username>

set -euo pipefail

ORG="${1:?Usage: ./grant-agent-access.sh <target-org>}"
PERMISSION_SET="Resume_Parser_User"
AGENT_API_NAME="Resume_Parser_Agent"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJECT="$TMP/project"
mkdir -p "$PROJECT/force-app"
cat > "$PROJECT/sfdx-project.json" <<'JSON'
{
  "packageDirectories": [
    { "path": "force-app", "default": true }
  ],
  "name": "Resume Parser Agent Access Grant",
  "namespace": "",
  "sourceApiVersion": "66.0"
}
JSON

echo "▸ Retrieving the current $PERMISSION_SET permission set from $ORG ..."
(
  cd "$PROJECT"
  sf project retrieve start \
    --metadata "PermissionSet:$PERMISSION_SET" \
    --target-org "$ORG" \
    --wait 15
)

PERMISSION_FILE="$PROJECT/force-app/main/default/permissionsets/$PERMISSION_SET.permissionset-meta.xml"
if [[ ! -f "$PERMISSION_FILE" ]]; then
  echo "✗ Permission set $PERMISSION_SET was not retrieved. Install the app before publishing the agent." >&2
  exit 1
fi

CHANGED="$(python3 - "$PERMISSION_FILE" "$AGENT_API_NAME" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, agent_name = sys.argv[1:]
namespace = 'http://soap.sforce.com/2006/04/metadata'
ET.register_namespace('', namespace)
tree = ET.parse(path)
root = tree.getroot()
q = lambda name: f'{{{namespace}}}{name}'

matches = []
for access in root.findall(q('agentAccesses')):
    if access.findtext(q('agentName')) == agent_name:
        matches.append(access)
if len(matches) > 1:
    raise SystemExit(f'Permission set contains duplicate agent access rows for {agent_name}.')

changed = False
if matches:
    enabled = matches[0].find(q('enabled'))
    if enabled is None:
        enabled = ET.SubElement(matches[0], q('enabled'))
    if enabled.text != 'true':
        enabled.text = 'true'
        changed = True
else:
    access = ET.Element(q('agentAccesses'))
    ET.SubElement(access, q('agentName')).text = agent_name
    ET.SubElement(access, q('enabled')).text = 'true'
    root.insert(0, access)
    changed = True

if changed:
    ET.indent(tree, space='    ')
    tree.write(path, encoding='UTF-8', xml_declaration=True)
print('true' if changed else 'false')
PY
)"

if [[ "$CHANGED" == "true" ]]; then
  echo "▸ Validating the post-agent permission-set grant ..."
  (
    cd "$PROJECT"
    sf project deploy start \
      --dry-run \
      --metadata "PermissionSet:$PERMISSION_SET" \
      --target-org "$ORG" \
      --wait 15
  )

  echo "▸ Granting $AGENT_API_NAME access in $PERMISSION_SET ..."
  (
    cd "$PROJECT"
    sf project deploy start \
      --metadata "PermissionSet:$PERMISSION_SET" \
      --target-org "$ORG" \
      --wait 15
  )
else
  echo "▸ $AGENT_API_NAME access is already enabled in $PERMISSION_SET; no deployment needed."
fi

# Retrieve again and verify the resulting org metadata rather than trusting deploy output alone.
VERIFY="$TMP/verify"
mkdir -p "$VERIFY/force-app"
cp "$PROJECT/sfdx-project.json" "$VERIFY/sfdx-project.json"
(
  cd "$VERIFY"
  sf project retrieve start \
    --metadata "PermissionSet:$PERMISSION_SET" \
    --target-org "$ORG" \
    --wait 15
)
python3 - "$VERIFY/force-app/main/default/permissionsets/$PERMISSION_SET.permissionset-meta.xml" "$AGENT_API_NAME" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, agent_name = sys.argv[1:]
namespace = 'http://soap.sforce.com/2006/04/metadata'
root = ET.parse(path).getroot()
q = lambda name: f'{{{namespace}}}{name}'
rows = [
    (access.findtext(q('agentName')), access.findtext(q('enabled')))
    for access in root.findall(q('agentAccesses'))
    if access.findtext(q('agentName')) == agent_name
]
if rows != [(agent_name, 'true')]:
    raise SystemExit(f'Agent-access verification failed: {rows!r}')
print(f'✓ Verified {agent_name} access is enabled in the target permission set.')
PY
