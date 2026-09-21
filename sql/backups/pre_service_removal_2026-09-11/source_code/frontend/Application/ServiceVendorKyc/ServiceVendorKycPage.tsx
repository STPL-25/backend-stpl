import React, { useState, useMemo, useCallback, useEffect, useRef } from 'react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { ShieldCheck, RefreshCw, Send } from 'lucide-react';
import { FormSection, PageHeader } from '@/CustomComponent/PageComponents';
import { CustomInputField } from '@/CustomComponent/InputComponents/CustomInputField';
import { useServiceVendorKycFields } from '@/FieldDatas/ServiceVendorKycData';
import axios from 'axios';
import { createServiceVendorKyc, apiGetGSTNDetails } from '@/Services/Api';
import { toast } from 'sonner';
import usePost from '@/hooks/usePostHook';
import { usePermissions } from '@/globalState/hooks/usePermissions';
import type { FieldType } from '@/FieldDatas/fieldType/fieldType';

interface FormErrors {
  [key: string]: string;
}

// ── GST auto-fetch — ported from Kyc-Screen/KycEntry.tsx, business-identity
// fields only (legal/trade name, status). Address patching is skipped:
// service_vendor_kyc has no address columns to patch into, unlike
// kyc_basic_info. Same apiGetGSTNDetails endpoint (an internal SOAP service,
// no new credentials), so this is pure reuse, not a new integration.
const GSTIN_PATTERN = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/;
type UnknownRecord = Record<string, unknown>;
type GstSubmissionFields = {
  legal_name: string;
  trade_name: string;
  gst_status: string;
  gst_blk_status: string;
  date_of_reg: string;
};
const toText = (value: unknown) => (value === null || value === undefined ? '' : String(value).trim());
const firstText = (...values: unknown[]) => values.map(toText).find(Boolean) || '';
const asRecord = (value: unknown): UnknownRecord | null =>
  typeof value === 'object' && value !== null ? (value as UnknownRecord) : null;
const unwrapGstRecord = (payload: unknown): UnknownRecord | null => {
  const payloadRecord = asRecord(payload);
  const root = payloadRecord?.data ?? payload;
  if (Array.isArray(root)) return asRecord(root[0]);
  const rootRecord = asRecord(root);
  if (Array.isArray(rootRecord?.data)) return asRecord((rootRecord as any).data[0]);
  return rootRecord;
};
const buildGstSubmissionFields = (payload: unknown): GstSubmissionFields => {
  const record = unwrapGstRecord(payload);
  return {
    legal_name: firstText(record?.LegalName, record?.legalName, record?.legal_name, record?.lgnm),
    trade_name: firstText(record?.TradeName, record?.tradeName, record?.trade_name, record?.tradeNam, record?.tradenm),
    gst_status: firstText(record?.Status),
    gst_blk_status: firstText(record?.BlkStatus),
    date_of_reg: firstText(record?.DtDReg),
  };
};

const NAME_FIELD_MAP: Record<string, string> = {
  com_sno: 'com_name',
  div_sno: 'div_name',
  brn_sno: 'brn_name',
  dept_sno: 'dept_name',
};

function resolveNameField(fieldName: string): string {
  return NAME_FIELD_MAP[fieldName] ?? fieldName.replace('_sno', '_name');
}

