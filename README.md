# Résumé Parser for Salesforce

A Salesforce reference implementation that turns an uploaded résumé into structured **Work Experience**
records under a **Contact** through an in-chat Agentforce wizard. Released package **3.3.0-1**
(`04tbm000000j6Z7AAI`) is the production-installable bounded generic CMDT runtime. The public `force-app/`
source matches that packaged runtime; the Agent Script agent still publishes separately.

[![Salesforce API](https://img.shields.io/badge/Salesforce%20API-v66.0-blue)](https://developer.salesforce.com/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE.txt)

## 🎯 Overview

A recruiter opens the **Résumé Parser** agent, names the Contact the résumé is for, and — after the
agent resolves and confirms that Contact conversationally — an interactive wizard renders **right in
the chat** (a custom Lightning type). The wizard:

1. parses the uploaded PDF/PNG/JPG with a GenAI vision prompt template (no Document AI),
2. shows the parsed candidate info + a table of roles with a left/right pager,
3. lets the user inline-edit any field, then
4. saves `Work_Experience__c` children under a `Resume_Data__c` record **linked to the Contact**.

The Contact record page shows a **Resume Data** related list, so every committed résumé rolls up to
the candidate. Recommitting the same Draft replaces its role children rather than duplicating them.

| Confirm the Contact & upload | Review & edit parsed roles, then save |
|---|---|
| ![Résumé wizard — confirm Contact and upload the file](docs/screenshots/wizard-01-contact-upload.png) | ![Résumé wizard — parsed candidate info and roles with inline editing](docs/screenshots/wizard-02-parsed-roles.png) |

> The screenshots use intentionally altered, synthetic demonstration data. They do not show customer
> or employee records.

### What makes it work

- **In-chat wizard via a custom Lightning type** — the whole capture lives in the conversation, no
  page navigation. The agent renders the wizard as the sole action of its own subagent (the render
  rule) and hands off to it deterministically after the user confirms the Contact.
- **Standard CRM actions, not custom Apex, for contact resolution** — `IdentifyRecordByName` +
  `GetRecordDetails` find and enrich the Contact; Apex is reserved for JSON coercion and the
  idempotent write.
- **Draft-then-confirm** — upload creates a temporary Draft résumé and stores its file so the prompt
  can parse it. Work-experience children are written only after approval. In 3.3, parse failure and
  Re-upload remove the temporary Draft/file. Closing a session can still leave a Draft for administrator
  review.

---

## 🚀 Install

Choose the app distribution first, then install the separate Agent Script agent:

- **Released package 3.3.0-1 (`04tbm000000j6Z7AAI`)** — code-coverage validated at 92%, promoted to
  Released, production-installable, and contains the bounded generic CMDT runtime.
- **Current public source** — `force-app/` contains the same 3.3 app runtime and can be deployed directly
  to an appropriately enabled non-production org. For production, install the Released package.

The **Agent Script agent** can't be packaged (see [below](#whats-in-the-package-vs-the-agent-step)) and
publishes separately from `agent/`. Publishing the agent never upgrades the selected app distribution.

### 0. Prerequisites (one-time, per machine)

- **Salesforce CLI** with the agent plugin:
  ```bash
  sf --version                 # if missing, install from https://developer.salesforce.com/tools/salesforcecli
  sf plugins install agent
  ```
- **git** and **python3** (the agent script uses python3 to identify the exact version it published).
- A **target org with Agentforce / Einstein enabled** (Developer Edition or sandbox with Agentforce
  on). A bare scratch org can host the package but can't publish the agent.

### 1. Clone this repo

```bash
git clone https://github.com/salesforce/Resume_Parser.git
cd Resume_Parser
```

### 2. Authenticate your org and note its alias

```bash
sf org login web --alias my-org        # opens a browser; log into the target org
sf org list                            # confirm "my-org" is listed
```

`<your-org>` in every command below is that **alias** (or the full username). The CLI stores this
login globally on your machine, so you run the scripts from the cloned repo folder but they act on
whatever org you pass via `<your-org>` — the folder isn't tied to any org.

### 3. Install everything (choose one app track)

#### Track A — released package 3.3.0-1 (recommended; production-installable generic runtime)

```bash
./install.sh <your-org> 04tbm000000j6Z7AAI
```

#### Track B — matching 3.3 source deploy (non-production)

Use the no-package-ID path only in an appropriately enabled non-production org:

```bash
./install.sh <your-non-production-org>
```

The script runs the selected app track, publishes the separate agent, reconciles Agent Access, and assigns
the permission set. To run those steps individually:

```bash
# Track A app: released 3.3.0-1 bounded generic CMDT runtime
sf package install --package 04tbm000000j6Z7AAI --target-org <your-org> \
  --apex-compile package --wait 20 --no-prompt

# Track B app: matching 3.3 source (non-production)
sf project deploy start --source-dir force-app --target-org <your-org>

# Both tracks: publish the separate agent and reconcile its access
./deploy-agent.sh <your-org>

# Assign the permission set (existing assignments inherit the access update)
sf org assign permset --name "Resume_Parser_User" --target-org <your-org>
```

> **Use `--apex-compile package`** (not "compile all"). "Compile all" recompiles *every* Apex class
> already in your org — if any unrelated class has a pre-existing compile error, the whole install
> rolls back with a misleading error. Scoping compilation to the package avoids that.

### 4. Manual Setup verification

1. **Verify the Lightning Agentforce panel.** In Setup, open **Agentforce Agents**, select
   **Resume Parser Agent**, and confirm the version printed by `deploy-agent.sh` is Active. Verify the
   agent is available in the Lightning Agentforce panel your users will use. If it isn't, configure the
   supported employee-agent panel/channel in Setup for your org and release; do not edit generated agent
   metadata.
2. **Verify agent access.** The agent isn't in the package, so the packaged permission set intentionally
   has no pre-agent dependency. After activation, `deploy-agent.sh` calls `grant-agent-access.sh`, which
   retrieves the target's existing **Resume Parser User** set, adds only enabled access for
   `Resume_Parser_Agent` when needed, validates/deploys it, and retrieves it again to verify. In Setup →
   **Permission Sets → Resume Parser User → Agent Access**, confirm Resume Parser Agent is enabled and
   assigned users can select it in the intended panel. If the agent was published separately, run
   `./grant-agent-access.sh <your-org>`; it is idempotent.
3. **Add the related list.** Setup → Object Manager → **Contact** → Page Layouts → add the
   **Resume Data** related list, so parsed résumés show on the Contact.

### 5. Try it

Open the Agentforce panel and say **"add a résumé for [contact name]."** The agent resolves the
Contact, confirms it, and opens the upload wizard in the chat.

---

**Current released package:** `Resume Parser@3.3.0-1` → `04tbm000000j6Z7AAI` is code-coverage
validated at 92%, promoted to Released, production-installable, and contains the bounded generic CMDT
runtime. As an alternative to the Track A CLI command, install it via a browser URL, then continue with
the separate agent step:

```
Developer / Sandbox: https://test.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000j6Z7AAI
Production:          https://login.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000j6Z7AAI
```

> If installing via the browser URL, choose **"Compile only the Apex in the package"** (same reason
> as `--apex-compile package` above).

---

## What's in the package vs. the agent step

GenAI metadata **does** package in a 2GP unlocked package — confirmed by building a code-coverage
validated version (prompt template + GenAiFunction + custom Lightning type + Einstein-calling Apex).
Two requirements make it work, both already configured here:
- `packageMetadataAccess: { "permissionSets": ["EinsteinGPTPromptTemplateManager"] }` in `sfdx-project.json`
- the package-validation scratch org enables Einstein (`Einstein1AIPlatform` + `enableEinsteinGptPlatform`)

The **one thing that can't be packaged** is the agent itself: it's a next-gen **Agent Script (ASL)**
agent, and `sf agent generate template` (the supported "package an agent as a template" path)
explicitly does not support Agent-Script agents. So the agent ships as a source bundle under
`agent/` and installs via `deploy-agent.sh` (deploy → `sf agent publish` → identify the new version →
activate that exact version → idempotently reconcile permission-set agent access). The packaged/source
permission set stays agent-independent so an initial package install cannot fail before the separate agent
exists. Panel availability is then verified/configured through supported Setup UI; the script never edits
generated Bot or planner metadata.

| Distribution layer | Capability | Installs via |
|---|---|---|
| **Released app package 3.3.0-1** | Production-installable bounded generic CMDT runtime | unlocked package `04tbm000000j6Z7AAI` |
| **Matching app source** | Same 3.3 app runtime for non-production source deployment | `force-app/` source deploy |
| **Agent** (Agent Script) + post-publish access | Separate from either app distribution; does not upgrade app runtime | `agent/`, `grant-agent-access.sh` via `deploy-agent.sh` |

For the deeper architecture (diagrams, decisions, data model), see
[`RESUME_PARSER_ARCHITECTURE.md`](RESUME_PARSER_ARCHITECTURE.md).

---

## Requirements

- Target org has **Einstein / Agentforce** enabled. A Developer Edition or sandbox with Agentforce
  on works; a bare scratch org can host the package but typically can't publish the agent without
  Agentforce provisioning.
- `sf` CLI with the `agent` plugin (`sf plugins install agent`). API 66.0+.

## Verified

### Released package 3.3.0-1

- `04tbm000000j6Z7AAI` is code-coverage validated at 92%, promoted to Released, and installable in
  production or non-production orgs.
- It contains the bounded generic CMDT runtime, generic defaults, Candidate Website field/FLS/layout,
  fail-closed mapping validation, and current Draft/file cleanup.
- The matching source passed full source deployment validation and focused Apex 22/22 in enabled
  non-production orgs.

## Manual steps the platform can't automate

| Step | Where | Why |
|---|---|---|
| Verify/configure the intended **Lightning Agentforce panel** | Setup → Agentforce Agents → Resume Parser Agent | Surface/channel availability varies by org and release; use supported Setup UI, not generated metadata edits |
| Add the **Resume Data** related list to the **Contact** layout | Setup → Object Manager → Contact → Page Layouts | A package shouldn't overwrite a subscriber's standard Contact layout |
| Verify post-publish **agent access** | Setup → Permission Sets → Resume Parser User → Agent Access | `deploy-agent.sh` runs the idempotent `grant-agent-access.sh`; verify the resulting target metadata and panel selector |
| Assign **Resume Parser User** to end users | Setup → Permission Sets | One set grants data, Apex, flow, and the post-publish agent access; existing assignments inherit updates |

## Notes

- In released package/source 3.3, committing the same Draft résumé replaces its work-experience children;
  parse failure and Re-upload remove the current temporary Draft/file. Closing the session can still leave
  an unconfirmed Draft that the adopting org should handle through its retention policy.
- Supported file types: `.pdf`, `.png`, `.jpg` (`.jpeg` is unreliable for vision — convert to `.jpg`).

## Versions

**Current Released package/source: v3.3.0-1** — makes the extraction prompt **fully CMDT-driven**: the
`Extract_Work_Experience` template no longer hardcodes the field schema; the entire key list (candidate
keys + the `workExperiences[]` role keys) is built from the active `Resume_Field_Map__mdt` rows by
`ResumeParsing.buildExtraInstructions()` and injected via the template's `ExtraInstructions` input.
An admin can add or tune candidate/role fields through CMDT without named Apex DTO members or named LWC
controls. Apex returns generic field envelopes and the LWC repeats metadata-driven inputs/table columns;
commit sends parse-key/value envelopes back to a fresh server-side map and uses dynamic `SObject.put`.
The runtime allowlist is deliberately narrow: direct fields on `Resume_Data__c` (candidate scope) and
`Work_Experience__c` (repeating role scope) only, with supported compatible types Text, Email, Phone, URL,
Date, Checkbox, Number, and configured Picklist. Each active editable target field may have **exactly one**
mapping per allowed object; duplicate `{Target_Object__c, Target_Field_API_Name__c}` targets fail closed as
a configuration error rather than rendering duplicate controls or relying on sort/last-write behavior.
Relationship paths, other objects, duplicate keys/targets, the candidate-scope structural key
`workExperiences`, missing/incompatible fields, and invalid generic picklists remain visible as ignored rows
and never enter prompt, UI, or DML. `Show_In_Review__c` controls
inclusion; `Read_Only__c` disables editing and prevents commit. Candidate Website is an ordinary URL mapping,
and configured picklists contribute prompt guidance plus safe case/space/hyphen normalization before an
explicit `Other` fallback. Every supported visible role field remains represented in the parsed-roles table.
At narrow Agentforce widths the table uses stable per-type/label widths and wrapped cell text while
`lightning-datatable` owns one continuous built-in horizontal scroll surface. No outer nested scroller,
dynamic column hiding, or persistence change is used.

**Admin field workflow:** an admin can add a future `Candidate_Linkedin__c`-style field without Apex/LWC.
Create a direct field on Resume Data or Work Experience; grant readable/editable FLS to intended users and
**Resume Parser User**; verify there is no existing active editable mapping to that exact object/field; create
exactly one active map with a unique parse key, compatible type, extraction hint, prompt/review/read-only
flags, deterministic order, target-active Picklist values when applicable, and an optional type-compatible
Default Value only when blank model output should be guessed/defaulted. Close and reopen the wizard
after metadata changes—`getFieldMap()` is cacheable and the component loads mappings when it connects—then
confirm **How fields map** reports Editable and test hint-driven extraction, review, and persistence in a
non-production org. An `Ignored:` issue is fail-closed, not a partial write; correct the configuration/FLS,
then reopen. New objects, relationship paths, or unsupported widgets require reviewed source changes.

The `Candidate_Website__c` field, layout placement, and Resume Parser User FLS are included in released
package/source 3.3. Its CMDT mapping is intentionally absent. Create exactly one compatible Website mapping
using the workflow above; later edit that row rather than adding a duplicate. The same one-field/one-map
rule applies to future `Candidate_Linkedin__c`-style fields.

| CMDT Data Type | Compatible described target type |
|---|---|
| `Text` | String or Text Area |
| `Email` | Email or String |
| `Phone` | Phone or String |
| `URL` | URL or String |
| `Date` | Date only; defaults must exactly match valid `YYYY`, `YYYY-MM`, or `YYYY-MM-DD` calendar values |
| `Checkbox` | Boolean only |
| `Number` | Integer, Double, Currency, or Percent |
| `Picklist` | Picklist only; every mapping must explicitly configure values and each must be active on the target picklist |

`Default_Value__c` is an optional generic blank-input policy. It is applied only when the model returns an
empty value; an explicit recognized value always wins. Defaults use the same type/picklist coercion and make
a mapping inert when invalid. Mappings without a default remain blank.

The shipped Employment Type mapping keeps seven values and a cue-based closest-value hint. It configures
`Default_Value__c=Full-time`: contract/contractor/consultant cues map to Contract, freelance/self-employed
to Freelance, intern to Internship, temporary/seasonal to Temporary, and no such cue defaults to Full-time.
An explicit unsupported type still maps to `Other`, and the field remains visible/editable for human review.

The single (v1) template version runs on **GPT-5 Mini** (`sfdc_ai__DefaultGPT5Mini`). Released 3.3 also
removes temporary Draft/files after parse failure or Re-upload. The separate agent lifecycle uses
exact-version activation without editing generated planner metadata.

**Current built / Released: `04tbm000000j6Z7AAI` (v3.3.0-1)** — code-coverage validated at 92%,
promoted to Released, and production-installable. This is the version to install for the bounded generic
CMDT runtime.

All earlier versions are **deprecated** — install v3.3.0-1:
- `04tHu000004hhiJIAQ` (v3.2.1-1) — production-installable historical package with older hardcoded-schema behavior.
- `04tHu000004hhiEIAQ` (v3.2.0-1) — field-map disclosure, but the agent won't publish on current Agentforce (dedicated contactId input).
- `04tHu000004hhi4IAA` (v3.1.0-1) — data-driven `Resume_Field_Map__mdt` field map, but the agent won't publish on current Agentforce.
- `04tHu000004hhWpIAI` (v3.0.1-1) — hardcoded field mapping; single `Resume_Parser_User` permission set and themed wizard.
- `04tHu000004hhWkIAI` (v3.0.0-1) — same as 3.0.1 but built before the theme comments were genericized.
- `04tHu000004hhWfIAI` (v2.0.0-1) — skip-validation beta (sandbox/dev only), two permission sets, un-themed wizard.
- `04tHu000004hhWaIAI` (v1.0.0-1) — initial release.

To rebuild after future changes (the Einstein scratch-def is required so the validation org has the
prompt-template feature):

```bash
sf package version create --package "Resume Parser" --definition-file config/project-scratch-def.json \
  --code-coverage --installation-key-bypass --wait 90 --target-dev-hub <hub>
sf package version promote --package "Resume Parser@<new>" --no-prompt --target-dev-hub <hub>
```
