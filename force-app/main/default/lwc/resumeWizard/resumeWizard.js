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

/* ── CLT value envelope unwrap (matches the fileUpload CLT pattern) ──
   The agent passes a config JSON (title, subtitle, contactId) wrapped in an Apex envelope
   field. We use it for the display labels and to pre-select the Contact; the wizard is
   otherwise self-driving via Apex regardless of config. */
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

const EMPLOYMENT_TYPE_OPTIONS = [
  'Full-time', 'Part-time', 'Contract', 'Internship', 'Temporary', 'Freelance', 'Other'
].map((t) => ({ label: t, value: t }));

const ALLOWED_EXTENSIONS = ['.pdf', '.png', '.jpg'];

const TABLE_COLUMNS = [
  { label: 'Company', fieldName: 'company' },
  { label: 'Title', fieldName: 'title' },
  { label: 'Start', fieldName: 'startDate', type: 'date-local',
    typeAttributes: { month: '2-digit', day: '2-digit', year: 'numeric' } },
  { label: 'End', fieldName: 'endDate', type: 'date-local',
    typeAttributes: { month: '2-digit', day: '2-digit', year: 'numeric' } },
  { label: 'Type', fieldName: 'employmentType' }
];

export default class ResumeWizard extends LightningElement {
  _value;
  @api
  get value() { return this._value; }
  set value(v) {
    this._value = unwrapEnvelope(v);
    // The CLT value can arrive after connectedCallback; pre-fill the Contact when it does.
    this.prefillContact();
  }

  // step: upload | parsing | preview | committing | done | error
  @track step = 'upload';
  @track errorMessage = '';

  // Contact context: auto-populated when the agent/CLT is opened on a Contact record page.
  @api recordId;
  @track selectedContactId;

  // upload state
  _file;
  fileName = '';

  // Read-only CMDT field-map disclosure ("How fields map").
  @track fieldMap = [];
  @track showFieldMap = false;

  connectedCallback() {
    this.prefillContact();
    this.loadFieldMap();
  }

  // Load the active Resume_Field_Map__mdt rows for the disclosure. Fails quietly — the field map
  // is informational, so any error just leaves the section hidden and never breaks the wizard.
  loadFieldMap() {
    getFieldMap()
      .then((rows) => { this.fieldMap = rows || []; })
      .catch(() => { this.fieldMap = []; });
  }

  handleToggleFieldMap() { this.showFieldMap = !this.showFieldMap; }

  // Pre-fill the Contact picker from (1) the agent-supplied contactId in the CLT config, or
  // (2) the host record-page id when embedded on a Contact page. The agent resolves/confirms
  // the Contact conversationally and passes its Id in the Details JSON (config.contactId).
  prefillContact() {
    const fromConfig = this._value && this._value.contactId;
    if (fromConfig && String(fromConfig).startsWith('003')) {
      this.selectedContactId = fromConfig;
    } else if (this.recordId && this.recordId.startsWith('003')) {
      this.selectedContactId = this.recordId;
    }
  }

  // parse/preview state
  resumeDataId;
  @track candidate = { candidateName: '', candidateEmail: '', candidatePhone: '', summary: '' };
  @track drafts = [];
  @track activeIndex = 0;
  savedCount = 0;

  employmentTypeOptions = EMPLOYMENT_TYPE_OPTIONS;
  tableColumns = TABLE_COLUMNS;

  // ── display getters (config-driven labels with sensible defaults) ──
  get title() { return this._value?.title || 'Résumé Parser'; }
  get subtitle() { return this._value?.subtitle || 'Upload a résumé, review the parsed work history, then save.'; }

  get isUpload()   { return this.step === 'upload'; }
  get isParsing()  { return this.step === 'parsing'; }
  get isPreview()  { return this.step === 'preview'; }
  get isCommitting(){ return this.step === 'committing'; }
  get isDone()     { return this.step === 'done'; }
  get isError()    { return this.step === 'error'; }

  get hasDrafts() { return this.drafts.length > 0; }
  get roleCount() { return this.drafts.length; }
  get pagerLabel() { return `Role ${this.activeIndex + 1} of ${this.drafts.length}`; }
  get atFirst() { return this.activeIndex <= 0; }
  get atLast() { return this.activeIndex >= this.drafts.length - 1; }
  get activeDraft() { return this.drafts[this.activeIndex] || {}; }
  get confirmLabel() {
    return `Save ${this.drafts.length} work experience${this.drafts.length === 1 ? '' : 's'}`;
  }
  get doneMessage() {
    return `Saved ${this.savedCount} work experience record${this.savedCount === 1 ? '' : 's'}.`;
  }

  // table rows need a key; map drafts → display rows
  get tableRows() {
    return this.drafts.map((d) => ({ ...d, id: d.rowId }));
  }

