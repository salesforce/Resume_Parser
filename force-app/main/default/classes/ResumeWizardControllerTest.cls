/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 * For full license text, see the LICENSE.txt file in the repo root or
 * https://opensource.org/licenses/Apache-2.0
 */

/**
 * @description Tests for the in-chat wizard controller and the shared ResumeParsing util.
 * The LLM call in uploadAndParse can't run in test context, so that path verifies temporary
 * upload cleanup; commit + parsing are exercised fully with synthetic data.
 */
@isTest
private class ResumeWizardControllerTest {

    private static final String SAMPLE_B64 = 'dGVzdA==';  // "test"

    // ── CMDT test seam ───────────────────────────────────────────────
    // Inject the field map in-memory so tests never depend on deployed Resume_Field_Map__mdt rows.
    // Static vars reset between test methods, so each test that parses/commits calls useTestMappings().

    private static Resume_Field_Map__mdt fm(String pk, String tObj, String tField, String dType,
                                            Integer maxLen, Decimal sortOrder, String picklist) {
        return new Resume_Field_Map__mdt(
            Parse_Key__c = pk, Target_Object__c = tObj, Target_Field_API_Name__c = tField,
            Data_Type__c = dType, Max_Length__c = maxLen, Picklist_Values__c = picklist,
            Include_In_Prompt__c = true, Show_In_Review__c = true, Read_Only__c = false,
            Is_Active__c = true, Sort_Order__c = sortOrder);
    }

    private static void useTestMappings() {
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{
            fm('candidateName',  'Resume_Data__c',     'Candidate_Name__c',  'Text',  255,   1, null),
            fm('candidateEmail', 'Resume_Data__c',     'Candidate_Email__c', 'Email', 80,    2, null),
            fm('candidatePhone', 'Resume_Data__c',     'Candidate_Phone__c', 'Phone', 40,    3, null),
            fm('summary',        'Resume_Data__c',     'Summary__c',         'Text',  32000, 4, null),
            fm('company',        'Work_Experience__c', 'Company_Name__c',    'Text',  255,   10, null),
            fm('title',          'Work_Experience__c', 'Job_Title__c',       'Text',  255,   11, null),
            fm('startDate',      'Work_Experience__c', 'Start_Date__c',      'Date',  null,  12, null),
            fm('endDate',        'Work_Experience__c', 'End_Date__c',        'Date',  null,  13, null),
            fm('isCurrent',      'Work_Experience__c', 'Is_Current__c',      'Checkbox', null, 14, null),
            fm('location',       'Work_Experience__c', 'Location__c',        'Text',  255,   15, null),
            fm('employmentType', 'Work_Experience__c', 'Employment_Type__c', 'Picklist', null, 16,
               'Full-time\nPart-time\nContract\nInternship\nTemporary\nFreelance\nOther'),
            fm('description',    'Work_Experience__c', 'Description__c',     'Text',  32000, 17, null)
        };
    }

    private static ResumeParsing.WorkExperienceDraft draft(String company, String title, String start, String endDt, Boolean current, String type) {
        ResumeParsing.WorkExperienceDraft d = new ResumeParsing.WorkExperienceDraft();
        d.company = company; d.title = title; d.startDate = start; d.endDate = endDt;
        d.isCurrent = current; d.location = 'Remote'; d.employmentType = type; d.description = 'Did things.';
        return d;
    }

    private static Id makeContact() {
        useTestMappings();
        Contact c = new Contact(LastName = 'Test Candidate');
        insert c;
        return c.Id;
    }

    private static Id makeDraftResume() {
        Resume_Data__c r = new Resume_Data__c(Processing_Status__c = 'Draft', Contact__c = makeContact());
        insert r;
        return r.Id;
    }

    // ── ResumeParsing.toDrafts ───────────────────────────────────────

