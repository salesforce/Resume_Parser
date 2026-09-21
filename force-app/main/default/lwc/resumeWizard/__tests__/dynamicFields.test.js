import {
  buildDisclosureRows,
  buildRoleTableColumns,
  decorateFields,
  flattenRoleRows,
  updateFieldValue,
  visibleFields
} from '../dynamicFields';

const field = (parseKey, overrides = {}) => ({
  parseKey,
  label: parseKey,
  dataType: 'Text',
  value: '',
  showInReview: true,
  readOnly: false,
  ...overrides
});

describe('generic dynamic résumé fields', () => {
  it('renders newly injected candidate and role keys without named DTO knowledge', () => {
    expect(visibleFields([field('portfolioUrl', { inputType: 'url' })])[0].parseKey)
      .toBe('portfolioUrl');
    expect(buildRoleTableColumns([{
      parseKey: 'roleCategory',
      targetObject: 'Work_Experience__c',
      targetLabel: 'Role Category',
      dataType: 'Picklist',
      showInReview: true,
      supported: true
    }])).toEqual([{
      label: 'Role Category',
      fieldName: 'roleCategory',
      type: 'text',
      initialWidth: 180,
      wrapText: true
    }]);
  });

  it('excludes invalid mappings from review but exposes their configuration issue', () => {
    expect(visibleFields([field('hidden', { showInReview: false })])).toEqual([]);
    const invalid = {
      parseKey: 'duplicateTarget',
      targetObject: 'Resume_Data__c',
      targetField: 'Candidate_Website__c',
      dataType: 'URL',
      showInReview: true,
      supported: false,
      issue: 'Duplicate active editable target field in the same scope; each writable field requires exactly one mapping.'
    };
    expect(visibleFields([invalid])).toEqual([]);
    expect(buildRoleTableColumns([invalid])).toEqual([]);
    expect(buildDisclosureRows([invalid])[0].access)
      .toBe('Ignored: Duplicate active editable target field in the same scope; each writable field requires exactly one mapping.');
  });

  it('projects read-only and configured picklist behavior', () => {
    const [picklist] = decorateFields([field('roleCategory', {
      dataType: 'Picklist', readOnly: true, value: 'Contract', options: ['Contract', 'Other']
    })]);
    expect(picklist.disabled).toBe(true);
    expect(picklist.options).toEqual([
      { label: 'Contract', value: 'Contract' },
      { label: 'Other', value: 'Other' }
    ]);
    expect(buildDisclosureRows([{
      parseKey: 'employmentType',
      targetObject: 'Work_Experience__c',
      targetField: 'Employment_Type__c',
      dataType: 'Picklist',
      showInReview: true,
      readOnly: false,
      supported: true,
      defaultValue: 'Full-time'
    }])[0].access).toBe('Editable · Default: Full-time');
  });

  it('keeps every visible dynamic role column readable and discoverable', () => {
    const columns = buildRoleTableColumns([
      {
        parseKey: 'roleKindRuntimeDedicated',
        targetObject: 'Work_Experience__c',
        targetLabel: 'Dynamic CMDT Role Kind Proof',
        dataType: 'Picklist',
        showInReview: true,
        supported: true
      },
      {
        parseKey: 'isCurrent',
        targetObject: 'Work_Experience__c',
        targetLabel: 'Is Current Role',
        dataType: 'Checkbox',
        showInReview: true,
        supported: true
      }
    ]);
    expect(columns).toHaveLength(2);
    expect(columns[0]).toMatchObject({
      label: 'Dynamic CMDT Role Kind Proof',
      initialWidth: 280,
      wrapText: true
    });
    expect(columns[1]).toMatchObject({
      label: 'Is Current Role',
      initialWidth: 160,
      wrapText: true
    });
  });

  it('round-trips arbitrary parse-key values and stable role ids', () => {
    const fields = updateFieldValue([field('newRuntimeKey')], 'newRuntimeKey', 'edited');
    expect(fields[0].value).toBe('edited');
    expect(flattenRoleRows([{ rowId: 'row-7', fields }]))
      .toEqual([{ id: 'row-7', newRuntimeKey: 'edited' }]);
  });
});
