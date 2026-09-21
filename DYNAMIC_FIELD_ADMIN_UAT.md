# Post-Release Admin Dynamic Field Smoke Test and Video Script

This is a recommended post-release/admin smoke test, not a pre-push gate. Record PASS/FAIL and report findings through the normal issue/support channel so future mapping or documentation improvements can be evaluated.

## Acceptance contract

An admin can configure a shipped or future résumé field without Apex/LWC when:

1. The field is a direct field on `Resume_Data__c` or `Work_Experience__c`.
2. Intended users and `Resume Parser User` have readable/editable FLS.
3. Exactly one active editable `Resume_Field_Map__mdt` row targets `{Target_Object__c, Target_Field_API_Name__c}`.
4. `Data_Type__c` is compatible with the described target field.
5. Picklist mappings contain only active target-picklist values.
6. The row has a unique parse key that is not reserved structural key `workExperiences`, plus extraction hint, prompt/review/read-only/active settings, deterministic order, and an optional compatible Default Value only when blank model output should be guessed/defaulted.
7. The wizard is closed and reopened after metadata changes; `getFieldMap()` is cacheable and the LWC loads mappings when it connects.

Invalid mappings are visible as `Ignored:` and are inert: no prompt key, control, column, or DML.

## Recommended owner smoke video — Candidate Website mapping

`Candidate_Website__c`, its layout placement, and Resume Parser User FLS ship in source. The CMDT mapping does **not** ship; the owner video creates it as the no-code admin proof. Target duration: 5–8 minutes. Use a non-production org and sanitized résumé.

### 1. Establish baseline

- Show exact package/source version, candidate SHA if available, and target org.
- In Object Manager, show `Resume_Data__c.Candidate_Website__c` exists and is Text(255).
- In Resume Parser User, show readable/editable Candidate Website FLS and preserved Resume Parser Agent access.
- Query/open Resume Field Maps and prove zero active editable rows target `Resume_Data__c.Candidate_Website__c`.
- If one exists, stop and edit that row; never create a duplicate.

### 2. Create exactly one mapping

Create one Resume Field Map record:

| Setting | Value |
|---|---|
| Label | Candidate Website |
| Parse Key | `candidateWebsite` |
| Target Object | `Resume_Data__c` |
| Target Field | `Candidate_Website__c` |
| Data Type | `URL` |
| Max Length | `255` |
| Include In Prompt | true |
| Show In Review | true |
| Read Only | false |
| Is Active | true |
| Sort Order | an unused deterministic value |
| Extraction Hint | `The candidate's website or portfolio URL.` |
| Default Value | blank — missing Website evidence must remain blank |

Before save, reconfirm no other active editable mapping targets Candidate Website.

### 3. Refresh runtime metadata

- Close any open wizard/panel session.
- Open a fresh Resume Parser Agent session and wizard.
- Do not rely on a wizard opened before the metadata change.

### 4. Verify disclosure, hint, and review

- Open **How fields map**.
- Confirm `candidateWebsite` is Editable with the correct target and URL type.
- Upload a sanitized résumé containing a website.
- Show the extraction hint contributes the prompt key/value.
- Confirm the generic Candidate Website URL control renders without a code deployment.
- Edit to a unique proof URL.

### 5. Verify persistence

- Save.
- Query the exact `Resume_Data__c` id and show `Candidate_Website__c` equals the reviewed URL.
- Show no Apex/LWC/source deployment occurred between mapping creation and persistence.

### 6. Verify Read Only and restore editability

- Change the same mapping to Read Only=true.
- Close/reopen the wizard.
- Confirm Candidate Website is still represented but the generic control is disabled.
- Verify the saved Website value is unchanged and no client-supplied edit is written.
- Restore Read Only=false, close/reopen, and confirm editability returns. Do not create a second mapping.

### 7. Record result and cleanup decision

Record:

- field and FLS evidence;
- CMDT DeveloperName and all values;
- disclosure/review screenshots or video timestamps;
- exact Resume Data id and bounded SOQL result;
- package/source SHA;
- data retention or cleanup decision;
- PASS or FAIL, with an issue link for any failure.

After the video, future behavior changes must edit this one mapping rather than create another target collision.

## Future Candidate LinkedIn-style field

The same workflow supports `Candidate_Linkedin__c` without Apex/LWC:

1. Create a direct URL or Text(255) field on Resume Data.
2. Grant Resume Parser User FLS.
3. Confirm no active editable map targets it.
4. Create exactly one `candidateLinkedin` URL mapping with hint `The candidate's LinkedIn profile URL.`
5. Close/reopen the wizard.
6. Verify disclosure, hint-driven extraction, generic review, and persistence.

New target objects, relationship paths, formulas/computed fields, or unsupported widgets still require reviewed source changes.

## Responsive parsed-role table QA

At a narrow Agentforce panel width:

- verify every Show-in-Review role field remains a column;
- verify complete labels/values are discoverable through one continuous horizontal gesture;
- verify scrolling does not stop at an outer wrapper and require a second gesture;
- verify keyboard navigation remains on the datatable grid;
- never hide a column or change persistence to reduce table density.

## Error recovery

| Disclosure issue | Recovery |
|---|---|
| Duplicate active editable target | Remove/deactivate the extra row or edit the existing mapping. Never resolve by sort order. |
| Reserved candidate key `workExperiences` | Choose a unique candidate key; `workExperiences` exclusively names the repeating role array. |
| Unsupported object or relationship path | Use a direct field on Resume Data or Work Experience. |
| Incompatible data type | Choose the compatible CMDT type or correct the field type. |
| Invalid Picklist values | Configure only active target-picklist values. |
| Invalid Default Value | Remove it or configure a compatible value. Date defaults must be real calendar values in exact `YYYY`, `YYYY-MM`, or `YYYY-MM-DD` form. |
| Unexpected guessing/defaulting | Clear Default Value, close/reopen, and verify missing evidence remains blank. |
| Field missing after valid change | Close/reopen the wizard; verify FLS, active/show settings, and disclosure. |
| Read-only unexpectedly | Set Read Only=false, reopen, and verify user FLS. |

## Post-video checklist

- [ ] Non-production org and sanitized input used.
- [ ] Candidate Website field exists and FLS is readable/editable.
- [ ] Resume Parser Agent access and user assignment preserved.
- [ ] Baseline proved zero active Candidate Website target mappings.
- [ ] Exactly one Candidate Website mapping created.
- [ ] Unique parse key and extraction hint verified.
- [ ] URL-to-Text compatibility verified.
- [ ] Default Value policy recorded (blank for Candidate Website).
- [ ] Fresh wizard opened after metadata change.
- [ ] Disclosure reports Editable, not Ignored.
- [ ] Hint-driven prompt extraction observed.
- [ ] Generic review control rendered without code deployment.
- [ ] Reviewed value persisted to Candidate Website.
- [ ] Read Only=true produced a disabled control and no write.
- [ ] Read Only=false was restored and editability returned after reopen.
- [ ] No duplicate target mapping exists after proof.
- [ ] Narrow role table exposes all visible columns in one continuous scroll surface.
- [ ] Test data retention/cleanup decision recorded.
- [ ] Video/result link and PASS or FAIL recorded in post-release evidence.

This checklist does not block source publication. Report failures with the field, mapping, org, source/package version, disclosure text, bounded query result, and video timestamp.
