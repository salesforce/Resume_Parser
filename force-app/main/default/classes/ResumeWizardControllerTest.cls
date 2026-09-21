/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 */

@isTest
private class ResumeWizardControllerTest {
    private static final String SAMPLE_B64 = 'dGVzdA==';

    private static Resume_Field_Map__mdt fm(String key, String scope, String field, String type,
                                             Integer maxLength, Decimal order, String options) {
        return fm(key, scope, field, type, maxLength, order, options, true, false, true);
    }

    private static Resume_Field_Map__mdt fm(String key, String scope, String field, String type,
                                             Integer maxLength, Decimal order, String options,
                                             Boolean show, Boolean readOnly, Boolean prompt) {
        return new Resume_Field_Map__mdt(
            Parse_Key__c = key,
            Target_Object__c = scope,
            Target_Field_API_Name__c = field,
            Data_Type__c = type,
            Max_Length__c = maxLength,
            Picklist_Values__c = options,
            Include_In_Prompt__c = prompt,
            Show_In_Review__c = show,
            Read_Only__c = readOnly,
            Is_Active__c = true,
            Sort_Order__c = order
        );
    }

    private static void useTestMappings() {
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{
            fm('candidateName', 'Resume_Data__c', 'Candidate_Name__c', 'Text', 255, 1, null),
            fm('candidateEmail', 'Resume_Data__c', 'Candidate_Email__c', 'Email', 80, 2, null),
            fm('candidatePhone', 'Resume_Data__c', 'Candidate_Phone__c', 'Phone', 40, 3, null),
            fm('portfolioRuntime', 'Resume_Data__c', 'Candidate_Website__c', 'URL', 255, 4, null),
            fm('summary', 'Resume_Data__c', 'Summary__c', 'Text', 32000, 5, null),
            fm('company', 'Work_Experience__c', 'Company_Name__c', 'Text', 255, 10, null),
            fm('title', 'Work_Experience__c', 'Job_Title__c', 'Text', 255, 11, null),
            fm('startDate', 'Work_Experience__c', 'Start_Date__c', 'Date', null, 12, null),
            fm('endDate', 'Work_Experience__c', 'End_Date__c', 'Date', null, 13, null),
            fm('isCurrent', 'Work_Experience__c', 'Is_Current__c', 'Checkbox', null, 14, null),
            fm('location', 'Work_Experience__c', 'Location__c', 'Text', 255, 15, null),
            fm('roleKindRuntime', 'Work_Experience__c', 'Employment_Type__c', 'Picklist', null, 16,
                'Full-time\nPart-time\nContract\nInternship\nTemporary\nFreelance\nOther'),
            fm('description', 'Work_Experience__c', 'Description__c', 'Text', 32000, 17, null)
        };
    }

    private static String valueOf(List<ResumeParsing.FieldDraft> fields, String key) {
        for (ResumeParsing.FieldDraft field : fields) {
            if (field.parseKey == key) { return field.value; }
        }
        return null;
    }

    private static ResumeParsing.FieldDraft field(String key, String value) {
        ResumeParsing.FieldDraft out = new ResumeParsing.FieldDraft();
        out.parseKey = key;
        out.value = value;
        return out;
    }

    private static ResumeParsing.WorkExperienceDraft role(Map<String, String> values) {
        ResumeParsing.WorkExperienceDraft out = new ResumeParsing.WorkExperienceDraft();
        out.rowId = 'manual-row';
        for (String key : values.keySet()) { out.fields.add(field(key, values.get(key))); }
        return out;
    }

    private static Id makeContact() {
        Contact contact = new Contact(LastName = 'Dynamic Resume Test');
        insert contact;
        return contact.Id;
    }

    private static Id makeDraftResume() {
        Resume_Data__c resume = new Resume_Data__c(
            Processing_Status__c = 'Draft', Contact__c = makeContact());
        insert resume;
        return resume.Id;
    }

