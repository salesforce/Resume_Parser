## Security

Please report any security issue to [https://www.sfdc.co/SubmitVuln](https://www.sfdc.co/SubmitVuln)
as soon as it is discovered. This project limits its runtime dependencies in
order to reduce the total cost of ownership as much as can be, but all consumers
should remain vigilant and have their security stakeholders review all third-party
products (3PP) like this one and their dependencies.

## Security model (by design — review before adopting)

- **System-mode writes.** The Apex runs `with sharing`, but the dynamic field writes in
  `ResumeParsing.putCoerced` intentionally do **not** enforce per-field CRUD/FLS. This matches the
  original direct-assignment behavior and avoids silently dropping fields for a user who does not yet
  have FLS (e.g. immediately after a fresh package install, before the permission set is assigned).
  Access is instead controlled by who can invoke the wizard and who is assigned the permission set.
- **Broad object access in the permission set.** `Resume Parser User` currently grants
  View All / Modify All on `Resume_Data__c` and `Work_Experience__c` so any assigned user can see and
  edit all parsed résumés (collaborative recruiting default). If your org needs record-level isolation,
  tighten this set to object CRUD without View All/Modify All and rely on sharing.
- **AI extraction.** Uploaded résumé files are sent to the org's configured Einstein/Agentforce model
  via the `Extract_Work_Experience` prompt template. Review your org's data-handling/trust settings for those model calls.
- **Temporary draft retention.** Upload persists a Draft `Resume_Data__c` record and its file before
  user confirmation because the prompt is grounded on the stored `ContentDocument`. In unreleased 3.3
  source, parse failure and the Re-upload action remove the current temporary Draft/file. Released package
  3.2.1 predates that cleanup. In either version, closing the session without Re-upload or Save can leave
  a Draft; adopting orgs should apply an appropriate retention policy for unconfirmed résumé data.
- **Demonstration media.** Repository screenshots use intentionally altered, synthetic data and do not
  contain customer or employee records.
