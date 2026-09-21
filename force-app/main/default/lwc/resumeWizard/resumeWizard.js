/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 * For full license text, see the LICENSE.txt file in the repo root or
 * https://opensource.org/licenses/Apache-2.0
 */

import { LightningElement, api, track } from 'lwc';
import uploadAndParse from '@salesforce/apex/ResumeWizardController.uploadAndParse';
import commitDrafts from '@salesforce/apex/ResumeWizardController.commitDrafts';
import abandonDraft from '@salesforce/apex/ResumeWizardController.abandonDraft';
import getFieldMap from '@salesforce/apex/ResumeWizardController.getFieldMap';
import {
  buildDisclosureRows,
  buildRoleTableColumns,
  flattenRoleRows,
  updateFieldValue,
  visibleFields
} from './dynamicFields';

const ENVELOPE_FIELD = 'resumeWizardJSON';
function peelValueWrapper(parsed) {
  if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
    const keys = Object.keys(parsed);
    if (keys.length === 1 && keys[0] === 'value' && parsed.value && typeof parsed.value === 'object') {
      return parsed.value;
    }
  }
  return parsed;
}
function unwrapEnvelope(raw) {
  if (raw == null || typeof raw !== 'object') return raw;
  if (!(ENVELOPE_FIELD in raw)) return peelValueWrapper(raw);
  const field = raw[ENVELOPE_FIELD];
  if (typeof field === 'string' && field.trim()) {
    try { return peelValueWrapper(JSON.parse(field)); } catch { return null; }
  }
  return null;
}

const ALLOWED_EXTENSIONS = ['.pdf', '.png', '.jpg'];

export default class ResumeWizard extends LightningElement {
  _value;
  @api
  get value() { return this._value; }
  set value(v) {
    this._value = unwrapEnvelope(v);
    this.prefillContact();
  }

  @track step = 'upload';
  @track errorMessage = '';
  @api recordId;
  @track selectedContactId;
  _file;
  fileName = '';

  // The map is both disclosure and runtime UI schema. Loading fails closed.
  @track fieldMap = [];
  fieldMapState = 'loading';
  @track showFieldMap = false;

  // Generic review envelopes returned by Apex.
  resumeDataId;
  @track candidateFields = [];
  @track drafts = [];
  @track activeIndex = 0;
  savedCount = 0;

  connectedCallback() {
    this.prefillContact();
    this.loadFieldMap();
  }

  async loadFieldMap() {
    this.fieldMapState = 'loading';
    try {
      const rows = await getFieldMap();
      if (!rows || !rows.some((row) => row.supported === true)) {
        throw new Error('No supported active mappings were returned.');
      }
      this.fieldMap = rows;
      this.fieldMapState = 'ready';
    } catch {
      this.fieldMap = [];
      this.fieldMapState = 'error';
    }
  }

  handleToggleFieldMap() { this.showFieldMap = !this.showFieldMap; }

  prefillContact() {
    const fromConfig = this._value && this._value.contactId;
    if (fromConfig && String(fromConfig).startsWith('003')) {
      this.selectedContactId = fromConfig;
    } else if (this.recordId && this.recordId.startsWith('003')) {
      this.selectedContactId = this.recordId;
    }
  }

  // ── Display state ──
  get title() { return this._value?.title || 'Résumé Parser'; }
  get subtitle() { return this._value?.subtitle || 'Upload a résumé, review the parsed work history, then save.'; }
  get isUpload() { return this.step === 'upload'; }
  get isParsing() { return this.step === 'parsing'; }
  get isPreview() { return this.step === 'preview'; }
  get isCommitting() { return this.step === 'committing'; }
  get isDone() { return this.step === 'done'; }
  get isError() { return this.step === 'error'; }
  get hasDrafts() { return this.drafts.length > 0; }
  get roleCount() { return this.drafts.length; }
  get pagerLabel() { return `Role ${this.activeIndex + 1} of ${this.drafts.length}`; }
  get atFirst() { return this.activeIndex <= 0; }
  get atLast() { return this.activeIndex >= this.drafts.length - 1; }
  get activeDraft() { return this.drafts[this.activeIndex] || { fields: [] }; }
  get confirmLabel() {
    return `Save ${this.drafts.length} work experience${this.drafts.length === 1 ? '' : 's'}`;
  }
  get doneMessage() {
    return `Saved ${this.savedCount} work experience record${this.savedCount === 1 ? '' : 's'}.`;
  }

  get fieldMapReady() { return this.fieldMapState === 'ready'; }
  get isFieldMapLoading() { return this.fieldMapState === 'loading'; }
  get isFieldMapError() { return this.fieldMapState === 'error'; }
  get visibleCandidateFields() { return visibleFields(this.candidateFields); }
  get activeDraftFields() { return visibleFields(this.activeDraft.fields); }
  get hasVisibleCandidateFields() { return this.visibleCandidateFields.length > 0; }
  get hasVisibleRoleFields() { return this.activeDraftFields.length > 0; }
  get tableColumns() { return buildRoleTableColumns(this.fieldMap); }
  get hasVisibleRoleTableFields() { return this.tableColumns.length > 0; }
  get tableRows() { return flattenRoleRows(this.drafts); }