    @isTest
    static void toDraftsParsesCandidateAndRoles() {
        useTestMappings();
        String json = '{"candidateName":"Jane Doe","candidateEmail":"jane@example.com","candidatePhone":"555-1234",'
            + '"summary":"Engineer.","workExperiences":['
            + '{"company":"Acme","title":"Sr Engineer","startDate":"2020-01-15","endDate":null,"isCurrent":true,"location":"Remote","employmentType":"Full-time","description":"Led team."},'
            + '{"company":"Globex","title":"Engineer","startDate":"2017-06","endDate":"2019-12","isCurrent":false,"location":"NYC","employmentType":"contract","description":"Built."}]}';
        Test.startTest();
        ResumeParsing.ParseResult r = ResumeParsing.toDrafts(json);
        Test.stopTest();

        System.assertEquals('Jane Doe', r.candidateName);
        System.assertEquals(2, r.workExperiences.size(), 'Two drafts parsed');
        System.assertEquals('Contract', r.workExperiences[1].employmentType, 'Employment type coerced');
        System.assertEquals('2017-06-01', r.workExperiences[1].startDate, 'Year-month coerced to a date string');
        System.assertEquals(0, [SELECT COUNT() FROM Work_Experience__c], 'Parsing creates NO child records');
    }

    @isTest
    static void toDraftsHandlesCodeFencesAndEmpty() {
        useTestMappings();
        ResumeParsing.ParseResult r = ResumeParsing.toDrafts('```json\n{"candidateName":"Sam","workExperiences":[]}\n```');
        System.assertEquals('Sam', r.candidateName);
        System.assertEquals(0, r.workExperiences.size());
    }

    // ── commit ───────────────────────────────────────────────────────

    @isTest
    static void commitCreatesRowsNoDupes() {
        Id rid = makeDraftResume();
        List<ResumeParsing.WorkExperienceDraft> rows = new List<ResumeParsing.WorkExperienceDraft>{
            draft('Acme', 'Sr Engineer', '2020-01-01', null, true, 'Full-time'),
            draft('Globex', 'Engineer', '2017-06-01', '2019-12-01', false, 'Contract')
        };
        Test.startTest();
        Integer n = ResumeWizardController.commitDrafts(rid, JSON.serialize(rows), null);
        Test.stopTest();

        System.assertEquals(2, n, 'commit returns saved count');
        System.assertEquals(2, [SELECT COUNT() FROM Work_Experience__c WHERE Resume_Data__c = :rid]);
        Resume_Data__c r = [SELECT Processing_Status__c, Last_Processed__c FROM Resume_Data__c WHERE Id = :rid];
        System.assertEquals('Success', r.Processing_Status__c);
        System.assertNotEquals(null, r.Last_Processed__c);
    }

