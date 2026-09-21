/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 */

export function decorateFields(fields) {
  return (fields || []).map((field) => ({
    ...field,
    checked: String(field.value).toLowerCase() === 'true',
    disabled: field.readOnly === true,
    isPicklist: field.inputKind === 'picklist',
    isCheckbox: field.inputKind === 'checkbox',
    isTextarea: field.inputKind === 'textarea',
    isInput: field.inputKind === 'input',
    options: (field.options || []).map((value) => ({ label: value, value }))
  }));
}

export function visibleFields(fields) {
  return decorateFields(fields).filter((field) =>
    field.showInReview === true && field.supported !== false);
}

function tableType(dataType) {
  if (dataType === 'Date') return 'date-local';
  if (dataType === 'Checkbox') return 'boolean';
  if (dataType === 'Number') return 'number';
  return 'text';
}

function tableColumnWidth(field) {
  const labelLength = (field.targetLabel || field.parseKey || '').length;
  if (field.dataType === 'Checkbox') return 160;
  if (field.dataType === 'Date' || field.dataType === 'Number') return 150;
  if (field.dataType === 'Picklist') return Math.max(180, Math.min(280, labelLength * 8 + 56));
  return Math.max(160, Math.min(280, labelLength * 8 + 56));
}

export function buildRoleTableColumns(fieldMap) {
  return (fieldMap || [])
    .filter((field) => field.supported === true &&
      field.targetObject === 'Work_Experience__c' && field.showInReview === true)
    .map((field) => ({
      label: field.targetLabel || field.parseKey,
      fieldName: field.parseKey,
      type: tableType(field.dataType),
      initialWidth: tableColumnWidth(field),
      wrapText: true,
      ...(field.dataType === 'Date'
        ? { typeAttributes: { month: '2-digit', day: '2-digit', year: 'numeric' } }
        : {})
    }));
}

export function flattenRoleRows(rows) {
  return (rows || []).map((row) => {
    const flat = { id: row.rowId };
    (row.fields || []).forEach((field) => {
      flat[field.parseKey] = field.dataType === 'Checkbox'
        ? String(field.value).toLowerCase() === 'true'
        : field.value;
    });
    return flat;
  });
}

export function updateFieldValue(fields, parseKey, value) {
  return (fields || []).map((field) => field.parseKey === parseKey
    ? { ...field, value: String(value), checked: value === true || String(value).toLowerCase() === 'true' }
    : field);
}

export function buildDisclosureRows(fieldMap) {
  return (fieldMap || []).map((mapping, index) => {
    const access = mapping.supported !== true
      ? `Ignored: ${mapping.issue}`
      : (mapping.readOnly ? 'Read-only' : (mapping.showInReview ? 'Editable' : 'Hidden'));
    const defaultPolicy = mapping.supported === true && mapping.defaultValue
      ? ` · Default: ${mapping.defaultValue}`
      : '';
    return {
      id: `${mapping.targetObject}-${mapping.parseKey}-${index}`,
      parseKey: mapping.parseKey,
      target: `${mapping.targetObject || ''}${mapping.targetField
        ? ' · ' + (mapping.targetLabel || mapping.targetField)
        : ''}`,
      type: mapping.dataType,
      access: access + defaultPolicy
    };
  });
}