  get hasFieldMap() { return (this.fieldMap || []).length > 0; }
  get fieldMapToggleLabel() { return this.showFieldMap ? 'Hide field mapping' : 'How fields map'; }
  get fieldMapToggleIcon() { return this.showFieldMap ? 'utility:chevrondown' : 'utility:chevronright'; }
  get fieldMapRows() { return buildDisclosureRows(this.fieldMap); }

  get canUpload() { return !!this.selectedContactId && !!this._file; }
  get uploadDisabled() { return !this.canUpload || !this.fieldMapReady; }

  // ── Upload ──
  handleContactChange(event) {
    this.selectedContactId = event.detail ? event.detail.recordId : null;
    this.errorMessage = '';
  }

  handleFileChange(event) {
    this.errorMessage = '';
    const file = (event.target.files || [])[0];
    if (!file) return;
    const ext = file.name.toLowerCase().substring(file.name.lastIndexOf('.'));
    if (!ALLOWED_EXTENSIONS.includes(ext)) {
      this.errorMessage = `Unsupported file type "${ext}". Please use .pdf, .png, or .jpg (note: .jpeg is not supported — convert to .jpg).`;
      return;
    }
    this._file = file;
    this.fileName = file.name;
  }

  async handleUploadAndParse() {
    if (!this.selectedContactId) {
      this.errorMessage = 'Please select the Contact this résumé belongs to.';
      return;
    }
    if (!this._file) {
      this.errorMessage = 'Please choose a résumé file first.';
      return;
    }
    if (!this.fieldMapReady) {
      this.errorMessage = 'The review configuration is not ready. Refresh the wizard and try again.';
      return;
    }
    this.errorMessage = '';
    this.step = 'parsing';
    try {
      const base64Data = await this.readAsBase64(this._file);
      const result = await uploadAndParse({
        fileName: this._file.name,
        base64Data,
        contactId: this.selectedContactId
      });
      this.resumeDataId = result.resumeDataId;
      this.candidateFields = result.candidateFields || [];
      this.drafts = (result.workExperiences || []).map((row, index) => ({
        ...row,
        rowId: row.rowId || `row-${index}`,
        fields: row.fields || []
      }));
      this.activeIndex = 0;
      this.step = this.drafts.length ? 'preview' : 'error';
      if (!this.drafts.length) {
        this.errorMessage = 'No work experience could be read from that résumé. Try a clearer PDF, PNG, or JPG.';
      }
    } catch (err) {
      this.step = 'error';
      this.errorMessage = this.extractError(err);
    }
  }

  // ── Generic review editing ──
  handlePrev() { if (!this.atFirst) this.activeIndex -= 1; }
  handleNext() { if (!this.atLast) this.activeIndex += 1; }

  handleRowSelect(event) {
    const id = event.detail?.row?.id || event.currentTarget?.dataset?.id;
    const index = this.drafts.findIndex((row) => row.rowId === id);
    if (index >= 0) this.activeIndex = index;
  }

  eventValue(event) {
    return event.target.type === 'checkbox' ? event.target.checked : event.target.value;
  }

  handleCandidateChange(event) {
    this.candidateFields = updateFieldValue(
      this.candidateFields,
      event.target.dataset.key,
      this.eventValue(event)
    );
  }

  handleDraftChange(event) {
    const next = [...this.drafts];
    const active = next[this.activeIndex];
    next[this.activeIndex] = {
      ...active,
      fields: updateFieldValue(active.fields, event.target.dataset.key, this.eventValue(event))
    };
    this.drafts = next;
  }

  handleRemoveRole() {
    const next = this.drafts.filter((_, index) => index !== this.activeIndex);
    this.drafts = next;
    if (this.activeIndex >= next.length) this.activeIndex = Math.max(0, next.length - 1);
    if (next.length === 0) this.errorMessage = 'All roles removed. Re-upload a résumé to start over.';
  }

  // ── Commit ──
  async handleConfirm() {
    this.errorMessage = '';
    this.step = 'committing';
    try {
      this.savedCount = await commitDrafts({
        resumeDataId: this.resumeDataId,
        rowsJson: JSON.stringify(this.drafts),
        candidateJson: JSON.stringify(this.candidateFields)
      });
      this.step = 'done';
    } catch (err) {
      this.step = 'preview';
      this.errorMessage = this.extractError(err);
    }
  }

  async handleReset() {
    if (this.resumeDataId) {
      try {
        await abandonDraft({ resumeDataId: this.resumeDataId });
      } catch (err) {
        this.errorMessage = `Could not discard the temporary résumé: ${this.extractError(err)}`;
        return;
      }
    }
    this._file = undefined;
    this.fileName = '';
    this.resumeDataId = undefined;
    this.candidateFields = [];
    this.drafts = [];
    this.activeIndex = 0;
    this.savedCount = 0;
    this.errorMessage = '';
    this.selectedContactId = null;
    this.prefillContact();
    this.step = 'upload';
  }

  readAsBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result.split(',')[1]);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(file);
    });
  }

  extractError(err) {
    return (err && err.body && err.body.message) || (err && err.message) || 'Something went wrong.';
  }
}