    @isTest
    static void arbitraryCandidateAndRoleKeysRoundTripWithoutDtoMembers() {
        useTestMappings();
        ResumeParsing.ParseResult parsed = ResumeParsing.toDrafts(
            '{"portfolioRuntime":"https://portfolio.example/new","workExperiences":['
            + '{"company":"Acme","title":"Engineer","startDate":"2022-03",'
            + '"roleKindRuntime":"FULL TIME"}]}'
        );
        System.assertEquals('https://portfolio.example/new',
            valueOf(parsed.candidateFields, 'portfolioRuntime'));
        System.assertEquals('Full-time',
            valueOf(parsed.workExperiences[0].fields, 'roleKindRuntime'));

        Id resumeId = makeDraftResume();
        Integer saved = ResumeWizardController.commitDrafts(
            resumeId,
            JSON.serialize(parsed.workExperiences),
            JSON.serialize(parsed.candidateFields)
        );
        System.assertEquals(1, saved);
        Resume_Data__c parent = [
            SELECT Candidate_Website__c FROM Resume_Data__c WHERE Id = :resumeId
        ];
        Work_Experience__c child = [
            SELECT Employment_Type__c, Company_Name__c, Job_Title__c, Start_Date__c, External_Key__c
            FROM Work_Experience__c WHERE Resume_Data__c = :resumeId LIMIT 1
        ];
        System.assertEquals('https://portfolio.example/new', parent.Candidate_Website__c);
        System.assertEquals('Full-time', child.Employment_Type__c);
        System.assertEquals(
            String.valueOf(resumeId) + '|Acme|Engineer|2022-03-01', child.External_Key__c,
            'Established resume child identity remains parent|company|title|startDate');
        String firstIdentity = child.External_Key__c;
        ResumeWizardController.commitDrafts(
            resumeId, JSON.serialize(parsed.workExperiences), JSON.serialize(parsed.candidateFields));
        Work_Experience__c recommitted = [
            SELECT External_Key__c FROM Work_Experience__c WHERE Resume_Data__c = :resumeId LIMIT 1
        ];
        System.assertEquals(firstIdentity, recommitted.External_Key__c,
            'Identical reviewed role identity fields produce the same external key');
        System.assertEquals(1, [
            SELECT COUNT() FROM Work_Experience__c WHERE Resume_Data__c = :resumeId
        ]);
    }

    @isTest
    static void hiddenAndReadOnlyAreIndependentAndEnforced() {
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{
            fm('lockedName', 'Resume_Data__c', 'Candidate_Name__c', 'Text', 255, 1, null,
                true, true, true),
            fm('hiddenSummary', 'Resume_Data__c', 'Summary__c', 'Text', 32000, 2, null,
                false, false, true)
        };
        ResumeParsing.ParseResult parsed = ResumeParsing.toDrafts(
            '{"lockedName":"Model Name","hiddenSummary":"Hidden but persistable"}'
        );
        System.assertEquals(true, parsed.candidateFields[0].readOnly);
        System.assertEquals(false, parsed.candidateFields[1].showInReview);
        parsed.candidateFields[0].value = 'Client tamper';

        Id resumeId = makeDraftResume();
        ResumeWizardController.commitDrafts(resumeId, '[]', JSON.serialize(parsed.candidateFields));
        Resume_Data__c saved = [
            SELECT Candidate_Name__c, Summary__c FROM Resume_Data__c WHERE Id = :resumeId
        ];
        System.assertEquals(null, saved.Candidate_Name__c, 'Read-only mapping never commits');
        System.assertEquals('Hidden but persistable', saved.Summary__c,
            'Show In Review controls UI only; hidden non-read-only values still follow the map');
    }

    @isTest
    static void invalidMappingsAreDisclosedButExcludedFromPromptReviewAndDml() {
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{
            fm('safe', 'Resume_Data__c', 'Candidate_Name__c', 'Text', 255, 1, null),
            fm('wrongObject', 'Account', 'Name', 'Text', 255, 2, null),
            fm('relationshipPath', 'Resume_Data__c', 'Contact__r.Name', 'Text', 255, 3, null),
            fm('missingField', 'Work_Experience__c', 'Does_Not_Exist__c', 'Text', 255, 4, null),
            fm('badType', 'Resume_Data__c', 'Candidate_Email__c', 'Date', null, 5, null)
        };

        List<ResumeParsing.FieldMapView> views = ResumeParsing.fieldMapViews();
        System.assertEquals(5, views.size());
        Integer rejected = 0;
        for (ResumeParsing.FieldMapView view : views) {
            if (view.supported == false) {
                rejected++;
                System.assertNotEquals(null, view.issue);
            }
        }
        System.assertEquals(4, rejected);
        String prompt = ResumeParsing.buildExtraInstructions();
        System.assert(prompt.contains('"safe"'));
        System.assert(!prompt.contains('wrongObject'));
        ResumeParsing.ParseResult parsed = ResumeParsing.toDrafts(
            '{"safe":"Allowed","wrongObject":"No","relationshipPath":"No","workExperiences":['
            + '{"missingField":"No"}]}'
        );
        System.assertEquals(1, parsed.candidateFields.size());
        System.assertEquals('safe', parsed.candidateFields[0].parseKey);
        System.assertEquals(1, parsed.workExperiences.size());
        System.assertEquals(0, parsed.workExperiences[0].fields.size());
    }

