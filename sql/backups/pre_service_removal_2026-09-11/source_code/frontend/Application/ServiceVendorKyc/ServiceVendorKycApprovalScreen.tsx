import React, { useState, useEffect } from 'react';
import { AlertCircle, Clock } from 'lucide-react';
import ServiceVendorKycApprovalScreenLayout from '@/LayoutComponent/ApprovalLayout/ServiceVendorKycApprovalScreenLayout';
import useFetch from '@/hooks/useFetchHook';
import usePost from '@/hooks/usePostHook';
import { getServiceVendorKycsForApproval, approveServiceVendorKyc } from '@/Services/Api';
import { useAppState } from '@/imports';
import { useServiceVendorKycApprovalSideCardDatas } from '@/FieldDatas/ServiceVendorKycApprovalData';
import {
  socket, SOCKET_JOIN_SERVICE_VENDOR_KYC_APPROVAL, SOCKET_LEAVE_SERVICE_VENDOR_KYC_APPROVAL,
  SOCKET_SERVICE_VENDOR_KYC_APPROVAL_UPDATED,
} from '@/Services/Socket';

interface APIResponse {
  success: boolean;
  data: any[];
}

const ServiceVendorKycApprovalScreen: React.FC = () => {
  const [selectedRecord, setSelectedRecord] = useState<any | null>(null);
  const [showApprovalDialog, setShowApprovalDialog] = useState(false);
  const [actionType, setActionType] = useState<'approve' | 'reject'>('approve');
  const [comments, setComments] = useState('');
  const [recordList, setRecordList] = useState<any[]>([]);
  const [refreshKey, setRefreshKey] = useState(0);
  const [toast, setToast] = useState<{ message: string; type: 'success' | 'error' } | null>(null);

  const { userData } = useAppState();
  const fieldDatas = useServiceVendorKycApprovalSideCardDatas();
  const { postData, loading } = usePost();

  const { data, loading: fetchLoading, error } = useFetch<APIResponse>(
    getServiceVendorKycsForApproval,
    "",
    null,
    refreshKey
  );

  useEffect(() => {
    if (data && !fetchLoading) setRecordList(data.data ?? []);
  }, [data, fetchLoading]);

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 3500);
    return () => clearTimeout(t);
  }, [toast]);

  useEffect(() => {
    socket.emit(SOCKET_JOIN_SERVICE_VENDOR_KYC_APPROVAL);

    const onApprovalUpdated = (payload: { service_vendor_kyc_sno: number; approved_by: string }) => {
      if (payload.approved_by === userData[0]?.ecno) return;
      setRefreshKey((k) => k + 1);
      setToast({ message: `A record was actioned — refreshing list…`, type: 'success' });
    };

    socket.on(SOCKET_SERVICE_VENDOR_KYC_APPROVAL_UPDATED, onApprovalUpdated);

    return () => {
      socket.emit(SOCKET_LEAVE_SERVICE_VENDOR_KYC_APPROVAL);
      socket.off(SOCKET_SERVICE_VENDOR_KYC_APPROVAL_UPDATED, onApprovalUpdated);
    };
  }, [userData]);

  const handleRecordSelect = (record: any) => setSelectedRecord(record);

  const handleAction = (action: string) => {
    setActionType(action as 'approve' | 'reject');
    setComments('');
    setShowApprovalDialog(true);
  };

  const handleSubmit = async () => {
    if (!selectedRecord) return;

    const rawStages = selectedRecord.stage_order_json;
    let approval_stages: any[] = [];
    if (rawStages) {
      try {
        approval_stages = typeof rawStages === 'string' ? JSON.parse(rawStages) : rawStages;
      } catch {
        approval_stages = [];
      }
    }

    const payload = {
      service_vendor_kyc_sno: selectedRecord.service_vendor_kyc_sno,
      ecno: userData[0]?.ecno,
      action: actionType,
      comments: comments.trim(),
      approval_stages,
    };

    try {
      await postData(approveServiceVendorKyc, payload);

      setRecordList((prev) => prev.filter((r) => r.service_vendor_kyc_sno !== selectedRecord.service_vendor_kyc_sno));
      setSelectedRecord(null);
      setShowApprovalDialog(false);
      setComments('');
      setToast({ message: `Record ${actionType === 'approve' ? 'approved' : 'rejected'} successfully`, type: 'success' });
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

  if (fetchLoading && recordList.length === 0) {
    return (
      <div className="min-h-full bg-background flex items-center justify-center">
        <div className="text-center space-y-3">
          <Clock className="h-16 w-16 text-slate-300 dark:text-foreground mx-auto animate-spin" />
          <h3 className="text-xl font-semibold text-muted-foreground dark:text-muted-foreground/70">Loading Service Vendor KYC Records...</h3>
        </div>
      </div>
    );
  }

  return (
    <ServiceVendorKycApprovalScreenLayout
      approvalName="Service Vendor KYC"
      recordList={recordList}
      selectedRecord={selectedRecord}
      handleRecordSelect={handleRecordSelect}
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

export default ServiceVendorKycApprovalScreen;