  // ── Field-map disclosure getters ──
  get hasFieldMap() { return (this.fieldMap || []).length > 0; }
  get fieldMapToggleLabel() { return this.showFieldMap ? 'Hide field mapping' : 'How fields map'; }
  get fieldMapToggleIcon() { return this.showFieldMap ? 'utility:chevrondown' : 'utility:chevronright'; }
  get fieldMapRows() {
    return (this.fieldMap || []).map((m, i) => ({
      id: `${m.parseKey}-${i}`,
      parseKey: m.parseKey,
      // "Object · Field label" (fall back to the API name when no label resolved)
      target: `${m.targetObject || ''}${m.targetField ? ' · ' + (m.targetLabel || m.targetField) : ''}`,
      type: m.dataType,
      access: m.readOnly ? 'Read-only' : (m.showInReview ? 'Editable' : 'Hidden')
    }));
  }

  // can only upload once a Contact and a file are both chosen
  get canUpload() { return !!this.selectedContactId && !!this._file; }
  get uploadDisabled() { return !this.canUpload; }

  // ── Upload step ──
  handleContactChange(event) {
    // lightning-record-picker fires onchange with detail.recordId (null when cleared)
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
    this.errorMessage = '';
    this.step = 'parsing';
    try {
      const base64Data = await this.readAsBase64(this._file);
      const result = await uploadAndParse({ fileName: this._file.name, base64Data, contactId: this.selectedContactId });
      this.resumeDataId = result.resumeDataId;
      this.candidate = {
        candidateName: result.candidateName || '',
        candidateEmail: result.candidateEmail || '',
        candidatePhone: result.candidatePhone || '',
        summary: result.summary || ''
      };
      this.drafts = (result.workExperiences || []).map((d, i) => ({ ...d, rowId: d.rowId || `row-${i}` }));
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

  // ── Preview step: pager ──
  handlePrev() { if (!this.atFirst) this.activeIndex -= 1; }
  handleNext() { if (!this.atLast) this.activeIndex += 1; }

  handleRowSelect(event) {
    const id = event.detail?.row?.id || event.currentTarget?.dataset?.id;
    const idx = this.drafts.findIndex((d) => d.rowId === id);
    if (idx >= 0) this.activeIndex = idx;
  }

  // ── Preview step: inline edits ──
  handleCandidateChange(event) {
    const field = event.target.dataset.field;
    this.candidate = { ...this.candidate, [field]: event.target.value };
  }

  handleDraftChange(event) {
    const field = event.target.dataset.field;
    const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
    const next = [...this.drafts];
    next[this.activeIndex] = { ...next[this.activeIndex], [field]: value };
    this.drafts = next;
  }

  handleRemoveRole() {
    const next = this.drafts.filter((_, i) => i !== this.activeIndex);
    this.drafts = next;
    if (this.activeIndex >= next.length) this.activeIndex = Math.max(0, next.length - 1);
    if (next.length === 0) {
      this.errorMessage = 'All roles removed. Re-upload a résumé to start over.';
    }
  }

  // ── Commit step ──
  async handleConfirm() {
    this.errorMessage = '';
    this.step = 'committing';
    try {
      const rows = this.drafts.map((d) => ({
        rowId: d.rowId,
        company: d.company,
        title: d.title,
        startDate: d.startDate,
        endDate: d.endDate,
        isCurrent: d.isCurrent === true,
        location: d.location,
        employmentType: d.employmentType,
        description: d.description
      }));
      // Include the user's candidate-level edits so they persist too (name/email/phone/summary).
      const candidate = {
        candidateName: this.candidate.candidateName,
        candidateEmail: this.candidate.candidateEmail,
        candidatePhone: this.candidate.candidatePhone,
        summary: this.candidate.summary
      };
      // Pass as JSON strings — a List<InnerClass>/object Apex param loses field values across the
      // LWC→Apex binding; the controller JSON.deserializes these back into typed drafts.
      this.savedCount = await commitDrafts({
        resumeDataId: this.resumeDataId,
        rowsJson: JSON.stringify(rows),
        candidateJson: JSON.stringify(candidate)
      });
      this.step = 'done';
    } catch (err) {
      this.step = 'preview';
      this.errorMessage = this.extractError(err);
    }
  }

  async handleReset() {
    // Preview data already has a persisted Draft parent + uploaded file. Remove both before
    // starting over so Re-upload doesn't leave abandoned temporary records. A successful resume
    // is preserved; abandonDraft is intentionally a no-op for Success status.
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
    this.candidate = { candidateName: '', candidateEmail: '', candidatePhone: '', summary: '' };
    this.drafts = [];
    this.activeIndex = 0;
    this.savedCount = 0;
    this.errorMessage = '';
    // Re-apply the pre-filled Contact (from config or page context) for the next résumé.
    this.selectedContactId = null;
    this.prefillContact();
    this.step = 'upload';
  }

  // ── helpers ──
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