/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 * For full license text, see the LICENSE.txt file in the repo root or
 * https://opensource.org/licenses/Apache-2.0
 */

/**
 * @description Lightning Type backing class for the résumé wizard CLT. Holds the
 * display-config JSON as a string; the matching LWC (c/resumeWizard) parses it into
 * `@api value`. Mirrors the standard Lightning-type data-envelope pattern.
 */
@JsonAccess(serializable='always' deserializable='always')
global class ResumeWizardData {

    @AuraEnabled
    global String resumeWizardJSON;

    global ResumeWizardData(String resumeWizardJSON) {
        this.resumeWizardJSON = resumeWizardJSON;
    }

    global ResumeWizardData() {
        this.resumeWizardJSON = '';
    }
}