    @isTest
    static void duplicateParseKeysFailClosed() {
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{
            fm('duplicate', 'Resume_Data__c', 'Candidate_Name__c', 'Text', 255, 1, null),
            fm('duplicate', 'Resume_Data__c', 'Summary__c', 'Text', 255, 2, null)
        };
        ResumeParsing.ParseResult parsed = ResumeParsing.toDrafts('{"duplicate":"unsafe"}');
        System.assertEquals(0, parsed.candidateFields.size());
        for (ResumeParsing.FieldMapView view : ResumeParsing.fieldMapViews()) {
            System.assertEquals(false, view.supported);
            System.assert(view.issue.contains('Duplicate'));
        }
    }

    @isTest
    static void configuredPicklistNormalizesAndFallsBack() {
        useTestMappings();
        ResumeParsing.ParseResult parsed = ResumeParsing.toDrafts(
            '{"workExperiences":['
            + '{"roleKindRuntime":"FULL TIME"},'
            + '{"roleKindRuntime":"part-time"},'
            + '{"roleKindRuntime":"Permanent"}]}'
        );
        System.assertEquals('Full-time', valueOf(parsed.workExperiences[0].fields, 'roleKindRuntime'));
        System.assertEquals('Part-time', valueOf(parsed.workExperiences[1].fields, 'roleKindRuntime'));
        System.assertEquals('Other', valueOf(parsed.workExperiences[2].fields, 'roleKindRuntime'));
    }

    @isTest
    static void configuredDefaultAppliesOnlyToBlankAndPersists() {
        Resume_Field_Map__mdt company = fm(
            'company', 'Work_Experience__c', 'Company_Name__c', 'Text', 255, 1, null);
        Resume_Field_Map__mdt type = fm(
            'roleKind', 'Work_Experience__c', 'Employment_Type__c', 'Picklist', null, 2,
            'Full-time\nPart-time\nContract\nInternship\nTemporary\nFreelance\nOther');
        type.Default_Value__c = 'Full-time';
        type.Extraction_Hint__c = 'Infer the closest allowed value from role cues.';
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{company, type};

        ResumeParsing.ParseResult parsed = ResumeParsing.toDrafts(
            '{"workExperiences":['
            + '{"company":"Blank Co","roleKind":""},'
            + '{"company":"Explicit Co","roleKind":"Contract"}]}'
        );
        System.assertEquals('Full-time', valueOf(parsed.workExperiences[0].fields, 'roleKind'),
            'Blank model value receives the configured default');
        System.assertEquals('Contract', valueOf(parsed.workExperiences[1].fields, 'roleKind'),
            'Explicit recognized value wins over the configured default');
        String prompt = ResumeParsing.buildExtraInstructions();
        System.assert(prompt.contains('Infer the closest allowed value from role cues.'));
        System.assert(prompt.contains('Configured default when the extracted value is empty: Full-time.'));

        Id resumeId = makeDraftResume();
        ResumeWizardController.commitDrafts(resumeId, JSON.serialize(parsed.workExperiences), null);
        Map<String, String> savedByCompany = new Map<String, String>();
        for (Work_Experience__c row : [
            SELECT Company_Name__c, Employment_Type__c
            FROM Work_Experience__c WHERE Resume_Data__c = :resumeId
        ]) {
            savedByCompany.put(row.Company_Name__c, row.Employment_Type__c);
        }
        System.assertEquals('Full-time', savedByCompany.get('Blank Co'),
            'Configured default round-trips through generic commit');
        System.assertEquals('Contract', savedByCompany.get('Explicit Co'));
    }

