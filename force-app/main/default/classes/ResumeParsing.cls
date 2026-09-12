/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 * For full license text, see the LICENSE.txt file in the repo root or
 * https://opensource.org/licenses/Apache-2.0
 */

/**
 * @description Shared resume-parsing utilities for the in-chat résumé wizard.
 *
 * Owns: LLM-JSON cleanup, the CMDT-driven field map (Resume_Field_Map__mdt), value
 * coercion (date/checkbox/picklist/number/text), JSON -> editable drafts (preview),
 * drafts -> Work_Experience__c child rows, candidate fields -> Resume_Data__c parent,
 * and the concurrency-safe "replace the child set under a parent lock" commit.
 *
 * The map is DATA (Resume_Field_Map__mdt), so an admin can retarget or tune the existing typed
 * candidate/role wire keys without changing the prompt template. A brand-new wire key still needs
 * a matching Apex DTO member and LWC review control. Target_Object__c routes a mapping to the parent
 * (Resume_Data__c) or the repeating work-experience child rows (Work_Experience__c).
 *
 * Nothing here calls the LLM or queries for the file — pure transformation + DML.
 */
public with sharing class ResumeParsing {

    public static final Integer MAX_ROWS = 50;

    // Fallback picklist values, used only when a Picklist mapping has no Picklist_Values__c set.
    public static final List<String> EMPLOYMENT_TYPES = new List<String>{
        'Full-time', 'Part-time', 'Contract', 'Internship', 'Temporary', 'Freelance', 'Other'
    };

    // Test seam: let tests inject mappings instead of relying on deployed CMDT rows.
    @TestVisible private static List<Resume_Field_Map__mdt> overrideMappings = null;

    /**
     * @description The editable shape for one role. Returned to the LWC for preview/edit,
     * and accepted back from the LWC on commit. @AuraEnabled so it crosses to the wire.
     * The member names ARE the CMDT Parse Keys (the single wire contract), which is why
     * a draft can be round-tripped through a Parse-Key-keyed Map (see toDrafts/commitDrafts).
     */
    public class WorkExperienceDraft {
        @AuraEnabled public String rowId;            // client-side key for the LWC (not persisted)
        @AuraEnabled public String company;
        @AuraEnabled public String title;
        @AuraEnabled public String startDate;        // ISO-ish string; coerced to Date on commit
        @AuraEnabled public String endDate;
        @AuraEnabled public Boolean isCurrent;
        @AuraEnabled public String location;
        @AuraEnabled public String employmentType;
        @AuraEnabled public String description;
    }

    /** The editable candidate-level (résumé) fields, sent back from the wizard on commit. */
    public class CandidateDraft {
        @AuraEnabled public String candidateName;
        @AuraEnabled public String candidateEmail;
        @AuraEnabled public String candidatePhone;
        @AuraEnabled public String summary;
    }

    /** Candidate-level + roles, returned by the wizard's uploadAndParse. */
    public class ParseResult {
        @AuraEnabled public String resumeDataId;
        @AuraEnabled public String candidateName;
        @AuraEnabled public String candidateEmail;
        @AuraEnabled public String candidatePhone;
        @AuraEnabled public String summary;
        @AuraEnabled public List<WorkExperienceDraft> workExperiences = new List<WorkExperienceDraft>();
    }

    /**
     * @description A read-only projection of one Resume_Field_Map__mdt row for the wizard's
     * "How fields map" disclosure — so a user can see, in-chat, where each parsed value lands
     * without opening Setup. Built by fieldMapViews(); never used for parsing/commit.
     */
    public class FieldMapView {
        @AuraEnabled public String parseKey;
        @AuraEnabled public String targetObject;
        @AuraEnabled public String targetField;
        @AuraEnabled public String targetLabel;   // resolved field label (best-effort), else null
        @AuraEnabled public String dataType;
        @AuraEnabled public Boolean showInReview;
        @AuraEnabled public Boolean readOnly;
        @AuraEnabled public Decimal sortOrder;
    }

    // ── Mapping access ──────────────────────────────────────────────────────

    private static List<Resume_Field_Map__mdt> activeMappings() {
        if (overrideMappings != null) { return overrideMappings; }
        return [
            SELECT DeveloperName, Label, Parse_Key__c, Extraction_Hint__c, Target_Object__c,
                   Target_Field_API_Name__c, Data_Type__c, Picklist_Values__c, Max_Length__c,
                   Include_In_Prompt__c, Show_In_Review__c, Read_Only__c, Is_Active__c, Sort_Order__c
            FROM Resume_Field_Map__mdt
            WHERE Is_Active__c = true
            ORDER BY Sort_Order__c NULLS LAST
        ];
    }

    /** Active mappings whose Target Object is the given object (parent vs. child routing). */
    private static List<Resume_Field_Map__mdt> mappingsFor(String targetObject) {
        List<Resume_Field_Map__mdt> out = new List<Resume_Field_Map__mdt>();
        for (Resume_Field_Map__mdt m : activeMappings()) {
            if (targetObject.equalsIgnoreCase(m.Target_Object__c)) { out.add(m); }
        }
        return out;
    }

    /**
     * @description Read-only projection of the active field map for the wizard disclosure. Resolves
     * each target field's label from the object describe (best-effort — null if the field can't be
     * resolved, never throws). Ordered by Sort Order (activeMappings already orders). No DML.
     */
    public static List<FieldMapView> fieldMapViews() {
        Map<String, Map<String, Schema.SObjectField>> fieldsByObject =
            new Map<String, Map<String, Schema.SObjectField>>{
                'Resume_Data__c'     => Resume_Data__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap(),
                'Work_Experience__c' => Work_Experience__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap()
            };
        List<FieldMapView> views = new List<FieldMapView>();
        for (Resume_Field_Map__mdt m : activeMappings()) {
            FieldMapView v = new FieldMapView();
            v.parseKey     = m.Parse_Key__c;
            v.targetObject = m.Target_Object__c;
            v.targetField  = m.Target_Field_API_Name__c;
            v.dataType     = m.Data_Type__c;
            v.showInReview = m.Show_In_Review__c == true;
            v.readOnly     = m.Read_Only__c == true;
            v.sortOrder    = m.Sort_Order__c;
            Map<String, Schema.SObjectField> fmap = String.isBlank(m.Target_Object__c)
                ? null : fieldsByObject.get(m.Target_Object__c);
            if (fmap != null && String.isNotBlank(m.Target_Field_API_Name__c)) {
                Schema.SObjectField sof = fmap.get(m.Target_Field_API_Name__c.toLowerCase());
                if (sof != null) { v.targetLabel = sof.getDescribe().getLabel(); }
            }
            views.add(v);
        }
        return views;
    }

    /**
     * @description Build the ENTIRE extraction schema from the active CMDT rows — the prompt template
     * has NO hardcoded field names, so this method is the single source of truth for what the AI is
     * asked to return. Candidate-level rows (Target Object = Resume_Data__c) become top-level keys;
     * work-experience rows (Target Object = Work_Experience__c) become the keys of each object inside a
     * "workExperiences" array. Each promptable row (Include_In_Prompt = true) is emitted exactly once
     * with a type-aware format instruction plus the admin's Extraction Hint. Fed into the template via
     * {!$Input:ExtraInstructions}; the template just wraps it in braces and the JSON rules. Existing
     * typed wire keys can be retargeted or tuned in CMDT without a template change; brand-new keys
     * still require Apex DTO and LWC support.
     */
    public static String buildExtraInstructions() {
        List<String> candLines = new List<String>();
        List<String> weLines = new List<String>();
        for (Resume_Field_Map__mdt m : activeMappings()) {
            if (m.Include_In_Prompt__c != true || String.isBlank(m.Parse_Key__c)) { continue; }
            String hintText = String.isBlank(m.Extraction_Hint__c) ? '' : m.Extraction_Hint__c.trim();
            String tail = m.Data_Type__c == 'Checkbox' ? ' Use false if not indicated.' : ' Empty string if not found.';
            String keyDesc = (schemaGuidance(m.Data_Type__c) + hintText + tail).trim();  // 'desc' is a reserved Apex identifier
            String body = '"' + m.Parse_Key__c + '": "' + keyDesc + '"';
            if ('Work_Experience__c'.equalsIgnoreCase(m.Target_Object__c)) { weLines.add('      ' + body); }
            else { candLines.add('  ' + body); }
        }
        List<String> parts = new List<String>(candLines);
        if (!weLines.isEmpty()) {
            parts.add('  "workExperiences": [\n    {\n' + String.join(weLines, ',\n') + '\n    }\n  ]');
        }
        return String.join(parts, ',\n');
    }

    /** Type-aware formatting guidance prepended to each key's description so values come back clean. */
    private static String schemaGuidance(String dataType) {
        if (dataType == 'Number') { return 'A plain number with no symbols or commas. '; }
        if (dataType == 'Date')   { return 'A date formatted YYYY-MM-DD (or YYYY-MM / YYYY if only partly known). '; }
        if (dataType == 'Checkbox') { return 'A boolean true/false. '; }
        return '';
    }

    /**
     * @description Parse the LLM's raw JSON string into a ParseResult of editable drafts, driven by
     * the CMDT map: candidate-level rows (Target Object = Resume_Data__c) are read from the top level;
     * work-experience rows (Target Object = Work_Experience__c) are read from each element of the
     * workExperiences[] array. Each value is coerced per its Data Type / Max Length / Picklist Values.
     * No DML. Used to populate the wizard's preview.
     */
    public static ParseResult toDrafts(String rawJson) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(stripCodeFences(rawJson));

        // Candidate-level: build a Parse-Key-keyed map of coerced values, then hydrate the typed
        // ParseResult from it (member names == parse keys, so a JSON round-trip binds them).
        Map<String, Object> candVals = new Map<String, Object>();
        for (Resume_Field_Map__mdt m : mappingsFor('Resume_Data__c')) {
            candVals.put(m.Parse_Key__c, coerceForDraft(parsed.get(m.Parse_Key__c), m));
        }
        ParseResult out = (ParseResult) JSON.deserialize(JSON.serialize(candVals), ParseResult.class);
        out.workExperiences = new List<WorkExperienceDraft>();

        List<Resume_Field_Map__mdt> weMappings = mappingsFor('Work_Experience__c');
        List<Object> exps = (parsed.get('workExperiences') instanceof List<Object>)
            ? (List<Object>) parsed.get('workExperiences')
            : new List<Object>();

        Integer count = 0;
        for (Object o : exps) {
            if (count >= MAX_ROWS) { break; }
            if (!(o instanceof Map<String, Object>)) { continue; }
            Map<String, Object> item = (Map<String, Object>) o;

            Map<String, Object> row = new Map<String, Object>{ 'rowId' => 'row-' + count };
            for (Resume_Field_Map__mdt m : weMappings) {
                row.put(m.Parse_Key__c, coerceForDraft(item.get(m.Parse_Key__c), m));
            }
            out.workExperiences.add(
                (WorkExperienceDraft) JSON.deserialize(JSON.serialize(row), WorkExperienceDraft.class));
            count++;
        }
        return out;
    }

    /**
     * @description Commit a set of drafts as the children of a parent resume, replacing any
     * existing children — driven by the CMDT map (Work_Experience__c rows). Concurrency-safe:
     * locks the parent first so racing transactions serialize, then deletes + inserts so the
     * result is exactly one clean set (handles the Atlas-planner-fires-twice case and re-runs
     * identically). Returns the inserted rows.
     */
    public static List<Work_Experience__c> commitDrafts(Id resumeId, List<WorkExperienceDraft> drafts) {
        // Serialize concurrent commits against the same parent and fail clearly if it is gone.
        List<Resume_Data__c> lockedParents = [
            SELECT Id FROM Resume_Data__c WHERE Id = :resumeId FOR UPDATE
        ];
        if (lockedParents.isEmpty()) {
            throw new AuraHandledException('The resume record no longer exists.');
        }

        Map<String, Schema.SObjectField> weFields = Work_Experience__c.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();
        List<Resume_Field_Map__mdt> weMappings = mappingsFor('Work_Experience__c');

        List<Work_Experience__c> rows = new List<Work_Experience__c>();
        Integer count = 0;
        if (drafts != null) {
            for (WorkExperienceDraft d : drafts) {
                if (count >= MAX_ROWS) { break; }
                // The draft's member names are the CMDT parse keys, so serialize→untyped gives a
                // Parse-Key-keyed map the commit loop can read from generically.
                Map<String, Object> vals = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(d));

                Work_Experience__c we = new Work_Experience__c(Resume_Data__c = resumeId);
                for (Resume_Field_Map__mdt m : weMappings) {
                    if (m.Read_Only__c == true) { continue; }   // read-only reference fields never commit
                    putCoerced(we, weFields, m, vals.get(m.Parse_Key__c));
                }

                // External key is the dedupe identity (company|title|startDate) — domain logic, not a
                // field mapping — so it reads the stable parse keys directly.
                String company = truncate(asString(vals.get('company')), 255);
                String title   = truncate(asString(vals.get('title')), 255);
                Date startDate = parseDate(asString(vals.get('startDate')));
                we.External_Key__c = buildExternalKey(resumeId, company, title, startDate);

                rows.add(we);
                count++;
            }
        }

        delete [SELECT Id FROM Work_Experience__c WHERE Resume_Data__c = :resumeId];
        insert rows;
        return rows;
    }

    /**
     * @description Apply candidate-level (Resume_Data__c) values onto the parent record via the CMDT
     * map, given a Parse-Key-keyed map of values (e.g. from a CandidateDraft or a ParseResult).
     * Dynamic put per field via putCoerced (system-mode; no per-field FLS gate — see putCoerced's
     * note on why). The caller owns the DML.
     */
    public static void applyCandidateFields(Resume_Data__c parent, Map<String, Object> vals) {
        if (vals == null) { return; }
        Map<String, Schema.SObjectField> rdFields = Resume_Data__c.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();
        for (Resume_Field_Map__mdt m : mappingsFor('Resume_Data__c')) {
            if (m.Read_Only__c == true) { continue; }
            putCoerced(parent, rdFields, m, vals.get(m.Parse_Key__c));
        }
    }

    /**
     * @description Dynamic assignment of one coerced value onto a record, per the mapping's Data Type.
     * Skips blank target fields and unknown/typo field names (so a bad mapping is inert rather than
     * fatal). This class is `with sharing` and the wizard write is admin-driven, matching the original
     * behavior of assigning the fields directly — no per-field FLS gate (which would silently drop
     * fields for any user not granted FLS on them, e.g. before the permission set is assigned).
     */
    private static void putCoerced(SObject rec, Map<String, Schema.SObjectField> fields,
                                   Resume_Field_Map__mdt m, Object rawVal) {
        String apiName = m.Target_Field_API_Name__c;
        if (String.isBlank(apiName)) { return; }
        Schema.SObjectField sof = fields.get(apiName.toLowerCase());
        if (sof == null) { return; }

        String dt = m.Data_Type__c;
        if (dt == 'Date') {
            rec.put(apiName, parseDate(asString(rawVal)));
        } else if (dt == 'Checkbox') {
            rec.put(apiName, asBoolean(rawVal));
        } else if (dt == 'Number') {
            rec.put(apiName, parseNumber(asString(rawVal)));
        } else if (dt == 'Picklist') {
            rec.put(apiName, coercePicklist(asString(rawVal), m));
        } else {
            rec.put(apiName, truncate(asString(rawVal), maxLenOf(m)));   // Text / Email / Phone
        }
    }

    /** Coerce a raw JSON value into the string/boolean a draft field expects, per the mapping. */
    private static Object coerceForDraft(Object rawVal, Resume_Field_Map__mdt m) {
        String dt = m.Data_Type__c;
        if (dt == 'Checkbox') { return asBoolean(rawVal); }
        if (dt == 'Date')     { return normalizeDateString(asString(rawVal)); }
        if (dt == 'Picklist') { return coercePicklist(asString(rawVal), m); }
        return truncate(asString(rawVal), maxLenOf(m));   // Text / Email / Phone / Number (as string)
    }

    private static Integer maxLenOf(Resume_Field_Map__mdt m) {
        return m.Max_Length__c == null ? null : Integer.valueOf(m.Max_Length__c);
    }

    /** Allowed picklist values for a mapping — the CMDT list, falling back to EMPLOYMENT_TYPES. */
    private static List<String> picklistValuesOf(Resume_Field_Map__mdt m) {
        if (String.isBlank(m.Picklist_Values__c)) { return EMPLOYMENT_TYPES; }
        List<String> out = new List<String>();
        for (String part : m.Picklist_Values__c.split('[\\r\\n,]+')) {
            if (String.isNotBlank(part)) { out.add(part.trim()); }
        }
        return out.isEmpty() ? EMPLOYMENT_TYPES : out;
    }

    /** Snap a value to one of the mapping's allowed picklist values; unknown non-blank → 'Other' if allowed. */
    private static String coercePicklist(String s, Resume_Field_Map__mdt m) {
        if (String.isBlank(s)) { return null; }
        List<String> allowed = picklistValuesOf(m);
        for (String v : allowed) {
            if (v.equalsIgnoreCase(s.trim())) { return v; }
        }
        for (String v : allowed) {
            if (v.equalsIgnoreCase('Other')) { return 'Other'; }
        }
        return null;
    }

    // ── Coercion / formatting helpers ──

    /** Removes ```json ... ``` fences the LLM sometimes wraps around the output. */
    public static String stripCodeFences(String raw) {
        if (String.isBlank(raw)) { return '{}'; }
        String s = raw.trim();
        if (s.startsWith('```')) {
            s = s.replaceFirst('^```[a-zA-Z]*\\s*', '');
            if (s.endsWith('```')) {
                s = s.substring(0, s.length() - 3);
            }
        }
        Integer first = s.indexOf('{');
        Integer last  = s.lastIndexOf('}');
        if (first >= 0 && last > first) {
            s = s.substring(first, last + 1);
        }
        return s.trim();
    }

    public static String asString(Object o) {
        return o == null ? null : String.valueOf(o).trim();
    }

    public static Boolean asBoolean(Object o) {
        if (o instanceof Boolean) { return (Boolean) o; }
        if (o == null) { return false; }
        String s = String.valueOf(o).trim().toLowerCase();
        return s == 'true' || s == 'yes' || s == 'current' || s == 'present';
    }

    /** Truncate to max; null/blank → null; a null max means "no limit". */
    public static String truncate(String s, Integer max) {
        if (String.isBlank(s)) { return null; }
        if (max == null) { return s; }
        return s.length() > max ? s.substring(0, max) : s;
    }

    /** Strip everything but digits/decimal/sign; parse to Decimal. Null on failure. */
    public static Decimal parseNumber(String s) {
        if (String.isBlank(s)) { return null; }
        String t = s.replaceAll('[^0-9.\\-]', '');
        if (String.isBlank(t)) { return null; }
        try { return Decimal.valueOf(t); } catch (Exception e) { return null; }
    }

    /** Accepts YYYY-MM-DD, YYYY-MM, or YYYY; returns null on anything else. */
    public static Date parseDate(String s) {
        if (String.isBlank(s)) { return null; }
        String t = s.trim();
        if (t.equalsIgnoreCase('present') || t.equalsIgnoreCase('current')) { return null; }
        try {
            Pattern p = Pattern.compile('^(\\d{4})(?:-(\\d{1,2}))?(?:-(\\d{1,2}))?');
            Matcher mm = p.matcher(t);
            if (mm.find()) {
                Integer y = Integer.valueOf(mm.group(1));
                Integer mo = mm.group(2) != null ? Integer.valueOf(mm.group(2)) : 1;
                Integer d = mm.group(3) != null ? Integer.valueOf(mm.group(3)) : 1;
                if (mo < 1 || mo > 12) { mo = 1; }
                if (d < 1 || d > 28) { d = 1; }
                return Date.newInstance(y, mo, d);
            }
        } catch (Exception ignored) { /* fall through */ }
        return null;
    }

    /** Normalize a date string for display in the editor (round-trips through parseDate). */
    public static String normalizeDateString(String s) {
        Date d = parseDate(s);
        return d == null ? null : String.valueOf(d);  // yyyy-MM-dd
    }

    /** Kept for back-compat; picklist coercion is now CMDT-driven via coercePicklist. */
    public static String coerceEmploymentType(String s) {
        if (String.isBlank(s)) { return null; }
        for (String valid : EMPLOYMENT_TYPES) {
            if (valid.equalsIgnoreCase(s.trim())) { return valid; }
        }
        return 'Other';
    }

    public static String buildExternalKey(Id resumeId, String company, String title, Date startDate) {
        String sd = startDate == null ? '' : String.valueOf(startDate);
        return (String.valueOf(resumeId) + '|' + (company == null ? '' : company)
            + '|' + (title == null ? '' : title) + '|' + sd).left(255);
    }
}
