import React, { useState, useEffect } from 'react';
import { AlertCircle, Clock } from 'lucide-react';
import ServicePOApprovalScreenLayout from '@/LayoutComponent/ApprovalLayout/ServicePOApprovalScreenLayout';
import useFetch from '@/hooks/useFetchHook';
import usePost from '@/hooks/usePostHook';
import { getServicePORecords, servicePoApproveAction, sendServicePOEmail } from '@/Services/Api';
import { useAppState } from '@/imports';
import { useServicePoApprovalSideCardDatas } from '@/FieldDatas/ServicePOApprovalData';
import { buildServicePOPdfBlob } from './generateServicePOPdfBlob';
import {
  socket, SOCKET_JOIN_SERVICE_PO_APPROVAL, SOCKET_LEAVE_SERVICE_PO_APPROVAL,
  SOCKET_SERVICE_PO_APPROVAL_UPDATED,
} from '@/Services/Socket';

interface APIResponse {
  success: boolean;
  data: any[];
}

function parseItems(po: any): any[] {
  try {
    const raw = po?.items;
    if (!raw) return [];
    return typeof raw === 'string' ? JSON.parse(raw) : raw;
  } catch { return []; }
}

const ServicePOApprovalScreen: React.FC = () => {
  const [selectedPO, setSelectedPO] = useState<any | null>(null);
  const [showApprovalDialog, setShowApprovalDialog] = useState(false);
  const [actionType, setActionType] = useState<'approve' | 'reject'>('approve');
  const [comments, setComments] = useState('');
  const [poList, setPoList] = useState<any[]>([]);
  const [refreshKey, setRefreshKey] = useState(0);
  const [toast, setToast] = useState<{ message: string; type: 'success' | 'error' } | null>(null);

  const { userData } = useAppState();
  const fieldDatas = useServicePoApprovalSideCardDatas();
  const { postData, loading } = usePost();
  const { postData: postSendEmail } = usePost();

  const { data, loading: fetchLoading, error } = useFetch<APIResponse>(
    getServicePORecords,
    "",
    null,
    refreshKey
  );

  useEffect(() => {
    if (data && !fetchLoading) setPoList(data.data ?? []);
  }, [data, fetchLoading]);

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 3500);
    return () => clearTimeout(t);
  }, [toast]);

  useEffect(() => {
    socket.emit(SOCKET_JOIN_SERVICE_PO_APPROVAL);

    const onApprovalUpdated = (payload: { po_basic_sno?: number; approved_by: string }) => {
      if (payload.approved_by === userData[0]?.ecno) return;
      setRefreshKey((k) => k + 1);
      setToast({ message: `A Service PO was actioned — refreshing list…`, type: 'success' });
    };

    socket.on(SOCKET_SERVICE_PO_APPROVAL_UPDATED, onApprovalUpdated);

    return () => {
      socket.emit(SOCKET_LEAVE_SERVICE_PO_APPROVAL);
      socket.off(SOCKET_SERVICE_PO_APPROVAL_UPDATED, onApprovalUpdated);
    };
  }, [userData]);

  const handlePOSelect = (po: any) => setSelectedPO(po);

  const handleAction = (action: string) => {
    setActionType(action as 'approve' | 'reject');
    setComments('');
    setShowApprovalDialog(true);
  };

  // Final-stage approval only: render the PO PDF from the record already on
  // screen (no round trip needed — getServicePORecords already returned
  // everything the PDF needs, including items), then upload+email it. Mirrors
  // POApprovalScreen.tsx's sendFinalPOToSupplier — approval itself never
  // emails (see ServicePOService.approveServicePO), this is the deliberate,
  // separate "send to supplier" step.
  const sendFinalPOToSupplier = async (po: any) => {
    try {
      const items = parseItems(po);
      const { doc, fileName } = buildServicePOPdfBlob({
        po_no: po.po_no,
        vendor_name: po.vendor_name,
        po_type: po.po_type,
        pr_no: po.pr_no,
        purpose: po.purpose,
        validity_from: po.validity_from,
        validity_to: po.validity_to,
        terms_conditions: po.terms_conditions,
        delivery_address: po.delivery_address,
        items,
      });
      doc.save(fileName);

      const emailItems = items.map((item: any) => ({
        prod_name: item.service_name,
        qty: item.qty,
        unit_name: item.unit_name,
        unit_price: item.agreed_unit_price,
        total_amount: item.net_cost,
      }));

      const fd = new FormData();
      fd.append('vendor_sno', String(po.vendor_sno));
      fd.append('po_no', String(po.po_no));
      fd.append('terms_conditions', po.terms_conditions ?? '');
      fd.append('delivery_address', po.delivery_address ?? '');
      fd.append('items', JSON.stringify(emailItems));
      fd.append('po_basic_sno', String(po.po_basic_sno));
      fd.append('po_pdf', doc.output('blob'), fileName);

      await postSendEmail(sendServicePOEmail, fd, {
        headers: { 'Content-Type': 'multipart/form-data' },
        withCredentials: true,
      });
    } catch (error) {
      console.error('Unable to send the final Service PO to the supplier:', error);
    }
  };

  const handleSubmit = async () => {
    if (!selectedPO) return;

    const rawStages = selectedPO.stage_order_json;
    let approval_stages: any[] = [];
    if (rawStages) {
      try {
        approval_stages = typeof rawStages === 'string' ? JSON.parse(rawStages) : rawStages;
      } catch {
        approval_stages = [];
      }
    }

    const payload = {
      po_basic_sno: selectedPO.po_basic_sno,
      comments: comments.trim(),
      approval_stages,
      action: actionType,
    };

    try {
      const result: any = await postData(servicePoApproveAction, payload);
      const isFinal = actionType === 'approve' && result?.data?.[0]?.next_approver === 'FINAL_STAGE';

      setPoList((prev) => prev.filter((p) => p.po_basic_sno !== selectedPO.po_basic_sno));
      const finishedPO = selectedPO;
      setSelectedPO(null);
      setShowApprovalDialog(false);
      setComments('');
      setToast({ message: `Service PO ${actionType === 'approve' ? 'approved' : 'rejected'} successfully`, type: 'success' });

      if (isFinal) {
        sendFinalPOToSupplier(finishedPO);
      }
    } catch (err: any) {
      const message = err?.response?.data?.error || err?.message || 'Action failed';
      setToast({ message, type: 'error' });
    }
  };

  if (error) {
    return (
      <div className="min-h-full bg-background flex items-center justify-center">
        <div className="text-center space-y-3">
          <AlertCircle className="h-16 w-16 text-red-500 mx-auto" />
          <h3 className="text-xl font-semibold text-muted-foreground dark:text-muted-foreground/70">Error Loading Data</h3>
          <p className="text-sm text-muted-foreground">{error}</p>
        </div>
      </div>
    );
  }

  if (fetchLoading && poList.length === 0) {
    return (
      <div className="min-h-full bg-background flex items-center justify-center">
        <div className="text-center space-y-3">
          <Clock className="h-16 w-16 text-slate-300 dark:text-foreground mx-auto animate-spin" />
          <h3 className="text-xl font-semibold text-muted-foreground dark:text-muted-foreground/70">Loading Service Purchase Orders...</h3>
        </div>
      </div>
    );
  }

  return (
    <ServicePOApprovalScreenLayout
      approvalName="Service Purchase Orders"
      poList={poList}
      selectedPO={selectedPO}
      handlePOSelect={handlePOSelect}
      handleAction={handleAction}
      showApprovalDialog={showApprovalDialog}
      setShowApprovalDialog={setShowApprovalDialog}
      comments={comments}
      setComments={setComments}
      handleSubmit={handleSubmit}
      loading={loading}
      actionType={actionType}
      fieldDatas={fieldDatas}
      toast={toast}
    />
  );
};

export default ServicePOApprovalScreen;