    @isTest
    static void invalidConfiguredDefaultsFailClosedAndNoDefaultStaysBlank() {
        for (String invalidDate : new List<String>{
            'not-a-date', '2024-13-31', '2024-02-31', '2024-01-31 trailing'
        }) {
            Resume_Field_Map__mdt badDate = fm(
                'dateValue', 'Work_Experience__c', 'Start_Date__c', 'Date', null, 1, null);
            badDate.Default_Value__c = invalidDate;
            ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{badDate};
            ResumeParsing.FieldMapView invalidView = ResumeParsing.fieldMapViews()[0];
            System.assertEquals(false, invalidView.supported, 'Invalid calendar/trailing date must fail closed');
            System.assert(invalidView.issue.contains('valid Date'));
        }

        List<String> validDates = new List<String>{'2024', '2024-02', '2024-02-29', '2024-01-31'};
        List<String> normalizedDates = new List<String>{'2024-01-01', '2024-02-01', '2024-02-29', '2024-01-31'};
        for (Integer i = 0; i < validDates.size(); i++) {
            Resume_Field_Map__mdt validDate = fm(
                'dateValue', 'Work_Experience__c', 'Start_Date__c', 'Date', null, 1, null);
            validDate.Default_Value__c = validDates[i];
            ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{validDate};
            System.assertEquals(true, ResumeParsing.fieldMapViews()[0].supported);
            ResumeParsing.ParseResult parsedDate = ResumeParsing.toDrafts(
                '{"workExperiences":[{"dateValue":""}]}'
            );
            System.assertEquals(normalizedDates[i], valueOf(parsedDate.workExperiences[0].fields, 'dateValue'),
                'Valid partial/full date default must preserve the real calendar day');
        }

        Resume_Field_Map__mdt badCheckbox = fm(
            'badCheckbox', 'Work_Experience__c', 'Is_Current__c', 'Checkbox', null, 2, null);
        badCheckbox.Default_Value__c = 'maybe';
        Resume_Field_Map__mdt badPicklist = fm(
            'badPicklist', 'Work_Experience__c', 'Employment_Type__c', 'Picklist', null, 3,
            'Full-time\nContract\nOther');
        badPicklist.Default_Value__c = 'Permanent';
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{badCheckbox, badPicklist};
        List<ResumeParsing.FieldMapView> invalid = ResumeParsing.fieldMapViews();
        System.assertEquals(false, invalid[0].supported);
        System.assert(invalid[0].issue.contains('true or false'));
        System.assertEquals(false, invalid[1].supported);
        System.assert(invalid[1].issue.contains('allowed Picklist Value'));
        System.assertEquals(0, ResumeParsing.toDrafts(
            '{"workExperiences":[{"badCheckbox":"","badPicklist":""}]}'
        ).workExperiences[0].fields.size(), 'Invalid defaults make mappings inert');

        Resume_Field_Map__mdt noDefault = fm(
            'noDefault', 'Work_Experience__c', 'Employment_Type__c', 'Picklist', null, 1,
            'Full-time\nContract\nOther');
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{noDefault};
        ResumeParsing.ParseResult blank = ResumeParsing.toDrafts(
            '{"workExperiences":[{"noDefault":""}]}'
        );
        System.assertEquals(null, valueOf(blank.workExperiences[0].fields, 'noDefault'),
            'Mappings without configured defaults remain blank');
    }

    @isTest
    static void everyPicklistMappingRequiresConfiguredValues() {
        List<Resume_Field_Map__mdt> missingConfigurations = new List<Resume_Field_Map__mdt>{
            fm('employmentType', 'Work_Experience__c', 'Employment_Type__c', 'Picklist', null, 1, null),
            fm('newPicklist', 'Work_Experience__c', 'Employment_Type__c', 'Picklist', null, 2, null),
            fm('employmentType', 'Resume_Data__c', 'Processing_Status__c', 'Picklist', null, 3, null)
        };
        // Evaluate each independently so duplicate-target validation doesn't mask the generic rule.
        for (Resume_Field_Map__mdt mapping : missingConfigurations) {
            ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{mapping};
            ResumeParsing.FieldMapView view = ResumeParsing.fieldMapViews()[0];
            System.assertEquals(false, view.supported,
                'Every Picklist mapping requires explicit configured values regardless of identity');
            System.assert(view.issue.contains('Picklist Values'));
        }
    }