    @isTest
    static void commitIsIdempotentReplace() {
        Id rid = makeDraftResume();
        List<ResumeParsing.WorkExperienceDraft> rows = new List<ResumeParsing.WorkExperienceDraft>{
            draft('Acme', 'Dev', '2021-01-01', null, true, 'Full-time')
        };
        Test.startTest();
        ResumeWizardController.commitDrafts(rid, JSON.serialize(rows), null);
        ResumeWizardController.commitDrafts(rid, JSON.serialize(rows), null);   // re-commit same set
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Work_Experience__c WHERE Resume_Data__c = :rid],
            'Re-commit replaces, does not duplicate');
    }

    @isTest
    static void commitPersistsUserEdits() {
        Id rid = makeDraftResume();
        // Simulate the user editing a title and employment type in the wizard before confirming.
        List<ResumeParsing.WorkExperienceDraft> rows = new List<ResumeParsing.WorkExperienceDraft>{
            draft('Acme Corp', 'Staff Engineer (edited)', '2022-03-01', null, true, 'Part-time')
        };
        Test.startTest();
        ResumeWizardController.commitDrafts(rid, JSON.serialize(rows), null);
        Test.stopTest();
        Work_Experience__c we = [SELECT Job_Title__c, Employment_Type__c, Start_Date__c FROM Work_Experience__c WHERE Resume_Data__c = :rid LIMIT 1];
        System.assertEquals('Staff Engineer (edited)', we.Job_Title__c, 'Edited title persisted');
        System.assertEquals('Part-time', we.Employment_Type__c, 'Edited type persisted');
        System.assertEquals(Date.newInstance(2022, 3, 1), we.Start_Date__c);
    }

    @isTest
    static void commitBadEmploymentTypeCoercesToOther() {
        Id rid = makeDraftResume();
        List<ResumeParsing.WorkExperienceDraft> rows = new List<ResumeParsing.WorkExperienceDraft>{
            draft('X', 'Y', '2015', null, false, 'Gig')   // not a valid picklist value
        };
        Test.startTest();
        ResumeWizardController.commitDrafts(rid, JSON.serialize(rows), null);
        Test.stopTest();
        Work_Experience__c we = [SELECT Employment_Type__c FROM Work_Experience__c WHERE Resume_Data__c = :rid LIMIT 1];
        System.assertEquals('Other', we.Employment_Type__c, 'Unknown type coerced to Other');
    }

    @isTest
    static void commitPersistsCandidateEdits() {
        Id rid = makeDraftResume();
        List<ResumeParsing.WorkExperienceDraft> rows = new List<ResumeParsing.WorkExperienceDraft>{
            draft('Acme', 'Dev', '2021-01-01', null, true, 'Full-time')
        };
        // The user edited the candidate (résumé) details in the preview.
        ResumeParsing.CandidateDraft cand = new ResumeParsing.CandidateDraft();
        cand.candidateName = 'Edited Name';
        cand.candidateEmail = 'edited@example.com';
        cand.candidatePhone = '555-9999';
        cand.summary = 'Edited summary.';

        Test.startTest();
        ResumeWizardController.commitDrafts(rid, JSON.serialize(rows), JSON.serialize(cand));
        Test.stopTest();

        Resume_Data__c r = [SELECT Candidate_Name__c, Candidate_Email__c, Candidate_Phone__c, Summary__c FROM Resume_Data__c WHERE Id = :rid];
        System.assertEquals('Edited Name', r.Candidate_Name__c, 'Edited candidate name persisted');
        System.assertEquals('edited@example.com', r.Candidate_Email__c, 'Edited email persisted');
        System.assertEquals('555-9999', r.Candidate_Phone__c, 'Edited phone persisted');
        System.assertEquals('Edited summary.', r.Summary__c, 'Edited summary persisted');
    }

    @isTest
    static void commitBlankIdThrows() {
        Boolean threw = false;
        Test.startTest();
        try { ResumeWizardController.commitDrafts('', '[]', null); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assert(threw, 'Blank id should throw');
    }

    // ── uploadAndParse (LLM call throws in test context) ──

    @isTest
    static void uploadCleansTemporaryDataWhenParseUnavailable() {
        Id contactId = makeContact();
        Test.startTest();
        try {
            ResumeWizardController.uploadAndParse('synthetic_resume.pdf', SAMPLE_B64, contactId);
        } catch (Exception ignored) {
            // ConnectApi.EinsteinLLM is unavailable in test context — expected.
        }
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Resume_Data__c],
            'Failed parse removes the temporary resume');
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocument],
            'Failed parse removes the temporary uploaded file');
    }

    @isTest
    static void uploadBlankInputThrows() {
        Boolean threw = false;
        Test.startTest();
        try { ResumeWizardController.uploadAndParse('', '', null); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assert(threw, 'Blank input should throw');
    }

    @isTest
    static void uploadMissingContactThrows() {
        Boolean threw = false;
        Test.startTest();
        try { ResumeWizardController.uploadAndParse('jane.pdf', SAMPLE_B64, null); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assert(threw, 'Missing contact should throw');
    }

    @isTest
    static void uploadWrongSObjectIdThrows() {
        // A non-Contact Id (this Account) must be rejected by the SObjectType check.
        Account a = new Account(Name = 'Acme'); insert a;
        Boolean threw = false;
        Test.startTest();
        try { ResumeWizardController.uploadAndParse('jane.pdf', SAMPLE_B64, a.Id); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assert(threw, 'A non-Contact Id should be rejected');
    }

    @isTest
    static void uploadGarbageContactIdThrows() {
        // A malformed Id must hit the StringException → AuraHandledException path.
        Boolean threw = false;
        Test.startTest();
        try { ResumeWizardController.uploadAndParse('jane.pdf', SAMPLE_B64, 'not-an-id'); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assert(threw, 'A malformed contact id should throw');
    }

    @isTest
    static void commitInvalidJsonThrows() {
        Id rid = makeDraftResume();
        Boolean threw = false;
        Test.startTest();
        try { ResumeWizardController.commitDrafts(rid, 'not valid json', null); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assert(threw, 'Unparseable rowsJson should throw');
    }

    @isTest
    static void commitInvalidResumeIdThrows() {
        Boolean threw = false;
        Test.startTest();
        try { ResumeWizardController.commitDrafts('not-an-id', '[]', null); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assert(threw, 'A malformed resume id should throw');
    }

    @isTest
    static void commitMissingResumeThrows() {
        Id rid = makeDraftResume();
        delete [SELECT Id FROM Resume_Data__c WHERE Id = :rid];
        Boolean threw = false;
        Test.startTest();
        try { ResumeWizardController.commitDrafts(rid, '[]', null); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assert(threw, 'A deleted resume should fail before child DML');
    }

    @isTest
    static void abandonDraftDeletesTemporaryResumeAndFile() {
        Id rid = makeDraftResume();
        ContentVersion cv = new ContentVersion(
            Title = 'synthetic-resume',
            PathOnClient = 'synthetic-resume.pdf',
            VersionData = Blob.valueOf('synthetic'),
            FirstPublishLocationId = rid
        );
        insert cv;
        Id contentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        update new Resume_Data__c(Id = rid, Source_ContentDocumentId__c = contentDocumentId);

        Test.startTest();
        Boolean removed = ResumeWizardController.abandonDraft(rid);
        Test.stopTest();

        System.assertEquals(true, removed, 'Draft should be removed');
        System.assertEquals(0, [SELECT COUNT() FROM Resume_Data__c WHERE Id = :rid]);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :contentDocumentId]);
    }

    @isTest
    static void abandonDraftPreservesSuccessfulResume() {
        Id rid = makeDraftResume();
        update new Resume_Data__c(Id = rid, Processing_Status__c = 'Success');

        Test.startTest();
        Boolean removed = ResumeWizardController.abandonDraft(rid);
        Test.stopTest();

        System.assertEquals(false, removed, 'Successful resumes must never be removed by reset');
        System.assertEquals(1, [SELECT COUNT() FROM Resume_Data__c WHERE Id = :rid]);
    }

    @isTest
    static void abandonDraftRejectsInvalidId() {
        Boolean threw = false;
        Test.startTest();
        try { ResumeWizardController.abandonDraft('not-an-id'); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assert(threw, 'A malformed resume id should throw');
    }

    @isTest
    static void abandonDraftDoesNotDeleteUnlinkedDocument() {
        Id rid = makeDraftResume();
        Contact unrelatedOwner = new Contact(LastName = 'Synthetic File Owner');
        insert unrelatedOwner;
        ContentVersion cv = new ContentVersion(
            Title = 'unrelated-synthetic-file',
            PathOnClient = 'unrelated-synthetic-file.pdf',
            VersionData = Blob.valueOf('synthetic'),
            FirstPublishLocationId = unrelatedOwner.Id
        );
        insert cv;
        Id unrelatedDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        update new Resume_Data__c(Id = rid, Source_ContentDocumentId__c = unrelatedDocumentId);

        Test.startTest();
        Boolean removed = ResumeWizardController.abandonDraft(rid);
        Test.stopTest();

        System.assertEquals(true, removed, 'The temporary resume can still be discarded');
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocument WHERE Id = :unrelatedDocumentId],
            'An unlinked Salesforce File must never be deleted from the stored text pointer alone');
    }

    @isTest
    static void abandonDraftRejectsMalformedStoredFileId() {
        Id rid = makeDraftResume();
        update new Resume_Data__c(Id = rid, Source_ContentDocumentId__c = 'not-an-id');
        Boolean threw = false;

        Test.startTest();
        try { ResumeWizardController.abandonDraft(rid); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();

        System.assert(threw, 'A malformed stored file reference should stop cleanup');
        System.assertEquals(1, [SELECT COUNT() FROM Resume_Data__c WHERE Id = :rid],
            'No data should be removed when the stored file reference is malformed');
    }

    // ── CMDT-driven behavior ─────────────────────────────────────────

    @isTest
    static void buildExtraInstructionsCoversBothLevels() {
        useTestMappings();
        String s = ResumeParsing.buildExtraInstructions();
        // Fully CMDT-driven schema: candidate keys at the top level, roles inside a nested array.
        System.assert(s.contains('"candidateName"'), 'Candidate-level key present');
        System.assert(s.contains('"workExperiences": ['), 'workExperiences emitted as a nested array');
        System.assert(s.contains('"company"'), 'Role key present inside the array');
        System.assert(s.contains('Empty string if not found.'), 'Empty-value guidance present on string keys');
        System.assert(s.contains('Use false if not indicated.'), 'Boolean guidance present for the isCurrent checkbox');
        System.assert(!s.contains('Top-level candidate keys:'), 'Old prose-header format is gone (now a real JSON skeleton)');
    }

    @isTest
    static void mapDrivesWhichFieldsAppear() {
        // The map is the single source of truth: with only a candidate-level mapping and NO
        // Work_Experience__c mappings, no role fields are produced even when the JSON has roles.
        ResumeParsing.overrideMappings = new List<Resume_Field_Map__mdt>{
            new Resume_Field_Map__mdt(Parse_Key__c = 'candidateName', Target_Object__c = 'Resume_Data__c',
                Target_Field_API_Name__c = 'Candidate_Name__c', Data_Type__c = 'Text', Max_Length__c = 255,
                Is_Active__c = true, Include_In_Prompt__c = true, Sort_Order__c = 1)
        };
        ResumeParsing.ParseResult r = ResumeParsing.toDrafts(
            '{"candidateName":"Solo","workExperiences":[{"company":"Acme","title":"Dev"}]}');
        System.assertEquals('Solo', r.candidateName);
        System.assertEquals(1, r.workExperiences.size(), 'Row still created, but with no mapped role fields');
        System.assertEquals(null, r.workExperiences[0].company, 'No company mapping → company stays null');
    }

    @isTest
    static void coercionHelpers() {
        System.assertEquals(Decimal.valueOf('1200'), ResumeParsing.parseNumber('$1,200'), 'parseNumber strips symbols');
        System.assertEquals(null, ResumeParsing.parseNumber('   '), 'blank → null');
        System.assertEquals('Other', ResumeParsing.coerceEmploymentType('Gig'), 'unknown type → Other');
        System.assertEquals('Contract', ResumeParsing.coerceEmploymentType('contract'), 'case-insensitive match');
        System.assertEquals(null, ResumeParsing.truncate(null, 10), 'null → null');
        System.assertEquals('abc', ResumeParsing.truncate('abcdef', 3), 'truncates to max');
        System.assertEquals('abcdef', ResumeParsing.truncate('abcdef', null), 'null max → no limit');
    }

    @isTest
    static void fieldMapViewsExposeCmdtRows() {
        useTestMappings();
        List<ResumeParsing.FieldMapView> views = ResumeWizardController.getFieldMap();
        System.assertEquals(12, views.size(), 'One view per active mapping');

        ResumeParsing.FieldMapView nameView;
        for (ResumeParsing.FieldMapView v : views) {
            if (v.parseKey == 'candidateName') { nameView = v; }
        }
        System.assertNotEquals(null, nameView, 'candidateName mapping is exposed');
        System.assertEquals('Resume_Data__c', nameView.targetObject);
        System.assertEquals('Candidate_Name__c', nameView.targetField);
        System.assertNotEquals(null, nameView.targetLabel, 'Target field label resolved from describe');
        System.assertEquals(false, nameView.readOnly);
    }
}
