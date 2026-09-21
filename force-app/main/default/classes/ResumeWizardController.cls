/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 * For full license text, see the LICENSE.txt file in the repo root or
 * https://opensource.org/licenses/Apache-2.0
 */

/**
 * @description Imperative controller for the in-chat resume wizard LWC (c/resumeWizard).
 * The wizard owns the whole flow client-side and calls these methods directly —
 * no agent round-trip — which is why it works in the Lightning Agentforce panel.
 *
 *   1. uploadAndParse  → create Resume_Data__c (Draft) + attach file, run the
 *                        Extract_Work_Experience prompt template, return editable
 *                        drafts. NOTHING is written to Work_Experience__c yet.
 *   2. commit          → persist the (possibly user-edited) drafts as children,
 *                        replacing any prior set, and stamp the parent Success.
 *
 * All transformation + the concurrency-safe replace live in ResumeParsing.
 */
public with sharing class ResumeWizardController {

    private static final String PROMPT_TEMPLATE = 'Extract_Work_Experience';

    /**
     * @description Validated active Resume_Field_Map__mdt projection used by the generic review UI
     * and the transparent "How fields map" disclosure. Cacheable — pure SOQL + describe, no DML.
     */
    @AuraEnabled(cacheable=true)
    public static List<ResumeParsing.FieldMapView> getFieldMap() {
        return ResumeParsing.fieldMapViews();
    }

    /**
     * @description Step 1 — receive the uploaded file, attach it, and parse it into
     * editable drafts for the wizard's preview. Creates the parent in 'Draft' status.
     * Does not create any Work_Experience__c rows.
     */
    @AuraEnabled
    public static ResumeParsing.ParseResult uploadAndParse(String fileName, String base64Data, String contactId) {
        if (String.isBlank(fileName) || String.isBlank(base64Data)) {
            throw new AuraHandledException('A file name and file contents are required.');
        }
        if (String.isBlank(contactId)) {
            throw new AuraHandledException('Please select the Contact this resume belongs to.');
        }
        Id contactRef;
        try {
            contactRef = (Id) contactId;
            if (contactRef.getSObjectType() != Contact.SObjectType) {
                throw new AuraHandledException('The selected record is not a Contact.');
            }
        } catch (System.StringException se) {
            throw new AuraHandledException('The Contact id was not valid.');
        }

        Resume_Data__c resume;
        Id contentDocumentId;
        Savepoint sp = Database.setSavepoint();
        try {
            // 1. Persist a Draft parent linked to the chosen Contact. The draft and uploaded file
            //    exist before confirmation; Work_Experience__c children are deferred until commit.
            resume = new Resume_Data__c(Processing_Status__c = 'Draft', Contact__c = contactRef);
            insert resume;

            // 2. Attach the file (FirstPublishLocationId auto-creates the ContentDocumentLink).
            ContentVersion cv = new ContentVersion(
                Title                  = fileName,
                PathOnClient           = fileName,
                VersionData            = EncodingUtil.base64Decode(base64Data),
                FirstPublishLocationId = resume.Id
            );
            insert cv;
            contentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].ContentDocumentId;

            resume.Source_ContentDocumentId__c = contentDocumentId;
            update resume;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Could not save the uploaded file: ' + e.getMessage());
        }

        // 3. Parse via the prompt template. If parsing fails, remove the temporary Draft/file so
        //    a failed upload doesn't leave retained résumé data behind.
        try {
            String rawJson = invokeTemplate(contentDocumentId);
            ResumeParsing.ParseResult result = ResumeParsing.toDrafts(rawJson);
            result.resumeDataId = resume.Id;

            // Stamp the candidate-level fields on the parent now so the record is useful even
            // before commit; the children are intentionally deferred to commit(). Which fields land
            // where is driven by the Resume_Field_Map__mdt map (Target Object = Resume_Data__c).
            Resume_Data__c stamp = new Resume_Data__c(Id = resume.Id);
            ResumeParsing.applyCandidateFields(stamp, result.candidateFields);
            update stamp;
            return result;
        } catch (Exception e) {
            cleanupDraft(resume.Id, contentDocumentId);
            throw new AuraHandledException('I could not read the resume, so the temporary draft and file were removed: ' + e.getMessage());
        }
    }

    /**
     * @description Discard an uncommitted Draft/Error resume and its uploaded file when the user
     * chooses Re-upload. Successful resumes are never removed by this method.
     * @param resumeDataId Id of the temporary Resume_Data__c record.
     * @return true when an uncommitted draft was removed; false when no removable draft exists.
     */
    @AuraEnabled
    public static Boolean abandonDraft(String resumeDataId) {
        if (String.isBlank(resumeDataId)) { return false; }
        Id resumeId;
        try {
            resumeId = (Id) resumeDataId;
            if (resumeId.getSObjectType() != Resume_Data__c.SObjectType) {
                throw new AuraHandledException('The resume record id was not valid.');
            }
        } catch (System.StringException e) {
            throw new AuraHandledException('The resume record id was not valid.');
        }

        List<Resume_Data__c> candidates = [
            SELECT Id, Processing_Status__c, Source_ContentDocumentId__c
            FROM Resume_Data__c
            WHERE Id = :resumeId
            LIMIT 1
            FOR UPDATE
        ];
        if (candidates.isEmpty() || candidates[0].Processing_Status__c == 'Success') { return false; }

        Id contentDocumentId;
        try {
            contentDocumentId = String.isBlank(candidates[0].Source_ContentDocumentId__c)
                ? null : (Id) candidates[0].Source_ContentDocumentId__c;
        } catch (System.StringException e) {
            throw new AuraHandledException('The stored file reference is invalid; no data was removed.');
        }
        cleanupDraft(candidates[0].Id, contentDocumentId);
        return true;
    }

    /** Remove a temporary parent and its uploaded ContentDocument atomically. */
    private static void cleanupDraft(Id resumeId, Id contentDocumentId) {
        Savepoint cleanupSavepoint = Database.setSavepoint();
        try {
            if (contentDocumentId != null) {
                // Delete only the file that is actually linked to this temporary résumé. The stored
                // text pointer alone is never sufficient authority to delete a Salesforce File.
                List<ContentDocumentLink> ownedLinks = [
                    SELECT Id
                    FROM ContentDocumentLink
                    WHERE LinkedEntityId = :resumeId AND ContentDocumentId = :contentDocumentId
                    LIMIT 1
                ];
                if (!ownedLinks.isEmpty()) {
                    List<ContentDocument> docs = [
                        SELECT Id FROM ContentDocument WHERE Id = :contentDocumentId LIMIT 1
                    ];
                    if (!docs.isEmpty()) { delete docs; }
                }
            }
            List<Resume_Data__c> resumes = [SELECT Id FROM Resume_Data__c WHERE Id = :resumeId LIMIT 1];
            if (!resumes.isEmpty()) { delete resumes; }
        } catch (Exception cleanupError) {
            Database.rollback(cleanupSavepoint);
            throw cleanupError;
        }
    }

    /**
     * @description Step 2 — commit the user-reviewed drafts as the resume's children,
     * replacing any prior set, and stamp the parent Success. Returns the saved count.
     *
     * rowsJson is the wizard's generic role envelopes as a JSON string; candidateJson is the
     * generic candidate FieldDraft list. We deserialize here because direct LWC binding to Apex
     * inner-class collections can silently drop member values.
     */
    @AuraEnabled
    public static Integer commitDrafts(String resumeDataId, String rowsJson, String candidateJson) {
        if (String.isBlank(resumeDataId)) {
            throw new AuraHandledException('No resume record was provided.');
        }
        Id resumeId;
        try {
            resumeId = (Id) resumeDataId;
        } catch (Exception e) {
            throw new AuraHandledException('The resume record id was not valid.');
        }

        List<ResumeParsing.WorkExperienceDraft> rows;
        try {
            rows = (List<ResumeParsing.WorkExperienceDraft>) JSON.deserialize(
                String.isBlank(rowsJson) ? '[]' : rowsJson,
                List<ResumeParsing.WorkExperienceDraft>.class
            );
        } catch (Exception e) {
            throw new AuraHandledException('The work experiences could not be read: ' + e.getMessage());
        }

        // Generic candidate field envelopes round-trip parseKey + value; server-side CMDT is still
        // the only authority for target object/field/type.
        List<ResumeParsing.FieldDraft> candidateFields;
        if (String.isNotBlank(candidateJson)) {
            try {
                candidateFields = (List<ResumeParsing.FieldDraft>) JSON.deserialize(
                    candidateJson, List<ResumeParsing.FieldDraft>.class);
            } catch (Exception e) {
                throw new AuraHandledException('The candidate details could not be read: ' + e.getMessage());
            }
        }

        try {
            List<Work_Experience__c> saved = ResumeParsing.commitDrafts(resumeId, rows);
            Resume_Data__c parent = new Resume_Data__c(
                Id = resumeId,
                Processing_Status__c = 'Success',
                Last_Processed__c = System.now()
            );
            if (candidateFields != null) {
                ResumeParsing.applyCandidateFields(parent, candidateFields);
            }
            update parent;
            return saved.size();
        } catch (Exception e) {
            throw new AuraHandledException('Could not save the work experiences: ' + e.getMessage());
        }
    }

    /**
     * @description Invoke the Extract_Work_Experience Flex prompt template against the uploaded
     * ContentDocument and return the raw response string.
     *
     * The template has NO hardcoded field list: the entire extraction schema (candidate keys plus the
     * workExperiences[] role keys) is built from the active Resume_Field_Map__mdt rows by
     * ResumeParsing.buildExtraInstructions() and passed in via {!$Input:ExtraInstructions}. Existing
     * valid candidate/role keys can be added through CMDT without named DTO members. Runtime validation
     * still restricts them to direct fields on Resume_Data__c and Work_Experience__c plus supported types.
     */
    private static String invokeTemplate(Id contentDocumentId) {
        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = new Map<String, Object>{ 'id' => contentDocumentId, 'type' => 'ContentDocument' };

        ConnectApi.WrappedValue extraVal = new ConnectApi.WrappedValue();
        extraVal.value = ResumeParsing.buildExtraInstructions();

        ConnectApi.EinsteinPromptTemplateGenerationsInput inp = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        inp.inputParams = new Map<String, ConnectApi.WrappedValue>{
            'Input:ResumeFile' => wv,
            'Input:ExtraInstructions' => extraVal
        };
        inp.isPreview = false;   // required — a null previewOnly throws inside the platform
        inp.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        inp.additionalConfig.applicationName = 'PromptTemplateGenerationsInvocable';

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation res =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PROMPT_TEMPLATE, inp);
        return res.generations[0].text;
    }
}