    @isTest
    static void duplicateEditableTargetsAreDisclosedAndNeverWrite() {
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{
            fm('websiteOne', 'Resume_Data__c', 'Candidate_Website__c', 'URL', 255, 1, null),
            fm('websiteTwo', 'Resume_Data__c', 'Candidate_Website__c', 'URL', 255, 2, null)
        };
        List<ResumeParsing.FieldMapView> views = ResumeParsing.fieldMapViews();
        System.assertEquals(2, views.size());
        for (ResumeParsing.FieldMapView view : views) {
            System.assertEquals(false, view.supported);
            System.assert(view.issue.contains('Duplicate active editable target field'));
        }
        System.assertEquals(0, ResumeParsing.toDrafts(
            '{"websiteOne":"https://one.invalid","websiteTwo":"https://two.invalid"}'
        ).candidateFields.size(), 'Colliding controls are excluded from review');

        Id resumeId = makeDraftResume();
        ResumeWizardController.commitDrafts(resumeId, '[]', JSON.serialize(
            new List<ResumeParsing.FieldDraft>{
                field('websiteOne', 'https://one.invalid'),
                field('websiteTwo', 'https://two.invalid')
            }
        ));
        System.assertEquals(null, [
            SELECT Candidate_Website__c FROM Resume_Data__c WHERE Id = :resumeId
        ].Candidate_Website__c, 'A duplicate target collision never writes either value');
    }

    @isTest
    static void incompatibleTypesAndPicklistValuesAreInert() {
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{
            fm('textIntoDate', 'Work_Experience__c', 'Start_Date__c', 'Text', 255, 1, null),
            fm('invalidOption', 'Work_Experience__c', 'Employment_Type__c', 'Picklist', null, 2,
                'Full-time\nAlien')
        };
        List<ResumeParsing.FieldMapView> views = ResumeParsing.fieldMapViews();
        System.assertEquals(false, views[0].supported);
        System.assert(views[0].issue.contains('incompatible'));
        System.assertEquals(false, views[1].supported);
        System.assert(views[1].issue.contains('active values'));

        Id resumeId = makeDraftResume();
        ResumeWizardController.commitDrafts(resumeId, JSON.serialize(
            new List<ResumeParsing.WorkExperienceDraft>{
                role(new Map<String, String>{
                    'textIntoDate' => 'not-a-date',
                    'invalidOption' => 'Alien'
                })
            }
        ), null);
        Work_Experience__c saved = [
            SELECT Start_Date__c, Employment_Type__c
            FROM Work_Experience__c WHERE Resume_Data__c = :resumeId LIMIT 1
        ];
        System.assertEquals(null, saved.Start_Date__c);
        System.assertEquals(null, saved.Employment_Type__c,
            'Invalid type and invalid target picklist values are never written');
    }

    @isTest
    static void promptUsesOnlyValidatedDynamicMappingsAndOptions() {
        useTestMappings();
        String prompt = ResumeParsing.buildExtraInstructions();
        System.assert(prompt.contains('"portfolioRuntime"'));
        System.assert(prompt.contains('"roleKindRuntime"'));
        System.assert(prompt.contains('Allowed values: Full-time, Part-time, Contract'));
        System.assert(prompt.contains('A complete URL.'));
        System.assert(prompt.contains('"workExperiences": ['));
    }

