import React, { useState, useMemo, useCallback } from 'react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Checkbox } from '@/components/ui/checkbox';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { ClipboardCheck, Search, Send, RefreshCw, Package } from 'lucide-react';
import { FormSection, PageHeader } from '@/CustomComponent/PageComponents';
import { CustomInputField } from '@/CustomComponent/InputComponents/CustomInputField';
import {
  useServiceVendorEntryFilterFields,
  useServiceVendorConsolidationPOFields,
} from '@/FieldDatas/ServiceVendorEntryData';
import axios from 'axios';
import { getServiceVendorEntries, consolidateServiceVendorEntries } from '@/Services/Api';
import { toast } from 'sonner';
import { usePermissions } from '@/globalState/hooks/usePermissions';
import type { FieldType } from '@/FieldDatas/fieldType/fieldType';

interface FormErrors {
  [key: string]: string;
}

const NAME_FIELD_MAP: Record<string, string> = {
  com_sno: 'com_name', div_sno: 'div_name', brn_sno: 'brn_name', dept_sno: 'dept_name',
  vendor_sno: 'vendor_name', service_sno: 'service_name',
};
function resolveNameField(fieldName: string): string {
  return NAME_FIELD_MAP[fieldName] ?? fieldName.replace('_sno', '_name');
}