// Separate KYC intake for SERVICE vendors — kept apart from the existing
// goods/trade vendor KYC (Kyc-Screen module, kyc_basic_info). On final
// approval this record auto-provisions a matching kyc_basic_info row (see
// sql/44_service_vendor_kyc_approval_and_provisioning.sql) so it becomes
// pickable everywhere an approved supplier is needed.
const ServiceVendorKycPage: React.FC = () => {
  const { canCreate, canEdit } = usePermissions();
  const permissionComponent = 'ServiceVendorKycPage';
  const canSubmit = canCreate(permissionComponent) || canEdit(permissionComponent);

  const [selectedCompany, setSelectedCompany] = useState('');
  const [selectedDivision, setSelectedDivision] = useState('');
  const [selectedBranch, setSelectedBranch] = useState('');

  const fields = useServiceVendorKycFields({ selectedCompany, selectedDivision, selectedBranch });

  const [formData, setFormData] = useState<Record<string, any>>({});
  const [errors, setErrors] = useState<FormErrors>({});
  const [submitting, setSubmitting] = useState(false);

  const { postData: fetchGstDetails } = usePost<{ success: boolean; data?: unknown }>();
  const lastFetchedGstRef = useRef('');

  const maybeFetchGstDetails = useCallback(async (gstValue: unknown, isGstAvailable: unknown) => {
    const gst = toText(gstValue).toUpperCase();
    if (isGstAvailable !== 'true' || !GSTIN_PATTERN.test(gst) || lastFetchedGstRef.current === gst) return;
    lastFetchedGstRef.current = gst;

    try {
      const response = await fetchGstDetails(apiGetGSTNDetails, { gst });
      const gstRecord = unwrapGstRecord(response?.data);
      if (!gstRecord) throw new Error('GST details response was empty');

      const submissionFields = buildGstSubmissionFields(response?.data);
      setFormData((prev) => ({ ...prev, gst_no: gst, ...submissionFields }));
      toast.success(
        submissionFields.legal_name
          ? `GST details loaded: ${submissionFields.legal_name}`
          : 'GST details loaded'
      );
    } catch (error: any) {
      lastFetchedGstRef.current = '';
      toast.error(error?.response?.data?.error ?? error?.message ?? 'Unable to fetch GST details');
    }
  }, [fetchGstDetails]);

  const buildInitialFormData = useCallback((flds: FieldType[]) => {
    const d: Record<string, any> = {};
    flds.forEach((field) => {
      if (!field.input) return;
      if (field.defaultValue !== undefined) d[field.field] = field.defaultValue;
      else if (field.type === 'file') d[field.field] = null;
      else d[field.field] = '';
    });
    return d;
  }, []);

  useEffect(() => {
    setFormData(buildInitialFormData(fields));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleFieldChange = (fieldName: string, value: any) => {
    const nextValue = fieldName === 'gst_no' ? toText(value).toUpperCase() : value;
    const nextGstNo = fieldName === 'gst_no' ? nextValue : formData.gst_no;
    const nextIsGstAvailable = fieldName === 'is_gst_avail' ? nextValue : formData.is_gst_avail;

    if (
      (fieldName === 'gst_no' && nextValue !== formData.gst_no) ||
      (fieldName === 'is_gst_avail' && nextValue !== 'true')
    ) {
      lastFetchedGstRef.current = '';
    }

    setFormData((prev) => {
      const updated = { ...prev, [fieldName]: nextValue };

      if (fieldName === 'com_sno') {
        updated.div_sno = ''; updated.div_name = '';
        updated.brn_sno = ''; updated.brn_name = '';
        updated.dept_sno = ''; updated.dept_name = '';
        setSelectedCompany(String(value));
        setSelectedDivision('');
        setSelectedBranch('');
      } else if (fieldName === 'div_sno') {
        updated.brn_sno = ''; updated.brn_name = '';
        updated.dept_sno = ''; updated.dept_name = '';
        setSelectedDivision(String(value));
        setSelectedBranch('');
      } else if (fieldName === 'brn_sno') {
        updated.dept_sno = ''; updated.dept_name = '';
        setSelectedBranch(String(value));
      }

      const field = fields.find((f) => f.field === fieldName);
      if (field?.options && Array.isArray(field.options)) {
        const selectedOption = (field.options as any[]).find((opt) => String(opt.value) === String(value));
        if (selectedOption) updated[resolveNameField(fieldName)] = selectedOption.label;
      }

      return updated;
    });

    if (errors[fieldName]) {
      setErrors((prev) => {
        const e = { ...prev };
        delete e[fieldName];
        return e;
      });
    }

    if (fieldName === 'gst_no' || fieldName === 'is_gst_avail') {
      void maybeFetchGstDetails(nextGstNo, nextIsGstAvailable);
    }
  };

  const inputFields = useMemo(() => fields.filter((f) => f.input), [fields]);

  const validateForm = (): boolean => {
    const errs: FormErrors = {};
    inputFields.forEach((field) => {
      if (field.require && !formData[field.field]) errs[field.field] = `${field.label} is required`;
    });
    setErrors(errs);
    return Object.keys(errs).length === 0;
  };

  const buildKycFormData = (): FormData => {
    const fd = new FormData();
    Object.entries(formData).forEach(([key, value]) => {
      if (key === 'kyc_document') return;
      if (value === null || value === undefined || value === '') return;
      fd.append(key, String(value));
    });
    if (formData.kyc_document instanceof File) {
      fd.append('kyc_document', formData.kyc_document);
    }
    return fd;
  };

  const handleReset = () => {
    setFormData(buildInitialFormData(fields));
    setErrors({});
    setSelectedCompany(''); setSelectedDivision(''); setSelectedBranch('');
    lastFetchedGstRef.current = '';
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validateForm()) return;

    if (!(formData.kyc_document instanceof File)) {
      setErrors((prev) => ({ ...prev, kyc_document: 'A supporting document is required' }));
      return;
    }

    setSubmitting(true);
    try {
      const res = await axios.post(createServiceVendorKyc, buildKycFormData(), {
        headers: { 'Content-Type': 'multipart/form-data' },
      });
      const data = res?.data?.data;
      toast.success(`Service Vendor KYC submitted for approval${data?.service_vendor_kyc_sno ? ` (#${data.service_vendor_kyc_sno})` : ''}`);
      handleReset();
    } catch (error: any) {
      const errMsg = error?.response?.data?.error || 'Submission failed. Please try again.';
      toast.error(errMsg);
    } finally {
      setSubmitting(false);
    }
  };

  const gridFields = useMemo(
    () => inputFields.filter((f) => f.type !== 'textarea' && f.type !== 'file'),
    [inputFields]
  );
  const textareaFields = useMemo(() => inputFields.filter((f) => f.type === 'textarea'), [inputFields]);
  const fileField = useMemo(() => inputFields.find((f) => f.type === 'file') ?? null, [inputFields]);

  return (
    <div className="flex flex-col h-full bg-muted/30 min-h-full">
      <PageHeader icon={ShieldCheck} title="Service Vendor KYC" description="Onboarding + approval for service vendors, separate from goods/trade vendor KYC" />

      <div className="container mx-auto py-6 px-4">
        <Card className="shadow-md">
          <CardContent className="pt-6">
            <form onSubmit={handleSubmit} className="space-y-6">
              <FormSection icon={ShieldCheck} title="Vendor Details">
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-x-4 gap-y-5">
                  {gridFields.map((field) => (
                    <div key={field.field} data-error={!!errors[field.field]} className="flex flex-col">
                      <CustomInputField
                        field={field.field}
                        label={field.label}
                        require={field.require}
                        type={field.type}
                        options={field.options}
                        value={formData[field.field] ?? ''}
                        onChange={(value) => handleFieldChange(field.field, value)}
                        error={errors[field.field]}
                        placeholder={field.placeholder ?? (field.type === 'select' || field.type === 'search-select' ? `Select ${field.label.toLowerCase()}` : undefined)}
                        className="h-10"
                      />
                    </div>
                  ))}
                </div>

                {textareaFields.map((field) => (
                  <div key={field.field} data-error={!!errors[field.field]}>
                    <CustomInputField
                      field={field.field}
                      label={field.label}
                      require={field.require}
                      type={field.type}
                      value={formData[field.field] ?? ''}
                      onChange={(value) => handleFieldChange(field.field, value)}
                      error={errors[field.field]}
                      placeholder={`Enter ${field.label.toLowerCase()}...`}
                      rows={2}
                      className="resize-none"
                    />
                  </div>
                ))}

                {fileField && (
                  <div data-error={!!errors[fileField.field]} className="max-w-xs">
                    <CustomInputField
                      field={fileField.field}
                      label={fileField.label}
                      require={fileField.require}
                      type={fileField.type}
                      value={formData[fileField.field] ?? null}
                      onChange={(file) => handleFieldChange(fileField.field, file)}
                      error={errors[fileField.field]}
                    />
                  </div>
                )}

                {Object.keys(errors).length > 0 && (
                  <div className="bg-destructive/10 border border-destructive/20 rounded-md p-3">
                    <ul className="list-disc list-inside text-destructive text-xs space-y-0.5">
                      {Object.values(errors).map((err, i) => <li key={i}>{err}</li>)}
                    </ul>
                  </div>
                )}
              </FormSection>

              <div className="flex items-center justify-between gap-3 pt-4 border-t flex-wrap">
                <Button type="button" variant="outline" onClick={handleReset} disabled={submitting} className="h-9">
                  <RefreshCw className="h-4 w-4 mr-2" />Reset
                </Button>

                {canSubmit && (
                  <Button type="submit" className="bg-blue-600 hover:bg-blue-700 h-9" disabled={submitting}>
                    {submitting ? <RefreshCw className="h-4 w-4 mr-2 animate-spin" /> : <Send className="h-4 w-4 mr-2" />}
                    Submit for Approval
                  </Button>
                )}
              </div>
            </form>
          </CardContent>
        </Card>
      </div>
    </div>
  );
};

export default ServiceVendorKycPage;