    @isTest
    static void candidateWorkExperiencesParseKeyIsReservedAndInert() {
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{
            fm('workExperiences', 'Resume_Data__c', 'Summary__c', 'Text', 32000, 1, null),
            fm('company', 'Work_Experience__c', 'Company_Name__c', 'Text', 255, 2, null)
        };
        List<ResumeParsing.FieldMapView> views = ResumeParsing.fieldMapViews();
        System.assertEquals(false, views[0].supported);
        System.assertEquals('Reserved parse key; workExperiences is the repeating-role envelope.',
            views[0].issue);
        System.assertEquals(true, views[1].supported);

        String prompt = ResumeParsing.buildExtraInstructions();
        Integer structuralKey = prompt.indexOf('"workExperiences"');
        System.assert(structuralKey >= 0, 'The role array remains in the generated schema');
        System.assert(!prompt.substring(structuralKey + 1).contains('"workExperiences"'),
            'Reserved candidate mapping must not add a second structural key');

        ResumeParsing.ParseResult parsed = ResumeParsing.toDrafts(
            '{"workExperiences":[{"company":"Acme"}]}'
        );
        System.assertEquals(0, parsed.candidateFields.size());
        System.assertEquals('Acme', valueOf(parsed.workExperiences[0].fields, 'company'));

        Id resumeId = makeDraftResume();
        ResumeWizardController.commitDrafts(
            resumeId,
            JSON.serialize(parsed.workExperiences),
            JSON.serialize(new List<ResumeParsing.FieldDraft>{field('workExperiences', 'must not write')})
        );
        System.assertEquals(null, [SELECT Summary__c FROM Resume_Data__c WHERE Id = :resumeId].Summary__c);
        System.assertEquals('Acme', [
            SELECT Company_Name__c FROM Work_Experience__c WHERE Resume_Data__c = :resumeId LIMIT 1
        ].Company_Name__c);
    }

    @isTest
    static void promptSchemaEscapesAdminAuthoredKeysAndHints() {
        Resume_Field_Map__mdt escaped = fm(
            'candidate"Path\\Key', 'Resume_Data__c', 'Summary__c', 'Text', 32000, 1, null);
        escaped.Extraction_Hint__c = 'Extract the "preferred" path C:\\profile.\nKeep the second line.';
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{escaped};

        String completeSchema = '{' + ResumeParsing.buildExtraInstructions() + '}';
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(completeSchema);
        String exactKey = 'candidate"Path\\Key';
        System.assertEquals(true, parsed.containsKey(exactKey),
            'Quoted/backslashed parse key must remain valid JSON');
        String guidance = (String) parsed.get(exactKey);
        System.assert(guidance.contains('"preferred"'));
        System.assert(guidance.contains('C:\\profile'));
        System.assert(guidance.contains('second line'));
    }

    @isTest
    static void maxRowsIsPreserved() {
        useTestMappings();
        List<String> roles = new List<String>();
        for (Integer i = 0; i < ResumeParsing.MAX_ROWS + 5; i++) {
            roles.add('{"company":"Company ' + i + '"}');
        }
        ResumeParsing.ParseResult parsed = ResumeParsing.toDrafts(
            '{"workExperiences":[' + String.join(roles, ',') + ']}'
        );
        System.assertEquals(ResumeParsing.MAX_ROWS, parsed.workExperiences.size());
        System.assertEquals('row-49', parsed.workExperiences[49].rowId);
    }

    @isTest
    static void commitLocksAndReplacesCurrentChildren() {
        useTestMappings();
        Id resumeId = makeDraftResume();
        List<ResumeParsing.WorkExperienceDraft> first = new List<ResumeParsing.WorkExperienceDraft>{
            role(new Map<String, String>{'company' => 'One', 'title' => 'First'})
        };
        List<ResumeParsing.WorkExperienceDraft> second = new List<ResumeParsing.WorkExperienceDraft>{
            role(new Map<String, String>{'company' => 'Two', 'title' => 'Second'}),
            role(new Map<String, String>{'company' => 'Three', 'title' => 'Third'})
        };
        ResumeWizardController.commitDrafts(resumeId, JSON.serialize(first), null);
        ResumeWizardController.commitDrafts(resumeId, JSON.serialize(second), null);
        List<Work_Experience__c> rows = [
            SELECT Company_Name__c FROM Work_Experience__c WHERE Resume_Data__c = :resumeId
            ORDER BY Company_Name__c
        ];
        System.assertEquals(2, rows.size());
        System.assertEquals('Three', rows[0].Company_Name__c);
        System.assertEquals('Two', rows[1].Company_Name__c);
    }

    @isTest
    static void commitMissingParentFailsBeforeReplace() {
        useTestMappings();
        Id resumeId = makeDraftResume();
        delete new Resume_Data__c(Id = resumeId);
        Boolean threw = false;
        try {
            ResumeWizardController.commitDrafts(resumeId, '[]', null);
        } catch (AuraHandledException expected) { threw = true; }
        System.assert(threw);
    }