const ServiceVendorConsolidationPage: React.FC = () => {
  const { canCreate, canEdit } = usePermissions();
  const permissionComponent = 'ServiceVendorConsolidationPage';
  const canSubmit = canCreate(permissionComponent) || canEdit(permissionComponent);

  const [selectedCompany, setSelectedCompany] = useState('');
  const [selectedDivision, setSelectedDivision] = useState('');
  const [selectedBranch, setSelectedBranch] = useState('');

  const filterFields = useServiceVendorEntryFilterFields({ selectedCompany, selectedDivision, selectedBranch });
  const poFields = useServiceVendorConsolidationPOFields();

  const [filters, setFilters] = useState<Record<string, any>>({});
  const [filterErrors, setFilterErrors] = useState<FormErrors>({});
  const [poData, setPoData] = useState<Record<string, any>>({ po_type: 'ONE_TIME' });

  const [entries, setEntries] = useState<Record<string, any>[]>([]);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [searched, setSearched] = useState(false);
  const [searching, setSearching] = useState(false);
  const [raising, setRaising] = useState(false);

  const handleFilterChange = (fieldName: string, value: any) => {
    setFilters((prev) => {
      const updated = { ...prev, [fieldName]: value };
      if (fieldName === 'com_sno') {
        updated.div_sno = ''; updated.div_name = '';
        updated.brn_sno = ''; updated.brn_name = '';
        updated.dept_sno = ''; updated.dept_name = '';
        setSelectedCompany(String(value)); setSelectedDivision(''); setSelectedBranch('');
      } else if (fieldName === 'div_sno') {
        updated.brn_sno = ''; updated.brn_name = '';
        updated.dept_sno = ''; updated.dept_name = '';
        setSelectedDivision(String(value)); setSelectedBranch('');
      } else if (fieldName === 'brn_sno') {
        updated.dept_sno = ''; updated.dept_name = '';
        setSelectedBranch(String(value));
      }
      const field = filterFields.find((f) => f.field === fieldName);
      if (field?.options && Array.isArray(field.options)) {
        const opt = (field.options as any[]).find((o) => String(o.value) === String(value));
        if (opt) updated[resolveNameField(fieldName)] = opt.label;
      }
      return updated;
    });
    if (filterErrors[fieldName]) setFilterErrors((prev) => { const e = { ...prev }; delete e[fieldName]; return e; });
  };

  const handlePoFieldChange = (fieldName: string, value: any) => {
    setPoData((prev) => ({ ...prev, [fieldName]: value }));
  };

  const inputFilterFields = useMemo(() => filterFields.filter((f) => f.input), [filterFields]);

  const handleSearch = async () => {
    if (!filters.vendor_sno) {
      setFilterErrors({ vendor_sno: 'Supplier is required' });
      return;
    }
    setFilterErrors({});
    setSearching(true);
    setSearched(true);
    setSelected(new Set());
    try {
      const res = await axios.get(getServiceVendorEntries, {
        params: {
          vendor_sno: filters.vendor_sno,
          service_sno: filters.service_sno || undefined,
          com_sno: filters.com_sno || undefined,
          div_sno: filters.div_sno || undefined,
          brn_sno: filters.brn_sno || undefined,
          dept_sno: filters.dept_sno || undefined,
          date_from: filters.date_from || undefined,
          date_to: filters.date_to || undefined,
          status: 'PENDING',
        },
      });
      setEntries(res?.data?.data ?? []);
    } catch (error: any) {
      toast.error(error?.response?.data?.error || 'Failed to load pending entries');
      setEntries([]);
    } finally {
      setSearching(false);
    }
  };

  const toggleRow = (entry_sno: number) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(entry_sno)) next.delete(entry_sno); else next.add(entry_sno);
      return next;
    });
  };

  const allSelected = entries.length > 0 && selected.size === entries.length;
  const toggleAll = () => {
    setSelected(allSelected ? new Set() : new Set(entries.map((e) => e.entry_sno)));
  };

  const selectedTotal = useMemo(
    () => entries.filter((e) => selected.has(e.entry_sno)).reduce((sum, e) => sum + (Number(e.total_amount) || 0), 0),
    [entries, selected]
  );

  const handleRaisePO = useCallback(async () => {
    if (selected.size === 0) return;
    setRaising(true);
    try {
      const res = await axios.post(consolidateServiceVendorEntries, {
        entry_snos: Array.from(selected),
        po_type: poData.po_type || 'ONE_TIME',
        delivery_address: poData.delivery_address,
        terms_conditions: poData.terms_conditions,
        purpose: poData.purpose,
      });
      const data = res?.data?.data;
      toast.success(
        data?.is_direct_issue
          ? `Service PO ${data.po_no} issued directly (${data.entries_consolidated} entries consolidated)`
          : `Service PO ${data?.po_no ?? ''} submitted for approval (${data?.entries_consolidated ?? ''} entries consolidated)`
      );
      setEntries((prev) => prev.filter((e) => !selected.has(e.entry_sno)));
      setSelected(new Set());
    } catch (error: any) {
      toast.error(error?.response?.data?.error || 'Failed to raise PO. Entries were not consolidated — try again.');
    } finally {
      setRaising(false);
    }
  }, [selected, poData]);

  const gridFilterFields = inputFilterFields.filter((f) => f.type !== 'textarea');

  return (
    <div className="flex flex-col h-full bg-muted/30 min-h-full">
      <PageHeader
        icon={ClipboardCheck}
        title="Vendor Entry Consolidation"
        description="Select accumulated Vendor Driven daily entries and raise one PO"
      />

      <div className="container mx-auto py-6 px-4 space-y-6">
        <Card className="shadow-md">
          <CardContent className="pt-6 space-y-4">
            <FormSection icon={Search} title="Find Pending Entries">
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-x-4 gap-y-5">
                {gridFilterFields.map((field) => (
                  <div key={field.field} data-error={!!filterErrors[field.field]} className="flex flex-col">
                    <CustomInputField
                      field={field.field}
                      label={field.label}
                      require={field.require}
                      type={field.type}
                      options={field.options}
                      value={filters[field.field] ?? ''}
                      onChange={(value) => handleFilterChange(field.field, value)}
                      error={filterErrors[field.field]}
                      placeholder={field.type === 'select' || field.type === 'search-select' ? `Select ${field.label.toLowerCase()}` : undefined}
                      className="h-10"
                    />
                  </div>
                ))}
              </div>
              <div className="flex justify-end pt-1">
                <Button type="button" onClick={handleSearch} disabled={searching} className="h-9">
                  {searching ? <RefreshCw className="h-4 w-4 mr-2 animate-spin" /> : <Search className="h-4 w-4 mr-2" />}
                  Search
                </Button>
              </div>
            </FormSection>
          </CardContent>
        </Card>

        {searched && (
          <Card className="shadow-md">
            <CardContent className="pt-6 space-y-4">
              <div className="flex items-center justify-between">
                <h3 className="text-sm font-semibold text-foreground flex items-center gap-2">
                  Pending Entries<Badge variant="secondary">{entries.length}</Badge>
                </h3>
                {selected.size > 0 && (
                  <span className="text-xs text-muted-foreground">
                    {selected.size} selected — total ₹{selectedTotal.toFixed(2)}
                  </span>
                )}
              </div>

              {entries.length > 0 ? (
                <div className="border rounded-xl overflow-hidden">
                  <Table>
                    <TableHeader>
                      <TableRow className="bg-muted/50 hover:bg-muted/50">
                        <TableHead className="w-10">
                          <Checkbox checked={allSelected} onCheckedChange={toggleAll} />
                        </TableHead>
                        <TableHead className="text-xs">Date</TableHead>
                        <TableHead className="text-xs">Service</TableHead>
                        <TableHead className="text-xs">Qty</TableHead>
                        <TableHead className="text-xs">Unit</TableHead>
                        <TableHead className="text-xs">Unit Price</TableHead>
                        <TableHead className="text-xs">Total</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {entries.map((entry) => (
                        <TableRow key={entry.entry_sno} className={selected.has(entry.entry_sno) ? 'bg-blue-50 dark:bg-blue-950/20' : ''}>
                          <TableCell>
                            <Checkbox checked={selected.has(entry.entry_sno)} onCheckedChange={() => toggleRow(entry.entry_sno)} />
                          </TableCell>
                          <TableCell className="text-xs">{String(entry.entry_date).slice(0, 10)}</TableCell>
                          <TableCell className="text-xs">{entry.service_name}</TableCell>
                          <TableCell className="text-xs">{entry.qty}</TableCell>
                          <TableCell className="text-xs">{entry.unit_name ?? '—'}</TableCell>
                          <TableCell className="text-xs">{entry.unit_price}</TableCell>
                          <TableCell className="text-xs font-medium">{entry.total_amount}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
              ) : (
                <div className="text-center py-10 text-muted-foreground border rounded-xl bg-muted/10">
                  <Package className="h-10 w-10 mx-auto mb-3 opacity-20" />
                  <p className="text-sm">No pending entries found for this filter.</p>
                </div>
              )}
            </CardContent>
          </Card>
        )}

        {searched && entries.length > 0 && (
          <Card className="shadow-md">
            <CardContent className="pt-6 space-y-4">
              <FormSection icon={ClipboardCheck} title="PO Details">
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-x-4 gap-y-5">
                  {poFields.filter((f) => f.type !== 'textarea').map((field) => (
                    <div key={field.field} className="flex flex-col">
                      <CustomInputField
                        field={field.field}
                        label={field.label}
                        require={field.require}
                        type={field.type}
                        options={field.options}
                        value={poData[field.field] ?? ''}
                        onChange={(value) => handlePoFieldChange(field.field, value)}
                        className="h-10"
                      />
                    </div>
                  ))}
                </div>
                {poFields.filter((f) => f.type === 'textarea').map((field) => (
                  <div key={field.field}>
                    <CustomInputField
                      field={field.field}
                      label={field.label}
                      require={field.require}
                      type={field.type}
                      value={poData[field.field] ?? ''}
                      onChange={(value) => handlePoFieldChange(field.field, value)}
                      placeholder={`Enter ${field.label.toLowerCase()}...`}
                      rows={2}
                      className="resize-none"
                    />
                  </div>
                ))}
              </FormSection>

              <div className="flex items-center justify-end pt-4 border-t">
                {canSubmit && (
                  <Button
                    type="button"
                    onClick={handleRaisePO}
                    disabled={selected.size === 0 || raising}
                    className="bg-blue-600 hover:bg-blue-700 h-9"
                  >
                    {raising ? <RefreshCw className="h-4 w-4 mr-2 animate-spin" /> : <Send className="h-4 w-4 mr-2" />}
                    Raise PO ({selected.size} {selected.size === 1 ? 'entry' : 'entries'})
                  </Button>
                )}
              </div>
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
};

export default ServiceVendorConsolidationPage;
