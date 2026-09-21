/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 * For full license text, see the LICENSE.txt file in the repo root or
 * https://opensource.org/licenses/Apache-2.0
 */

/**
 * @description CMDT-driven résumé parsing, review envelopes, coercion, and persistence.
 *
 * Active Resume_Field_Map__mdt rows are the runtime allowlist. A row can target only
 * Resume_Data__c (candidate scope) or Work_Experience__c (repeating role scope), must name a
 * real direct field, and must use a supported/compatible data type. Invalid rows remain visible
 * in the disclosure with an issue but are excluded from prompt, review, and DML.
 *
 * Writes remain system-mode as in the original implementation; this refactor does not silently
 * introduce a per-field FLS contract. The strict boundary is metadata routing + object/type checks.
 */
public with sharing class ResumeParsing {

    public static final Integer MAX_ROWS = 50;
    private static final String CANDIDATE_SCOPE = 'Resume_Data__c';
    private static final String ROLE_SCOPE = 'Work_Experience__c';
    private static final Set<String> SUPPORTED_TYPES = new Set<String>{
        'Text', 'Email', 'Phone', 'URL', 'Date', 'Checkbox', 'Number', 'Picklist'
    };

    @TestVisible private static List<Resume_Field_Map__mdt> overrideMappings = null;

    /** One generic editable value plus the trusted display metadata projected from CMDT. */
    public class FieldDraft {
        @AuraEnabled public String parseKey;
        @AuraEnabled public String label;
        @AuraEnabled public String targetObject;
        @AuraEnabled public String targetField;
        @AuraEnabled public String dataType;
        @AuraEnabled public String value;       // canonical wire string; checkbox uses "true"/"false"
        @AuraEnabled public Boolean showInReview;
        @AuraEnabled public Boolean readOnly;
        @AuraEnabled public Decimal sortOrder;
        @AuraEnabled public String inputKind;   // input | textarea | checkbox | picklist
        @AuraEnabled public String inputType;   // lightning-input type where inputKind=input
        @AuraEnabled public List<String> options = new List<String>();
    }

    /** One repeating role. Stable rowId is UI identity only; fields are generic envelopes. */
    public class WorkExperienceDraft {
        @AuraEnabled public String rowId;
        @AuraEnabled public List<FieldDraft> fields = new List<FieldDraft>();
    }

    /** Generic candidate fields plus generic repeating role rows. */
    public class ParseResult {
        @AuraEnabled public String resumeDataId;
        @AuraEnabled public List<FieldDraft> candidateFields = new List<FieldDraft>();
        @AuraEnabled public List<WorkExperienceDraft> workExperiences = new List<WorkExperienceDraft>();
    }

    /** Disclosure row, including invalid active mappings that are excluded from review and DML. */
    public class FieldMapView {
        @AuraEnabled public String parseKey;
        @AuraEnabled public String targetObject;
        @AuraEnabled public String targetField;
        @AuraEnabled public String targetLabel;
        @AuraEnabled public String dataType;
        @AuraEnabled public String defaultValue;
        @AuraEnabled public Boolean showInReview;
        @AuraEnabled public Boolean readOnly;
        @AuraEnabled public Decimal sortOrder;
        @AuraEnabled public Boolean supported;
        @AuraEnabled public String issue;
        @AuraEnabled public String inputKind;
        @AuraEnabled public String inputType;
        @AuraEnabled public List<String> options = new List<String>();
    }

    // ── Mapping access and validation ──────────────────────────────────────

    private static List<Resume_Field_Map__mdt> activeMappings() {
        if (overrideMappings != null) { return overrideMappings; }
        return [
            SELECT DeveloperName, Label, Parse_Key__c, Extraction_Hint__c, Target_Object__c,
                   Target_Field_API_Name__c, Data_Type__c, Default_Value__c, Picklist_Values__c, Max_Length__c,
                   Include_In_Prompt__c, Show_In_Review__c, Read_Only__c, Is_Active__c, Sort_Order__c
            FROM Resume_Field_Map__mdt
            WHERE Is_Active__c = true
            ORDER BY Sort_Order__c NULLS LAST
        ];
    }

    private static String canonicalScope(String targetObject) {
        if (CANDIDATE_SCOPE.equalsIgnoreCase(targetObject)) { return CANDIDATE_SCOPE; }
        if (ROLE_SCOPE.equalsIgnoreCase(targetObject)) { return ROLE_SCOPE; }
        return null;
    }

    private static Map<String, Schema.SObjectField> fieldsForScope(String scope) {
        if (scope == CANDIDATE_SCOPE) {
            return Resume_Data__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();
        }
        if (scope == ROLE_SCOPE) {
            return Work_Experience__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();
        }
        return null;
    }

    private static Schema.SObjectField resolveField(Map<String, Schema.SObjectField> fields, String apiName) {
        if (fields == null || String.isBlank(apiName) || apiName.contains('.')) { return null; }
        Schema.SObjectField out = fields.get(apiName);
        return out == null ? fields.get(apiName.toLowerCase()) : out;
    }

    private static Map<String, Integer> parseKeyCounts(List<Resume_Field_Map__mdt> rows) {
        Map<String, Integer> counts = new Map<String, Integer>();
        for (Resume_Field_Map__mdt m : rows) {
            String scope = canonicalScope(m.Target_Object__c);
            if (scope == null || String.isBlank(m.Parse_Key__c)) { continue; }
            String key = scope + '|' + m.Parse_Key__c.trim().toLowerCase();
            counts.put(key, (counts.containsKey(key) ? counts.get(key) : 0) + 1);
        }
        return counts;
    }

    private static Map<String, Integer> editableTargetCounts(List<Resume_Field_Map__mdt> rows) {
        Map<String, Integer> counts = new Map<String, Integer>();
        for (Resume_Field_Map__mdt m : rows) {
            String scope = canonicalScope(m.Target_Object__c);
            if (scope == null || m.Read_Only__c == true || String.isBlank(m.Target_Field_API_Name__c)
                || m.Target_Field_API_Name__c.contains('.')) { continue; }
            String key = scope + '|' + m.Target_Field_API_Name__c.trim().toLowerCase();
            counts.put(key, (counts.containsKey(key) ? counts.get(key) : 0) + 1);
        }
        return counts;
    }

    private static Boolean typeCompatible(String configuredType, Schema.DescribeFieldResult field) {
        String actual = String.valueOf(field.getType()).toLowerCase();
        if (configuredType == 'Date') { return actual == 'date'; }
        if (configuredType == 'Checkbox') { return actual == 'boolean'; }
        if (configuredType == 'Number') {
            return new Set<String>{'integer', 'double', 'currency', 'percent'}.contains(actual);
        }
        if (configuredType == 'Picklist') { return actual == 'picklist'; }
        if (configuredType == 'Email') { return actual == 'email' || actual == 'string'; }
        if (configuredType == 'Phone') { return actual == 'phone' || actual == 'string'; }
        if (configuredType == 'URL') { return actual == 'url' || actual == 'string'; }
        return configuredType == 'Text' && new Set<String>{'string', 'textarea'}.contains(actual);
    }

    private static Boolean picklistValuesCompatible(Resume_Field_Map__mdt m, Schema.DescribeFieldResult field) {
        List<String> configured = picklistValuesOf(m);
        if (configured.isEmpty()) { return false; }
        Set<String> activeTargetValues = new Set<String>();
        for (Schema.PicklistEntry entry : field.getPicklistValues()) {
            if (entry.isActive()) { activeTargetValues.add(entry.getValue()); }
        }
        for (String value : configured) {
            if (!activeTargetValues.contains(value)) { return false; }
        }
        return true;
    }

    private static Boolean matchesAllowedPicklistValue(String value, Resume_Field_Map__mdt m) {
        String normalized = normalizePicklistToken(value);
        for (String option : picklistValuesOf(m)) {
            if (normalizePicklistToken(option) == normalized) { return true; }
        }
        return false;
    }

    private static String defaultValueIssue(Resume_Field_Map__mdt m) {
        if (String.isBlank(m.Default_Value__c)) { return null; }
        String value = m.Default_Value__c.trim();
        if (m.Data_Type__c == 'Date' && parseDate(value) == null) {
            return 'Configured Default Value is not a valid Date.';
        }
        if (m.Data_Type__c == 'Checkbox'
            && value.toLowerCase() != 'true' && value.toLowerCase() != 'false') {
            return 'Configured Default Value for Checkbox must be true or false.';
        }
        if (m.Data_Type__c == 'Number' && parseNumber(value) == null) {
            return 'Configured Default Value is not a valid Number.';
        }
        if (m.Data_Type__c == 'Picklist' && !matchesAllowedPicklistValue(value, m)) {
            return 'Configured Default Value must match an allowed Picklist Value.';
        }
        return null;
    }

    private static String mappingIssue(Resume_Field_Map__mdt m, Map<String, Integer> parseCounts,
                                       Map<String, Integer> targetCounts) {
        String scope = canonicalScope(m.Target_Object__c);
        if (scope == null) { return 'Unsupported target object; only Resume_Data__c and Work_Experience__c are allowed.'; }
        if (String.isBlank(m.Parse_Key__c)) { return 'Parse key is required.'; }
        if (scope == CANDIDATE_SCOPE && 'workExperiences'.equalsIgnoreCase(m.Parse_Key__c.trim())) {
            return 'Reserved parse key; workExperiences is the repeating-role envelope.';
        }
        String countKey = scope + '|' + m.Parse_Key__c.trim().toLowerCase();
        if (parseCounts.get(countKey) > 1) { return 'Duplicate parse key in the same scope.'; }
        if (!SUPPORTED_TYPES.contains(m.Data_Type__c)) { return 'Unsupported data type.'; }
        if (String.isBlank(m.Target_Field_API_Name__c) || m.Target_Field_API_Name__c.contains('.')) {
            return 'A direct target field is required; relationship paths are not allowed.';
        }
        String targetKey = scope + '|' + m.Target_Field_API_Name__c.trim().toLowerCase();
        if (m.Read_Only__c != true && targetCounts.get(targetKey) > 1) {
            return 'Duplicate active editable target field in the same scope; each writable field requires exactly one mapping.';
        }
        Schema.SObjectField sof = resolveField(fieldsForScope(scope), m.Target_Field_API_Name__c);
        if (sof == null) { return 'Target field does not exist on the allowed object.'; }
        Schema.DescribeFieldResult describe = sof.getDescribe();
        if (describe.isCalculated() || describe.isAutoNumber()) { return 'Calculated or auto-number target fields are not writable.'; }
        if (!typeCompatible(m.Data_Type__c, describe)) { return 'Configured data type is incompatible with the target field.'; }
        if (m.Data_Type__c == 'Picklist' && picklistValuesOf(m).isEmpty()) {
            return 'Picklist Values are required for this mapping.';
        }
        if (m.Data_Type__c == 'Picklist' && !picklistValuesCompatible(m, describe)) {
            return 'Configured Picklist Values must be active values on the target picklist.';
        }
        String defaultIssue = defaultValueIssue(m);
        if (defaultIssue != null) { return defaultIssue; }
        return null;
    }

    private static List<Resume_Field_Map__mdt> validMappingsFor(String requestedScope) {
        List<Resume_Field_Map__mdt> allRows = activeMappings();
        Map<String, Integer> parseCounts = parseKeyCounts(allRows);
        Map<String, Integer> targetCounts = editableTargetCounts(allRows);
        List<Resume_Field_Map__mdt> out = new List<Resume_Field_Map__mdt>();
        for (Resume_Field_Map__mdt m : allRows) {
            String scope = canonicalScope(m.Target_Object__c);
            if (scope == requestedScope && mappingIssue(m, parseCounts, targetCounts) == null) { out.add(m); }
        }
        return out;
    }

    private static FieldMapView viewFor(Resume_Field_Map__mdt m, String issue) {
        FieldMapView v = new FieldMapView();
        v.parseKey = m.Parse_Key__c;
        v.targetObject = m.Target_Object__c;
        v.targetField = m.Target_Field_API_Name__c;
        v.dataType = m.Data_Type__c;
        v.defaultValue = m.Default_Value__c;
        v.showInReview = m.Show_In_Review__c == true;
        v.readOnly = m.Read_Only__c == true;
        v.sortOrder = m.Sort_Order__c;
        v.supported = issue == null;
        v.issue = issue;
        v.options = m.Data_Type__c == 'Picklist' ? picklistValuesOf(m) : new List<String>();

        String scope = canonicalScope(m.Target_Object__c);
        Schema.SObjectField sof = resolveField(fieldsForScope(scope), m.Target_Field_API_Name__c);
        if (sof != null) { v.targetLabel = sof.getDescribe().getLabel(); }
        setInputShape(v, sof == null ? null : String.valueOf(sof.getDescribe().getType()).toLowerCase());
        return v;
    }

    private static void setInputShape(FieldMapView v, String actualType) {
        if (v.dataType == 'Picklist') { v.inputKind = 'picklist'; return; }
        if (v.dataType == 'Checkbox') { v.inputKind = 'checkbox'; return; }
        if (v.dataType == 'Text' && actualType == 'textarea') { v.inputKind = 'textarea'; return; }
        v.inputKind = 'input';
        if (v.dataType == 'Email') { v.inputType = 'email'; }
        else if (v.dataType == 'Phone') { v.inputType = 'tel'; }
        else if (v.dataType == 'URL') { v.inputType = 'url'; }
        else if (v.dataType == 'Date') { v.inputType = 'date'; }
        else if (v.dataType == 'Number') { v.inputType = 'number'; }
        else { v.inputType = 'text'; }
    }

    /** All active rows for disclosure; invalid rows remain visible with supported=false + issue. */
    public static List<FieldMapView> fieldMapViews() {
        List<Resume_Field_Map__mdt> rows = activeMappings();
        Map<String, Integer> parseCounts = parseKeyCounts(rows);
        Map<String, Integer> targetCounts = editableTargetCounts(rows);
        List<FieldMapView> views = new List<FieldMapView>();
        for (Resume_Field_Map__mdt m : rows) {
            views.add(viewFor(m, mappingIssue(m, parseCounts, targetCounts)));
        }
        return views;
    }

    // ── Prompt schema and generic review envelopes ─────────────────────────

    public static String buildExtraInstructions() {
        List<String> candLines = new List<String>();
        List<String> roleLines = new List<String>();
        List<Resume_Field_Map__mdt> candidateMappings = validMappingsFor(CANDIDATE_SCOPE);
        List<Resume_Field_Map__mdt> roleMappings = validMappingsFor(ROLE_SCOPE);
        for (Resume_Field_Map__mdt m : candidateMappings) {
            if (m.Include_In_Prompt__c == true) { candLines.add('  ' + promptLine(m)); }
        }
        for (Resume_Field_Map__mdt m : roleMappings) {
            if (m.Include_In_Prompt__c == true) { roleLines.add('      ' + promptLine(m)); }
        }
        List<String> parts = new List<String>(candLines);
        if (!roleLines.isEmpty()) {
            parts.add('  "workExperiences": [\n    {\n' + String.join(roleLines, ',\n') + '\n    }\n  ]');
        }
        return String.join(parts, ',\n');
    }

    private static String promptLine(Resume_Field_Map__mdt m) {
        String hintText = String.isBlank(m.Extraction_Hint__c) ? '' : m.Extraction_Hint__c.trim();
        List<String> options = m.Data_Type__c == 'Picklist' ? picklistValuesOf(m) : new List<String>();
        String allowed = options.isEmpty() ? '' : ' Allowed values: ' + String.join(options, ', ') + '.';
        String defaultGuidance = String.isBlank(m.Default_Value__c)
            ? '' : ' Configured default when the extracted value is empty: ' + m.Default_Value__c.trim() + '.';
        String tail = String.isNotBlank(m.Default_Value__c)
            ? ' Use the configured default if no value is found.'
            : (m.Data_Type__c == 'Checkbox' ? ' Use false if not indicated.' : ' Empty string if not found.');
        String description = (schemaGuidance(m.Data_Type__c) + hintText + allowed + defaultGuidance + tail).trim();
        // Admin-authored keys and hints can contain quotes, slashes, or newlines. Serialize both
        // strings so one mapping can never corrupt the complete generated JSON schema.
        return JSON.serialize(m.Parse_Key__c) + ': ' + JSON.serialize(description);
    }

    private static String schemaGuidance(String dataType) {
        if (dataType == 'Number') { return 'A plain number with no symbols or commas. '; }
        if (dataType == 'Date') { return 'A date formatted YYYY-MM-DD (or YYYY-MM / YYYY if only partly known). '; }
        if (dataType == 'Checkbox') { return 'A boolean true/false. '; }
        if (dataType == 'URL') { return 'A complete URL. '; }
        return '';
    }

    public static ParseResult toDrafts(String rawJson) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(stripCodeFences(rawJson));
        ParseResult out = new ParseResult();
        for (Resume_Field_Map__mdt m : validMappingsFor(CANDIDATE_SCOPE)) {
            out.candidateFields.add(toFieldDraft(m, parsed.get(m.Parse_Key__c)));
        }

        List<Resume_Field_Map__mdt> roleMappings = validMappingsFor(ROLE_SCOPE);
        List<Object> roles = parsed.get('workExperiences') instanceof List<Object>
            ? (List<Object>) parsed.get('workExperiences') : new List<Object>();
        Integer count = 0;
        for (Object roleObject : roles) {
            if (count >= MAX_ROWS) { break; }
            if (!(roleObject instanceof Map<String, Object>)) { continue; }
            Map<String, Object> values = (Map<String, Object>) roleObject;
            WorkExperienceDraft role = new WorkExperienceDraft();
            role.rowId = 'row-' + count;
            for (Resume_Field_Map__mdt m : roleMappings) {
                role.fields.add(toFieldDraft(m, values.get(m.Parse_Key__c)));
            }
            out.workExperiences.add(role);
            count++;
        }
        return out;
    }

    private static FieldDraft toFieldDraft(Resume_Field_Map__mdt m, Object rawValue) {
        FieldMapView view = viewFor(m, null);
        FieldDraft f = new FieldDraft();
        f.parseKey = view.parseKey;
        f.label = String.isBlank(view.targetLabel) ? view.parseKey : view.targetLabel;
        f.targetObject = canonicalScope(view.targetObject);
        f.targetField = view.targetField;
        f.dataType = view.dataType;
        f.value = canonicalDraftValue(rawValue, m);
        f.showInReview = view.showInReview;
        f.readOnly = view.readOnly;
        f.sortOrder = view.sortOrder;
        f.inputKind = view.inputKind;
        f.inputType = view.inputType;
        f.options = view.options;
        return f;
    }

    private static String canonicalDraftValue(Object rawValue, Resume_Field_Map__mdt m) {
        Object effectiveValue = rawValue;
        if (rawValue == null || (rawValue instanceof String && String.isBlank((String) rawValue))) {
            effectiveValue = String.isBlank(m.Default_Value__c) ? rawValue : m.Default_Value__c.trim();
        }
        if (m.Data_Type__c == 'Checkbox') { return String.valueOf(asBoolean(effectiveValue)); }
        if (m.Data_Type__c == 'Date') { return normalizeDateString(asString(effectiveValue)); }
        if (m.Data_Type__c == 'Number') {
            Decimal value = parseNumber(asString(effectiveValue));
            return value == null ? null : String.valueOf(value);
        }
        if (m.Data_Type__c == 'Picklist') { return coercePicklist(asString(effectiveValue), m); }
        return truncate(asString(effectiveValue), maxLenOf(m));
    }

    /** Parse-key/value map from a client envelope. Client-supplied target metadata is never trusted. */
    public static Map<String, Object> valuesFromFields(List<FieldDraft> fields) {
        Map<String, Object> values = new Map<String, Object>();
        if (fields == null) { return values; }
        for (FieldDraft field : fields) {
            if (field != null && String.isNotBlank(field.parseKey)) {
                values.put(field.parseKey, field.value);
            }
        }
        return values;
    }

    // ── Persistence ────────────────────────────────────────────────────────

    public static List<Work_Experience__c> commitDrafts(Id resumeId, List<WorkExperienceDraft> drafts) {
        List<Resume_Data__c> lockedParents = [
            SELECT Id FROM Resume_Data__c WHERE Id = :resumeId FOR UPDATE
        ];
        if (lockedParents.isEmpty()) { throw new AuraHandledException('The resume record no longer exists.'); }

        Map<String, Schema.SObjectField> fields = fieldsForScope(ROLE_SCOPE);
        List<Resume_Field_Map__mdt> mappings = validMappingsFor(ROLE_SCOPE);
        List<Work_Experience__c> rows = new List<Work_Experience__c>();
        Integer count = 0;
        if (drafts != null) {
            for (WorkExperienceDraft draft : drafts) {
                if (count >= MAX_ROWS) { break; }
                Map<String, Object> values = valuesFromFields(draft == null ? null : draft.fields);
                Work_Experience__c row = new Work_Experience__c(Resume_Data__c = resumeId);
                for (Resume_Field_Map__mdt m : mappings) {
                    if (m.Read_Only__c == true) { continue; }
                    putCoerced(row, fields, m, values.get(m.Parse_Key__c));
                }
                String company = truncate(asString(row.get('Company_Name__c')), 255);
                String title = truncate(asString(row.get('Job_Title__c')), 255);
                Date startDate = (Date) row.get('Start_Date__c');
                row.External_Key__c = buildExternalKey(resumeId, company, title, startDate);
                rows.add(row);
                count++;
            }
        }

        delete [SELECT Id FROM Work_Experience__c WHERE Resume_Data__c = :resumeId];
        insert rows;
        return rows;
    }

    public static void applyCandidateFields(Resume_Data__c parent, List<FieldDraft> fields) {
        applyCandidateValues(parent, valuesFromFields(fields));
    }

    @TestVisible private static void applyCandidateValues(Resume_Data__c parent, Map<String, Object> values) {
        if (values == null) { return; }
        Map<String, Schema.SObjectField> fields = fieldsForScope(CANDIDATE_SCOPE);
        for (Resume_Field_Map__mdt m : validMappingsFor(CANDIDATE_SCOPE)) {
            if (m.Read_Only__c == true) { continue; }
            putCoerced(parent, fields, m, values.get(m.Parse_Key__c));
        }
    }

    private static void putCoerced(SObject record, Map<String, Schema.SObjectField> fields,
                                   Resume_Field_Map__mdt m, Object rawValue) {
        Schema.SObjectField sof = resolveField(fields, m.Target_Field_API_Name__c);
        if (sof == null) { return; } // defensive; validMappingsFor already rejected it
        String apiName = m.Target_Field_API_Name__c;
        if (m.Data_Type__c == 'Date') { record.put(apiName, parseDate(asString(rawValue))); }
        else if (m.Data_Type__c == 'Checkbox') { record.put(apiName, asBoolean(rawValue)); }
        else if (m.Data_Type__c == 'Number') { record.put(apiName, parseNumber(asString(rawValue))); }
        else if (m.Data_Type__c == 'Picklist') { record.put(apiName, coercePicklist(asString(rawValue), m)); }
        else { record.put(apiName, truncate(asString(rawValue), maxLenOf(m))); }
    }

    // ── Coercion helpers ──────────────────────────────────────────────────

    private static Integer maxLenOf(Resume_Field_Map__mdt m) {
        return m.Max_Length__c == null ? null : Integer.valueOf(m.Max_Length__c);
    }

    private static List<String> configuredPicklistValuesOf(Resume_Field_Map__mdt m) {
        List<String> out = new List<String>();
        if (String.isBlank(m.Picklist_Values__c)) { return out; }
        for (String part : m.Picklist_Values__c.split('[\\r\\n,]+')) {
            if (String.isNotBlank(part)) { out.add(part.trim()); }
        }
        return out;
    }

    private static List<String> picklistValuesOf(Resume_Field_Map__mdt m) {
        return configuredPicklistValuesOf(m);
    }

    private static String normalizePicklistToken(String value) {
        return String.isBlank(value) ? '' : value.trim().toLowerCase().replaceAll('[\\s\\-]+', '');
    }

    private static String coercePicklist(String value, Resume_Field_Map__mdt m) {
        if (String.isBlank(value)) { return null; }
        List<String> allowed = picklistValuesOf(m);
        String normalized = normalizePicklistToken(value);
        for (String option : allowed) {
            if (normalizePicklistToken(option) == normalized) { return option; }
        }
        for (String option : allowed) {
            if (option.equalsIgnoreCase('Other')) { return option; }
        }
        return null;
    }

    public static String stripCodeFences(String raw) {
        if (String.isBlank(raw)) { return '{}'; }
        String value = raw.trim();
        if (value.startsWith('```')) {
            value = value.replaceFirst('^```[a-zA-Z]*\\s*', '');
            if (value.endsWith('```')) { value = value.substring(0, value.length() - 3); }
        }
        Integer first = value.indexOf('{');
        Integer last = value.lastIndexOf('}');
        if (first >= 0 && last > first) { value = value.substring(first, last + 1); }
        return value.trim();
    }

    public static String asString(Object value) {
        return value == null ? null : String.valueOf(value).trim();
    }

    public static Boolean asBoolean(Object value) {
        if (value instanceof Boolean) { return (Boolean) value; }
        if (value == null) { return false; }
        String normalized = String.valueOf(value).trim().toLowerCase();
        return normalized == 'true' || normalized == 'yes' || normalized == 'current' || normalized == 'present';
    }

    public static String truncate(String value, Integer maxLength) {
        if (String.isBlank(value)) { return null; }
        if (maxLength == null) { return value; }
        return value.length() > maxLength ? value.substring(0, maxLength) : value;
    }

    public static Decimal parseNumber(String value) {
        if (String.isBlank(value)) { return null; }
        String normalized = value.replaceAll('[^0-9.\\-]', '');
        if (String.isBlank(normalized)) { return null; }
        try { return Decimal.valueOf(normalized); } catch (Exception ignored) { return null; }
    }

    public static Date parseDate(String value) {
        if (String.isBlank(value)) { return null; }
        String normalized = value.trim();
        if (normalized.equalsIgnoreCase('present') || normalized.equalsIgnoreCase('current')) { return null; }
        try {
            Pattern pattern = Pattern.compile('^(\\d{4})(?:-(\\d{2})(?:-(\\d{2}))?)?$');
            Matcher match = pattern.matcher(normalized);
            if (match.matches()) {
                Integer year = Integer.valueOf(match.group(1));
                Integer month = match.group(2) == null ? 1 : Integer.valueOf(match.group(2));
                Integer day = match.group(3) == null ? 1 : Integer.valueOf(match.group(3));
                if (month < 1 || month > 12 || day < 1 || day > 31) { return null; }
                // Apex can normalize out-of-range dates, so verify the constructed calendar parts.
                Date parsed = Date.newInstance(year, month, day);
                return parsed.year() == year && parsed.month() == month && parsed.day() == day
                    ? parsed : null;
            }
        } catch (Exception ignored) { /* fail closed */ }
        return null;
    }

    public static String normalizeDateString(String value) {
        Date parsed = parseDate(value);
        return parsed == null ? null : String.valueOf(parsed);
    }

    /** Stable résumé-domain child identity: parent + company + title + start date. */
    public static String buildExternalKey(Id resumeId, String company, String title, Date startDate) {
        String datePart = startDate == null ? '' : String.valueOf(startDate);
        return (String.valueOf(resumeId) + '|' + (company == null ? '' : company)
            + '|' + (title == null ? '' : title) + '|' + datePart).left(255);
    }
}