    @isTest
    static void clientTargetMetadataCannotEscapeServerAllowlist() {
        useTestMappings();
        Id resumeId = makeDraftResume();
        ResumeParsing.FieldDraft forged = field('portfolioRuntime', 'https://safe.example');
        forged.targetObject = 'Account';
        forged.targetField = 'Name';
        forged.dataType = 'Text';
        ResumeWizardController.commitDrafts(resumeId, '[]', JSON.serialize(
            new List<ResumeParsing.FieldDraft>{forged}));
        System.assertEquals('https://safe.example', [
            SELECT Candidate_Website__c FROM Resume_Data__c WHERE Id = :resumeId
        ].Candidate_Website__c, 'Server CMDT—not client target metadata—controls the write');
    }

    @isTest
    static void fieldMapViewsExposeGenericInputMetadata() {
        useTestMappings();
        List<ResumeParsing.FieldMapView> views = ResumeWizardController.getFieldMap();
        System.assertEquals(13, views.size());
        ResumeParsing.FieldMapView urlView;
        ResumeParsing.FieldMapView picklistView;
        for (ResumeParsing.FieldMapView view : views) {
            if (view.parseKey == 'portfolioRuntime') urlView = view;
            if (view.parseKey == 'roleKindRuntime') picklistView = view;
        }
        System.assertEquals(true, urlView.supported);
        System.assertEquals('url', urlView.inputType);
        System.assertEquals('picklist', picklistView.inputKind);
        System.assertEquals(7, picklistView.options.size());
    }

    @isTest
    static void uploadInputValidationAndCleanupRemain() {
        useTestMappings();
        Id contactId = makeContact();
        Boolean blankThrew = false;
        try { ResumeWizardController.uploadAndParse('', '', null); }
        catch (AuraHandledException expected) { blankThrew = true; }
        System.assert(blankThrew);

        Test.startTest();
        try { ResumeWizardController.uploadAndParse('synthetic.pdf', SAMPLE_B64, contactId); }
        catch (Exception expected) { /* prompt generation unavailable in tests */ }
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Resume_Data__c]);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocument]);
    }

    @isTest
    static void abandonDraftDeletesOwnedFileButPreservesSuccess() {
        useTestMappings();
        Id draftId = makeDraftResume();
        ContentVersion version = new ContentVersion(
            Title = 'synthetic', PathOnClient = 'synthetic.pdf',
            VersionData = Blob.valueOf('synthetic'), FirstPublishLocationId = draftId);
        insert version;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;
        update new Resume_Data__c(Id = draftId, Source_ContentDocumentId__c = documentId);
        System.assertEquals(true, ResumeWizardController.abandonDraft(draftId));
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :documentId]);

        Id successId = makeDraftResume();
        update new Resume_Data__c(Id = successId, Processing_Status__c = 'Success');
        System.assertEquals(false, ResumeWizardController.abandonDraft(successId));
        System.assertEquals(1, [SELECT COUNT() FROM Resume_Data__c WHERE Id = :successId]);
    }

    @isTest
    static void malformedPayloadsAndIdsFailClearly() {
        useTestMappings();
        Id resumeId = makeDraftResume();
        Integer failures = 0;
        try { ResumeWizardController.commitDrafts('', '[]', null); }
        catch (AuraHandledException expected) { failures++; }
        try { ResumeWizardController.commitDrafts('not-an-id', '[]', null); }
        catch (AuraHandledException expected) { failures++; }
        try { ResumeWizardController.commitDrafts(resumeId, 'not-json', null); }
        catch (AuraHandledException expected) { failures++; }
        try { ResumeWizardController.commitDrafts(resumeId, '[]', 'not-json'); }
        catch (AuraHandledException expected) { failures++; }
        System.assertEquals(4, failures);
    }

    @isTest
    static void coercionHelpersRemainBounded() {
        System.assertEquals(Decimal.valueOf('1200'), ResumeParsing.parseNumber('$1,200'));
        System.assertEquals(null, ResumeParsing.parseNumber('   '));
        System.assertEquals(Date.newInstance(2020, 6, 1), ResumeParsing.parseDate('2020-06'));
        System.assertEquals(false, ResumeParsing.asBoolean('no'));
        System.assertEquals(true, ResumeParsing.asBoolean('present'));
        System.assertEquals('abc', ResumeParsing.truncate('abcdef', 3));
    }
}
