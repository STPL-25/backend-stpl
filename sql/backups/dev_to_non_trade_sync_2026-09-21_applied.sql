-- Sync Non_trade_Dev -> Non_Trade  (2026-09-21T09-56-17-288Z, mode=apply)
-- Additive only: no rows copied/updated/deleted. sp_InsertKYCData keeps workflow_types_id=32.

-- [A. create tables] dbo.service_agreement_vendor
CREATE TABLE [dbo].[service_agreement_vendor] (
  [agreement_vendor_sno] int IDENTITY(1,1) NOT NULL,
  [agreement_sno] int NOT NULL,
  [vendor_sno] int NOT NULL,
  [share_amount] decimal(18,2) NOT NULL,
  [share_pct] decimal(9,6) NOT NULL,
  [sort_order] smallint NOT NULL CONSTRAINT [DF__service_a__sort___2764BD12] DEFAULT ((1)),
  [created_at] datetime NOT NULL CONSTRAINT [DF__service_a__creat__2858E14B] DEFAULT (getdate()),
  CONSTRAINT [PK__service___396E772F74704AA1] PRIMARY KEY CLUSTERED ([agreement_vendor_sno]),
  CONSTRAINT [UQ_service_agreement_vendor] UNIQUE NONCLUSTERED ([agreement_sno], [vendor_sno]),
  CONSTRAINT [CK_service_agreement_vendor_share] CHECK ([share_amount]>(0) AND [share_pct]>(0) AND [share_pct]<=(100))
);
GO
-- [A. create tables] dbo.service_agreement_statutory
CREATE TABLE [dbo].[service_agreement_statutory] (
  [agreement_sno] int NOT NULL,
  [facility_type] varchar(15) NOT NULL,
  [facility_ref_no] nvarchar(100) NULL,
  [sanctioned_amount] decimal(18,2) NOT NULL,
  [drawing_power] decimal(18,2) NULL,
  [rate_type] varchar(10) NOT NULL,
  [benchmark_rate_pct] decimal(7,3) NULL,
  [spread_pct] decimal(7,3) NULL,
  [interest_rate_pct] decimal(7,3) NOT NULL,
  [modified_at] datetime NULL,
  [benchmark_name] varchar(30) NULL,
  [disbursed_amount] decimal(18,2) NULL,
  [disbursement_date] date NULL,
  [interest_payment_day] tinyint NULL,
  [day_count_basis] smallint NULL,
  CONSTRAINT [PK__service___D5DBD29C93BB5EAA] PRIMARY KEY CLUSTERED ([agreement_sno]),
  CONSTRAINT [CK_service_agreement_statutory_facility] CHECK ([facility_type]='CASH_CREDIT' OR [facility_type]='REPO' OR [facility_type]='LOAN'),
  CONSTRAINT [CK_service_agreement_statutory_rate_type] CHECK ([rate_type]='FLOATING' OR [rate_type]='FIXED'),
  CONSTRAINT [CK_service_agreement_statutory_paymentday] CHECK ([interest_payment_day] IS NULL OR [interest_payment_day]>=(1) AND [interest_payment_day]<=(31)),
  CONSTRAINT [CK_service_agreement_statutory_amount] CHECK ([sanctioned_amount]>(0)),
  CONSTRAINT [CK_service_agreement_statutory_basis] CHECK ([day_count_basis] IS NULL OR ([day_count_basis]=(365) OR [day_count_basis]=(360))),
  CONSTRAINT [CK_service_agreement_statutory_interest] CHECK ([interest_rate_pct]>=(0) AND [interest_rate_pct]<=(100)),
  CONSTRAINT [CK_service_agreement_statutory_disbursed] CHECK ([disbursed_amount] IS NULL OR [disbursed_amount]>=(0) AND [disbursed_amount]<=[sanctioned_amount])
);
GO
-- [A. create tables] dbo.service_agreement_version
CREATE TABLE [dbo].[service_agreement_version] (
  [version_sno] int IDENTITY(1,1) NOT NULL,
  [agreement_sno] int NOT NULL,
  [version_no] int NOT NULL,
  [action_type] varchar(20) NOT NULL,
  [outcome] varchar(10) NOT NULL CONSTRAINT [DF__service_a__outco__34BEB830] DEFAULT ('PENDING'),
  [period_start_date] date NOT NULL,
  [period_end_date] date NOT NULL,
  [terms_json] nvarchar(max) NOT NULL,
  [note] nvarchar(300) NULL,
  [submitted_by] varchar(30) NULL,
  [submitted_at] datetime NOT NULL CONSTRAINT [DF__service_a__submi__35B2DC69] DEFAULT (getdate()),
  [decided_at] datetime NULL,
  [superseded_at] datetime NULL,
  CONSTRAINT [PK__service___27CF3F52FE544B7D] PRIMARY KEY CLUSTERED ([version_sno]),
  CONSTRAINT [UQ_service_agreement_version] UNIQUE NONCLUSTERED ([agreement_sno], [version_no]),
  CONSTRAINT [CK_service_agreement_version_outcome] CHECK ([outcome]='EXPIRED' OR [outcome]='REJECTED' OR [outcome]='APPROVED' OR [outcome]='PENDING'),
  CONSTRAINT [CK_service_agreement_version_json] CHECK (isjson([terms_json])=(1))
);
GO
-- [A. create tables] dbo.loan_rate_period
CREATE TABLE [dbo].[loan_rate_period] (
  [rate_period_sno] int IDENTITY(1,1) NOT NULL,
  [agreement_sno] int NOT NULL,
  [effective_from] date NOT NULL,
  [benchmark_rate_pct] decimal(7,3) NULL,
  [spread_pct] decimal(7,3) NULL,
  [interest_rate_pct] decimal(7,3) NOT NULL,
  [remarks] nvarchar(300) NULL,
  [created_by] varchar(30) NULL,
  [created_at] datetime NOT NULL CONSTRAINT [DF__loan_rate__creat__3548C815] DEFAULT (getdate()),
  CONSTRAINT [PK__loan_rat__588DCF89B01912E0] PRIMARY KEY CLUSTERED ([rate_period_sno]),
  CONSTRAINT [UQ_loan_rate_period] UNIQUE NONCLUSTERED ([agreement_sno], [effective_from]),
  CONSTRAINT [CK_loan_rate_period_rate] CHECK ([interest_rate_pct]>=(0) AND [interest_rate_pct]<=(100))
);
GO
-- [A. create tables] dbo.loan_principal_txn
CREATE TABLE [dbo].[loan_principal_txn] (
  [txn_sno] int IDENTITY(1,1) NOT NULL,
  [agreement_sno] int NOT NULL,
  [txn_date] date NOT NULL,
  [txn_type] varchar(10) NOT NULL,
  [amount] decimal(18,2) NOT NULL,
  [voucher_sno] int NULL,
  [remarks] nvarchar(300) NULL,
  [created_by] varchar(30) NULL,
  [created_at] datetime NOT NULL CONSTRAINT [DF__loan_prin__creat__3A0D7D32] DEFAULT (getdate()),
  [is_active] char(1) NOT NULL CONSTRAINT [DF__loan_prin__is_ac__3B01A16B] DEFAULT ('Y'),
  CONSTRAINT [PK__loan_pri__A762C595C276AE11] PRIMARY KEY CLUSTERED ([txn_sno]),
  CONSTRAINT [CK_loan_principal_txn_type] CHECK ([txn_type]='REPAYMENT' OR [txn_type]='DRAWDOWN'),
  CONSTRAINT [CK_loan_principal_txn_amount] CHECK ([amount]>(0))
);
CREATE NONCLUSTERED INDEX [IX_loan_principal_txn_agreement] ON [dbo].[loan_principal_txn] ([agreement_sno], [txn_date]);
GO
-- [A. create tables] dbo.service_po_cycle_vendor
CREATE TABLE [dbo].[service_po_cycle_vendor] (
  [cycle_vendor_sno] int IDENTITY(1,1) NOT NULL,
  [cycle_sno] int NOT NULL,
  [vendor_sno] int NOT NULL,
  [share_pct] decimal(9,6) NOT NULL,
  [rate_amount] decimal(18,2) NOT NULL,
  [net_cost] decimal(18,2) NOT NULL,
  [po_basic_sno] int NULL,
  [created_at] datetime NOT NULL CONSTRAINT [DF__service_p__creat__3C5FD9F8] DEFAULT (getdate()),
  CONSTRAINT [PK__service___7E94694CC34FE138] PRIMARY KEY CLUSTERED ([cycle_vendor_sno]),
  CONSTRAINT [UQ_service_po_cycle_vendor] UNIQUE NONCLUSTERED ([cycle_sno], [vendor_sno])
);
GO
-- [A. create tables] dbo.bank_payment_voucher
CREATE TABLE [dbo].[bank_payment_voucher] (
  [voucher_sno] int IDENTITY(1,1) NOT NULL,
  [voucher_no] varchar(30) NOT NULL,
  [agreement_sno] int NOT NULL,
  [com_sno] int NOT NULL,
  [div_sno] int NOT NULL,
  [brn_sno] int NOT NULL,
  [dept_sno] int NOT NULL,
  [vendor_sno] int NOT NULL,
  [period_from] date NOT NULL,
  [period_to] date NOT NULL,
  [days] int NOT NULL,
  [day_count_basis] smallint NOT NULL,
  [opening_principal] decimal(18,2) NOT NULL,
  [principal_on_payment] decimal(18,2) NOT NULL,
  [interest_amount] decimal(18,2) NOT NULL,
  [principal_repayment] decimal(18,2) NOT NULL CONSTRAINT [DF__bank_paym__princ__41AE9EFA] DEFAULT ((0)),
  [total_payable] decimal(18,2) NOT NULL,
  [principal_after] decimal(18,2) NOT NULL,
  [rate_pct] decimal(7,3) NOT NULL,
  [segments_json] nvarchar(max) NOT NULL,
  [next_due_date] date NULL,
  [next_days] int NULL,
  [next_est_interest] decimal(18,2) NULL,
  [next_segments_json] nvarchar(max) NULL,
  [remarks] nvarchar(500) NULL,
  [status] varchar(20) NOT NULL CONSTRAINT [DF__bank_paym__statu__42A2C333] DEFAULT ('PENDING_APPROVAL'),
  [workflow_types_id] int NULL,
  [current_approver_id] varchar(30) NULL,
  [current_stage_seq] int NOT NULL CONSTRAINT [DF__bank_paym__curre__4396E76C] DEFAULT ((0)),
  [created_by] varchar(30) NOT NULL,
  [created_at] datetime NOT NULL CONSTRAINT [DF__bank_paym__creat__448B0BA5] DEFAULT (getdate()),
  [approved_at] datetime NULL,
  [paid_on] date NULL,
  [payment_mode] varchar(10) NULL,
  [payment_ref_no] nvarchar(100) NULL,
  [paid_from_bank] nvarchar(150) NULL,
  [paid_by] varchar(30) NULL,
  [paid_recorded_at] datetime NULL,
  CONSTRAINT [PK__bank_pay__6E3C274408BF5FA6] PRIMARY KEY CLUSTERED ([voucher_sno]),
  CONSTRAINT [UQ_bank_payment_voucher_no] UNIQUE NONCLUSTERED ([voucher_no]),
  CONSTRAINT [CK_bank_payment_voucher_status] CHECK ([status]='REJECTED' OR [status]='PAID' OR [status]='APPROVED' OR [status]='PENDING_APPROVAL'),
  CONSTRAINT [CK_bank_payment_voucher_period] CHECK ([period_to]>[period_from]),
  CONSTRAINT [CK_bank_payment_voucher_json] CHECK (isjson([segments_json])=(1))
);
CREATE NONCLUSTERED INDEX [IX_bank_payment_voucher_agreement] ON [dbo].[bank_payment_voucher] ([agreement_sno], [status]);
CREATE NONCLUSTERED INDEX [IX_bank_payment_voucher_approver] ON [dbo].[bank_payment_voucher] ([current_approver_id], [status]);
CREATE UNIQUE NONCLUSTERED INDEX [UX_bank_payment_voucher_one_open] ON [dbo].[bank_payment_voucher] ([agreement_sno]) WHERE ([status]='PENDING_APPROVAL');
GO
-- [A. create tables] dbo.bank_payment_voucher_history
CREATE TABLE [dbo].[bank_payment_voucher_history] (
  [history_sno] int IDENTITY(1,1) NOT NULL,
  [voucher_sno] int NOT NULL,
  [action_type] varchar(30) NOT NULL,
  [status_by] varchar(30) NOT NULL,
  [comment] nvarchar(500) NULL,
  [created_at] datetime NOT NULL CONSTRAINT [DF__bank_paym__creat__4B380934] DEFAULT (getdate()),
  CONSTRAINT [PK__bank_pay__896384B2C719EA42] PRIMARY KEY CLUSTERED ([history_sno])
);
GO
-- [A. create tables] dbo.pr_vendor_driven_info
CREATE TABLE [dbo].[pr_vendor_driven_info] (
  [pr_vd_info_sno] int IDENTITY(1,1) NOT NULL,
  [pr_basic_sno] int NOT NULL,
  [vendor_sno] int NOT NULL,
  [payment_cycle_days] int NOT NULL CONSTRAINT [DF__pr_vendor__payme__509BDCCF] DEFAULT ((15)),
  [created_by] varchar(20) NULL,
  [created_date] datetime NULL,
  [attachment] nvarchar(500) NULL,
  CONSTRAINT [PK__pr_vendo__34DDDA46AF59C062] PRIMARY KEY CLUSTERED ([pr_vd_info_sno]),
  CONSTRAINT [UQ_pr_vendor_driven_info_pr_basic_sno] UNIQUE NONCLUSTERED ([pr_basic_sno])
);
CREATE NONCLUSTERED INDEX [IX_pr_vendor_driven_info_vendor] ON [dbo].[pr_vendor_driven_info] ([vendor_sno], [pr_basic_sno]);
GO
-- [A. create tables] dbo.pr_vendor_driven_item_details
CREATE TABLE [dbo].[pr_vendor_driven_item_details] (
  [pr_vd_item_sno] int IDENTITY(1,1) NOT NULL,
  [pr_item_sno] int NOT NULL,
  [item_rate] decimal(18,4) NOT NULL,
  [gst_pct] decimal(5,2) NOT NULL CONSTRAINT [DF__pr_vendor__gst_p__546C6DB3] DEFAULT ((0)),
  [discount_pct] decimal(5,2) NOT NULL CONSTRAINT [DF__pr_vendor__disco__556091EC] DEFAULT ((0)),
  [taxable_amount] decimal(18,2) NOT NULL,
  [gst_amount] decimal(18,2) NOT NULL,
  CONSTRAINT [PK__pr_vendo__9D6AED1F79D837BA] PRIMARY KEY CLUSTERED ([pr_vd_item_sno]),
  CONSTRAINT [UQ_pr_vendor_driven_item_details_pr_item_sno] UNIQUE NONCLUSTERED ([pr_item_sno])
);
GO
-- [A. create tables] dbo.product_stock_level_master
CREATE TABLE [dbo].[product_stock_level_master] (
  [stock_level_sno] int IDENTITY(1,1) NOT NULL,
  [prod_sno] int NOT NULL,
  [scope_type] varchar(10) NOT NULL,
  [com_sno] int NULL,
  [div_sno] int NULL,
  [brn_sno] int NULL,
  [location_sno] int NULL,
  [min_qty] decimal(18,2) NOT NULL,
  [max_qty] decimal(18,2) NOT NULL,
  [reorder_level] decimal(18,2) NOT NULL,
  [is_active] char(1) NOT NULL CONSTRAINT [DF__product_s__is_ac__59662CFA] DEFAULT ('Y'),
  [created_by] varchar(20) NULL,
  [created_date] datetime NOT NULL CONSTRAINT [DF__product_s__creat__5A5A5133] DEFAULT (getdate()),
  [modified_by] varchar(20) NULL,
  [modified_date] datetime NULL,
  CONSTRAINT [PK__product___D13B2357F4EEDD39] PRIMARY KEY CLUSTERED ([stock_level_sno]),
  CONSTRAINT [CK_prod_stock_level_scope_type] CHECK ([scope_type]='LOCATION' OR [scope_type]='ORG'),
  CONSTRAINT [CK_prod_stock_level_is_active] CHECK ([is_active]='N' OR [is_active]='Y'),
  CONSTRAINT [CK_prod_stock_level_scope_shape] CHECK ([scope_type]='ORG' AND [com_sno] IS NOT NULL AND [location_sno] IS NULL OR [scope_type]='LOCATION' AND [location_sno] IS NOT NULL AND [com_sno] IS NULL AND [div_sno] IS NULL AND [brn_sno] IS NULL),
  CONSTRAINT [CK_prod_stock_level_qty_range] CHECK ([min_qty]>=(0) AND [max_qty]>=(0) AND [reorder_level]>=(0) AND [min_qty]<=[max_qty] AND ([reorder_level]>=[min_qty] AND [reorder_level]<=[max_qty]))
);
CREATE NONCLUSTERED INDEX [IX_prod_stock_level_prod_sno] ON [dbo].[product_stock_level_master] ([prod_sno]);
GO
-- [A. create tables] dbo.nt_stock_batches
CREATE TABLE [dbo].[nt_stock_batches] (
  [batch_sno] int IDENTITY(1,1) NOT NULL,
  [batch_no] varchar(60) NOT NULL,
  [item_sno] int NOT NULL,
  [grn_basic_sno] int NULL,
  [grn_item_sno] int NULL,
  [grn_no] varchar(30) NULL,
  [received_qty] decimal(18,2) NOT NULL,
  [remaining_qty] decimal(18,2) NOT NULL,
  [unit_cost] decimal(18,2) NULL,
  [received_date] date NOT NULL,
  [uom] varchar(20) NULL,
  [com_sno] int NULL,
  [div_sno] int NULL,
  [brn_sno] int NULL,
  [dept_sno] int NULL,
  [status] varchar(20) NOT NULL CONSTRAINT [DF__nt_stock___statu__5A254709] DEFAULT ('Active'),
  [created_by] varchar(50) NULL,
  [created_at] datetime NOT NULL CONSTRAINT [DF__nt_stock___creat__5B196B42] DEFAULT (getdate()),
  CONSTRAINT [PK__nt_stock__41B97C84C17C0450] PRIMARY KEY CLUSTERED ([batch_sno])
);
CREATE NONCLUSTERED INDEX [IX_nt_stock_batches_fifo] ON [dbo].[nt_stock_batches] ([item_sno], [received_date], [batch_sno]);
GO
-- [A. create tables] dbo.service_po_cycle
CREATE TABLE [dbo].[service_po_cycle] (
  [cycle_sno] int IDENTITY(1,1) NOT NULL,
  [agreement_sno] int NOT NULL,
  [com_sno] int NOT NULL,
  [div_sno] int NOT NULL,
  [brn_sno] int NOT NULL,
  [dept_sno] int NOT NULL,
  [billing_period_start] date NOT NULL,
  [pr_basic_sno] int NOT NULL,
  [pr_no] varchar(20) NOT NULL,
  [qty] decimal(18,4) NOT NULL,
  [rate_amount] decimal(18,2) NULL,
  [discount_pct] decimal(5,2) NULL,
  [gst_pct] decimal(5,2) NULL,
  [net_cost] decimal(18,2) NULL,
  [remarks] nvarchar(500) NULL,
  [status] varchar(20) NOT NULL CONSTRAINT [DF__service_p__statu__63AEB143] DEFAULT ('PENDING_ENTRY'),
  [workflow_types_id] int NULL,
  [current_approver_id] varchar(30) NULL,
  [entered_by] varchar(20) NULL,
  [entered_at] datetime NULL,
  [po_basic_sno] int NULL,
  [created_at] datetime NOT NULL CONSTRAINT [DF__service_p__creat__64A2D57C] DEFAULT (getdate()),
  CONSTRAINT [PK__service___35E1584186E51E16] PRIMARY KEY CLUSTERED ([cycle_sno]),
  CONSTRAINT [UQ_service_po_cycle_period] UNIQUE NONCLUSTERED ([agreement_sno], [billing_period_start]),
  CONSTRAINT [CK_service_po_cycle_status] CHECK ([status]='REJECTED' OR [status]='GENERATED' OR [status]='PENDING_APPROVAL' OR [status]='PENDING_ENTRY')
);
CREATE NONCLUSTERED INDEX [IX_service_po_cycle_approver] ON [dbo].[service_po_cycle] ([current_approver_id], [status]);
GO
-- [A. create tables] dbo.service_po_cycle_history
CREATE TABLE [dbo].[service_po_cycle_history] (
  [history_sno] int IDENTITY(1,1) NOT NULL,
  [cycle_sno] int NOT NULL,
  [action_type] varchar(30) NOT NULL,
  [status_by] varchar(20) NOT NULL,
  [comment] varchar(500) NULL,
  [created_at] datetime NOT NULL CONSTRAINT [DF__service_p__creat__6A5BAED2] DEFAULT (getdate()),
  CONSTRAINT [PK__service___896384B27BB5AA61] PRIMARY KEY CLUSTERED ([history_sno])
);
GO
-- [B. sequences] seq_nonstaff_login_id
CREATE SEQUENCE [dbo].[seq_nonstaff_login_id] AS int START WITH 1 INCREMENT BY 1 NO CYCLE;
GO
-- [C. add columns] dbo.kyc_address_info.state_code
ALTER TABLE [dbo].[kyc_address_info] ADD [state_code] int NULL;
GO
-- [C. add columns] dbo.nt_stock_movements.batch_sno
ALTER TABLE [dbo].[nt_stock_movements] ADD [batch_sno] int NULL;
GO
-- [C. add columns] dbo.pr_basic_info.request_mode
ALTER TABLE [dbo].[pr_basic_info] ADD [request_mode] varchar(30) NOT NULL CONSTRAINT [DF_pr_basic_info_request_mode] DEFAULT ('NORMAL');
GO
-- [C. add columns] dbo.pr_basic_info.vendor_sno
ALTER TABLE [dbo].[pr_basic_info] ADD [vendor_sno] int NULL;
GO
-- [C. add columns] dbo.pr_basic_info.payment_cycle_days
ALTER TABLE [dbo].[pr_basic_info] ADD [payment_cycle_days] int NULL;
GO
-- [C. add columns] dbo.pr_item_details.item_description
ALTER TABLE [dbo].[pr_item_details] ADD [item_description] nvarchar(500) NULL;
GO
-- [C. add columns] dbo.pr_item_details.item_rate
ALTER TABLE [dbo].[pr_item_details] ADD [item_rate] decimal(18,4) NULL;
GO
-- [C. add columns] dbo.pr_item_details.gst_pct
ALTER TABLE [dbo].[pr_item_details] ADD [gst_pct] decimal(5,2) NULL;
GO
-- [C. add columns] dbo.pr_item_details.discount_pct
ALTER TABLE [dbo].[pr_item_details] ADD [discount_pct] decimal(5,2) NULL;
GO
-- [C. add columns] dbo.pr_item_details.taxable_amount
ALTER TABLE [dbo].[pr_item_details] ADD [taxable_amount] decimal(18,2) NULL;
GO
-- [C. add columns] dbo.pr_item_details.gst_amount
ALTER TABLE [dbo].[pr_item_details] ADD [gst_amount] decimal(18,2) NULL;
GO
-- [C. add columns] dbo.product_master.prod_uom_con_uom_sno
ALTER TABLE [dbo].[product_master] ADD [prod_uom_con_uom_sno] int NULL;
GO
-- [C. add columns] dbo.service_agreement.qty
ALTER TABLE [dbo].[service_agreement] ADD [qty] decimal(18,4) NOT NULL CONSTRAINT [DF__service_agr__qty__1A3FCC1E] DEFAULT ((1));
GO
-- [C. add columns] dbo.service_agreement.terms_conditions
ALTER TABLE [dbo].[service_agreement] ADD [terms_conditions] nvarchar(max) NULL;
GO
-- [C. add columns] dbo.service_agreement_history.created_at
ALTER TABLE [dbo].[service_agreement_history] ADD [created_at] datetime NOT NULL CONSTRAINT [DF__service_a__creat__29820FAE] DEFAULT (getdate());
GO
-- [C. add columns] dbo.service_agreement_history.version_no
ALTER TABLE [dbo].[service_agreement_history] ADD [version_no] int NULL;
GO
-- [C. add columns] dbo.subcategory_master.perishable_days
ALTER TABLE [dbo].[subcategory_master] ADD [perishable_days] int NULL;
GO
-- [D. alter columns] dbo.service_agreement.vendor_sno
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [vendor_sno] int NOT NULL;
GO
-- [D. alter columns] dbo.service_agreement.rate_amount
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [rate_amount] decimal(18,2) NOT NULL;
GO
-- [D. alter columns] dbo.service_agreement.recurrence_cadence_sno
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [recurrence_cadence_sno] int NOT NULL;
GO
-- [D. alter columns] dbo.service_agreement.notify_days_before
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [notify_days_before] smallint NOT NULL;
ALTER TABLE [dbo].[service_agreement] ADD CONSTRAINT [DF__service_a__notif__1B33F057] DEFAULT ((0)) FOR [notify_days_before];
GO
-- [D. alter columns] dbo.service_agreement.status
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [status] char(1) NOT NULL;
ALTER TABLE [dbo].[service_agreement] ADD CONSTRAINT [DF__service_a__statu__1C281490] DEFAULT ('P') FOR [status];
GO
-- [D. alter columns] dbo.service_agreement_history.comment
ALTER TABLE [dbo].[service_agreement_history] ALTER COLUMN [comment] nvarchar(500) NULL;
GO
-- [D2. relax legacy columns] dbo.service_agreement.recurrence_cadence
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [recurrence_cadence] varchar(20) NULL;
GO
-- [E. indexes] dbo.pr_basic_info.IX_pr_basic_info_vendor_mode
CREATE NONCLUSTERED INDEX [IX_pr_basic_info_vendor_mode] ON [dbo].[pr_basic_info] ([request_mode], [vendor_sno], [status]);
GO
-- [E. indexes] dbo.nt_user_permissions_json.UX_nt_user_permissions_json_staff_user
CREATE UNIQUE NONCLUSTERED INDEX [UX_nt_user_permissions_json_staff_user] ON [dbo].[nt_user_permissions_json] ([nt_sign_up_sno]) WHERE ([nt_sign_up_sno] IS NOT NULL);
GO
-- [E. checks] dbo.service_agreement.CK_service_agreement_qty
ALTER TABLE [dbo].[service_agreement] WITH CHECK ADD CONSTRAINT [CK_service_agreement_qty] CHECK ([qty]>(0));
GO
-- [E. checks] dbo.service_agreement.CK_service_agreement_rate
ALTER TABLE [dbo].[service_agreement] WITH CHECK ADD CONSTRAINT [CK_service_agreement_rate] CHECK ([rate_amount]>(0));
GO
-- [E. checks] dbo.subcategory_master.CK_subcategory_master_perishable_days
ALTER TABLE [dbo].[subcategory_master] WITH CHECK ADD CONSTRAINT [CK_subcategory_master_perishable_days] CHECK ([perishable_days] IS NULL OR [perishable_days]>(0));
GO
-- [E. foreign keys] dbo.service_agreement.FK_service_agreement_cadence
ALTER TABLE [dbo].[service_agreement] WITH CHECK ADD CONSTRAINT [FK_service_agreement_cadence] FOREIGN KEY ([recurrence_cadence_sno]) REFERENCES [dbo].[recurrence_cadence_master] ([recurrence_cadence_sno]);
GO
-- [E. foreign keys] dbo.nt_stock_movements.FK_nt_stock_movements_batch
ALTER TABLE [dbo].[nt_stock_movements] WITH CHECK ADD CONSTRAINT [FK_nt_stock_movements_batch] FOREIGN KEY ([batch_sno]) REFERENCES [dbo].[nt_stock_batches] ([batch_sno]);
GO
-- [E. foreign keys (new tables)] dbo.service_agreement_vendor.FK_service_agreement_vendor_agreement
ALTER TABLE [dbo].[service_agreement_vendor] WITH CHECK ADD CONSTRAINT [FK_service_agreement_vendor_agreement] FOREIGN KEY ([agreement_sno]) REFERENCES [dbo].[service_agreement] ([agreement_sno]);
GO
-- [E. foreign keys (new tables)] dbo.service_agreement_statutory.FK_service_agreement_statutory_agreement
ALTER TABLE [dbo].[service_agreement_statutory] WITH CHECK ADD CONSTRAINT [FK_service_agreement_statutory_agreement] FOREIGN KEY ([agreement_sno]) REFERENCES [dbo].[service_agreement] ([agreement_sno]);
GO
-- [E. foreign keys (new tables)] dbo.loan_rate_period.FK_loan_rate_period_agreement
ALTER TABLE [dbo].[loan_rate_period] WITH CHECK ADD CONSTRAINT [FK_loan_rate_period_agreement] FOREIGN KEY ([agreement_sno]) REFERENCES [dbo].[service_agreement] ([agreement_sno]);
GO
-- [E. foreign keys (new tables)] dbo.service_agreement_version.FK_service_agreement_version_agreement
ALTER TABLE [dbo].[service_agreement_version] WITH CHECK ADD CONSTRAINT [FK_service_agreement_version_agreement] FOREIGN KEY ([agreement_sno]) REFERENCES [dbo].[service_agreement] ([agreement_sno]);
GO
-- [E. foreign keys (new tables)] dbo.loan_principal_txn.FK_loan_principal_txn_agreement
ALTER TABLE [dbo].[loan_principal_txn] WITH CHECK ADD CONSTRAINT [FK_loan_principal_txn_agreement] FOREIGN KEY ([agreement_sno]) REFERENCES [dbo].[service_agreement] ([agreement_sno]);
GO
-- [E. foreign keys (new tables)] dbo.bank_payment_voucher.FK_bank_payment_voucher_agreement
ALTER TABLE [dbo].[bank_payment_voucher] WITH CHECK ADD CONSTRAINT [FK_bank_payment_voucher_agreement] FOREIGN KEY ([agreement_sno]) REFERENCES [dbo].[service_agreement] ([agreement_sno]);
GO
-- [E. foreign keys (new tables)] dbo.service_po_cycle.FK_service_po_cycle_agreement
ALTER TABLE [dbo].[service_po_cycle] WITH CHECK ADD CONSTRAINT [FK_service_po_cycle_agreement] FOREIGN KEY ([agreement_sno]) REFERENCES [dbo].[service_agreement] ([agreement_sno]);
GO
-- [E. foreign keys (new tables)] dbo.nt_stock_batches.FK_nt_stock_batches_item
ALTER TABLE [dbo].[nt_stock_batches] WITH CHECK ADD CONSTRAINT [FK_nt_stock_batches_item] FOREIGN KEY ([item_sno]) REFERENCES [dbo].[nt_inventory_items] ([item_sno]);
GO
-- [E. foreign keys (new tables)] dbo.bank_payment_voucher_history.FK_bank_payment_voucher_history_voucher
ALTER TABLE [dbo].[bank_payment_voucher_history] WITH CHECK ADD CONSTRAINT [FK_bank_payment_voucher_history_voucher] FOREIGN KEY ([voucher_sno]) REFERENCES [dbo].[bank_payment_voucher] ([voucher_sno]);
GO
-- [E. foreign keys (new tables)] dbo.loan_principal_txn.FK_loan_principal_txn_voucher
ALTER TABLE [dbo].[loan_principal_txn] WITH CHECK ADD CONSTRAINT [FK_loan_principal_txn_voucher] FOREIGN KEY ([voucher_sno]) REFERENCES [dbo].[bank_payment_voucher] ([voucher_sno]);
GO
-- [E. foreign keys (new tables)] dbo.service_po_cycle_vendor.FK_service_po_cycle_vendor_cycle
ALTER TABLE [dbo].[service_po_cycle_vendor] WITH CHECK ADD CONSTRAINT [FK_service_po_cycle_vendor_cycle] FOREIGN KEY ([cycle_sno]) REFERENCES [dbo].[service_po_cycle] ([cycle_sno]);
GO
-- [E. foreign keys (new tables)] dbo.service_po_cycle_history.FK_service_po_cycle_history_cycle
ALTER TABLE [dbo].[service_po_cycle_history] WITH CHECK ADD CONSTRAINT [FK_service_po_cycle_history_cycle] FOREIGN KEY ([cycle_sno]) REFERENCES [dbo].[service_po_cycle] ([cycle_sno]);
GO
-- [E. foreign keys (new tables)] dbo.service_po_cycle_vendor.FK_service_po_cycle_vendor_po
ALTER TABLE [dbo].[service_po_cycle_vendor] WITH CHECK ADD CONSTRAINT [FK_service_po_cycle_vendor_po] FOREIGN KEY ([po_basic_sno]) REFERENCES [dbo].[po_request_info] ([po_basic_sno]);
GO
-- [E. foreign keys (new tables)] dbo.service_po_cycle.FK_service_po_cycle_po
ALTER TABLE [dbo].[service_po_cycle] WITH CHECK ADD CONSTRAINT [FK_service_po_cycle_po] FOREIGN KEY ([po_basic_sno]) REFERENCES [dbo].[po_request_info] ([po_basic_sno]);
GO
-- [F0. functions] dbo.fn_LoanBilledThrough  (new)
CREATE OR ALTER FUNCTION dbo.fn_LoanBilledThrough (@agreement_sno INT)
RETURNS DATE
AS
BEGIN
    RETURN ISNULL(
        (SELECT MAX(v.period_to) FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = @agreement_sno AND v.status IN ('APPROVED', 'PAID')),
        (SELECT s.disbursement_date FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno));
END;
GO
-- [F0. functions] dbo.fn_LoanInterestSegments  (new)
-- Interest for [@from, @to): one row per slice with a constant principal and a
-- constant rate. @extra_repay is a principal repayment not yet written to
-- loan_principal_txn (used to project the NEXT period after a voucher that
-- repays principal); it reduces every slice from @from onward.
CREATE OR ALTER FUNCTION dbo.fn_LoanInterestSegments (@agreement_sno INT, @from DATE, @to DATE, @extra_repay DECIMAL(18,2))
RETURNS @seg TABLE (
    seg_no INT, seg_from DATE, seg_to DATE, days INT, principal DECIMAL(18,2),
    benchmark_rate_pct DECIMAL(7,3), spread_pct DECIMAL(7,3), rate_pct DECIMAL(7,3), interest DECIMAL(18,2)
)
AS
BEGIN
    DECLARE @basis SMALLINT = ISNULL((SELECT day_count_basis FROM dbo.service_agreement_statutory WHERE agreement_sno = @agreement_sno), 365);
    DECLARE @bp TABLE (d DATE NOT NULL);

    INSERT INTO @bp (d)
    SELECT x.d
    FROM (
        SELECT @from AS d
        UNION SELECT effective_from FROM dbo.loan_rate_period WHERE agreement_sno = @agreement_sno
        UNION SELECT txn_date FROM dbo.loan_principal_txn WHERE agreement_sno = @agreement_sno AND is_active = 'Y'
        UNION SELECT disbursement_date FROM dbo.service_agreement_statutory WHERE agreement_sno = @agreement_sno AND disbursement_date IS NOT NULL
    ) x
    WHERE x.d >= @from AND x.d < @to;

    INSERT INTO @seg (seg_no, seg_from, seg_to, days, principal, benchmark_rate_pct, spread_pct, rate_pct, interest)
    SELECT ROW_NUMBER() OVER (ORDER BY b.d), b.d, b.nxt, DATEDIFF(DAY, b.d, b.nxt), b.pr,
           r.benchmark_rate_pct, r.spread_pct, r.interest_rate_pct,
           ROUND(b.pr * r.interest_rate_pct / 100.0 * DATEDIFF(DAY, b.d, b.nxt) / @basis, 2)
    FROM (
        SELECT d, ISNULL(LEAD(d) OVER (ORDER BY d), @to) AS nxt,
               dbo.fn_LoanPrincipalAt(@agreement_sno, d) - ISNULL(@extra_repay, 0) AS pr
        FROM @bp
    ) b
    CROSS APPLY dbo.fn_LoanRateAt(@agreement_sno, b.d) r;

    RETURN;
END;
GO
-- [F0. functions] dbo.fn_LoanLockedThrough  (new)
CREATE OR ALTER FUNCTION dbo.fn_LoanLockedThrough (@agreement_sno INT)
RETURNS DATE
AS
BEGIN
    RETURN ISNULL(
        (SELECT MAX(v.period_to) FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = @agreement_sno AND v.status IN ('PENDING_APPROVAL', 'APPROVED', 'PAID')),
        (SELECT s.disbursement_date FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno));
END;
GO
-- [F0. functions] dbo.fn_LoanNextDueDate  (new)
-- The next scheduled interest date strictly after @after. A payment day the
-- month doesn't have (31st in February) falls on the month's last day.
CREATE OR ALTER FUNCTION dbo.fn_LoanNextDueDate (@pay_day TINYINT, @after DATE)
RETURNS DATE
AS
BEGIN
    DECLARE @cand DATE = DATEFROMPARTS(YEAR(@after), MONTH(@after),
        CASE WHEN @pay_day > DAY(EOMONTH(@after)) THEN DAY(EOMONTH(@after)) ELSE @pay_day END);
    IF @cand <= @after
    BEGIN
        DECLARE @nm DATE = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@after), MONTH(@after), 1));
        SET @cand = DATEFROMPARTS(YEAR(@nm), MONTH(@nm),
            CASE WHEN @pay_day > DAY(EOMONTH(@nm)) THEN DAY(EOMONTH(@nm)) ELSE @pay_day END);
    END
    RETURN @cand;
END;
GO
-- [F0. functions] dbo.fn_LoanPrincipalAt  (new)
-- Principal outstanding ON a date (movements dated on or before it have taken effect).
CREATE OR ALTER FUNCTION dbo.fn_LoanPrincipalAt (@agreement_sno INT, @on DATE)
RETURNS DECIMAL(18,2)
AS
BEGIN
    RETURN
        ISNULL((SELECT CASE WHEN s.disbursement_date <= @on THEN ISNULL(s.disbursed_amount, 0) ELSE 0 END
                FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno), 0)
      + ISNULL((SELECT SUM(CASE t.txn_type WHEN 'DRAWDOWN' THEN t.amount ELSE -t.amount END)
                FROM dbo.loan_principal_txn t
                WHERE t.agreement_sno = @agreement_sno AND t.is_active = 'Y' AND t.txn_date <= @on), 0);
END;
GO
-- [F0. functions] dbo.fn_LoanRateAt  (new)
-- The rate in force ON a date: the latest entered rate period on or before it,
-- else the rate the loan was sanctioned at (effective from the disbursement date).
CREATE OR ALTER FUNCTION dbo.fn_LoanRateAt (@agreement_sno INT, @on DATE)
RETURNS TABLE
AS
RETURN
(
    SELECT TOP 1 r.effective_from, r.benchmark_rate_pct, r.spread_pct, r.interest_rate_pct
    FROM (
        SELECT p.effective_from, p.benchmark_rate_pct, p.spread_pct, p.interest_rate_pct, 1 AS src
        FROM dbo.loan_rate_period p
        WHERE p.agreement_sno = @agreement_sno AND p.effective_from <= @on
        UNION ALL
        SELECT s.disbursement_date, s.benchmark_rate_pct, s.spread_pct, s.interest_rate_pct, 0
        FROM dbo.service_agreement_statutory s
        WHERE s.agreement_sno = @agreement_sno AND s.disbursement_date <= @on
    ) r
    ORDER BY r.effective_from DESC, r.src DESC
);
GO
-- [F1. views] dbo.ActiveBranches
CREATE OR ALTER VIEW ActiveBranches  
AS  
SELECT    
  bm.brn_sno,  
  bm.brn_name,  
  bm.brn_prefix,  
  cm.com_name, 
  cm.com_sno,
  cm.com_prefix,  
  dm.div_name,
  dm.div_sno,
  dm.div_prefix,  
  dm.div_type,  
  am.add_door_no,  
  am.add_street,  
  am.add_city,  
  am.add_state,  
  am.add_state_code,  
  am.add_pin_code  
  
  FROM [Non_trade_Dev].[dbo].[branch_master] bm left join [Non_trade_Dev].[dbo].[company_master] cm on  
  bm.com_sno=cm.com_sno left join [Non_trade_Dev].[dbo].[division_master] dm on bm.div_sno =dm.div_sno   
  left join [Non_trade_Dev].[dbo].[address_master] am on bm.add_sno=am.add_sno where bm.is_active='Y'
GO
-- [F1. views] dbo.vw_ActiveDivisions
CREATE OR ALTER VIEW [dbo].[vw_ActiveDivisions]  
AS  
SELECT   
    dm.div_sno AS div_sno,  
    dm.div_name AS div_name,  
dm.div_prefix as div_prefix,  
    dm.div_type AS div_type, 
    cm.com_sno AS com_sno,
    cm.com_name AS com_name,  
    cm.com_prefix AS com_prefix  
FROM [Non_trade_Dev].[dbo].[division_master] dm   
LEFT JOIN [Non_trade_Dev].[dbo].[company_master] cm   
    ON dm.com_sno = cm.com_sno   
WHERE dm.is_active = 'Y';
GO
-- [F1. views] dbo.vw_company_address
  CREATE OR ALTER VIEW vw_company_address AS
SELECT 
    -- Company Master fields
    cm.com_sno AS com_sno ,
    cm.com_name AS com_name,
    cm.com_prefix AS com_prefix,
    cm.is_active AS is_active,
    cm.created_date AS created_date,
    
    -- Address Master fields
     am.add_pan AS add_pan,
    am.is_gst_applicable AS is_gst_applicable,
    am.add_gst AS add_gst,
    am.add_tan AS add_tan,
    am.add_cin AS add_cin,
    am.add_door_no AS add_door_no,
    am.add_street AS add_street,
    am.add_city AS add_city,
    am.add_state AS add_state,
    am.add_state_code AS add_state_code,
    am.add_pin_code AS add_pin_code,
    am.add_reg_door_no AS add_reg_door_no,
    am.add_reg_street AS add_reg_street,
    am.add_reg_city AS add_reg_city,
    am.add_reg_state AS add_reg_state,
    am.add_reg_pincode AS add_reg_pincode
    
FROM [Non_trade_Dev].[dbo].[company_master] cm
LEFT JOIN [Non_trade_Dev].[dbo].[address_master] am 
    ON cm.add_sno = am.add_sno where cm.is_active='Y' ;
GO
-- [F1. views] dbo.vw_PR_Basic_Info
-- Approval-queue view: add the header-level attachment (additive column,
-- everything else unchanged from 74_vendor_driven_extension_tables.sql).
CREATE OR ALTER VIEW dbo.vw_PR_Basic_Info
AS
SELECT
    pbf.pr_basic_sno,
    pbf.brn_sno,
    vadr.brn_name,
    vadr.brn_prefix,
    vadr.dept_name,
    vadr.div_prefix,
    vadr.div_name,
    vadr.div_sno,
    vadr.com_name,
    vadr.com_sno,
    vve.ename                   AS created_by_name,
    pbf.dept_sno,
    pbf.reg_date,
    pbf.required_date,
    pbf.priority_sno,
    pbf.purpose,
    pbf.is_active,
    pbf.created_by,
    pbf.created_date,
    pbf.modified_by,
    pbf.modified_date,
    pbf.category,
    pbf.source_invoice_sno,

    -- Vendor-Driven fields (additive) — NULL/'NORMAL' for every ordinary PR.
    pbf.request_mode,
    pvd.vendor_sno,
    vk.company_name              AS vendor_name,
    pvd.payment_cycle_days,
    pvd.attachment               AS vendor_driven_attachment,

    -- group number of this split row (NULL when the PR has no items)
    g.grp                       AS [group],

    -- append /group ONLY when the PR is actually split into >1 group
    CASE
       WHEN g.grp IS NOT NULL AND g.group_count > 1
            THEN pbf.pr_no + '/' + CAST(g.grp AS VARCHAR(10))
        ELSE pbf.pr_no
    END                         AS pr_no,

    pbf.workflow_types_id,
    pbf.current_approver_id,
    pbf.status,

    -- PR Item Details as JSON array (only items of THIS group)
    (
        SELECT
            pid.pr_item_sno,
            pid.pr_basic_sno,
            pid.item_type,
            pid.prod_sno,
            pm.prod_name,
            pm.prod_code,
            pm.prod_notes,
            pid.service_sno,
            sm.service_name,
            sm.service_code,
            pid.specification,
            pid.qty,
            pid.unit,
            uom.uom_name,
            uom.uom_code,
            pid.est_cost,
            pid.total_cost,
            pid.remarks,
            pid.created_by,
            pid.created_date,
            pid.modified_by,
            pid.modified_date,
            pid.is_active,
            pid.[group],
            pid.pr_no,
            pvid.item_rate                AS rate,
            pvid.gst_pct,
            pvid.discount_pct,
            pvid.taxable_amount,
            pvid.gst_amount,
            pid.pr_prod_file              AS item_attachment
        FROM pr_item_details pid
        LEFT JOIN dbo.pr_vendor_driven_item_details pvid
            ON pvid.pr_item_sno = pid.pr_item_sno
        LEFT JOIN uom_master uom
            ON uom.uom_sno = pid.unit
        LEFT JOIN product_master pm
            ON pid.prod_sno = pm.prod_sno
        LEFT JOIN service_master sm
            ON pid.service_sno = sm.service_sno
        WHERE pid.pr_basic_sno = pbf.pr_basic_sno
          AND pid.is_active = 'Y'
          AND (pid.[group] = g.grp OR (pid.[group] IS NULL AND g.grp IS NULL))
        FOR JSON PATH
    ) AS pr_item_details,

    -- Workflow stage JSON
    (
        SELECT
            ws.stage_order_json
        FROM workflow_stage ws
        WHERE ws.workflow_types_id = pbf.workflow_types_id
          AND ws.is_active = 'Y'
    ) AS stage_order_json,

    (
        SELECT
            phd.status_by, COALESCE(vve.ename, nsl.full_name) AS ename, phd.status_date, phd.commends, phd.pr_edit_data
        FROM pr_history_data phd
        LEFT JOIN vw_verified_employees vve
            ON phd.status_by = vve.ecno
        LEFT JOIN dbo.nt_nonstaff_login nsl
            ON phd.status_by = nsl.login_id
        WHERE phd.pr_basic_sno = pbf.pr_basic_sno
        FOR JSON PATH
    ) AS pr_history_data

FROM pr_basic_info pbf
INNER JOIN workflow_types wt
    ON pbf.workflow_types_id = wt.workflow_types_id
INNER JOIN vw_ActiveDeptRecords vadr
    ON pbf.brn_sno   = vadr.brn_sno
   AND pbf.dept_sno  = vadr.dept_sno
INNER JOIN vw_verified_employees vve
    ON pbf.created_by = vve.ecno
LEFT JOIN dbo.pr_vendor_driven_info pvd
    ON pvd.pr_basic_sno = pbf.pr_basic_sno
LEFT JOIN dbo.kyc_basic_info vk
    ON vk.kyc_basic_info_sno = pvd.vendor_sno
OUTER APPLY (
    -- one row per distinct group in this PR; group_count = number of groups
    SELECT
        pid.[group]      AS grp,
        COUNT(*) OVER () AS group_count
    FROM pr_item_details pid
    WHERE pid.pr_basic_sno = pbf.pr_basic_sno
      AND pid.is_active = 'Y'
    GROUP BY pid.[group]
) g;
GO
-- [F2. procedures] dbo.sp_approve_pr_datas
-- ============================================================
-- sp_approve_pr_datas v2
-- Database: Non_trade_Dev (MSSQL)
--
-- Surgical addition only: both result sets (REJECTED and SUCCESS/approve)
-- now also return pr_basic_info.request_mode. The Node approval path
-- (PR.controller.js#approvePr) needs this to know whether a just-approved
-- PR is VENDOR_DRIVEN, so it can auto-issue the child PO
-- (sp_nt_CreateVendorDrivenPOFromPR) right after a final-stage approval —
-- without this, the Node layer would need a second round-trip query just
-- to check request_mode. Every other line of this procedure is byte-for-
-- byte unchanged from the live version.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_approve_pr_datas
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        -- Validate JSON input
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        -- Extract scalar fields
        DECLARE @pr_no           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.pr_no'),
                @comments        VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');  -- 'approve' or 'reject'

        -- Validate action
        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END

        -- Normalize action to lowercase for comparison
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        -- Validate approval_stages
        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        -- Validate approver
        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        -- ✅ TEMP TABLE
        CREATE TABLE #approval_stages (
            seq_no               INT,
            approver_ecno        VARCHAR(30),
            stage                VARCHAR(100),
            required_approvals   VARCHAR(10),
            is_mandatory         CHAR(1),
            escalation_hours     VARCHAR(10),
            approver_condition   VARCHAR(200),
            next_approver_ecno   VARCHAR(30),
            can_forward          CHAR(1),
            can_backward         CHAR(1),
            can_edit_data        CHAR(1)
        );

        INSERT INTO #approval_stages (
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,
            escalation_hours, approver_condition, next_approver_ecno,
            can_forward, can_backward, can_edit_data
        )
        SELECT
            CAST(ojBase.[key] AS INT),
            JSON_VALUE(ojBase.[value], '$.approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.stage'),
            JSON_VALUE(ojBase.[value], '$.required_approvals'),
            JSON_VALUE(ojBase.[value], '$.is_mandatory'),
            JSON_VALUE(ojBase.[value], '$.escalation_hours'),
            JSON_VALUE(ojBase.[value], '$.approver_condition'),
            JSON_VALUE(ojBase.[value], '$.next_approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.can_forward'),
            JSON_VALUE(ojBase.[value], '$.can_backward'),
            JSON_VALUE(ojBase.[value], '$.can_edit_data')
        FROM OPENJSON(@approval_stages) AS ojBase;

        -- Check PR exists
        DECLARE @pr_basic_sno INT;
        DECLARE @request_mode VARCHAR(30);

        SELECT @pr_basic_sno = pr_basic_sno, @request_mode = request_mode
        FROM pr_basic_info
        WHERE pr_no = @pr_no AND is_active = 'Y';

        IF @pr_basic_sno IS NULL
        BEGIN
            RAISERROR('Purchase Request not found or inactive: %s', 16, 1, @pr_no);
            RETURN;
        END

        -- =============================================
        -- ✅ REJECT FLOW
        -- =============================================
        IF @action = 'reject'
        BEGIN
            -- Insert rejection into history with status = 'R'
            INSERT INTO pr_history_data (
                pr_basic_sno, pr_edit_data, workflow_types_id,
                approver_ecno, status, status_by,
                status_date, commends, is_active, pr_no
            )
            SELECT
                @pr_basic_sno,
                NULL,
                NULL,
                s.approver_ecno,
                'R',                -- R = Rejected
                @approved_by,
                GETDATE(),
                @comments,          -- Rejection reason stored as comments
                'Y',
                @pr_no
            FROM #approval_stages s
            WHERE s.approver_ecno = @approved_by;

            -- Update PR basic info: status = 'R', clear current approver
            UPDATE pr_basic_info
            SET status             = 'R',           -- R = Rejected
                current_approver_id = NULL           -- No further approval needed
            WHERE pr_basic_sno = @pr_basic_sno;

            DROP TABLE #approval_stages;

            -- Return rejection result
            SELECT
                'REJECTED'       AS result,
                @pr_no           AS pr_no,
                @approved_by     AS rejected_by,
                GETDATE()        AS rejected_on,
                @comments        AS rejection_reason,
                @request_mode    AS request_mode;

            RETURN;
        END

        -- =============================================
        -- ✅ APPROVE FLOW (original logic)
        -- =============================================

        -- Find next approver using LEAD()
        DECLARE @next_current_approver  VARCHAR(30);
        DECLARE @next_condition         VARCHAR(200);
        DECLARE @next_can_forward       CHAR(1);
        DECLARE @next_can_backward      CHAR(1);
        DECLARE @next_is_mandatory      CHAR(1);

        SELECT
            @next_current_approver = next_stage.approver_ecno,
            @next_condition        = next_stage.approver_condition,
            @next_can_forward      = next_stage.can_forward,
            @next_can_backward     = next_stage.can_backward,
            @next_is_mandatory     = next_stage.is_mandatory
        FROM (
            SELECT
                approver_ecno,
                LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #approval_stages
        ) current_stage
        LEFT JOIN #approval_stages next_stage
            ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        -- Insert approval history
        INSERT INTO pr_history_data (
            pr_basic_sno, pr_edit_data, workflow_types_id,
            approver_ecno, status, status_by,
            status_date, commends, is_active, pr_no
        )
        SELECT
            @pr_basic_sno,
            NULL,
            NULL,
            s.approver_ecno,
            'A',                -- A = Approved
            @approved_by,
            GETDATE(),
            @comments,
            'Y',
            @pr_no
        FROM #approval_stages s
        WHERE s.approver_ecno = @approved_by;

        DECLARE @stages_processed INT = @@ROWCOUNT;

        -- Update current approver (NULL = final stage reached)
        UPDATE pr_basic_info
        SET current_approver_id = @next_current_approver
        WHERE pr_basic_sno = @pr_basic_sno;

        -- If final stage, mark PR as fully Approved
        IF @next_current_approver IS NULL
        BEGIN
            UPDATE pr_basic_info
            SET status = 'A'
            WHERE pr_basic_sno = @pr_basic_sno;
        END

        DROP TABLE #approval_stages;

        -- Return approval result
        SELECT
            'SUCCESS'                                  AS result,
            @pr_no                                     AS pr_no,
            @approved_by                               AS approved_by,
            GETDATE()                                  AS approved_on,
            @stages_processed                          AS stages_processed,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @next_condition                            AS next_condition,
            @next_can_forward                          AS next_can_forward,
            @pr_basic_sno                               AS pr_basic_sno,
            @request_mode                               AS request_mode;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT
            'ERROR'           AS result,
            ERROR_NUMBER()    AS error_number,
            ERROR_MESSAGE()   AS error_message,
            ERROR_LINE()      AS error_line,
            ERROR_PROCEDURE() AS error_procedure;
    END CATCH

END;
GO
-- [F2. procedures] dbo.sp_approve_service_agreement
CREATE OR ALTER PROCEDURE dbo.sp_approve_service_agreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        DECLARE @agreement_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @comments         VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages  NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by      VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @agreement_sno IS NULL
        BEGIN
            RAISERROR('agreement_sno is required.', 16, 1);
            RETURN;
        END

        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno AND is_active = 'Y')
        BEGIN
            RAISERROR('Service agreement not found or inactive.', 16, 1);
            RETURN;
        END

        -- The version this decision applies to (sql/88): the highest version_no
        -- is the one currently in approval.
        DECLARE @cur_version INT = (SELECT MAX(version_no) FROM dbo.service_agreement_version WHERE agreement_sno = @agreement_sno);

        BEGIN TRANSACTION;

        CREATE TABLE #approval_stages (
            seq_no INT, approver_ecno VARCHAR(30), stage VARCHAR(100),
            required_approvals VARCHAR(10), is_mandatory CHAR(1), escalation_hours VARCHAR(10),
            approver_condition VARCHAR(200), next_approver_ecno VARCHAR(30),
            can_forward CHAR(1), can_backward CHAR(1), can_edit_data CHAR(1)
        );

        INSERT INTO #approval_stages (
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,
            escalation_hours, approver_condition, next_approver_ecno,
            can_forward, can_backward, can_edit_data
        )
        SELECT
            CAST(ojBase.[key] AS INT),
            JSON_VALUE(ojBase.[value], '$.approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.stage'),
            JSON_VALUE(ojBase.[value], '$.required_approvals'),
            JSON_VALUE(ojBase.[value], '$.is_mandatory'),
            JSON_VALUE(ojBase.[value], '$.escalation_hours'),
            JSON_VALUE(ojBase.[value], '$.approver_condition'),
            JSON_VALUE(ojBase.[value], '$.next_approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.can_forward'),
            JSON_VALUE(ojBase.[value], '$.can_backward'),
            JSON_VALUE(ojBase.[value], '$.can_edit_data')
        FROM OPENJSON(@approval_stages) AS ojBase;

        IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
            VALUES (@agreement_sno, 'REJECTED', @approved_by, @comments, @cur_version);

            UPDATE dbo.service_agreement SET status = 'R', current_approver_id = NULL WHERE agreement_sno = @agreement_sno;

            UPDATE dbo.service_agreement_version SET outcome = 'REJECTED', decided_at = GETDATE()
            WHERE agreement_sno = @agreement_sno AND version_no = @cur_version;

            DROP TABLE #approval_stages;
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @agreement_sno AS agreement_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
            RETURN;
        END

        DECLARE @next_current_approver VARCHAR(30);
        SELECT @next_current_approver = next_stage.approver_ecno
        FROM (
            SELECT approver_ecno, LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #approval_stages
        ) current_stage
        LEFT JOIN #approval_stages next_stage ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, 'APPROVED', @approved_by, @comments, @cur_version);

        UPDATE dbo.service_agreement SET current_approver_id = @next_current_approver WHERE agreement_sno = @agreement_sno;

        DECLARE @auto_po_result VARCHAR(200) = NULL, @auto_po_basic_sno INT = NULL, @auto_po_no VARCHAR(50) = NULL,
                @auto_pr_basic_sno INT = NULL, @auto_pr_no VARCHAR(20) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            -- ── Final stage: Fixed and Unfixed both go straight to Approved
            --    now — rate/qty stay whatever was entered at creation, no
            --    re-entry/finalization step here any more. ──────────────
            DECLARE @period_start DATE;
            SELECT @period_start = sa.period_start_date FROM dbo.service_agreement sa WHERE sa.agreement_sno = @agreement_sno;

            UPDATE dbo.service_agreement SET status = 'A' WHERE agreement_sno = @agreement_sno;

            UPDATE dbo.service_agreement_version SET outcome = 'APPROVED', decided_at = GETDATE()
            WHERE agreement_sno = @agreement_sno AND version_no = @cur_version;

            -- sql/88: only THIS term's billing dates count. A renewed agreement already
            -- has log rows from its previous term, which must not suppress the first
            -- cycle of the new one.
            IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno AND billing_period_start >= @period_start)
            BEGIN
                DECLARE @first_billing_period_start DATE = CASE WHEN CAST(GETDATE() AS DATE) < @period_start THEN @period_start ELSE CAST(GETDATE() AS DATE) END;
                DECLARE @firstCycleJson NVARCHAR(MAX) = (
                    SELECT @agreement_sno AS agreement_sno, @first_billing_period_start AS billing_period_start, @approved_by AS issued_by
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
                );

                BEGIN TRY
                    EXEC dbo.sp_nt_IssueRecurringServicePOCycle
                        @jsonInput = @firstCycleJson, @silent = 1,
                        @out_result = @auto_po_result OUTPUT, @out_po_basic_sno = @auto_po_basic_sno OUTPUT, @out_po_no = @auto_po_no OUTPUT,
                        @out_pr_basic_sno = @auto_pr_basic_sno OUTPUT, @out_pr_no = @auto_pr_no OUTPUT;
                END TRY
                BEGIN CATCH
                    -- Do not fail the approval itself — service_agreement_recurring_pr_log
                    -- already has a FAILED row for ops to find and retry via a fresh sweep call.
                    SET @auto_po_result = 'ERROR: ' + ERROR_MESSAGE();
                END CATCH
            END
        END

        DROP TABLE #approval_stages;
        COMMIT TRANSACTION;

        SELECT
            'SUCCESS' AS result, @agreement_sno AS agreement_sno, @approved_by AS approved_by, GETDATE() AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @auto_po_result AS auto_po_result, @auto_po_basic_sno AS auto_po_basic_sno, @auto_po_no AS auto_po_no,
            @auto_pr_basic_sno AS auto_pr_basic_sno, @auto_pr_no AS auto_pr_no;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL DROP TABLE #approval_stages;
        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_Get_Business_Details

  CREATE OR ALTER PROCEDURE [dbo].[sp_Get_Business_Details] 
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        SELECT  [business_types_id]
      ,[business_types_name]
      ,[Description]
      ,[LiabilityType]
      ,[IsActive]
      ,[CreatedAt]
  FROM [Non_trade_Dev].[dbo].[business_types]
WHERE IsActive=1
ORDER BY business_types_id;
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END
GO
-- [F2. procedures] dbo.sp_InserPurchaseRecords
  
  
CREATE OR ALTER PROCEDURE [dbo].[sp_InserPurchaseRecords]  
    @jsonInput   NVARCHAR(MAX)  
    --@po_no       VARCHAR(20) OUTPUT  
AS  
BEGIN  
    SET NOCOUNT ON;  
  
    BEGIN TRY  
        BEGIN TRANSACTION;  
  
        DECLARE  
            @com_sno             INT,  
            @div_sno             INT,  
            @brn_sno             INT,  
            @dept_sno            INT,  
            --@vendor_sno          INT,  
            @pr_basic_sno        INT,  
            --@budget_sno          INT,  
            --@budget_code         VARCHAR(50),  
            @po_date             DATE,  
            @required_date       DATE,  
            @priority_sno        INT,  
            @purpose             NVARCHAR(500),  
            --@terms_conditions    NVARCHAR(MAX),  
            --@delivery_address    NVARCHAR(500),  
            @split_pr_no         VARCHAR(20),  
            @created_by          VARCHAR(20),  
            @current_year        VARCHAR(10),  
            @po_prefix           VARCHAR(20),  
            @sequence_number     INT,  
            @po_basic_sno        INT,  
            @workflow_id         INT,  
            @workflow_types_id   INT,  
            @first_approver      VARCHAR(20),  
            @items_inserted      INT;  
  
        -- ── Generate PO Number ─────────────────────────────────────────────  
        SET @current_year = dbo.fn_GetFinancialYear(GETDATE());  
        SET @po_prefix    = 'PO' + @current_year;  -- e.g. 'PO26-27'  
  
        --SELECT @sequence_number = ISNULL(MAX(  
        --    CASE  
        --        WHEN po_no LIKE @po_prefix + '%'  
        --        THEN TRY_CAST(  
        --                 SUBSTRING(po_no, LEN(@po_prefix) + 1, LEN(po_no))  
        --             AS INT)  
        --        ELSE 0  
        --    END  
        --), 0) + 1  
        --FROM [Non_trade_Dev].[dbo].[po_request_info] WITH (UPDLOCK, HOLDLOCK)  
        --WHERE po_no LIKE @po_prefix + '%';  
  
        --SET @po_no = @po_prefix + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);  
        -- e.g. PO26-270001  
  
        -- ── Parse JSON ─────────────────────────────────────────────────────  
        SELECT  
            @com_sno          = JSON_VALUE(@jsonInput, '$.com_sno'),  
            @div_sno          = JSON_VALUE(@jsonInput, '$.div_sno'),  
            @brn_sno          = JSON_VALUE(@jsonInput, '$.brn_sno'),  
            @dept_sno         = JSON_VALUE(@jsonInput, '$.dept_sno'),  
            --@vendor_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.vendor_sno'),  
            @pr_basic_sno     = JSON_VALUE(@jsonInput, '$.pr_basic_sno'),  
            --@budget_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.budget_sno'),  
            --@budget_code      = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.budget_code'),   ''),  
            @po_date          = JSON_VALUE(@jsonInput, '$.po_date'),  
            @required_date    = JSON_VALUE(@jsonInput, '$.required_date'),  
            @priority_sno     = JSON_VALUE(@jsonInput, '$.priority_sno'),  
            @purpose          = NULLIF(JSON_VALUE(@jsonInput, '$.purpose'),       ''),  
            --@terms_conditions = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.terms_conditions'), ''),  
            --@delivery_address = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.delivery_address'), ''),  
            @split_pr_no      = NULLIF(JSON_VALUE(@jsonInput, '$.split_pr_no'),   ''),  
            @created_by       = JSON_VALUE(@jsonInput, '$.created_by');  
  
        -- ── Field Validations ──────────────────────────────────────────────  
        --IF @com_sno IS NULL  
        --    THROW 50010, 'Company (com_sno) is required.', 1;  
  
        --IF @div_sno IS NULL  
        --    THROW 50011, 'Division (div_sno) is required.', 1;  
  
        --IF @brn_sno IS NULL  
        --    THROW 50001, 'Branch (brn_sno) is required.', 1;  
  
        --IF @dept_sno IS NULL  
        --    THROW 50012, 'Department (dept_sno) is required.', 1;  
  
        --IF @vendor_sno IS NULL  
        --    THROW 50013, 'Vendor (vendor_sno) is required.', 1;  
  
        --IF @po_date IS NULL  
        --    THROW 50002, 'PO date (po_date) is required.', 1;  
  
        --IF @required_date IS NULL  
        --    THROW 50003, 'Required date is required.', 1;  
  
        --IF @created_by IS NULL  
        --    THROW 50004, 'Created by is required.', 1;  
  
        -- Validate items array  
        IF NOT EXISTS (  
            SELECT 1  
            FROM OPENJSON(@jsonInput, '$.items')  
            WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL  
              AND JSON_VALUE(value, '$.prod_sno') != ''  
              AND JSON_VALUE(value, '$.unit')      IS NOT NULL  
              AND JSON_VALUE(value, '$.unit')      != ''  
        )  
            THROW 50005, 'At least one valid item with prod_sno and unit is required.', 1;  
  
        -- ── Resolve Workflow ───────────────────────────────────────────────  
        SELECT  
            @workflow_id       = wt.workflow_id,  
            @workflow_types_id = wt.workflow_types_id  
        FROM workflow_types wt  
        INNER JOIN approval_workflow_master awm  
            ON awm.workflow_id = wt.workflow_id  
        WHERE wt.brn_sno      = @brn_sno  
          AND wt.dept_sno     = @dept_sno  
          AND wt.com_sno      = @com_sno  
          AND wt.div_sno      = @div_sno  
          AND awm.entity_type = 'PurchaseOrder';  
  
        --IF @workflow_types_id IS NULL  
        --    THROW 50006, 'No workflow configuration found for this branch and department.', 1;  
        -- Resolve first approver  
        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')  
        FROM vw_workflow_stages AS ws  
        CROSS APPLY OPENJSON(ws.stages_json) AS s  
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2  
        WHERE ws.workflow_types_id = @workflow_types_id  
          AND s.[key]  = '0'  
          AND s2.[key] = '0';  
  
        --IF @first_approver IS NULL  
        --    THROW 50007, 'No approver found for the first stage of the workflow.', 1;  
  
        -- ── Insert PO Basic Info ───────────────────────────────────────────  
        INSERT INTO [Non_trade_Dev].[dbo].[po_request_info]  
        (  
                                [brn_sno],  
            [dept_sno],           [com_sno],              [div_sno],  
               [pr_basic_sno],  
            [po_date],            [required_date],        [priority_sno],  
            [purpose],             
            [is_active],          [workflow_types_id],    [current_approver_id],  
            [status],             [split_pr_no]            
              
        )  
        VALUES  
        (  
                                  @brn_sno,  
            @dept_sno,            @com_sno,               @div_sno,  
             @pr_basic_sno,  
            @po_date,             @required_date,         @priority_sno,  
            @purpose,              
            'Y',                  @workflow_types_id,     @first_approver,  
            'P',                  @split_pr_no             
            
        );  
  
        SET @po_basic_sno = SCOPE_IDENTITY();  
  
        -- ── Insert PO Item Details ─────────────────────────────────────────  
        INSERT INTO [Non_trade_Dev].[dbo].[po_item_details]  
        (  
            [po_basic_sno],       [pr_item_sno],          [prod_sno],  
            [prod_name],                   [specification],  
            [qty],                [unit],                 [unit_name],  
            [agreed_unit_price],  [total_cost],           [discount_pct],  
            [tax_pct],            [net_cost],             [remarks],  
            [split_pr_no],        [is_active],            [created_by],  
            [created_date]  
        )  
        SELECT  
            @po_basic_sno,  
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.pr_item_sno'),        '') AS INT),  
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.prod_sno'),           '') AS INT),  
            NULLIF(JSON_VALUE(value, '$.prod_name'),                   ''),  
             
            NULLIF(JSON_VALUE(value, '$.specification'),               ''),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.qty'),                  ''), 0),  
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.unit'),               '') AS INT),  
            NULLIF(JSON_VALUE(value, '$.unit_name'),                   ''),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.agreed_unit_price'),    ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.total_cost'),           ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.discount_pct'),         ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.tax_pct'),              ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.net_cost'),             ''), 0),  
            NULLIF(JSON_VALUE(value, '$.remarks'),                     ''),  
            @split_pr_no,  
            'Y',  
            @created_by,  
            GETDATE()  
        FROM OPENJSON(@jsonInput, '$.items')  
        WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL  
          AND JSON_VALUE(value, '$.prod_sno') != ''  
          AND JSON_VALUE(value, '$.unit')      IS NOT NULL  
          AND JSON_VALUE(value, '$.unit')      != '';  
  
        SET @items_inserted = @@ROWCOUNT;  
  
        IF @items_inserted = 0  
            THROW 50008, 'No items were inserted. Check that items array is valid and non-empty.', 1;  
  
        COMMIT TRANSACTION;  
  
        SELECT  
            --'PO Data Saved Successfully. PO No: ' + @pr_basic_sno AS Message,  
            --@jsonInput AS 'jsonInput',  
            'Success'                                       AS Status,  
            @po_basic_sno                                   AS POBasicSno,  
            @items_inserted                                 AS ItemsInserted;  
  
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
  
        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();  
        DECLARE @ErrorState    INT            = ERROR_STATE();  
  
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);  
    END CATCH  
END;
GO
-- [F2. procedures] dbo.sp_InsertKYCData
CREATE OR ALTER PROCEDURE [dbo].[sp_InsertKYCData]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE
            @kyc_basic_info_sno INT,
            @company_name       NVARCHAR(255),
            @contact_name       NVARCHAR(100),
            @email              NVARCHAR(100),
            @mobile_number      VARCHAR(15),
            @business_type      NVARCHAR(50),
            @is_gst_avail       CHAR(1),
            @gst_no             VARCHAR(20),
            @is_msme_avail      CHAR(1),
            @msme_no            VARCHAR(20),
            @pan_no             VARCHAR(20),
            @created_by         VARCHAR(50),
            @addresses          NVARCHAR(MAX),
            @bankDetails        NVARCHAR(MAX),
            @contacts           NVARCHAR(MAX),
            @document           NVARCHAR(MAX),
            @approver_ecno      VARCHAR(20),
            @supplier_cat_code  VARCHAR(20),
            @legal_name         VARCHAR(100),
            @trade_name         VARCHAR(100),
            @txp_type           VARCHAR(10),
            @gst_status         VARCHAR(1),
            @gst_blk_status     VARCHAR(10),
            @date_of_reg        date,
            @workflow_types_id  INT;
        -- Extract scalar values from JSON
        SELECT
            @company_name  = JSON_VALUE(@jsonInput, '$.company_name'),
            @contact_name  = JSON_VALUE(@jsonInput, '$.contact_name'),
            @email         = JSON_VALUE(@jsonInput, '$.email'),
            @mobile_number = JSON_VALUE(@jsonInput, '$.mobile_number'),
            @business_type = JSON_VALUE(@jsonInput, '$.business_type'),
            @is_gst_avail  = CASE WHEN JSON_VALUE(@jsonInput, '$.is_gst_avail')  = 'true' THEN 'Y' ELSE 'N' END,
            @gst_no        = JSON_VALUE(@jsonInput, '$.gst_no'),
            @is_msme_avail = CASE WHEN JSON_VALUE(@jsonInput, '$.is_msme_avail') = 'true' THEN 'Y' ELSE 'N' END,
            @msme_no       = JSON_VALUE(@jsonInput, '$.msme_no'),
            @pan_no        = JSON_VALUE(@jsonInput, '$.pan_no'),
            @created_by    = ISNULL(JSON_VALUE(@jsonInput, '$.created_by'), ''),
            @supplier_cat_code=JSON_VALUE(@jsonInput, '$.supplier_cat_code'),
            @legal_name=JSON_VALUE(@jsonInput, '$.legal_name'),
            @trade_name= JSON_VALUE(@jsonInput, '$.trade_name'),
            @txp_type=  JSON_VALUE(@jsonInput, '$.txp_type'),
            @gst_status  =  JSON_VALUE(@jsonInput, '$.gst_status'),
            @gst_blk_status=  JSON_VALUE(@jsonInput, '$.gst_blk_status'),
            @date_of_reg  =JSON_VALUE(@jsonInput, '$.date_of_reg');



        SET @workflow_types_id = 32; -- Non_Trade KYC workflow (Dev uses 5); environment-specific, do not sync from Dev
      SELECT @approver_ecno = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        --IF @approver_ecno IS NULL
        --    THROW 50007, 'No approver found for the first stage of the workflow.', 1;


        SET @addresses   = JSON_QUERY(@jsonInput, '$.addresses');
        SET @bankDetails = JSON_QUERY(@jsonInput, '$.bankDetails');
        SET @contacts    = JSON_QUERY(@jsonInput, '$.contacts');
        SET @document    = JSON_VALUE(@jsonInput, '$.document');

        -- 1. Insert into kyc_basic_info
        INSERT INTO kyc_basic_info (
            company_name, contact_person, email, mobile_number,
            business_type, is_gst_avail, gst_no, is_msme_avail,
            msme_no, pan_no, created_by, created_date, is_active, status ,workflow_types_id ,approver_ecno ,supplier_cat_code,
            legal_name,trade_name,txp_type, gst_status,gst_blk_status ,date_of_reg
        )
        VALUES (
            @company_name, @contact_name, @email, @mobile_number,
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail,
            @msme_no, @pan_no, @created_by, GETDATE(), 'Y', 'P' ,@workflow_types_id ,@approver_ecno ,@supplier_cat_code
            ,@legal_name,@trade_name,@txp_type,@gst_status,@gst_blk_status,@date_of_reg
        );

        SET @kyc_basic_info_sno = SCOPE_IDENTITY();

        -- 2. Insert into kyc_address_info
        IF ISJSON(@addresses) = 1
        BEGIN
            INSERT INTO kyc_address_info (
                kyc_basic_info_sno, address_type, door_no, street, area, city,
                taluk, state, state_code, pincode, location_link, is_primary,
                created_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'PRIMARY' ELSE 'SECONDARY' END,
                JSON_VALUE(value, '$.door_no'),
                JSON_VALUE(value, '$.street'),
                JSON_VALUE(value, '$.area'),
                JSON_VALUE(value, '$.city'),
                JSON_VALUE(value, '$.taluk'),
                JSON_VALUE(value, '$.state'),
                TRY_CONVERT(INT, JSON_VALUE(value, '$.state_code')),
                JSON_VALUE(value, '$.pincode'),
                NULLIF(JSON_VALUE(value, '$.location_link'), ''),
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'Y' ELSE 'N' END,
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@addresses);
        END

        -- 3. Insert into kyc_bank_info
        IF ISJSON(@bankDetails) = 1
        BEGIN
            INSERT INTO kyc_bank_info (
                kyc_basic_info_sno, ac_holder_name, ac_number, ac_type, ifsc,
                bank_name, bank_branch_name, bank_address, is_primary,
                created_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                JSON_VALUE(value, '$.ac_holder_name'),
                JSON_VALUE(value, '$.ac_number'),
                JSON_VALUE(value, '$.ac_type'),
                JSON_VALUE(value, '$.ifsc'),
                JSON_VALUE(value, '$.bank_name'),
                JSON_VALUE(value, '$.bank_branch_name'),
                JSON_VALUE(value, '$.bank_address'),
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'Y' ELSE 'N' END,
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@bankDetails);
        END

        -- 4. Insert into kyc_contact_info
        IF ISJSON(@contacts) = 1
        BEGIN
            INSERT INTO kyc_contact_info (
                kyc_basic_info_sno, contact_type, contact_name, contact_position,
                contact_mobile, contact_email, created_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'PRIMARY' ELSE 'SECONDARY' END,
                JSON_VALUE(value, '$.ownername'),
                JSON_VALUE(value, '$.ownerposition'),
                JSON_VALUE(value, '$.ownermobile'),
                JSON_VALUE(value, '$.owneremail'),
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@contacts);
        END

        -- 5. Insert into kyc_document_info
        IF ISJSON(@document) = 1
        BEGIN
            INSERT INTO kyc_document_info (
                kyc_basic_info_sno, document_type, document_name,
                document_path, file_size, uploaded_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                JSON_VALUE(value, '$.documentType'),
                JSON_VALUE(value, '$.filename'),
                JSON_VALUE(value, '$.url'),
                JSON_VALUE(value, '$.size'),
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@document);
        END

        COMMIT TRANSACTION;
                  SELECT
            @kyc_basic_info_sno AS kyc_basic_info_sno,
            'KYC Data Saved Successfully' AS message,
            'Success' AS Status;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();
        DECLARE @ErrorState    INT            = ERROR_STATE();

        SELECT @ErrorMessage AS errorMessage, 'Error' AS Status;
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_InsertPurchaseRecords
CREATE OR ALTER PROCEDURE [dbo].[sp_InsertPurchaseRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE
            @com_sno           INT,
            @div_sno           INT,
            @brn_sno           INT,
            @dept_sno          INT,
            @pr_basic_sno      INT,
            @po_date           DATE,
            @required_date     DATE,
            @priority_sno      INT,
            @purpose           NVARCHAR(500),
            @split_pr_no       VARCHAR(20),
            @created_by        VARCHAR(20),
            @po_basic_sno      INT,
            @workflow_types_id INT,
            @first_approver    VARCHAR(20),
            @items_inserted    INT;

        -- ── Parse JSON ─────────────────────────────────────────────────────
        SELECT
            @brn_sno       = JSON_VALUE(@jsonInput, '$.brn_sno'),
            @dept_sno      = JSON_VALUE(@jsonInput, '$.dept_sno'),
            @pr_basic_sno  = JSON_VALUE(@jsonInput, '$.pr_basic_sno'),
            @created_by    = JSON_VALUE(@jsonInput, '$.created_by'),
            @com_sno       = JSON_VALUE(@jsonInput, '$.com_sno'),
            @div_sno       = JSON_VALUE(@jsonInput, '$.div_sno'),
            @po_date       = NULLIF(JSON_VALUE(@jsonInput, '$.po_date'),       ''),
            @required_date = NULLIF(JSON_VALUE(@jsonInput, '$.required_date'), ''),
            @priority_sno  = JSON_VALUE(@jsonInput, '$.priority_sno'),
            @purpose       = NULLIF(JSON_VALUE(@jsonInput, '$.purpose'),       ''),
            @split_pr_no   = NULLIF(JSON_VALUE(@jsonInput, '$.split_pr_no'),   '');

            SELECT @brn_sno,@dept_sno,@pr_basic_sno,@created_by,@com_sno,@div_sno
        -- ── Field Validations ──────────────────────────────────────────────
        IF @brn_sno IS NULL
            THROW 50001, 'Branch (brn_sno) is required.', 1;

        IF @dept_sno IS NULL
            THROW 50012, 'Department (dept_sno) is required.', 1;

        IF @pr_basic_sno IS NULL
            THROW 50014, 'PR Basic SNO (pr_basic_sno) is required.', 1;

        IF @created_by IS NULL
            THROW 50004, 'Created by is required.', 1;

        IF NOT EXISTS (
            SELECT 1
            FROM OPENJSON(@jsonInput, '$.items')
            WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
              AND JSON_VALUE(value, '$.prod_sno') != ''
              AND JSON_VALUE(value, '$.unit')      IS NOT NULL
              AND JSON_VALUE(value, '$.unit')      != ''
        )
            THROW 50005, 'At least one valid item with prod_sno and unit is required.', 1;

        -- ── Resolve Workflow ───────────────────────────────────────────────
        SELECT TOP 1
            @workflow_types_id = wt.workflow_types_id
        FROM workflow_types wt
        INNER JOIN approval_workflow_master awm
            ON awm.workflow_id = wt.workflow_id
        WHERE wt.brn_sno      = @brn_sno
          AND wt.dept_sno     = @dept_sno
          AND (wt.com_sno     = @com_sno OR @com_sno IS NULL)
          AND (wt.div_sno     = @div_sno OR @div_sno IS NULL)
          AND awm.entity_type = 'PurchaseOrder'
        ORDER BY wt.workflow_types_id;

        --IF @workflow_types_id IS NULL
        --    THROW 50009, 'No approval workflow found for this branch/department.', 1;

        SELECT TOP 1
            @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        --IF @first_approver IS NULL
        --    THROW 50010, 'No first approver found for the resolved workflow.', 1;

        -- ── Insert PO Basic Info ───────────────────────────────────────────
        INSERT INTO [Non_trade_Dev].[dbo].[po_request_info]
        (
            [brn_sno],              [dept_sno],             [com_sno],
            [div_sno],              [pr_basic_sno],         [po_date],
            [required_date],        [priority_sno],         [purpose],
            [is_active],            [workflow_types_id],    [current_approver_id],
            [status],               [split_pr_no]       
        )
        VALUES
        (
            @brn_sno,               @dept_sno,              @com_sno,
            @div_sno,               @pr_basic_sno,          @po_date,
            @required_date,         @priority_sno,          @purpose,
            'Y',                    @workflow_types_id,     @first_approver,
            'P',                    @split_pr_no         
        );

        SET @po_basic_sno = SCOPE_IDENTITY();

        -- ── Insert PO Item Details ─────────────────────────────────────────
        INSERT INTO [Non_trade_Dev].[dbo].[po_item_details]
        (
            [po_basic_sno],         [pr_item_sno],          [prod_sno],
            [prod_name],            [specification],        [qty],
            [unit],                 [unit_name],            [agreed_unit_price],
            [total_cost],           [discount_pct],         [tax_pct],
            [net_cost],             [remarks],              [split_pr_no],
            [is_active]
        )
        SELECT
            @po_basic_sno,
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.pr_item_sno'),              '') AS INT),
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.prod_sno'),                 '') AS INT),
            NULLIF(JSON_VALUE(value, '$.prod_name'),                         ''),
            NULLIF(JSON_VALUE(value, '$.specification'),                     ''),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.qty'),              '') AS DECIMAL(18,4)), 0),
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.unit'),                    '') AS INT),
            NULLIF(JSON_VALUE(value, '$.unit_name'),                         ''),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.agreed_unit_price'),'') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.total_cost'),       '') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.discount_pct'),     '') AS DECIMAL(5,2)),  0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.tax_pct'),          '') AS DECIMAL(5,2)),  0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.net_cost'),         '') AS DECIMAL(18,4)), 0),
            NULLIF(JSON_VALUE(value, '$.remarks'),                           ''),
            @split_pr_no,
            'Y'
        FROM OPENJSON(@jsonInput, '$.items')
        WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
          AND JSON_VALUE(value, '$.prod_sno') != ''
          AND JSON_VALUE(value, '$.unit')      IS NOT NULL
          AND JSON_VALUE(value, '$.unit')      != '';

        SET @items_inserted = @@ROWCOUNT;

        IF @items_inserted = 0
            THROW 50008, 'No items were inserted. Check that items array is valid and non-empty.', 1;

        COMMIT TRANSACTION;

        SELECT
            'Success'       AS Status,
            @po_basic_sno   AS POBasicSno,
            @items_inserted AS ItemsInserted;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();
        DECLARE @ErrorState    INT            = ERROR_STATE();

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_AddLoanPrincipalTxn  (new)
-- @jsonInput: { agreement_sno, txn_type: DRAWDOWN|REPAYMENT, txn_date, amount, remarks?, entered_by }
-- A movement takes effect FROM its date. The outstanding principal must stay
-- between zero and the sanctioned amount (or the cash-credit drawing power) on
-- every date from then on — checked after the insert, rolled back if broken.
CREATE OR ALTER PROCEDURE dbo.sp_nt_AddLoanPrincipalTxn
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @agreement_sno INT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @txn_type VARCHAR(10)   = UPPER(LTRIM(RTRIM(ISNULL(JSON_VALUE(@jsonInput, '$.txn_type'), '')))),
                @txn_date DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.txn_date') AS DATE),
                @amount DECIMAL(18,2)   = TRY_CAST(JSON_VALUE(@jsonInput, '$.amount') AS DECIMAL(18,2)),
                @remarks NVARCHAR(300)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), ''),
                @entered_by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.entered_by');

        IF @agreement_sno IS NULL OR @txn_date IS NULL OR @entered_by IS NULL
            THROW 58460, 'agreement_sno, txn_date and entered_by are required.', 1;
        IF @txn_type NOT IN ('DRAWDOWN', 'REPAYMENT')
            THROW 58461, 'txn_type must be DRAWDOWN or REPAYMENT.', 1;
        IF @amount IS NULL OR @amount <= 0
            THROW 58462, 'The amount must be greater than zero.', 1;

        BEGIN TRANSACTION;

        DECLARE @status CHAR(1), @period_end DATE, @disb DATE, @cap DECIMAL(18,2);
        SELECT @status = sa.status, @period_end = sa.period_end_date, @disb = s.disbursement_date,
               @cap = CASE WHEN s.facility_type = 'CASH_CREDIT' THEN ISNULL(s.drawing_power, s.sanctioned_amount) ELSE s.sanctioned_amount END
        FROM dbo.service_agreement sa WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.service_agreement_statutory s ON s.agreement_sno = sa.agreement_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @status IS NULL THROW 58400, 'Loan facility not found for this agreement.', 1;
        IF @status <> 'A' THROW 58463, 'Principal movements can only be entered on an approved loan agreement.', 1;

        DECLARE @msg NVARCHAR(400), @locked DATE = dbo.fn_LoanLockedThrough(@agreement_sno);
        IF @txn_date < @disb
            THROW 58464, 'The date cannot be before the disbursement date.', 1;
        IF @txn_date < @locked
        BEGIN
            SET @msg = N'Interest is already billed (or a voucher is awaiting approval) up to ' + CONVERT(NVARCHAR(11), @locked, 106) + N', so a principal movement cannot be dated before that.';
            THROW 58465, @msg, 1;
        END
        IF @txn_date > @period_end
            THROW 58466, 'The date cannot be after the end of the loan term.', 1;

        INSERT INTO dbo.loan_principal_txn (agreement_sno, txn_date, txn_type, amount, remarks, created_by)
        VALUES (@agreement_sno, @txn_date, @txn_type, @amount, @remarks, @entered_by);
        DECLARE @txn_sno INT = SCOPE_IDENTITY();

        IF EXISTS (
            SELECT 1 FROM (
                SELECT @txn_date AS d
                UNION SELECT txn_date FROM dbo.loan_principal_txn WHERE agreement_sno = @agreement_sno AND is_active = 'Y' AND txn_date >= @txn_date
            ) x
            WHERE dbo.fn_LoanPrincipalAt(@agreement_sno, x.d) < 0 OR dbo.fn_LoanPrincipalAt(@agreement_sno, x.d) > @cap
        )
        BEGIN
            SET @msg = CASE WHEN @txn_type = 'REPAYMENT'
                            THEN N'That repayment is more than the principal outstanding on that date.'
                            ELSE N'That drawdown would take the outstanding principal above the ' + CONVERT(NVARCHAR(30), @cap) + N' limit.' END;
            THROW 58467, @msg, 1;
        END

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, @txn_sno AS txn_sno, dbo.fn_LoanPrincipalAt(@agreement_sno, @txn_date) AS principal_on_date;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_AddLoanRatePeriod  (new)
-- @jsonInput: { agreement_sno, effective_from, benchmark_rate_pct (floating) | interest_rate_pct (fixed), remarks?, entered_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_AddLoanRatePeriod
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @agreement_sno INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @effective_from DATE        = TRY_CAST(JSON_VALUE(@jsonInput, '$.effective_from') AS DATE),
                @benchmark DECIMAL(7,3)     = TRY_CAST(JSON_VALUE(@jsonInput, '$.benchmark_rate_pct') AS DECIMAL(7,3)),
                @fixed_rate DECIMAL(7,3)    = TRY_CAST(JSON_VALUE(@jsonInput, '$.interest_rate_pct') AS DECIMAL(7,3)),
                @remarks NVARCHAR(300)      = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), ''),
                @entered_by VARCHAR(30)     = JSON_VALUE(@jsonInput, '$.entered_by');

        IF @agreement_sno IS NULL OR @effective_from IS NULL OR @entered_by IS NULL
            THROW 58450, 'agreement_sno, effective_from and entered_by are required.', 1;

        BEGIN TRANSACTION;

        DECLARE @status CHAR(1), @period_end DATE, @disb DATE, @rate_type VARCHAR(10), @spread DECIMAL(7,3);
        SELECT @status = sa.status, @period_end = sa.period_end_date, @disb = s.disbursement_date,
               @rate_type = s.rate_type, @spread = s.spread_pct
        FROM dbo.service_agreement sa WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.service_agreement_statutory s ON s.agreement_sno = sa.agreement_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @status IS NULL THROW 58400, 'Loan facility not found for this agreement.', 1;
        IF @status <> 'A' THROW 58451, 'Rates can only be entered on an approved loan agreement.', 1;

        DECLARE @msg NVARCHAR(400), @locked DATE = dbo.fn_LoanLockedThrough(@agreement_sno);
        IF @effective_from <= @disb
        BEGIN
            SET @msg = N'The rate must take effect after the disbursement date (' + CONVERT(NVARCHAR(11), @disb, 106) + N') - the sanctioned rate already covers the start.';
            THROW 58452, @msg, 1;
        END
        IF @effective_from < @locked
        BEGIN
            SET @msg = N'Interest is already billed (or a voucher is awaiting approval) up to ' + CONVERT(NVARCHAR(11), @locked, 106) + N', so a rate cannot take effect before that date.';
            THROW 58453, @msg, 1;
        END
        IF @effective_from > @period_end
            THROW 58454, 'The rate cannot take effect after the end of the loan term.', 1;
        IF EXISTS (SELECT 1 FROM dbo.loan_rate_period WHERE agreement_sno = @agreement_sno AND effective_from = @effective_from)
            THROW 58455, 'A rate is already entered from that date - delete it first if it needs to change.', 1;

        DECLARE @effective DECIMAL(7,3);
        IF @rate_type = 'FLOATING'
        BEGIN
            IF @benchmark IS NULL OR @benchmark < 0 THROW 58456, 'Enter the benchmark (repo) rate in force from that date.', 1;
            SET @effective = @benchmark + ISNULL(@spread, 0);
        END
        ELSE
        BEGIN
            IF @fixed_rate IS NULL THROW 58457, 'Enter the new interest rate.', 1;
            SET @effective = @fixed_rate;
            SET @benchmark = NULL;
            SET @spread = NULL;
        END
        IF @effective < 0 OR @effective > 100
            THROW 58458, 'The effective interest rate must be between 0 and 100 percent.', 1;

        INSERT INTO dbo.loan_rate_period (agreement_sno, effective_from, benchmark_rate_pct, spread_pct, interest_rate_pct, remarks, created_by)
        VALUES (@agreement_sno, @effective_from, @benchmark, CASE WHEN @rate_type = 'FLOATING' THEN @spread END, @effective, @remarks, @entered_by);

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, SCOPE_IDENTITY() AS rate_period_sno, @effective AS interest_rate_pct;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_AdjustStock
-- ── sp_nt_AdjustStock — IN creates a batch (GRN-sourced only); OUT/shortfall ──
-- ── consumes FIFO across nt_stock_batches ─────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_AdjustStock
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @movement_type VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.movement_type');
    DECLARE @quantity      DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.quantity');
    DECLARE @reference_no  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.reference_no');
    DECLARE @to_warehouse  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.to_warehouse');
    DECLARE @reason        VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.reason');
    DECLARE @created_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    -- Optional — present only for a GRN-receipt IN, to create its batch.
    DECLARE @grn_basic_sno INT           = JSON_VALUE(@jsonInput, '$.grn_basic_sno');
    DECLARE @grn_item_sno  INT           = JSON_VALUE(@jsonInput, '$.grn_item_sno');
    DECLARE @grn_no        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.grn_no');
    DECLARE @received_date DATE          = JSON_VALUE(@jsonInput, '$.received_date');
    DECLARE @unit_cost     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.unit_cost');

    IF @item_sno IS NULL OR @movement_type IS NULL
    BEGIN
        RAISERROR('item_sno and movement_type are required.', 16, 1);
        RETURN;
    END

    DECLARE @current_stock DECIMAL(18,2),
            @warehouse     VARCHAR(100),
            @item_code     VARCHAR(50),
            @item_name     VARCHAR(255),
            @uom           VARCHAR(20);

    DECLARE @com_sno  INT, @div_sno  INT, @brn_sno  INT, @dept_sno INT;

    SELECT
        @current_stock = current_stock,
        @warehouse     = warehouse,
        @item_code     = item_code,
        @item_name     = item_name,
        @uom           = uom,
        @com_sno       = com_sno,
        @div_sno       = div_sno,
        @brn_sno       = brn_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;

    IF @current_stock IS NULL
    BEGIN
        RAISERROR('Inventory item not found.', 16, 1);
        RETURN;
    END

    IF @movement_type NOT IN ('IN', 'OUT', 'ADJUSTMENT', 'TRANSFER')
    BEGIN
        RAISERROR('Invalid movement_type ''%s''.', 16, 1, @movement_type);
        RETURN;
    END

    IF @movement_type = 'OUT' AND ISNULL(@quantity, 0) > @current_stock
    BEGIN
        RAISERROR('Insufficient stock for this item.', 16, 1);
        RETURN;
    END

    IF @movement_type = 'TRANSFER' AND @to_warehouse IS NULL
    BEGIN
        RAISERROR('to_warehouse is required for TRANSFER.', 16, 1);
        RETURN;
    END

    DECLARE @new_stock     DECIMAL(18,2) = @current_stock;
    DECLARE @new_warehouse VARCHAR(100)  = @warehouse;
    DECLARE @movements TABLE (movement_sno INT);
    DECLARE @movement_sno INT;

    IF @movement_type = 'IN'
        SET @new_stock = @current_stock + ISNULL(@quantity, 0);
    ELSE IF @movement_type = 'OUT'
        SET @new_stock = @current_stock - ISNULL(@quantity, 0);
    ELSE IF @movement_type = 'ADJUSTMENT'
        SET @new_stock = ISNULL(@quantity, @current_stock);
    ELSE IF @movement_type = 'TRANSFER'
        SET @new_warehouse = @to_warehouse;

    UPDATE dbo.nt_inventory_items
    SET current_stock = @new_stock,
        warehouse      = @new_warehouse,
        updated_by     = @created_by,
        updated_at     = GETDATE()
    WHERE item_sno = @item_sno;

    IF @movement_type = 'OUT'
    BEGIN
        -- FIFO: draw from the oldest non-exhausted batches first.
        DECLARE @remaining_to_issue DECIMAL(18,2) = ISNULL(@quantity, 0);
        DECLARE @b_batch_sno INT, @b_available DECIMAL(18,2), @draw_qty DECIMAL(18,2);

        DECLARE batch_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT batch_sno, remaining_qty
            FROM dbo.nt_stock_batches WITH (UPDLOCK, HOLDLOCK)
            WHERE item_sno = @item_sno AND remaining_qty > 0
            ORDER BY received_date ASC, batch_sno ASC;

        OPEN batch_cur;
        FETCH NEXT FROM batch_cur INTO @b_batch_sno, @b_available;
        WHILE @@FETCH_STATUS = 0 AND @remaining_to_issue > 0
        BEGIN
            SET @draw_qty = CASE WHEN @b_available <= @remaining_to_issue THEN @b_available ELSE @remaining_to_issue END;

            UPDATE dbo.nt_stock_batches
            SET remaining_qty = remaining_qty - @draw_qty,
                status = CASE WHEN remaining_qty - @draw_qty <= 0 THEN 'Exhausted' ELSE 'Active' END
            WHERE batch_sno = @b_batch_sno;

            INSERT INTO dbo.nt_stock_movements (
                item_sno, item_code, item_name, movement_type, quantity,
                balance_after, uom, reference_no, warehouse, reason,
                com_sno, div_sno, brn_sno, dept_sno, created_by, created_at, batch_sno
            )
            VALUES (
                @item_sno, @item_code, @item_name, 'OUT', @draw_qty,
                @new_stock, @uom, @reference_no, @new_warehouse, @reason,
                @com_sno, @div_sno, @brn_sno, @dept_sno, @created_by, GETDATE(), @b_batch_sno
            );
            INSERT INTO @movements (movement_sno) VALUES (SCOPE_IDENTITY());

            SET @remaining_to_issue -= @draw_qty;
            FETCH NEXT FROM batch_cur INTO @b_batch_sno, @b_available;
        END
        CLOSE batch_cur;
        DEALLOCATE batch_cur;

        -- Shortfall beyond tracked batches (pre-batch legacy stock, or a
        -- prior non-GRN IN) — one unbatched row so the ledger still adds up.
        IF @remaining_to_issue > 0
        BEGIN
            INSERT INTO dbo.nt_stock_movements (
                item_sno, item_code, item_name, movement_type, quantity,
                balance_after, uom, reference_no, warehouse, reason,
                com_sno, div_sno, brn_sno, dept_sno, created_by, created_at, batch_sno
            )
            VALUES (
                @item_sno, @item_code, @item_name, 'OUT', @remaining_to_issue,
                @new_stock, @uom, @reference_no, @new_warehouse, @reason,
                @com_sno, @div_sno, @brn_sno, @dept_sno, @created_by, GETDATE(), NULL
            );
            INSERT INTO @movements (movement_sno) VALUES (SCOPE_IDENTITY());
        END
    END
    ELSE
    BEGIN
        INSERT INTO dbo.nt_stock_movements (
            item_sno, item_code, item_name, movement_type, quantity,
            balance_after, uom, reference_no, warehouse, reason,
            com_sno, div_sno, brn_sno, dept_sno, created_by, created_at
        )
        VALUES (
            @item_sno, @item_code, @item_name, @movement_type, ISNULL(@quantity, 0),
            @new_stock, @uom, @reference_no, @new_warehouse, @reason,
            @com_sno, @div_sno, @brn_sno, @dept_sno, @created_by, GETDATE()
        );
        SET @movement_sno = SCOPE_IDENTITY();
        INSERT INTO @movements (movement_sno) VALUES (@movement_sno);

        -- One FIFO batch per GRN line item receipt only — a plain manual
        -- stock-in adjustment (no grn_item_sno) creates no batch.
        IF @movement_type = 'IN' AND @grn_item_sno IS NOT NULL AND ISNULL(@quantity, 0) > 0
        BEGIN
            DECLARE @batch_no VARCHAR(60) = ISNULL(@grn_no, 'ADJ') + '-B' + CAST(@grn_item_sno AS VARCHAR(10));
            DECLARE @new_batch_sno INT;

            INSERT INTO dbo.nt_stock_batches (
                batch_no, item_sno, grn_basic_sno, grn_item_sno, grn_no,
                received_qty, remaining_qty, unit_cost, received_date, uom,
                com_sno, div_sno, brn_sno, dept_sno, status, created_by, created_at
            )
            VALUES (
                @batch_no, @item_sno, @grn_basic_sno, @grn_item_sno, @grn_no,
                @quantity, @quantity, @unit_cost, ISNULL(@received_date, CAST(GETDATE() AS DATE)), @uom,
                @com_sno, @div_sno, @brn_sno, @dept_sno, 'Active', @created_by, GETDATE()
            );
            SET @new_batch_sno = SCOPE_IDENTITY();

            UPDATE dbo.nt_stock_movements SET batch_sno = @new_batch_sno WHERE movement_sno = @movement_sno;
        END
    END

    SELECT
        m.movement_sno, m.item_sno, m.item_code, m.item_name, m.movement_type, m.quantity,
        m.balance_after, m.uom, m.reference_no, m.warehouse, m.reason,
        m.com_sno, m.div_sno, m.brn_sno, m.batch_sno, m.created_by,
        CONVERT(VARCHAR(30), m.created_at, 120) AS created_at
    FROM dbo.nt_stock_movements m
    JOIN @movements x ON x.movement_sno = m.movement_sno
    ORDER BY m.movement_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_ApproveBankPaymentVoucher  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_ApproveBankPaymentVoucher
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @voucher_sno INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.voucher_sno') AS INT),
                @approved_by VARCHAR(30)  = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action      VARCHAR(10)  = LOWER(LTRIM(RTRIM(ISNULL(JSON_VALUE(@jsonInput, '$.action'), '')))),
                @comments    NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.comments'))), '');

        IF @voucher_sno IS NULL OR @approved_by IS NULL OR @action NOT IN ('approve', 'reject')
            THROW 58420, 'voucher_sno, approved_by and a valid action (approve / reject) are required.', 1;

        BEGIN TRANSACTION;

        DECLARE @status VARCHAR(20), @current_approver VARCHAR(30), @stage_seq INT, @workflow_types_id INT,
                @agreement_sno INT, @voucher_no VARCHAR(30), @period_to DATE, @repay DECIMAL(18,2);
        SELECT @status = status, @current_approver = current_approver_id, @stage_seq = current_stage_seq,
               @workflow_types_id = workflow_types_id, @agreement_sno = agreement_sno, @voucher_no = voucher_no,
               @period_to = period_to, @repay = principal_repayment
        FROM dbo.bank_payment_voucher WITH (UPDLOCK, HOLDLOCK)
        WHERE voucher_sno = @voucher_sno;

        IF @status IS NULL
            THROW 58421, 'Bank payment voucher not found.', 1;
        IF @status <> 'PENDING_APPROVAL'
            THROW 58422, 'This voucher is not awaiting approval.', 1;
        IF @current_approver IS NULL OR @current_approver <> @approved_by
            THROW 58423, 'This voucher is not awaiting your approval.', 1;

        IF @action = 'reject'
        BEGIN
            UPDATE dbo.bank_payment_voucher SET status = 'REJECTED', current_approver_id = NULL WHERE voucher_sno = @voucher_sno;
            INSERT INTO dbo.bank_payment_voucher_history (voucher_sno, action_type, status_by, comment)
            VALUES (@voucher_sno, 'REJECTED', @approved_by, @comments);
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @voucher_sno AS voucher_sno, @voucher_no AS voucher_no;
            RETURN;
        END

        INSERT INTO dbo.bank_payment_voucher_history (voucher_sno, action_type, status_by, comment)
        VALUES (@voucher_sno, 'APPROVED', @approved_by, @comments);

        -- Next stage of the workflow, if any
        DECLARE @next_approver VARCHAR(30) = NULL;
        SELECT TOP 1 @next_approver = JSON_VALUE(j.value, '$.approver_ecno')
        FROM dbo.workflow_stage ws
        CROSS APPLY OPENJSON(ws.stage_order_json) j
        WHERE ws.workflow_types_id = @workflow_types_id AND ws.is_active = 'Y' AND TRY_CAST(j.[key] AS INT) = @stage_seq + 1;

        IF @next_approver IS NOT NULL
        BEGIN
            UPDATE dbo.bank_payment_voucher SET current_approver_id = @next_approver, current_stage_seq = @stage_seq + 1 WHERE voucher_sno = @voucher_sno;
            COMMIT TRANSACTION;
            SELECT 'SUCCESS' AS result, @voucher_sno AS voucher_sno, @voucher_no AS voucher_no, @next_approver AS next_approver, 'PENDING_APPROVAL' AS status;
            RETURN;
        END

        -- Final stage
        UPDATE dbo.bank_payment_voucher
        SET status = 'APPROVED', current_approver_id = NULL, approved_at = GETDATE()
        WHERE voucher_sno = @voucher_sno;

        IF @repay > 0
        BEGIN
            INSERT INTO dbo.loan_principal_txn (agreement_sno, txn_date, txn_type, amount, voucher_sno, remarks, created_by)
            VALUES (@agreement_sno, @period_to, 'REPAYMENT', @repay, @voucher_sno, N'Principal repaid with ' + @voucher_no, @approved_by);

            IF dbo.fn_LoanPrincipalAt(@agreement_sno, @period_to) < 0
                THROW 58424, 'Approving this voucher would take the principal below zero - another principal movement was entered after the voucher was raised. Reject it and raise a new one.', 1;
        END

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, @voucher_sno AS voucher_sno, @voucher_no AS voucher_no, 'FINAL_STAGE' AS next_approver, 'APPROVED' AS status;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_ApproveServicePoCycle  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_ApproveServicePoCycle
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        DECLARE @cycle_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT),
                @comments        VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @cycle_sno IS NULL
        BEGIN
            RAISERROR('cycle_sno is required.', 16, 1);
            RETURN;
        END

        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.service_po_cycle WHERE cycle_sno = @cycle_sno AND status = 'PENDING_APPROVAL')
        BEGIN
            RAISERROR('Service PO cycle not found or not awaiting approval.', 16, 1);
            RETURN;
        END

        BEGIN TRANSACTION;

        CREATE TABLE #po_approval_stages (
            seq_no INT, approver_ecno VARCHAR(30), stage VARCHAR(100),
            required_approvals VARCHAR(10), is_mandatory CHAR(1), escalation_hours VARCHAR(10),
            approver_condition VARCHAR(200), next_approver_ecno VARCHAR(30),
            can_forward CHAR(1), can_backward CHAR(1), can_edit_data CHAR(1)
        );

        INSERT INTO #po_approval_stages (
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,
            escalation_hours, approver_condition, next_approver_ecno,
            can_forward, can_backward, can_edit_data
        )
        SELECT
            CAST(ojBase.[key] AS INT),
            JSON_VALUE(ojBase.[value], '$.approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.stage'),
            JSON_VALUE(ojBase.[value], '$.required_approvals'),
            JSON_VALUE(ojBase.[value], '$.is_mandatory'),
            JSON_VALUE(ojBase.[value], '$.escalation_hours'),
            JSON_VALUE(ojBase.[value], '$.approver_condition'),
            JSON_VALUE(ojBase.[value], '$.next_approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.can_forward'),
            JSON_VALUE(ojBase.[value], '$.can_backward'),
            JSON_VALUE(ojBase.[value], '$.can_edit_data')
        FROM OPENJSON(@approval_stages) AS ojBase;

        IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
            VALUES (@cycle_sno, 'REJECTED', @approved_by, @comments);

            UPDATE dbo.service_po_cycle SET status = 'REJECTED', current_approver_id = NULL WHERE cycle_sno = @cycle_sno;

            DROP TABLE #po_approval_stages;
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @cycle_sno AS cycle_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
            RETURN;
        END

        DECLARE @next_current_approver VARCHAR(30);
        SELECT @next_current_approver = next_stage.approver_ecno
        FROM (
            SELECT approver_ecno, LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #po_approval_stages
        ) current_stage
        LEFT JOIN #po_approval_stages next_stage ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'APPROVED', @approved_by, @comments);

        UPDATE dbo.service_po_cycle SET current_approver_id = @next_current_approver WHERE cycle_sno = @cycle_sno;

        DECLARE @out_po_basic_sno INT = NULL, @out_po_no VARCHAR(50) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            -- ── Final stage: raise ONE PO PER SUPPLIER in the cycle's split (sql/88) ──
            DECLARE @agreement_sno INT, @pr_basic_sno INT, @qty DECIMAL(18,4),
                    @discount_pct DECIMAL(5,2), @gst_pct DECIMAL(5,2),
                    @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
                    @service_sno INT, @service_name NVARCHAR(150), @rate_uom_sno INT, @agreement_no VARCHAR(30),
                    @service_type_sno INT, @period_end DATE;

            SELECT @agreement_sno = spc.agreement_sno, @pr_basic_sno = spc.pr_basic_sno, @qty = spc.qty,
                   @discount_pct = ISNULL(spc.discount_pct, 0), @gst_pct = ISNULL(spc.gst_pct, 0),
                   @com_sno = spc.com_sno, @div_sno = spc.div_sno, @brn_sno = spc.brn_sno, @dept_sno = spc.dept_sno
            FROM dbo.service_po_cycle spc
            WHERE spc.cycle_sno = @cycle_sno;

            SELECT @service_sno = sa.service_sno, @rate_uom_sno = sa.rate_uom_sno,
                   @agreement_no = sa.agreement_no, @period_end = sa.period_end_date,
                   @service_name = sm.service_name, @service_type_sno = sm.service_type_sno
            FROM dbo.service_agreement sa
            JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
            WHERE sa.agreement_sno = @agreement_sno;

            -- Defensive: a cycle with no split rows (none should exist after sql/88's
            -- backfill) falls back to the agreement's primary supplier at 100%.
            IF NOT EXISTS (SELECT 1 FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno)
                INSERT INTO dbo.service_po_cycle_vendor (cycle_sno, vendor_sno, share_pct, rate_amount, net_cost)
                SELECT spc.cycle_sno, sa.vendor_sno, 100, spc.rate_amount, spc.net_cost
                FROM dbo.service_po_cycle spc
                JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
                WHERE spc.cycle_sno = @cycle_sno;

            DECLARE @supplier_count INT = (SELECT COUNT(*) FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno);
            DECLARE @po_list VARCHAR(500) = '';
            DECLARE @cv_sno INT, @cv_vendor INT, @cv_rate DECIMAL(18,2), @cv_net DECIMAL(18,2), @cv_pct DECIMAL(9,6);
            DECLARE @new_po_sno INT, @new_po_no VARCHAR(50), @po_seq INT;
            DECLARE @po_year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));

            DECLARE po_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT cycle_vendor_sno, vendor_sno, rate_amount, net_cost, share_pct
                FROM dbo.service_po_cycle_vendor
                WHERE cycle_sno = @cycle_sno
                ORDER BY cycle_vendor_sno;

            OPEN po_cur;
            FETCH NEXT FROM po_cur INTO @cv_sno, @cv_vendor, @cv_rate, @cv_net, @cv_pct;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @po_seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
                FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
                WHERE po_df_no LIKE 'SVO-' + @po_year + '-%';
                SET @new_po_no = 'SVO-' + @po_year + '-' + RIGHT('0000' + CAST(@po_seq AS VARCHAR(4)), 4);

                INSERT INTO dbo.po_request_info (
                    vendor_sno, brn_sno, dept_sno, com_sno, div_sno, budget_sno, budget_code, pr_basic_sno,
                    po_date, required_date, purpose, terms_conditions, delivery_address,
                    is_active, workflow_types_id, current_approver_id, status, po_df_no, service_type_sno
                )
                VALUES (
                    @cv_vendor, @brn_sno, @dept_sno, @com_sno, @div_sno, NULL, NULL, @pr_basic_sno,
                    CAST(GETDATE() AS DATE), @period_end,
                    N'Recurring service PO — Agreement ' + @agreement_no + N' (' + @service_name + N')'
                        + CASE WHEN @supplier_count > 1
                               THEN N' — ' + CONVERT(NVARCHAR(12), CAST(@cv_pct AS DECIMAL(9,2))) + N'% share'
                               ELSE N'' END,
                    NULL, NULL,
                    'Y', NULL, NULL, 'A', @new_po_no, @service_type_sno
                );
                SET @new_po_sno = SCOPE_IDENTITY();

                INSERT INTO dbo.po_item_details (
                    po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
                    qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
                    remarks, po_section, created_by, created_date, is_active
                )
                SELECT
                    @new_po_sno, NULL, @service_sno, sm.service_name, '',
                    @qty, @rate_uom_sno, um.uom_name, @cv_rate, @cv_rate * @qty, @discount_pct, @gst_pct, @cv_net,
                    NULL, 'SERVICE', @approved_by, GETDATE(), '1'
                FROM dbo.service_master sm
                LEFT JOIN dbo.uom_master um ON um.uom_sno = @rate_uom_sno
                WHERE sm.service_sno = @service_sno;

                INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
                VALUES (@new_po_sno, 'APPROVED_ISSUED', @approved_by, N'Issued after Service PO cycle approval (Agreement ' + @agreement_no + N').', 'Y');

                UPDATE dbo.service_po_cycle_vendor SET po_basic_sno = @new_po_sno WHERE cycle_vendor_sno = @cv_sno;

                -- The first PO is the "primary" one kept on the cycle / recurring log
                IF @out_po_basic_sno IS NULL
                BEGIN
                    SET @out_po_basic_sno = @new_po_sno;
                    SET @out_po_no = @new_po_no;
                END
                SET @po_list = @po_list + CASE WHEN @po_list = '' THEN '' ELSE ',' END + CAST(@new_po_sno AS VARCHAR(20));

                FETCH NEXT FROM po_cur INTO @cv_sno, @cv_vendor, @cv_rate, @cv_net, @cv_pct;
            END
            CLOSE po_cur;
            DEALLOCATE po_cur;

            UPDATE dbo.service_po_cycle SET status = 'GENERATED', po_basic_sno = @out_po_basic_sno WHERE cycle_sno = @cycle_sno;

            UPDATE dbo.service_agreement_recurring_pr_log
            SET po_basic_sno = @out_po_basic_sno, po_no = @out_po_no
            WHERE agreement_sno = @agreement_sno AND pr_basic_sno = @pr_basic_sno;
        END

        DROP TABLE #po_approval_stages;
        COMMIT TRANSACTION;

        SELECT
            'SUCCESS' AS result, @cycle_sno AS cycle_sno, @approved_by AS approved_by, GETDATE() AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @out_po_basic_sno AS po_basic_sno, @out_po_no AS po_no,
            @po_list AS po_basic_snos, @supplier_count AS po_count;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF OBJECT_ID('tempdb..#po_approval_stages') IS NOT NULL DROP TABLE #po_approval_stages;
        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_ApproveSupplierQuotation
CREATE OR ALTER PROCEDURE dbo.sp_nt_ApproveSupplierQuotation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        ------------------------------------------------------------------
        -- 1. Validate input
        ------------------------------------------------------------------
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        DECLARE @sq_basic_sno    INT            = TRY_CAST(JSON_VALUE(@jsonInput, '$.sq_basic_sno') AS INT),
                @pr_no           VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.pr_no'))), ''),
                @comments        VARCHAR(1000)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX)  = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.approved_by'))), ''),
                @transfer_to     VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.transfer_to_ecno'))), ''),
                @action          VARCHAR(30)    = LOWER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.action'))));

        IF @sq_basic_sno IS NULL
        BEGIN
            RAISERROR('sq_basic_sno is required.', 16, 1);
            RETURN;
        END

        IF @action IS NULL OR @action NOT IN ('approve', 'reject', 'forward', 'backward')
        BEGIN
            RAISERROR('Invalid action. Use approve | reject | forward | backward.', 16, 1);
            RETURN;
        END

        IF @approved_by IS NULL
        BEGIN
            RAISERROR('approved_by (approver EC number) is required.', 16, 1);
            RETURN;
        END

        IF @action IN ('forward', 'backward')
           AND @transfer_to IS NULL
        BEGIN
            RAISERROR('transfer_to_ecno is required for forward/backward.', 16, 1);
            RETURN;
        END

        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages.', 16, 1);
            RETURN;
        END

        ------------------------------------------------------------------
        -- 2. Load quotation header
        ------------------------------------------------------------------
        DECLARE @pr_basic_sno      INT,
                @vendor_sno        INT,
                @com_sno           INT,
                @div_sno           INT,
                @brn_sno           INT,
                @dept_sno          INT,
                @workflow_types_id INT,
                @cur_transfer_from VARCHAR(30),
                @sq_pr_no          VARCHAR(30);

        SELECT
            @pr_basic_sno      = sq.pr_basic_sno,
            @vendor_sno        = sq.vendor_sno,
            @com_sno           = pr.com_sno,
            @div_sno           = pr.div_sno,
            @brn_sno           = sq.brn_sno,
            @dept_sno          = sq.dept_sno,
            @workflow_types_id = sq.workflow_types_id,
            @cur_transfer_from = sq.transferred_from,
            @sq_pr_no          = sq.pr_no
        FROM supplier_quotation_info sq
        INNER JOIN pr_basic_info pr ON pr.pr_basic_sno = sq.pr_basic_sno
        WHERE sq.sq_basic_sno = @sq_basic_sno
          AND sq.is_active = 1;

        IF @pr_basic_sno IS NULL
        BEGIN
            RAISERROR('Invalid sq_basic_sno or inactive quotation.', 16, 1);
            RETURN;
        END

        IF @pr_no IS NULL
    SET @pr_no = @sq_pr_no;

        ------------------------------------------------------------------
        -- 3. Materialize approval stages into temp table
        ------------------------------------------------------------------
        CREATE TABLE #approval_stages (
            seq_no             INT,
            approver_ecno      VARCHAR(30),
          stage              VARCHAR(100),
            required_approvals VARCHAR(10),
            is_mandatory       CHAR(1),
            escalation_hours   VARCHAR(10),
            approver_condition VARCHAR(200),
            next_approver_ecno VARCHAR(30),
            can_forward        CHAR(1),
            can_backward       CHAR(1),
            can_edit_data      CHAR(1)
        );

        INSERT INTO #approval_stages (
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,
            escalation_hours, approver_condition, next_approver_ecno,
            can_forward, can_backward, can_edit_data
        )
        SELECT
            CAST(oj.[key] AS INT),
            JSON_VALUE(oj.[value], '$.approver_ecno'),
            JSON_VALUE(oj.[value], '$.stage'),
            JSON_VALUE(oj.[value], '$.required_approvals'),
            JSON_VALUE(oj.[value], '$.is_mandatory'),
            JSON_VALUE(oj.[value], '$.escalation_hours'),
            JSON_VALUE(oj.[value], '$.approver_condition'),
            JSON_VALUE(oj.[value], '$.next_approver_ecno'),
            JSON_VALUE(oj.[value], '$.can_forward'),
            JSON_VALUE(oj.[value], '$.can_backward'),
            JSON_VALUE(oj.[value], '$.can_edit_data')
        FROM OPENJSON(@approval_stages) AS oj;

        DECLARE @stage_ecno VARCHAR(30) =
            CASE
                WHEN EXISTS (SELECT 1 FROM #approval_stages WHERE approver_ecno = @approved_by)
                    THEN @approved_by
                ELSE @cur_transfer_from
            END;

        IF @action IN ('approve', 'forward', 'backward')
           AND NOT EXISTS (SELECT 1 FROM #approval_stages WHERE approver_ecno = @stage_ecno)
        BEGIN
            RAISERROR('Current approver is not part of the approval workflow.', 16, 1);
            RETURN;
        END

        BEGIN TRANSACTION;

        ------------------------------------------------------------------
        -- 4A. REJECT
        -- Reject process for all quotations under same PR
        ------------------------------------------------------------------
        IF @action = 'reject'
        BEGIN
            INSERT INTO supplier_quotation_history (
                sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
                approver_ecno, status, status_by, transferred_from,
                transferred_to, comment, action_type, pr_basic_sno,
                selected_by, pr_no
            )
            SELECT
                sq.sq_basic_sno, NULL, 1, sq.workflow_types_id,
                @approved_by, 'R', @approved_by, sq.transferred_from,
                sq.transferred_to, @comments, 'REJECTED', sq.pr_basic_sno,
                NULL, sq.pr_no
            FROM supplier_quotation_info sq
            WHERE sq.pr_no = @pr_no
              AND sq.is_active = 1;

            UPDATE supplier_quotation_info
            SET status           = 'R',
                approver_ecno    = NULL,
                transferred_from = NULL,
                transferred_to   = NULL,
                modifed_by       = @approved_by,
                modifed_date     = GETDATE()
            WHERE pr_no = @pr_no
              AND is_active = 1;

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT 'REJECTED'    AS result,
                   @sq_basic_sno AS sq_basic_sno,
                   @pr_no        AS pr_no,
                   @approved_by  AS rejected_by,
                   GETDATE()     AS rejected_on,
                   @comments     AS rejection_reason;
            RETURN;
        END

        ------------------------------------------------------------------
        -- 4B. FORWARD / BACKWARD
        -- Update workflow columns for all quotations under same PR
        -- Keep status as process flag only; do not touch is_selected
        ------------------------------------------------------------------
      IF @action IN ('forward', 'backward')
        BEGIN
            DECLARE @can CHAR(1);

            SELECT @can =
                CASE
                    WHEN @action = 'forward' THEN can_forward
                    ELSE can_backward
                END
            FROM #approval_stages
            WHERE approver_ecno = @stage_ecno;

            IF ISNULL(@can, 'N') <> 'Y'
            BEGIN
                ROLLBACK TRANSACTION;
                DROP TABLE #approval_stages;
                RAISERROR('Current approver is not allowed to %s.', 16, 1, @action);
                RETURN;
            END

            INSERT INTO supplier_quotation_history (
                sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
                approver_ecno, status, status_by, transferred_from,
                transferred_to, comment, action_type, pr_basic_sno,
                selected_by, pr_no
            )
            SELECT
                sq.sq_basic_sno, NULL, 1, sq.workflow_types_id,
                @transfer_to, sq.status, @approved_by, @approved_by,
                @transfer_to, @comments, UPPER(@action), sq.pr_basic_sno,
                sq.is_selected, sq.pr_no
            FROM supplier_quotation_info sq
            WHERE sq.pr_no = @pr_no
              AND sq.is_active = 1;

            UPDATE supplier_quotation_info
            SET approver_ecno    = @transfer_to,
                transferred_from = @approved_by,
                transferred_to   = @transfer_to,
                modifed_by       = @approved_by,
                modifed_date     = GETDATE()
            WHERE pr_no = @pr_no
              AND is_active = 1;

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT UPPER(@action) AS result,
                   @sq_basic_sno  AS sq_basic_sno,
                   @pr_no         AS pr_no,
                   @approved_by   AS transferred_from,
                   @transfer_to   AS transferred_to,
                   GETDATE()      AS transferred_on;
            RETURN;
        END

        ------------------------------------------------------------------
        -- 4C. APPROVE — resolve next stage
        -- Update workflow columns for all quotations under same PR
        -- Keep final status/is_selected only for chosen quotation at final stage
        ------------------------------------------------------------------
        DECLARE @next_approver  VARCHAR(30),
                @next_condition VARCHAR(200);

        ;WITH stage_cte AS
        (
            SELECT
                seq_no,
                approver_ecno,
                LEAD(approver_ecno) OVER (ORDER BY seq_no) AS next_ecno
            FROM #approval_stages
        )
        SELECT
            @next_approver  = s2.approver_ecno,
            @next_condition = s2.approver_condition
        FROM stage_cte s1
        LEFT JOIN #approval_stages s2
               ON s2.approver_ecno = s1.next_ecno
        WHERE s1.approver_ecno = @stage_ecno;

        INSERT INTO supplier_quotation_history (
            sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
            approver_ecno, status, status_by, transferred_from,
            transferred_to, comment, action_type, pr_basic_sno,
            selected_by, pr_no
        )
        VALUES (
            @sq_basic_sno, NULL, 1, @workflow_types_id,
            @approved_by,
            CASE WHEN @next_approver IS NULL THEN 'A' ELSE 'P' END,
            @approved_by, NULL,
            NULL,
            @comments,
            CASE WHEN @next_approver IS NULL THEN 'FINAL_APPROVED' ELSE 'APPROVED' END,
            @pr_basic_sno,
            CASE WHEN @next_approver IS NULL THEN @approved_by ELSE NULL END,
            @pr_no
        );

        ------------------------------------------------------------------
        -- Intermediate approval: move all quotations in same PR
    -- to next approver, but do not finalize selection/status
        ------------------------------------------------------------------
        IF @next_approver IS NOT NULL
        BEGIN
            UPDATE supplier_quotation_info
            SET approver_ecno    = @next_approver,
                transferred_from = NULL,
                transferred_to   = NULL,
                modifed_by       = @approved_by,
                modifed_date     = GETDATE()
            WHERE pr_no = @pr_no
              AND is_active = 1;

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT 'APPROVED'      AS result,
                   @sq_basic_sno   AS sq_basic_sno,
                   @pr_no          AS pr_no,
                   @approved_by    AS approved_by,
                   GETDATE()       AS approved_on,
                   @next_approver  AS next_approver,
                   @next_condition AS next_condition,
                   'N'             AS is_final;
            RETURN;
        END

        --================================================================
        -- 5. FINAL STAGE → selected quotation only gets approved/selected
        -- other quotations only workflow columns reset; status/is_selected
        -- remain independent
        --================================================================

        UPDATE supplier_quotation_info
        SET status           = 'A',
            is_selected      = 1,
            approver_ecno    = NULL,
            transferred_from = NULL,
            transferred_to   = NULL,
            modifed_by       = @approved_by,
            modifed_date     = GETDATE()
        WHERE sq_basic_sno = @sq_basic_sno
          AND is_active = 1;

        UPDATE supplier_quotation_info
        SET is_selected      = 0,
            approver_ecno    = NULL,
            transferred_from = NULL,
            transferred_to   = NULL,
            modifed_by       = @approved_by,
            modifed_date     = GETDATE()
        WHERE pr_no = @pr_no
          AND sq_basic_sno <> @sq_basic_sno
          AND is_active = 1;

        ------------------------------------------------------------------
        -- 5a. Insert PO header — OR reuse an existing active PO for the
        -- same (pr_basic_sno, vendor_sno) pair (Part B grouping rule: a
        -- Service PO for this vendor+PR may already exist, e.g. the
        -- Electrical worked example's combined PO). Symmetric to the
        -- merge-check in sp_nt_CreateServicePO.
        ------------------------------------------------------------------
        DECLARE @po_basic_sno INT;
        DECLARE @po_df_no VARCHAR(50);
        DECLARE @is_new_po BIT = 0;

        SELECT @po_basic_sno = po_basic_sno, @po_df_no = po_df_no
        FROM po_request_info
        WHERE pr_basic_sno = @pr_basic_sno
          AND vendor_sno = @vendor_sno
          AND is_active = 'Y';

        IF @po_basic_sno IS NULL
        BEGIN
            SET @is_new_po = 1;

            INSERT INTO po_request_info (
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno,
                pr_basic_sno, po_date,
                terms_conditions,
      is_active, workflow_types_id, status,
                po_df_no,
                split_pr_no
            )
            SELECT
                sq.vendor_sno,
                sq.brn_sno,
                sq.dept_sno,
                pr.com_sno,
                pr.div_sno,
                sq.pr_basic_sno,
                GETDATE(),
                sq.payment_terms,
                'Y',
                sq.workflow_types_id,
                'A',
                NULL,
                @pr_no
            FROM supplier_quotation_info sq
            INNER JOIN pr_basic_info pr ON pr.pr_basic_sno = sq.pr_basic_sno
            WHERE sq.sq_basic_sno = @sq_basic_sno;

            SET @po_basic_sno = SCOPE_IDENTITY();

            ------------------------------------------------------------------
            -- 5b. Generate formatted PO number: com_prefix+div_prefix+brn_prefix+seq
            ------------------------------------------------------------------
            DECLARE @po_prefix VARCHAR(30),
                    @next_seq  INT;

            SELECT @po_prefix = ISNULL(vadr.com_prefix, '')
                              + ISNULL(vadr.div_prefix, '')
                              + ISNULL(vadr.brn_prefix, '')
            FROM vw_ActiveDeptRecords vadr
            WHERE vadr.com_sno  = @com_sno
              AND vadr.div_sno  = @div_sno
              AND vadr.brn_sno  = @brn_sno
              AND vadr.dept_sno = @dept_sno;

            IF @po_prefix IS NULL OR @po_prefix = ''
            BEGIN
                ROLLBACK TRANSACTION;
                DROP TABLE #approval_stages;
                RAISERROR('Unable to resolve PO prefix (company/division/branch).', 16, 1);
                RETURN;
            END

            -- Find last sequence for this prefix; lock to avoid duplicates under concurrency
            SELECT @next_seq = ISNULL(MAX(
                       TRY_CAST(SUBSTRING(po_df_no, LEN(@po_prefix) + 1, 20) AS INT)
                   ), 0) + 1
            FROM po_request_info WITH (UPDLOCK, HOLDLOCK)
            WHERE po_df_no LIKE @po_prefix + '%'
              AND TRY_CAST(SUBSTRING(po_df_no, LEN(@po_prefix) + 1, 20) AS INT) IS NOT NULL;

            SET @po_df_no = @po_prefix + RIGHT('000' + CAST(@next_seq AS VARCHAR(10)), 3);

            UPDATE po_request_info
            SET po_df_no = @po_df_no
            WHERE po_basic_sno = @po_basic_sno;
        END

        ------------------------------------------------------------------
        -- 5c. Insert PO line items (po_section='MATERIAL' — a combined PO
        -- may also carry SERVICE-section lines inserted separately by
        -- sp_nt_CreateServicePO, either before or after this runs)
        ------------------------------------------------------------------
       INSERT INTO po_item_details (
    po_basic_sno, pr_item_sno, prod_sno, specification,
    qty, unit, agreed_unit_price, discount_pct, tax_pct,
    total_cost, net_cost, remarks, po_section,
    created_by, created_date, is_active, split_pr_no
)
SELECT
    @po_basic_sno,
    sid.pr_item_sno,
    sid.prod_sno,
    sid.specification,
    sid.qty,
    sid.unit,
    sid.unit_price,
    sid.discount_pct,
    sid.tax_pct,
    sid.total_amount,              -- total_cost
    calc.net_cost,                 -- net_cost
    sid.remarks,
    'MATERIAL',
    @approved_by,
    GETDATE(),
    1,
    @pr_no
FROM supplier_quotation_items sid
CROSS APPLY (
    SELECT
      ((sid.qty * sid.unit_price - (sid.qty * sid.unit_price * ISNULL(sid.discount_pct,0) / 100.0))
            * ISNULL(sid.tax_pct,0) / 100.0) AS net_cost
) calc
WHERE sid.sq_basic_sno = @sq_basic_sno
  AND sid.is_active = 1;

        ------------------------------------------------------------------
        -- 5d. PO creation history
        ------------------------------------------------------------------
        INSERT INTO supplier_quotation_history (
            sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
            approver_ecno, status, status_by, transferred_from,
            transferred_to, comment, action_type, pr_basic_sno,
            selected_by, pr_no
        )
        VALUES (
            @sq_basic_sno, NULL, 1, @workflow_types_id,
            @approved_by, 'A', @approved_by, NULL,
            NULL,
            'PO ' + @po_df_no + CASE WHEN @is_new_po = 1
                THEN ' auto-generated on final quotation approval'
                ELSE ' — MATERIAL lines appended to the existing PO already shared with this vendor on this PR'
                END,
            'PO_CREATED',
            @pr_basic_sno,
            @approved_by,
            @pr_no
        );

        COMMIT TRANSACTION;
        DROP TABLE #approval_stages;

        ------------------------------------------------------------------
        -- 6. Final response
        ------------------------------------------------------------------
        DECLARE @po_header_json NVARCHAR(MAX),
                @vendor_json    NVARCHAR(MAX),
                @po_items_json  NVARCHAR(MAX),
                @approver_name  NVARCHAR(200);

        SELECT @po_header_json = (
            SELECT
                po.po_basic_sno,
                po.po_df_no,
                po.split_pr_no                              AS po_pr_no,
                CONVERT(VARCHAR(23), po.po_date, 126)       AS po_date,
                po.status                                   AS po_status,
                po.terms_conditions,
                vadr.com_sno,
                vadr.com_name,
                ISNULL(vadr.logo, '')                       AS com_logo,
                vadr.company_address,
                vadr.branch_address,
                vadr.div_sno,
                vadr.div_name,
                vadr.div_prefix,
                vadr.brn_name,
                vadr.brn_prefix,
                vadr.dept_name,
                pr.pr_basic_sno                             AS source_pr_basic_sno,
                pr.pr_no                                    AS source_pr_no,
                CONVERT(VARCHAR(23), pr.reg_date, 126)      AS pr_reg_date,
                CONVERT(VARCHAR(23), pr.required_date, 126) AS pr_required_date,
                pr.purpose                                  AS pr_purpose,
                pr.priority_sno
            FROM po_request_info po
            INNER JOIN vw_ActiveDeptRecords vadr
                ON vadr.brn_sno = po.brn_sno
               AND vadr.dept_sno = po.dept_sno
            INNER JOIN pr_basic_info pr
                ON pr.pr_basic_sno = po.pr_basic_sno
            WHERE po.po_basic_sno = @po_basic_sno
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        SELECT @vendor_json = (
            SELECT
               vgaki.kyc_basic_info_sno AS vendor_sno,
                vgaki.company_name       AS vendor_name,
                vgaki.supp_code          AS vendor_code,
                vgaki.contact_person,
                vgaki.mobile_number      AS vendor_mobile,
                vgaki.email              AS vendor_email,
                vgaki.kyc_address        AS vendor_address,
                vgaki.gst_no,
                vgaki.pan_no,
                vgaki.business_type
            FROM vw_get_all_kyc_info vgaki
            WHERE vgaki.kyc_basic_info_sno = @vendor_sno
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- v2: LEFT JOIN product_master/uom_master/pr_item_details (were
        -- INNER — would silently exclude SERVICE-section lines already on a
        -- combined PO, since those rows have prod_sno=NULL) + LEFT JOIN
        -- po_section, so the response shows every line on
        -- the PO, both sections combined.
        SELECT @po_items_json = (
            SELECT
                pid.po_item_sno,
                pid.po_basic_sno,
                @po_df_no                                    AS po_df_no,
                pid.split_pr_no                              AS pr_no,
                pid.pr_item_sno,
                pid.po_section,
                pid.prod_sno,
                pm.prod_name,
                pm.prod_code,
                pm.prod_notes,
                pid.service_sno,
                pid.specification,
                pid.qty,
                pid.unit                                     AS uom_sno,
                uom.uom_name,
                uom.uom_code,
                pid.agreed_unit_price,
                pid.discount_pct,
                pid.tax_pct,
                pid.total_cost,
                pid.net_cost,
                pid.remarks,
                prid.est_cost                                AS pr_est_cost,
                prid.total_cost                              AS pr_total_cost,
                prid.qty                                     AS pr_qty,
                pid.created_by,
                CONVERT(VARCHAR(23), pid.created_date, 126)  AS created_date,
                pid.is_active
            FROM po_item_details pid
            LEFT JOIN product_master pm     ON pm.prod_sno = pid.prod_sno
            LEFT JOIN uom_master uom        ON uom.uom_sno = pid.unit
            LEFT JOIN pr_item_details prid  ON prid.pr_item_sno = pid.pr_item_sno
            WHERE pid.po_basic_sno = @po_basic_sno
              AND pid.is_active = 1
            ORDER BY pid.po_item_sno
            FOR JSON PATH
        );

        SELECT @approver_name = vve.ename
        FROM vw_verified_employees vve
        WHERE vve.ecno = @approved_by;

        IF @approver_name IS NULL
            SELECT @approver_name = nsl.full_name
            FROM dbo.nt_nonstaff_login nsl
            WHERE nsl.login_id = @approved_by;

        SELECT
            'FINAL_APPROVED'                     AS result,
            'Y'                                  AS is_final,
            @sq_basic_sno                        AS sq_basic_sno,
            @pr_no                               AS pr_no,
            @approved_by                         AS final_approved_by,
            @approver_name  AS final_approved_by_name,
            CONVERT(VARCHAR(23), GETDATE(), 126) AS final_approved_on,
            @is_new_po                           AS is_new_po,
            JSON_QUERY(@po_header_json)          AS po_header,
    JSON_QUERY(@vendor_json)             AS vendor,
            JSON_QUERY(@po_items_json)           AS po_items;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT
            'ERROR'            AS result,
            ERROR_NUMBER()     AS error_number,
            ERROR_MESSAGE()    AS error_message,
            ERROR_LINE()       AS error_line,
            ERROR_PROCEDURE()  AS error_procedure;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_AutoCreateStockIssueFromGRN
-- ============================================================
-- Perishable stock: auto-issue off GRN like Non-Regular, plus an
-- "Expiry Stock" signal on the Inventory Stock page.
-- Database: Non_trade_Dev (MSSQL)
--
-- Requires backend-stpl/sql/77_subcategory_perishable_type.sql to have run
-- first (adds subcat_stock_type = 'Perishable' and subcategory_master.
-- perishable_days).
--
-- Both procedures below are reproduced from their live OBJECT_DEFINITION()
-- (not from the on-disk 22_nonregular_direct_issue.sql / 29_inventory_
-- stock_level_reference.sql copies, which had already drifted from live).
-- Only the marked lines change.
-- ============================================================

-- ============================================================
-- sp_nt_AutoCreateStockIssueFromGRN
-- Change: the auto-create-Pending-request fast path (previously gated on
-- @stock_type = 'Non-Regular' only) now also fires for 'Perishable'. No
-- change needed anywhere else — sp_nt_IssueStockRequest already supports
-- issuing part of a request now and the remainder later (Pending ->
-- Partially Issued -> Issued), so Perishable inherits that for free.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_AutoCreateStockIssueFromGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_item_sno   INT           = JSON_VALUE(@jsonInput, '$.po_item_sno');
    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @qty           DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.qty');
    DECLARE @grn_basic_sno INT           = JSON_VALUE(@jsonInput, '$.grn_basic_sno');
    DECLARE @grn_no        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.grn_no');
    DECLARE @created_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @po_item_sno IS NULL OR @item_sno IS NULL OR @qty IS NULL OR @qty <= 0
        RETURN;

    -- Resolve PR origin + the product's subcategory stock type in one hop.
    DECLARE @pr_item_sno    INT,
            @pr_basic_sno   INT,
            @pr_no          VARCHAR(20),
            @requester_ecno VARCHAR(20),
            @com_sno        INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
            @stock_type     VARCHAR(20);

    SELECT
        @pr_item_sno    = pid.pr_item_sno,
        @pr_basic_sno   = pb.pr_basic_sno,
        @pr_no          = pb.pr_no,
        @requester_ecno = pb.created_by,
        @com_sno        = pb.com_sno,
        @div_sno        = pb.div_sno,
        @brn_sno        = pb.brn_sno,
        @dept_sno       = pb.dept_sno,
        @stock_type     = scm.subcat_stock_type
    FROM dbo.po_item_details poid
    JOIN dbo.pr_item_details pid ON pid.pr_item_sno = poid.pr_item_sno
    JOIN dbo.pr_basic_info pb    ON pb.pr_basic_sno = pid.pr_basic_sno
    LEFT JOIN dbo.product_master pm     ON pm.prod_sno   = pid.prod_sno
    LEFT JOIN dbo.subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
    WHERE poid.po_item_sno = @po_item_sno;

    -- Not PR-traceable (e.g. a direct/Store PO line) -> nothing to create,
    -- nothing to notify.
    IF @pr_item_sno IS NULL
        RETURN;

    -- Idempotency: this exact Non-Regular/Perishable GRN line already
    -- produced a request (a retried GRN post). Nothing new to create or
    -- (re-)notify.
    IF @stock_type IN ('Non-Regular', 'Perishable') AND EXISTS (
        SELECT 1
        FROM dbo.nt_stock_request_items sri
        JOIN dbo.nt_stock_requests sr ON sr.request_sno = sri.request_sno
        WHERE sr.grn_basic_sno = @grn_basic_sno AND sri.po_item_sno = @po_item_sno
    )
        RETURN;

    DECLARE @requester_name VARCHAR(255);
    SELECT @requester_name = ename FROM dbo.vw_verified_employees WHERE ecno = @requester_ecno;

    DECLARE @item_code VARCHAR(50), @item_name VARCHAR(255), @uom VARCHAR(20);
    SELECT @item_code = item_code, @item_name = item_name, @uom = uom
    FROM dbo.nt_inventory_items WHERE item_sno = @item_sno;

    DECLARE @request_sno INT, @request_no VARCHAR(30);

    -- Non-Regular AND Perishable: auto-create the directly-issuable Pending
    -- request so the requester never has to raise a manual Store
    -- Requisition. (Perishable added here; Non-Regular behavior unchanged.)
    IF @stock_type IN ('Non-Regular', 'Perishable')
    BEGIN
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));

        BEGIN TRANSACTION;
        BEGIN TRY
            DECLARE @seq INT;
            SELECT @seq = ISNULL(MAX(CAST(RIGHT(request_no, 4) AS INT)), 0) + 1
            FROM dbo.nt_stock_requests WITH (UPDLOCK, HOLDLOCK)
            WHERE request_no LIKE 'SR-' + @year + '-%';

            SET @request_no = 'SR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

            INSERT INTO dbo.nt_stock_requests (
                request_no, requested_by, requested_name, purpose, status,
                source_type, pr_basic_sno, pr_no, grn_basic_sno,
                com_sno, div_sno, brn_sno, dept_sno, created_at
            )
            VALUES (
                @request_no, @requester_ecno, @requester_name,
                'Auto: GRN receipt for ' + @stock_type + ' item, PR ' + ISNULL(@pr_no, ''), 'Pending',
                'Auto-GRN', @pr_basic_sno, @pr_no, @grn_basic_sno,
                @com_sno, @div_sno, @brn_sno, @dept_sno, GETDATE()
            );

            SET @request_sno = SCOPE_IDENTITY();

            INSERT INTO dbo.nt_stock_request_items (
                request_sno, item_sno, item_code, item_name, uom,
                requested_qty, issued_qty, line_status, pr_item_sno, po_item_sno
            )
            VALUES (
                @request_sno, @item_sno, @item_code, @item_name, @uom,
                @qty, 0, 'Pending', @pr_item_sno, @po_item_sno
            );

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            THROW;
        END CATCH
    END

    -- Always returned when PR-traceable, so the caller can notify the
    -- requester regardless of stock type. request_sno/request_no are only
    -- non-NULL when the auto-create above just ran.
    SELECT
        @requester_ecno AS requester_ecno,
        @requester_name AS requester_name,
        @pr_no          AS pr_no,
        @pr_basic_sno   AS pr_basic_sno,
        @stock_type     AS stock_type,
        @item_name      AS item_name,
        @uom            AS uom,
        @qty            AS qty,
        @request_sno    AS request_sno,
        @request_no     AS request_no;
END;
GO
-- [F2. procedures] dbo.sp_nt_BuildServicePoCycleSplit  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_BuildServicePoCycleSplit
    @cycle_sno INT,
    @agreement_sno INT,
    @rate_amount DECIMAL(18,2),
    @qty DECIMAL(18,4),
    @discount_pct DECIMAL(5,2),
    @gst_pct DECIMAL(5,2),
    @out_net_cost DECIMAL(18,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno;

    INSERT INTO dbo.service_po_cycle_vendor (cycle_sno, vendor_sno, share_pct, rate_amount, net_cost)
    SELECT @cycle_sno, v.vendor_sno, v.share_pct, ROUND(@rate_amount * v.share_pct / 100.0, 2), 0
    FROM dbo.service_agreement_vendor v
    WHERE v.agreement_sno = @agreement_sno
    ORDER BY v.sort_order, v.agreement_vendor_sno;

    IF NOT EXISTS (SELECT 1 FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno)
        THROW 58170, 'This agreement has no suppliers configured, so the cycle cannot be split.', 1;

    DECLARE @last_sno INT = (SELECT MAX(cycle_vendor_sno) FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno);

    UPDATE dbo.service_po_cycle_vendor
    SET rate_amount = @rate_amount - ISNULL((
            SELECT SUM(x.rate_amount) FROM dbo.service_po_cycle_vendor x
            WHERE x.cycle_sno = @cycle_sno AND x.cycle_vendor_sno <> @last_sno
        ), 0)
    WHERE cycle_vendor_sno = @last_sno;

    UPDATE dbo.service_po_cycle_vendor
    SET net_cost = ROUND(rate_amount * @qty * (1 - @discount_pct / 100.0) * (1 + @gst_pct / 100.0), 2)
    WHERE cycle_sno = @cycle_sno;

    SELECT @out_net_cost = SUM(net_cost) FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_CalcLoanVoucher  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_CalcLoanVoucher
    @agreement_sno INT,
    @payment_date DATE = NULL,
    @principal_repayment DECIMAL(18,2) = 0,
    @out_agreement_no VARCHAR(30) = NULL OUTPUT,
    @out_period_from DATE = NULL OUTPUT,
    @out_period_to DATE = NULL OUTPUT,
    @out_default_payment_date DATE = NULL OUTPUT,
    @out_days INT = NULL OUTPUT,
    @out_basis SMALLINT = NULL OUTPUT,
    @out_opening_principal DECIMAL(18,2) = NULL OUTPUT,
    @out_principal_on_payment DECIMAL(18,2) = NULL OUTPUT,
    @out_interest DECIMAL(18,2) = NULL OUTPUT,
    @out_principal_after DECIMAL(18,2) = NULL OUTPUT,
    @out_rate_pct DECIMAL(7,3) = NULL OUTPUT,
    @out_segments_json NVARCHAR(MAX) = NULL OUTPUT,
    @out_next_due DATE = NULL OUTPUT,
    @out_next_days INT = NULL OUTPUT,
    @out_next_interest DECIMAL(18,2) = NULL OUTPUT,
    @out_next_segments_json NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status CHAR(1), @period_end DATE, @pay_day TINYINT, @disb DATE, @basis SMALLINT;
    SELECT @status = sa.status, @period_end = sa.period_end_date, @out_agreement_no = sa.agreement_no,
           @pay_day = s.interest_payment_day, @disb = s.disbursement_date, @basis = s.day_count_basis
    FROM dbo.service_agreement sa
    JOIN dbo.service_agreement_statutory s ON s.agreement_sno = sa.agreement_sno
    WHERE sa.agreement_sno = @agreement_sno;

    IF @status IS NULL
        THROW 58400, 'Loan facility not found for this agreement.', 1;
    IF @status <> 'A'
        THROW 58402, 'Interest vouchers can only be raised on an approved loan agreement.', 1;
    IF @pay_day IS NULL OR @disb IS NULL OR @basis IS NULL
        THROW 58403, 'This loan is missing its disbursement date, interest payment day or day-count basis - edit the agreement to add them.', 1;
    IF ISNULL(@principal_repayment, 0) < 0
        THROW 58406, 'The principal repayment cannot be negative.', 1;

    DECLARE @from DATE = dbo.fn_LoanBilledThrough(@agreement_sno);
    IF @from >= @period_end
        THROW 58408, 'Interest has been billed up to the end of the loan term - there is nothing further to bill. Renew the agreement to continue.', 1;

    DECLARE @default_to DATE = dbo.fn_LoanNextDueDate(@pay_day, @from);
    IF @default_to > @period_end SET @default_to = @period_end;
    DECLARE @to DATE = ISNULL(@payment_date, @default_to);

    DECLARE @msg NVARCHAR(400);
    IF @to <= @from
    BEGIN
        SET @msg = N'The payment date must be after ' + CONVERT(NVARCHAR(11), @from, 106) + N' - interest is already billed up to that date.';
        THROW 58404, @msg, 1;
    END
    IF @to > @period_end
    BEGIN
        SET @msg = N'The payment date is beyond the end of the loan term (' + CONVERT(NVARCHAR(11), @period_end, 106) + N').';
        THROW 58405, @msg, 1;
    END

    SET @out_period_from = @from;
    SET @out_period_to = @to;
    SET @out_default_payment_date = @default_to;
    SET @out_days = DATEDIFF(DAY, @from, @to);
    SET @out_basis = @basis;

    SELECT @out_interest = ISNULL(SUM(interest), 0)
    FROM dbo.fn_LoanInterestSegments(@agreement_sno, @from, @to, 0);

    SET @out_segments_json = ISNULL((
        SELECT seg_no, seg_from AS from_date, DATEADD(DAY, -1, seg_to) AS to_date, days, principal,
               benchmark_rate_pct, spread_pct, rate_pct, interest
        FROM dbo.fn_LoanInterestSegments(@agreement_sno, @from, @to, 0)
        ORDER BY seg_no
        FOR JSON PATH), N'[]');

    SET @out_opening_principal = dbo.fn_LoanPrincipalAt(@agreement_sno, @from);
    SET @out_principal_on_payment = dbo.fn_LoanPrincipalAt(@agreement_sno, @to);

    IF ISNULL(@principal_repayment, 0) > @out_principal_on_payment
    BEGIN
        SET @msg = N'The principal repayment (' + CONVERT(NVARCHAR(30), @principal_repayment) + N') is more than the principal outstanding on that date ('
                 + CONVERT(NVARCHAR(30), @out_principal_on_payment) + N').';
        THROW 58407, @msg, 1;
    END
    SET @out_principal_after = @out_principal_on_payment - ISNULL(@principal_repayment, 0);

    SELECT @out_rate_pct = interest_rate_pct FROM dbo.fn_LoanRateAt(@agreement_sno, @to);

    -- The NEXT interest date, priced at the rates already known (the last one
    -- carries forward) on the principal left after this payment.
    IF @to < @period_end
    BEGIN
        SET @out_next_due = dbo.fn_LoanNextDueDate(@pay_day, @to);
        IF @out_next_due > @period_end SET @out_next_due = @period_end;
        SET @out_next_days = DATEDIFF(DAY, @to, @out_next_due);

        SELECT @out_next_interest = ISNULL(SUM(interest), 0)
        FROM dbo.fn_LoanInterestSegments(@agreement_sno, @to, @out_next_due, ISNULL(@principal_repayment, 0));

        SET @out_next_segments_json = ISNULL((
            SELECT seg_no, seg_from AS from_date, DATEADD(DAY, -1, seg_to) AS to_date, days, principal,
                   benchmark_rate_pct, spread_pct, rate_pct, interest
            FROM dbo.fn_LoanInterestSegments(@agreement_sno, @to, @out_next_due, ISNULL(@principal_repayment, 0))
            ORDER BY seg_no
            FOR JSON PATH), N'[]');
    END
END;
GO
-- [F2. procedures] dbo.sp_nt_CreateAcYearRecords
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateAcYearRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Input validation
        IF @jsonInput IS NULL OR @jsonInput = ''
        BEGIN
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;
            RETURN;
        END
        
        -- Validate JSON format
        IF ISJSON(@jsonInput) = 0
        BEGIN
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;
            RETURN;
        END
        
        -- Validate required fields
        IF JSON_VALUE(@jsonInput, '$.ac_year_code') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ac_year_code'))) = ''
        BEGIN
            SELECT 'Failed' as Status, 'Ac year code is required' as ErrorMessage;
            RETURN;
        END
      
        BEGIN TRANSACTION;   
        
        DECLARE @InsertedCount INT;
     
        -- Insert records into ac_master table
        INSERT INTO [Non_trade_Dev].[dbo].[ac_master](
            ac_year_code, 
            ac_year
        )
        SELECT 
            LTRIM(RTRIM(ac_year_code)) as ac_year_code, 
            LTRIM(RTRIM(ac_year)) as ac_year
        FROM OPENJSON(@jsonInput)
        WITH (
            ac_year_code VARCHAR(50) '$.ac_year_code',
            ac_year VARCHAR(50) '$.ac_year'
        );
        
        SET @InsertedCount = @@ROWCOUNT;
        
        COMMIT TRANSACTION;
        
        -- Return success message with count
        SELECT 
            'Success' as Status, 
            CONCAT('Successfully inserted ', @InsertedCount, ' record(s)') as Message,
            @InsertedCount as RecordsInserted;
            
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        
        -- Return detailed error information
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END

GO
-- [F2. procedures] dbo.sp_nt_CreateBankPaymentVoucher  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateBankPaymentVoucher
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @agreement_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @payment_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE),
                @repay         DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.principal_repayment') AS DECIMAL(18,2)), 0),
                @remarks       NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), ''),
                @created_by    VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @agreement_sno IS NULL OR @created_by IS NULL
            THROW 58400, 'agreement_sno and created_by are required.', 1;

        BEGIN TRANSACTION;

        -- Serialise voucher creation per loan.
        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @vendor_sno INT;
        SELECT @com_sno = com_sno, @div_sno = div_sno, @brn_sno = brn_sno, @dept_sno = dept_sno, @vendor_sno = vendor_sno
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_sno = @agreement_sno;

        IF @com_sno IS NULL
            THROW 58400, 'Loan facility not found for this agreement.', 1;

        DECLARE @open_no VARCHAR(30) = (SELECT TOP 1 voucher_no FROM dbo.bank_payment_voucher WHERE agreement_sno = @agreement_sno AND status = 'PENDING_APPROVAL');
        IF @open_no IS NOT NULL
        BEGIN
            DECLARE @open_msg NVARCHAR(300) = N'Voucher ' + @open_no + N' for this loan is still awaiting approval - approve or reject it before raising the next one.';
            THROW 58410, @open_msg, 1;
        END

        DECLARE @agreement_no VARCHAR(30), @from DATE, @to DATE, @default_to DATE, @days INT, @basis SMALLINT,
                @opening DECIMAL(18,2), @on_payment DECIMAL(18,2), @interest DECIMAL(18,2), @after DECIMAL(18,2),
                @rate DECIMAL(7,3), @segments NVARCHAR(MAX), @next_due DATE, @next_days INT, @next_interest DECIMAL(18,2),
                @next_segments NVARCHAR(MAX);

        EXEC dbo.sp_nt_CalcLoanVoucher
            @agreement_sno = @agreement_sno, @payment_date = @payment_date, @principal_repayment = @repay,
            @out_agreement_no = @agreement_no OUTPUT, @out_period_from = @from OUTPUT, @out_period_to = @to OUTPUT,
            @out_default_payment_date = @default_to OUTPUT, @out_days = @days OUTPUT, @out_basis = @basis OUTPUT,
            @out_opening_principal = @opening OUTPUT, @out_principal_on_payment = @on_payment OUTPUT,
            @out_interest = @interest OUTPUT, @out_principal_after = @after OUTPUT, @out_rate_pct = @rate OUTPUT,
            @out_segments_json = @segments OUTPUT, @out_next_due = @next_due OUTPUT, @out_next_days = @next_days OUTPUT,
            @out_next_interest = @next_interest OUTPUT, @out_next_segments_json = @next_segments OUTPUT;

        IF @interest + @repay <= 0
            THROW 58411, 'There is nothing to pay for this period (no interest accrued and no principal repayment entered).', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        EXEC dbo.sp_nt_ResolveBankVoucherWorkflow
            @com_sno = @com_sno, @div_sno = @div_sno, @brn_sno = @brn_sno, @dept_sno = @dept_sno,
            @workflow_types_id = @workflow_types_id OUTPUT, @first_approver = @first_approver OUTPUT;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(voucher_no, 4) AS INT)), 0) + 1
        FROM dbo.bank_payment_voucher WITH (UPDLOCK, HOLDLOCK)
        WHERE voucher_no LIKE 'BPV-' + @year + '-%';
        DECLARE @voucher_no VARCHAR(30) = 'BPV-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.bank_payment_voucher (
            voucher_no, agreement_sno, com_sno, div_sno, brn_sno, dept_sno, vendor_sno,
            period_from, period_to, days, day_count_basis,
            opening_principal, principal_on_payment, interest_amount, principal_repayment, total_payable, principal_after, rate_pct,
            segments_json, next_due_date, next_days, next_est_interest, next_segments_json,
            remarks, status, workflow_types_id, current_approver_id, current_stage_seq, created_by
        )
        VALUES (
            @voucher_no, @agreement_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, @vendor_sno,
            @from, @to, @days, @basis,
            @opening, @on_payment, @interest, @repay, @interest + @repay, @after, @rate,
            @segments, @next_due, @next_days, @next_interest, @next_segments,
            @remarks, 'PENDING_APPROVAL', @workflow_types_id, @first_approver, 0, @created_by
        );
        DECLARE @voucher_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.bank_payment_voucher_history (voucher_sno, action_type, status_by, comment)
        VALUES (@voucher_sno, 'CREATED', @created_by, @remarks);

        COMMIT TRANSACTION;

        SELECT 'SUCCESS' AS result, @voucher_sno AS voucher_sno, @voucher_no AS voucher_no, @agreement_no AS agreement_no,
               @interest AS interest_amount, @repay AS principal_repayment, @interest + @repay AS total_payable,
               @first_approver AS current_approver_id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_CreateGRN
-- sp_nt_CreateGRN's final SELECT — add com/div/brn so the grn:created
-- broadcast can be org-scoped.
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @gate_entry_sno INT           = JSON_VALUE(@jsonInput, '$.gate_entry_sno');
    DECLARE @po_basic_sno   INT           = JSON_VALUE(@jsonInput, '$.po_basic_sno');
    DECLARE @vendor_sno     INT           = JSON_VALUE(@jsonInput, '$.vendor_sno');
    DECLARE @received_date  DATE          = JSON_VALUE(@jsonInput, '$.received_date');
    DECLARE @doc_ref_no     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.doc_ref_no');
    DECLARE @vehicle_no     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.vehicle_no');
    DECLARE @challan_no     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.challan_no');
    DECLARE @remarks        VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.remarks');
    DECLARE @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
    DECLARE @items          NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

    IF @gate_entry_sno IS NULL OR @po_basic_sno IS NULL OR @received_date IS NULL
    BEGIN
        RAISERROR('gate_entry_sno, po_basic_sno and received_date are required.', 16, 1);
        RETURN;
    END

    IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
    BEGIN
        RAISERROR('At least one item is required.', 16, 1);
        RETURN;
    END

    DECLARE @grn_basic_sno INT;
    DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT;

    SELECT
        @com_sno  = com_sno,
        @div_sno  = div_sno,
        @brn_sno  = brn_sno,
        @dept_sno = dept_sno
    FROM dbo.po_request_info
    WHERE po_basic_sno = @po_basic_sno;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @grn_no INT;
        SELECT @grn_no = ISNULL(MAX(grn_no), 0) + 1 FROM dbo.grn_basic_info;

        INSERT INTO dbo.grn_basic_info (
            grn_no, com_sno, div_sno, brn_sno, dept_sno,
            gate_entry_sno, po_basic_sno, vendor_sno,
            received_date, doc_ref_no, vehicle_no, challan_no, remarks,
            is_active, status, created_by, created_date
        )
        VALUES (
            @grn_no, @com_sno, @div_sno, @brn_sno, @dept_sno,
            @gate_entry_sno, @po_basic_sno, @vendor_sno,
            @received_date, @doc_ref_no, @vehicle_no, @challan_no, @remarks,
            'Y', 'Received', @created_by, GETDATE()
        );

        SET @grn_basic_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.grn_item_details (
            grn_basic_sno, po_item_sno, prod_sno, prod_name, specification,
            po_qty, received_qty, diff_qty, rejected_qty, unit_name,
            condition, hsn_code, remarks,
            warehouse_location_sno, warehouse_location_name,
            created_by, created_date, is_active
        )
        SELECT
            @grn_basic_sno,
            j.po_item_sno,
            j.prod_sno,
            j.prod_name,
            j.specification,
            j.ordered_qty,
            j.received_qty,
            (ISNULL(j.received_qty, 0) - ISNULL(j.ordered_qty, 0)),
            ISNULL(j.rejected_qty, 0),
            j.unit_name,
            ISNULL(j.condition, 'Good'),
            NULLIF(LTRIM(RTRIM(j.hsn_code)), ''),
            j.remarks,
            j.warehouse_location_sno,
            wl.location_name,
            @created_by,
            GETDATE(),
            'Y'
        FROM OPENJSON(@items)
        WITH (
            po_item_sno            INT           '$.po_item_sno',
            prod_sno                INT           '$.prod_sno',
            prod_name               VARCHAR(255)  '$.prod_name',
            specification           VARCHAR(500)  '$.specification',
            ordered_qty             DECIMAL(18,2) '$.ordered_qty',
            received_qty            DECIMAL(18,2) '$.received_qty',
            rejected_qty            DECIMAL(18,2) '$.rejected_qty',
            unit_name               VARCHAR(50)   '$.unit_name',
            condition               VARCHAR(20)   '$.condition',
            hsn_code                VARCHAR(10)   '$.hsn_code',
            remarks                 VARCHAR(500)  '$.remarks',
            warehouse_location_sno  INT           '$.warehouse_location_sno'
        ) j
        LEFT JOIN dbo.warehouse_location_master wl
            ON wl.location_sno = j.warehouse_location_sno;

        INSERT INTO dbo.grn_history_data (
            event_type, po_basic_sno, po_item_sno, grn_basic_sno, gate_entry_sno,
            qty, pending_qty_after, to_status, status_by, remarks
        )
        SELECT
            'Item Received',
            @po_basic_sno,
            j.po_item_sno,
            @grn_basic_sno,
            @gate_entry_sno,
            j.received_qty,
            (ISNULL(j.ordered_qty, 0) - ISNULL(j.received_qty, 0)),
            'Received',
            @created_by,
            j.remarks
        FROM OPENJSON(@items)
        WITH (
            po_item_sno   INT           '$.po_item_sno',
            ordered_qty   DECIMAL(18,2) '$.ordered_qty',
            received_qty  DECIMAL(18,2) '$.received_qty',
            remarks       VARCHAR(500)  '$.remarks'
        ) j;

        INSERT INTO dbo.grn_history_data (
            event_type, po_basic_sno, grn_basic_sno, gate_entry_sno,
            to_status, status_by, remarks
        )
        VALUES (
            'GRN Created', @po_basic_sno, @grn_basic_sno, @gate_entry_sno,
            'Received', @created_by, @remarks
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-'
            + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.gate_entry_sno,
        b.po_basic_sno,
        b.vendor_sno,
        CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
        CONVERT(VARCHAR(30), b.created_date, 120) AS created_at
    FROM dbo.grn_basic_info b
    WHERE b.grn_basic_sno = @grn_basic_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_CreateGstStateRecords
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateGstStateRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        -- Input validation  
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate JSON format  
        IF ISJSON(@jsonInput) = 0  
        BEGIN  
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate required fields  
        IF JSON_VALUE(@jsonInput, '$.gst_state_un_name') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.gst_state_un_name'))) = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'State/Un name is required' as ErrorMessage;  
            RETURN;  
        END  
        
        BEGIN TRANSACTION;     
          
        DECLARE @InsertedCount INT;  
     
        -- Insert records into gst_master table (corrected table name)  
        INSERT INTO [Non_trade_Dev].[dbo].[gst_master](  
            gst_state_un_name,   
            gst_code,
            is_active,
            created_date,
            gst_alpha_code  
        )  
        SELECT   
            LTRIM(RTRIM(gst_state_un_name)) as gst_state_un_name,   
            LTRIM(RTRIM(gst_code)) as gst_code, 
            'Y',
            getDate(),
            LTRIM(RTRIM(gst_alpha_code)) as gst_alpha_code  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            gst_state_un_name VARCHAR(50) '$.gst_state_un_name',  
            gst_code VARCHAR(10) '$.gst_code',  
            gst_alpha_code VARCHAR(5) '$.gst_alpha_code'  
        );  
          
        SET @InsertedCount = @@ROWCOUNT;  
          
        COMMIT TRANSACTION;  
          
        -- Return success message with count  
        SELECT   
            'Success' as Status,   
            CONCAT('Successfully inserted ', @InsertedCount, ' GST record(s)') as Message,  
            @InsertedCount as RecordsInserted;  
              
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
          DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
          
        -- Re-throw the original error  
        THROW;  
    END CATCH  
END
GO
-- [F2. procedures] dbo.sp_nt_CreateInventoryItem
-- ============================================================
-- Additive: surface com_sno/div_sno/brn_sno on write-SP return rows that
-- didn't have them, so the Node layer can compute which org-scoped Socket.IO
-- room(s) to broadcast an event to (see backend-stpl/index.js's new
-- orgRoomsForHierarchy/[domain]:live:com:X[:div:Y[:brn:Z]] room scheme, and
-- grn-service/src/utils/socketBroadcast.js). No behavior change to any
-- existing caller — every change here only ADDS columns to a SELECT.
--
-- Note: sp_nt_CreateInventoryItem's manual "Create Inventory Item" screen
-- has never captured com_sno/div_sno/brn_sno on the INSERT at all (a
-- pre-existing gap, not introduced here) — items created that way will
-- return NULL org columns, which the broadcast helper treats as "fall back
-- to the old unscoped room" rather than silently dropping the event.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_code     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.item_code');
    DECLARE @item_name     VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.item_name');
    DECLARE @category      VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.category');
    DECLARE @sub_category  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.sub_category');
    DECLARE @uom           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.uom');
    DECLARE @current_stock DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.current_stock');
    DECLARE @min_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.min_stock');
    DECLARE @max_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.max_stock');
    DECLARE @reorder_qty   DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.reorder_qty');
    DECLARE @warehouse     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.warehouse');
    DECLARE @location      VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.location');
    DECLARE @cost_price    DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.cost_price');
    DECLARE @selling_price DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.selling_price');
    DECLARE @status        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @hsn_code      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.hsn_code');
    DECLARE @description   VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.description');
    DECLARE @prod_sno      INT           = JSON_VALUE(@jsonInput, '$.prod_sno');
    DECLARE @created_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @item_code IS NULL OR @item_name IS NULL
    BEGIN
        RAISERROR('item_code and item_name are required.', 16, 1);
        RETURN;
    END

    DECLARE @item_sno INT;

    BEGIN TRANSACTION;
    BEGIN TRY
        INSERT INTO dbo.nt_inventory_items (
            item_code, item_name, category, sub_category, uom, current_stock,
            min_stock, max_stock, reorder_qty, warehouse, location, cost_price,
            selling_price, status, hsn_code, description, prod_sno, created_by, created_at
        )
        VALUES (
            @item_code, @item_name, @category, @sub_category, @uom, @current_stock,
            ISNULL(@min_stock, 0), ISNULL(@max_stock, 0), ISNULL(@reorder_qty, 0),
            @warehouse, @location, ISNULL(@cost_price, 0),
            ISNULL(@selling_price, 0), @status, @hsn_code, @description, @prod_sno, @created_by, GETDATE()
        );

        SET @item_sno = SCOPE_IDENTITY();

        IF @current_stock > 0
        BEGIN
            INSERT INTO dbo.nt_stock_movements (
                item_sno, item_code, item_name, movement_type, quantity,
                balance_after, uom, reference_no, warehouse, reason, created_by, created_at
            )
            VALUES (
                @item_sno, @item_code, @item_name, 'IN', @current_stock,
                @current_stock, @uom, NULL, @warehouse, 'Opening Stock', @created_by, GETDATE()
            );
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT item_sno, item_code, item_name, category, uom, current_stock, warehouse, status,
           com_sno, div_sno, brn_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_CreateNonStaffLogin
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateNonStaffLogin
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 51001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @full_name       NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.full_name'),
            @designation_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.designation_sno') AS INT),
            @email           VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.email'),
            @phone           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.phone'),
            @password_hash   VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.password_hash'),
            @created_by      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @full_name IS NULL OR @designation_sno IS NULL
       OR @email IS NULL OR @password_hash IS NULL
    BEGIN
        THROW 51002, N'full_name, designation_sno, email and password_hash are required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.designation_master WHERE designation_sno = @designation_sno AND is_active = 'Y')
    BEGIN
        THROW 51003, N'Unknown or inactive designation_sno.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.nt_nonstaff_login WHERE email = @email AND is_active = 'Y')
    BEGIN
        THROW 51005, N'A user with this email already exists.', 1;
        RETURN;
    END;

    DECLARE @login_id VARCHAR(30) =
        'NSU' + RIGHT('00000' + CAST(NEXT VALUE FOR dbo.seq_nonstaff_login_id AS VARCHAR(5)), 5);

    IF OBJECT_ID('dbo.nt_sign_up', 'U') IS NOT NULL
       AND EXISTS (SELECT 1 FROM dbo.nt_sign_up WHERE ecno = @login_id)
    BEGIN
        THROW 51006, N'Generated login ID collided with an existing staff ecno — retry.', 1;
        RETURN;
    END;

    INSERT INTO dbo.nt_nonstaff_login (
        login_id, full_name, designation_sno, email, phone,
        password_hash, must_reset_password, is_active, created_by
    )
    VALUES (
        @login_id, @full_name, @designation_sno, @email, @phone,
        @password_hash, 'Y', 'Y', @created_by
    );

    SELECT nonstaff_login_sno, login_id, full_name, must_reset_password
    FROM dbo.nt_nonstaff_login WHERE login_id = @login_id;
END;
GO
-- [F2. procedures] dbo.sp_nt_CreatePriorityRecords

 CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreatePriorityRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
       
       
       
      
        BEGIN TRANSACTION;   
        
        DECLARE @InsertedCount INT;
     
        -- Insert records into ac_master table
        INSERT INTO [Non_trade_Dev].[dbo].[priority_master](
            priority_name, 
            priority_desc
        )
        SELECT 
            LTRIM(RTRIM(priority_name)) as priority_name, 
            LTRIM(RTRIM(priority_desc)) as priority_desc
        FROM OPENJSON(@jsonInput)
        WITH (
            priority_name VARCHAR(50) '$.priority_name',
            priority_desc VARCHAR(50) '$.priority_desc'
        );
        
        SET @InsertedCount = @@ROWCOUNT;
        
        COMMIT TRANSACTION;
        
        -- Return success message with count
        SELECT 
            'Success' as Status, 
            CONCAT('Successfully inserted ', @InsertedCount, ' record(s)') as Message,
            @InsertedCount as RecordsInserted;
            
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        
        -- Return detailed error information
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        THROW;
    END CATCH
END

GO
-- [F2. procedures] dbo.sp_nt_CreateProductRecord
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateProductRecord]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    -- ───────────────────────────────────────────
    -- 1. Basic Input Validation
    -- ───────────────────────────────────────────
    IF @jsonInput IS NULL OR LTRIM(RTRIM(@jsonInput)) = ''
    BEGIN
        SELECT 'Failed' AS Status, 'JSON input is required' AS ErrorMessage;
        RETURN;
    END

    IF ISJSON(@jsonInput) = 0
    BEGIN
        SELECT 'Failed' AS Status, 'Invalid JSON format' AS ErrorMessage;
        RETURN;
    END

    -- ───────────────────────────────────────────
    -- 2. Normalize: wrap single object into array
    --    Handles both {} and [{}] inputs transparently
    -- ───────────────────────────────────────────
    DECLARE @normalizedJson NVARCHAR(MAX);

    SET @normalizedJson = CASE
        WHEN LEFT(LTRIM(@jsonInput), 1) = '{'
        THEN '[' + @jsonInput + ']'   -- single object → wrap as array
        ELSE @jsonInput               -- already an array
    END;

    -- Re-validate after normalization
    IF ISJSON(@normalizedJson) = 0
    BEGIN
        SELECT 'Failed' AS Status, 'Invalid JSON structure after normalization' AS ErrorMessage;
        RETURN;
    END

    BEGIN TRY

        -- ───────────────────────────────────────────
        -- 3. Parse JSON Array into Temp Table ONCE
        --    WITH clause = single parse pass (faster)
        --    ROW_NUMBER() used instead of [key]
        --    ([key] not available when WITH clause is used)
        -- ───────────────────────────────────────────
        CREATE TABLE #parsed_input (
            row_index            INT,
            company_sno          INT,
            division_sno         INT,
            branch_sno           INT,
            dept_sno             INT,
            cat_sno              INT,
            subcat_sno           INT,
            prod_name            VARCHAR(255),
            prod_description     VARCHAR(MAX),
            prod_notes           VARCHAR(MAX),
            hsn_code             VARCHAR(50),
            uom_sno              INT,
            tax_sno              INT,
            prod_uom_con_factor  DECIMAL(18,6),
            prod_uom_con_uom_sno INT,
            created_by           VARCHAR(50)
        );

        INSERT INTO #parsed_input
        SELECT
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1  AS row_index,
            company_sno,
            division_sno,
            branch_sno,
            dept_sno,
            cat_sno,
            subcat_sno,
            LTRIM(RTRIM(prod_name))                         AS prod_name,
            LTRIM(RTRIM(ISNULL(prod_description, '')))      AS prod_description,
            LTRIM(RTRIM(ISNULL(prod_notes, '')))            AS prod_notes,
            LTRIM(RTRIM(ISNULL(hsn_code, '')))              AS hsn_code,
            uom_sno,
            tax_sno,
            prod_uom_con_factor,
            prod_uom_con_uom_sno,
            created_by
        FROM OPENJSON(@normalizedJson)
        WITH (
            company_sno          INT             '$.company_sno',
            division_sno         INT             '$.division_sno',
            branch_sno           INT             '$.branch_sno',
            dept_sno             INT             '$.dept_sno',
            cat_sno              INT             '$.cat_sno',
            subcat_sno           INT             '$.subcat_sno',
            prod_name            VARCHAR(255)    '$.prod_name',
            prod_description     VARCHAR(MAX)    '$.prod_description',
            prod_notes           VARCHAR(MAX)    '$.prod_notes',
            hsn_code             VARCHAR(50)     '$.hsn_code',
            uom_sno              INT             '$.uom_sno',
            tax_sno              INT             '$.tax_sno',
            prod_uom_con_factor  DECIMAL(18,6)   '$.prod_uom_con_factor',
            prod_uom_con_uom_sno INT             '$.prod_uom_con_uom_sno',
            created_by           VARCHAR(50)     '$.created_by'
        );

        -- ───────────────────────────────────────────
        -- 4. Row-Level Validation
        --    Collects ALL failures across ALL rows before aborting
        -- ───────────────────────────────────────────
        CREATE TABLE #validation_errors (
            row_index    INT,
            ErrorMessage VARCHAR(500)
        );

        INSERT INTO #validation_errors (row_index, ErrorMessage)
        SELECT row_index, 'cat_sno is required'
            FROM #parsed_input WHERE cat_sno IS NULL
        UNION ALL
        SELECT row_index, 'prod_name is required'
            FROM #parsed_input WHERE prod_name IS NULL OR prod_name = ''
        UNION ALL
        SELECT row_index, 'uom_sno is required'
            FROM #parsed_input WHERE uom_sno IS NULL;

        IF EXISTS (SELECT 1 FROM #validation_errors)
        BEGIN
            SELECT
                'Failed'   AS Status,
                row_index  AS RowIndex,
                ErrorMessage
            FROM #validation_errors
            ORDER BY row_index;

            DROP TABLE #parsed_input;
            DROP TABLE #validation_errors;
            RETURN;
        END

        DROP TABLE #validation_errors;

        -- ───────────────────────────────────────────
        -- 5. Validate All Categories Exist (set-based)
        -- ───────────────────────────────────────────
        IF EXISTS (
            SELECT 1
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            LEFT JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            WHERE cm.cat_sno IS NULL
        )
        BEGIN
            SELECT
                'Failed'             AS Status,
                pi.cat_sno           AS InvalidCatSno,
                'Category not found' AS ErrorMessage
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            LEFT JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            WHERE cm.cat_sno IS NULL;

            DROP TABLE #parsed_input;
            RETURN;
        END

        -- ───────────────────────────────────────────
        -- 5b. Validate product-specific UOM conversion factor + unit
        --     A non-base UOM with no fixed uom_master.uom_con_factor (e.g.
        --     Box, Tin) varies per product, so prod_uom_con_factor AND
        --     prod_uom_con_uom_sno must both be supplied. The chosen
        --     conversion unit must exist and belong to the SAME uom_class as
        --     the product's own uom_sno (a Tin's contents can only be
        --     expressed in a MASS unit, never a VOLUME/LENGTH one).
        -- ───────────────────────────────────────────
        IF EXISTS (
            SELECT 1
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND (pi.prod_uom_con_factor IS NULL OR pi.prod_uom_con_factor <= 0)
        )
        BEGIN
            SELECT
                'Failed'                                                    AS Status,
                pi.row_index                                                AS RowIndex,
                'prod_uom_con_factor is required for unit ' + um.uom_name +
                    ' (its conversion is not fixed and varies per product)' AS ErrorMessage
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND (pi.prod_uom_con_factor IS NULL OR pi.prod_uom_con_factor <= 0);

            DROP TABLE #parsed_input;
            RETURN;
        END

        IF EXISTS (
            SELECT 1
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND pi.prod_uom_con_uom_sno IS NULL
        )
        BEGIN
            SELECT
                'Failed'                                                    AS Status,
                pi.row_index                                                AS RowIndex,
                'prod_uom_con_uom_sno is required for unit ' + um.uom_name +
                    ' (choose the unit the quantity above is expressed in)' AS ErrorMessage
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND pi.prod_uom_con_uom_sno IS NULL;

            DROP TABLE #parsed_input;
            RETURN;
        END

        IF EXISTS (
            SELECT 1
            FROM #parsed_input pi
            JOIN uom_master um    ON um.uom_sno = pi.uom_sno
            LEFT JOIN uom_master cu ON cu.uom_sno = pi.prod_uom_con_uom_sno
            WHERE pi.prod_uom_con_uom_sno IS NOT NULL
              AND (cu.uom_sno IS NULL OR cu.uom_class <> um.uom_class)
        )
        BEGIN
            SELECT
                'Failed'                                                        AS Status,
                pi.row_index                                                    AS RowIndex,
                'prod_uom_con_uom_sno must be a valid unit of the same class (' +
                    um.uom_class + ') as ' + um.uom_name                        AS ErrorMessage
            FROM #parsed_input pi
            JOIN uom_master um    ON um.uom_sno = pi.uom_sno
            LEFT JOIN uom_master cu ON cu.uom_sno = pi.prod_uom_con_uom_sno
            WHERE pi.prod_uom_con_uom_sno IS NOT NULL
              AND (cu.uom_sno IS NULL OR cu.uom_class <> um.uom_class);

            DROP TABLE #parsed_input;
            RETURN;
        END

        -- ───────────────────────────────────────────
        -- 6. Generate Product Codes — set-based per category
        --    MAX existing seq fetched once per category (with lock)
        --    ROW_NUMBER() per cat assigns each new row its offset
        -- ───────────────────────────────────────────
        CREATE TABLE #products_with_code (
            row_index            INT,
            company_sno          INT,
            division_sno         INT,
            branch_sno           INT,
            dept_sno             INT,
            cat_sno              INT,
            subcat_sno           INT,
            prod_name            VARCHAR(255),
            prod_description     VARCHAR(MAX),
            prod_notes           VARCHAR(MAX),
            prod_code            VARCHAR(50),
            hsn_code             VARCHAR(50),
            uom_sno              INT,
            tax_sno              INT,
            prod_uom_con_factor  DECIMAL(18,6),
            prod_uom_con_uom_sno INT,
            created_by           VARCHAR(50)
        );

        ;WITH CategoryPrefix AS (
            SELECT
                cm.cat_sno,
                cm.cat_notes AS cat_prefix,
                ISNULL(MAX(
                    CASE
                        WHEN ISNUMERIC(
                            SUBSTRING(pm.prod_code, LEN(cm.cat_notes) + 1, LEN(pm.prod_code))
                        ) = 1
                        THEN CAST(
                            SUBSTRING(pm.prod_code, LEN(cm.cat_notes) + 1, LEN(pm.prod_code))
                        AS INT)
                        ELSE 0
                    END
                ), 0) AS max_seq
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            LEFT JOIN product_master pm WITH (UPDLOCK, ROWLOCK)
                ON  pm.cat_sno   = cm.cat_sno
                AND pm.prod_code LIKE cm.cat_notes + '%'
            GROUP BY cm.cat_sno, cm.cat_notes
        ),
        RankedRows AS (
            SELECT
                pi.*,
                cp.cat_prefix,
                cp.max_seq,
                ROW_NUMBER() OVER (
                    PARTITION BY pi.cat_sno
                    ORDER BY pi.row_index
                ) AS rn
            FROM #parsed_input pi
            JOIN CategoryPrefix cp ON cp.cat_sno = pi.cat_sno
        )
        INSERT INTO #products_with_code
        SELECT
            row_index,
            company_sno,
            division_sno,
            branch_sno,
            dept_sno,
            cat_sno,
            subcat_sno,
            prod_name,
            prod_description,
            prod_notes,
            cat_prefix + RIGHT('00000' + CAST((max_seq + rn) AS VARCHAR(5)), 5) AS prod_code,
            hsn_code,
            uom_sno,
            tax_sno,
            prod_uom_con_factor,
            prod_uom_con_uom_sno,
            created_by
        FROM RankedRows;

        DROP TABLE #parsed_input;

        -- ───────────────────────────────────────────
        -- 7. Bulk Insert with OUTPUT clause
        --    All prod_sno values captured safely — no SCOPE_IDENTITY() race
        -- ───────────────────────────────────────────
        CREATE TABLE #inserted_results (
            prod_sno  INT,
            prod_code VARCHAR(50)
        );

        BEGIN TRANSACTION;

            INSERT INTO [dbo].[product_master] (
                company_sno,
                division_sno,
                branch_sno,
                dept_sno,
                cat_sno,
                subcat_sno,
                prod_name,
                prod_description,
                prod_notes,
                prod_code,
                uom_sno,
                tax_sno,
                prod_hsn_code,
                prod_uom_con_factor,
                prod_uom_con_uom_sno,
                prod_active,
                prod_created_date,
                prod_created_by
            )
            OUTPUT
                INSERTED.prod_sno,
                INSERTED.prod_code
            INTO #inserted_results (prod_sno, prod_code)
            SELECT
                company_sno,
                division_sno,
                branch_sno,
                dept_sno,
                cat_sno,
                subcat_sno,
                prod_name,
                prod_description,
                prod_notes,
                prod_code,
                uom_sno,
                tax_sno,
                hsn_code             AS prod_hsn_code,
                prod_uom_con_factor,
                prod_uom_con_uom_sno,
                'Y'                  AS prod_active,
                GETDATE()            AS prod_created_date,
                created_by           AS prod_created_by
            FROM #products_with_code
            ORDER BY row_index;

        COMMIT TRANSACTION;

        -- ───────────────────────────────────────────
        -- 8. Return Results — joined via prod_code
        -- ───────────────────────────────────────────
        SELECT
            'Success'                       AS Status,
            'Product inserted successfully' AS Message,
            ir.prod_sno,
            ir.prod_code,
            pwc.prod_name,
            pwc.cat_sno,
            pwc.row_index                   AS InputRowIndex
        FROM #inserted_results ir
        JOIN #products_with_code pwc ON pwc.prod_code = ir.prod_code
        ORDER BY pwc.row_index;

        DROP TABLE #products_with_code;
        DROP TABLE #inserted_results;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        IF OBJECT_ID('tempdb..#parsed_input')       IS NOT NULL DROP TABLE #parsed_input;
        IF OBJECT_ID('tempdb..#validation_errors')  IS NOT NULL DROP TABLE #validation_errors;
        IF OBJECT_ID('tempdb..#products_with_code') IS NOT NULL DROP TABLE #products_with_code;
        IF OBJECT_ID('tempdb..#inserted_results')   IS NOT NULL DROP TABLE #inserted_results;

        SELECT
            'Failed'        AS Status,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_NUMBER()  AS ErrorNumber,
            ERROR_LINE()    AS ErrorLine;
    END CATCH
END
GO
-- [F2. procedures] dbo.sp_nt_CreateProductStockLevel  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateProductStockLevel
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 59501, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @prod_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.prod_sno') AS INT),
            @scope_type     VARCHAR(10)   = JSON_VALUE(@jsonInput, '$.scope_type'),
            @com_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
            @div_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT),
            @brn_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT),
            @location_sno   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.location_sno') AS INT),
            @min_qty        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.min_qty') AS DECIMAL(18,2)),
            @max_qty        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.max_qty') AS DECIMAL(18,2)),
            @reorder_level  DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.reorder_level') AS DECIMAL(18,2)),
            @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @prod_sno IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.product_master WHERE prod_sno = @prod_sno)
    BEGIN
        THROW 59502, N'A valid product must be selected.', 1;
        RETURN;
    END;

    IF @scope_type NOT IN ('ORG','LOCATION')
    BEGIN
        THROW 59503, N'scope_type must be either ORG or LOCATION.', 1;
        RETURN;
    END;

    IF @min_qty IS NULL OR @max_qty IS NULL OR @reorder_level IS NULL
    BEGIN
        THROW 59504, N'Min Qty, Max Qty and Reorder Level are all required.', 1;
        RETURN;
    END;

    IF @min_qty < 0 OR @max_qty < 0 OR @reorder_level < 0
    BEGIN
        THROW 59505, N'Min Qty, Max Qty and Reorder Level cannot be negative.', 1;
        RETURN;
    END;

    IF @min_qty > @max_qty
    BEGIN
        THROW 59506, N'Min Qty cannot be greater than Max Qty.', 1;
        RETURN;
    END;

    IF @reorder_level < @min_qty OR @reorder_level > @max_qty
    BEGIN
        THROW 59507, N'Reorder Level must be between Min Qty and Max Qty.', 1;
        RETURN;
    END;

    IF @scope_type = 'ORG'
    BEGIN
        SET @location_sno = NULL;

        IF @com_sno IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.company_master WHERE com_sno = @com_sno)
        BEGIN
            THROW 59508, N'A valid company must be selected for an Org-scoped entry.', 1;
            RETURN;
        END;

        IF @div_sno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.division_master WHERE div_sno = @div_sno AND com_sno = @com_sno)
        BEGIN
            THROW 59509, N'Selected division does not belong to the selected company.', 1;
            RETURN;
        END;

        IF @brn_sno IS NOT NULL AND @div_sno IS NULL
        BEGIN
            THROW 59510, N'A branch cannot be selected without also selecting its division.', 1;
            RETURN;
        END;

        IF @brn_sno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.branch_master WHERE brn_sno = @brn_sno AND com_sno = @com_sno AND div_sno = @div_sno)
        BEGIN
            THROW 59511, N'Selected branch does not belong to the selected company/division.', 1;
            RETURN;
        END;

        IF EXISTS (
            SELECT 1 FROM dbo.product_stock_level_master
            WHERE prod_sno = @prod_sno AND scope_type = 'ORG' AND is_active = 'Y'
              AND com_sno = @com_sno
              AND ISNULL(div_sno, -1) = ISNULL(@div_sno, -1)
              AND ISNULL(brn_sno, -1) = ISNULL(@brn_sno, -1)
        )
        BEGIN
            THROW 59512, N'This product already has stock levels configured for this exact Company/Division/Branch scope.', 1;
            RETURN;
        END;
    END
    ELSE  -- LOCATION
    BEGIN
        SET @com_sno = NULL; SET @div_sno = NULL; SET @brn_sno = NULL;

        IF @location_sno IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.warehouse_location_master WHERE location_sno = @location_sno AND is_active = 'Y')
        BEGIN
            THROW 59513, N'A valid warehouse location must be selected.', 1;
            RETURN;
        END;

        IF EXISTS (
            SELECT 1 FROM dbo.product_stock_level_master
            WHERE prod_sno = @prod_sno AND scope_type = 'LOCATION' AND is_active = 'Y' AND location_sno = @location_sno
        )
        BEGIN
            THROW 59514, N'This product already has stock levels configured for this warehouse location.', 1;
            RETURN;
        END;
    END;

    INSERT INTO dbo.product_stock_level_master (
        prod_sno, scope_type, com_sno, div_sno, brn_sno, location_sno,
        min_qty, max_qty, reorder_level, is_active, created_by
    )
    VALUES (
        @prod_sno, @scope_type, @com_sno, @div_sno, @brn_sno, @location_sno,
        @min_qty, @max_qty, @reorder_level, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY() AS stock_level_sno, N'SUCCESS' AS status,
           N'Stock level configuration saved successfully.' AS message;
END;
GO
-- [F2. procedures] dbo.sp_nt_CreateRecurrenceCadenceRecords
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateRecurrenceCadenceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 58008, N'Invalid JSON payload provided.', 1;

    DECLARE @cadence_code   VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.cadence_code'),
            @cadence_name   NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.cadence_name'),
            @interval_unit  VARCHAR(10)   = UPPER(JSON_VALUE(@jsonInput, '$.interval_unit')),
            @interval_value INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.interval_value') AS INT),
            @description    NVARCHAR(200) = JSON_VALUE(@jsonInput, '$.description'),
            @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cadence_code IS NULL OR @cadence_name IS NULL OR @interval_unit IS NULL OR @interval_value IS NULL
        THROW 58009, N'cadence_code, cadence_name, interval_unit and interval_value are required.', 1;
    IF @interval_unit NOT IN ('DAY','MONTH') THROW 58010, N'interval_unit must be DAY or MONTH.', 1;
    IF @interval_value <= 0 THROW 58011, N'interval_value must be positive.', 1;
    IF EXISTS (SELECT 1 FROM dbo.recurrence_cadence_master WHERE cadence_code = @cadence_code)
        THROW 58012, N'A recurrence cadence with this code already exists.', 1;

    INSERT INTO dbo.recurrence_cadence_master (cadence_code, cadence_name, interval_unit, interval_value, description, is_active, created_by)
    VALUES (@cadence_code, @cadence_name, @interval_unit, @interval_value, @description, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS recurrence_cadence_sno, @cadence_code AS cadence_code, N'SUCCESS' AS status;
END;
GO
-- [F2. procedures] dbo.sp_nt_CreateServiceAgreement
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @terms_conditions   NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @vendors_json       NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.vendors');
        DECLARE @statutory_json     NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory');

        -- The first supplier in the split is the primary (service_agreement.vendor_sno).
        IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1
            SET @vendor_sno = ISNULL(TRY_CAST(JSON_VALUE(@vendors_json, '$[0].vendor_sno') AS INT), @vendor_sno);

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @vendor_sno IS NULL OR @created_by IS NULL
            THROW 58101, 'com_sno, div_sno, brn_sno, dept_sno, service_sno, at least one supplier and created_by are required.', 1;

        IF @qty IS NULL OR @qty <= 0
            THROW 58102, 'qty must be a positive quantity.', 1;

        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58103, 'rate_amount must be a positive amount (an approximate value is fine for an Unfixed or Statutory agreement).', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58104, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58105, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        IF @recurrence_cadence_sno IS NULL
            THROW 58106, 'recurrence_cadence_sno is required — see sp_nt_GetRecurrenceCadenceRecords for valid options.', 1;

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58107, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;

        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58108, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';

        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING', 'STATUTORY')
            THROW 58109, 'service_sno must reference an active Fixed, Unfixed or Statutory service.', 1;

        IF @service_type_code = 'FIXED_RECURRING'
            SET @ceiling_amount = NULL;
        ELSE IF @ceiling_amount IS NOT NULL AND @ceiling_amount <= 0
            THROW 58112, 'ceiling_amount must be a positive amount when provided.', 1;

        -- ── Resolve the ServiceAgreement workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';

        IF @workflow_types_id IS NULL
            THROW 58110, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 58111, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(agreement_no, 4) AS INT)), 0) + 1
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_no LIKE 'AGR-' + @year + '-%';
        DECLARE @agreement_no VARCHAR(30) = 'AGR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_agreement (
            agreement_no, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            qty, rate_amount, rate_uom_sno, recurrence_cadence_sno, po_generation_day, notify_days_before,
            period_start_date, period_end_date, agreement_doc_url, remarks, terms_conditions, ceiling_amount,
            workflow_types_id, current_approver_id, status, is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @qty, @rate_amount, @rate_uom_sno, @recurrence_cadence_sno, @po_generation_day, @notify_days_before,
            @period_start_date, @period_end_date, @agreement_doc_url, @remarks, @terms_conditions, @ceiling_amount,
            @workflow_types_id, @first_approver, 'P', 'Y', @created_by
        );

        DECLARE @agreement_sno INT = SCOPE_IDENTITY();

        DECLARE @total_per_cycle DECIMAL(18,2) = ROUND(@rate_amount * @qty, 2), @primary_vendor INT;
        EXEC dbo.sp_nt_SaveServiceAgreementSuppliers
            @agreement_sno = @agreement_sno, @vendors_json = @vendors_json, @fallback_vendor_sno = @vendor_sno,
            @total_amount = @total_per_cycle, @out_primary_vendor_sno = @primary_vendor OUTPUT;
        IF @primary_vendor IS NOT NULL AND @primary_vendor <> @vendor_sno
            UPDATE dbo.service_agreement SET vendor_sno = @primary_vendor WHERE agreement_sno = @agreement_sno;

        EXEC dbo.sp_nt_SaveServiceAgreementStatutory
            @agreement_sno = @agreement_sno, @service_type_code = @service_type_code, @statutory_json = @statutory_json;

        DECLARE @version_no INT;
        EXEC dbo.sp_nt_SnapshotServiceAgreementVersion
            @agreement_sno = @agreement_sno, @action_type = 'SUBMITTED', @submitted_by = @created_by,
            @out_version_no = @version_no OUTPUT;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, 'SUBMITTED', @created_by, NULL, @version_no);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, @agreement_no AS agreement_no, 'SUCCESS' AS result,
               N'Service agreement submitted for approval.' AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_CreateServiceRecords
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateServiceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 58004, N'Invalid JSON payload provided.', 1;

    DECLARE @service_name     NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.service_name'),
            @service_code     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.service_code'),
            @service_type_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT),
            @default_uom_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.default_uom_sno') AS INT),
            @description      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.description'),
            @created_by       VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_name IS NULL OR @service_code IS NULL OR @service_type_sno IS NULL
        THROW 58005, N'service_name, service_code and service_type_sno are required.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_sno = @service_type_sno AND is_active = 'Y')
        THROW 58006, N'service_type_sno does not reference an active service type.', 1;

    IF EXISTS (SELECT 1 FROM dbo.service_master WHERE service_code = @service_code)
        THROW 58007, N'A service with this code already exists.', 1;

    INSERT INTO dbo.service_master (service_name, service_code, service_type_sno, default_uom_sno, description, is_active, created_by)
    VALUES (@service_name, @service_code, @service_type_sno, @default_uom_sno, @description, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS service_sno, @service_code AS service_code, N'SUCCESS' AS status;
END;
GO
-- [F2. procedures] dbo.sp_nt_CreateServiceTypeRecords
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateServiceTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 58001, N'Invalid JSON payload provided.', 1;

    DECLARE @service_type_code VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.service_type_code'),
            @service_type_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.service_type_name'),
            @created_by        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_type_code IS NULL OR @service_type_name IS NULL
        THROW 58002, N'service_type_code and service_type_name are required.', 1;

    IF EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_code = @service_type_code)
        THROW 58003, N'A service type with this code already exists.', 1;

    INSERT INTO dbo.service_type_master (service_type_code, service_type_name, is_active, created_by)
    VALUES (@service_type_code, @service_type_name, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS service_type_sno, @service_type_code AS service_type_code, N'SUCCESS' AS status;
END;
GO
-- [F2. procedures] dbo.sp_nt_CreateSubCategoryRecords
-- ============================================================
-- sp_nt_CreateSubCategoryRecords — accept + validate perishable_days
-- Only additive: everything except the marked lines is unchanged from the
-- live definition (pulled via OBJECT_DEFINITION before editing).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateSubCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @cat_sno            INT           = JSON_VALUE(@jsonInput, '$.cat_sno'),
            @subcat_name        NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.subcat_name'),
            @subcat_description NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.subcat_description'),
            @subcat_notes       NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.subcat_notes'),
            @subcat_stock_type  VARCHAR(20)   = ISNULL(NULLIF(JSON_VALUE(@jsonInput, '$.subcat_stock_type'), ''), 'Regular'),
            @perishable_days    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.perishable_days') AS INT),
            @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cat_sno IS NULL OR @subcat_name IS NULL OR LTRIM(RTRIM(@subcat_name)) = ''
    BEGIN
        THROW 50002, N'cat_sno and subcat_name are required.', 1;
        RETURN;
    END;

    IF @subcat_stock_type NOT IN ('Regular', 'Non-Regular', 'Perishable')
    BEGIN
        THROW 50005, N'subcat_stock_type must be Regular, Non-Regular or Perishable.', 1;
        RETURN;
    END;

    -- New: perishable_days is mandatory (and > 0, enforced by the CHECK
    -- constraint too) only when the subcategory is Perishable; ignored/
    -- cleared otherwise so a stray value from the form can't leak in.
    IF @subcat_stock_type = 'Perishable' AND (@perishable_days IS NULL OR @perishable_days <= 0)
    BEGIN
        THROW 50006, N'perishable_days is required and must be greater than zero when subcat_stock_type is Perishable.', 1;
        RETURN;
    END;

    IF @subcat_stock_type <> 'Perishable'
        SET @perishable_days = NULL;

    IF NOT EXISTS (SELECT 1 FROM dbo.category_master WHERE cat_sno = @cat_sno AND cat_active = 'Y')
    BEGIN
        THROW 50003, N'Category not found.', 1;
        RETURN;
    END;

    IF EXISTS (
        SELECT 1 FROM dbo.subcategory_master
        WHERE cat_sno = @cat_sno AND subcat_name = @subcat_name AND subcat_active = 'Y'
    )
    BEGIN
        THROW 50004, N'A sub category with this name already exists under the selected category.', 1;
        RETURN;
    END;

    INSERT INTO dbo.subcategory_master (
        cat_sno, subcat_name, subcat_description, subcat_notes, subcat_stock_type, perishable_days,
        subcat_active, subcat_created_date, subcat_created_by
    )
    VALUES (
        @cat_sno, @subcat_name, @subcat_description, @subcat_notes, @subcat_stock_type, @perishable_days,
        'Y', GETDATE(), @created_by
    );

    SELECT SCOPE_IDENTITY()   AS subcat_sno,
           @subcat_name       AS subcat_name,
           @subcat_stock_type AS subcat_stock_type,
           @perishable_days   AS perishable_days,
           N'SUCCESS'         AS status,
           N'Sub category created successfully.' AS message;
END;
GO
-- [F2. procedures] dbo.sp_nt_CreateUomRecords
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateUomRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        -- Input validation  
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate JSON format  
        IF ISJSON(@jsonInput) = 0  
        BEGIN  
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate required fields  
        IF JSON_VALUE(@jsonInput, '$.uom_code') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.uom_code'))) = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'uom_code is required' as ErrorMessage;  
            RETURN;  
        END  
        
        BEGIN TRANSACTION;     
          
        DECLARE @InsertedCount INT;  
       
        -- Insert records into uom_master table  
        INSERT INTO [Non_trade_Dev].[dbo].[uom_master](  
            uom_code,   
            uom_name,   
            uom_class,  
            uom_base_uom_flag,
            is_active,
            created_date,
            uom_con_factor
            
        )  
        SELECT   
            LTRIM(RTRIM(uom_code)) as uom_code,   
            LTRIM(RTRIM(uom_name)) as uom_name,   
            LTRIM(RTRIM(uom_class)) as uom_class,  
            LTRIM(RTRIM(uom_base_uom_flag)) as uom_base_uom_flag,
            'Y',
            getDate(),
            uom_con_factor  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            uom_code CHAR(5) '$.uom_code',  
            uom_name VARCHAR(50) '$.uom_name',  
            uom_class VARCHAR(30) '$.uom_class',  
            uom_base_uom_flag CHAR(1) '$.uom_base_uom_flag',  
            uom_con_factor DECIMAL(18,6) '$.uom_con_factor'  
        )  
          
        SET @InsertedCount = @@ROWCOUNT;  
          
        COMMIT TRANSACTION;  
          
        -- Return success message with count  
        SELECT   
            'Success' as Status,   
            CONCAT('Successfully inserted ', @InsertedCount, ' UOM record(s)') as Message,  
            @InsertedCount as RecordsInserted;  
              
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
        -- Return detailed error information  
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
          
        -- Re-throw the original error  
        THROW;  
    END CATCH  
END  
GO
-- [F2. procedures] dbo.sp_nt_CreateVendorDrivenPOFromPR  (new)
-- ============================================================
-- sp_nt_CreateVendorDrivenPOFromPR — sources vendor/rate/gst/discount from
-- the extension tables when building the PO. Its final SELECT is extended
-- (was just po_basic_sno/po_no/result) to also return the vendor's contact
-- info, dates, and a FOR JSON PATH item array, so the Node approval path
-- can auto-email the PO to the vendor in one round trip after final
-- approval (see PR.controller.js#approvePr and PRApprovalScreen.tsx).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateVendorDrivenPOFromPR
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @pr_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT),
        @created_by VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.created_by'), ''),
        @vendor_sno INT,
        @com_sno INT,
        @div_sno INT,
        @brn_sno INT,
        @dept_sno INT,
        @required_date DATE,
        @purpose NVARCHAR(500),
        @workflow_types_id INT,
        @po_basic_sno INT,
        @po_no VARCHAR(50),
        @sequence_number INT;

    IF @pr_basic_sno IS NULL OR @created_by IS NULL
        THROW 59020, 'pr_basic_sno and created_by are required.', 1;

    SELECT
        @vendor_sno = pvd.vendor_sno,
        @com_sno = p.com_sno,
        @div_sno = p.div_sno,
        @brn_sno = p.brn_sno,
        @dept_sno = p.dept_sno,
        @required_date = p.required_date,
        @purpose = p.purpose,
        @workflow_types_id = p.workflow_types_id
    FROM dbo.pr_basic_info p WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN dbo.pr_vendor_driven_info pvd ON pvd.pr_basic_sno = p.pr_basic_sno
    WHERE p.pr_basic_sno = @pr_basic_sno
      AND p.request_mode = 'VENDOR_DRIVEN'
      AND p.status = 'A'
      AND p.is_active = 'Y';

    IF @vendor_sno IS NULL
        THROW 59021, 'Vendor-driven PR not found or not finally approved.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @po_basic_sno = po_basic_sno, @po_no = po_df_no
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_basic_sno = @pr_basic_sno
          AND vendor_sno = @vendor_sno
          AND is_active = 'Y';

        IF @po_basic_sno IS NULL
        BEGIN
            SELECT @sequence_number = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
            FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
            WHERE po_df_no LIKE 'VPO-' + CAST(YEAR(GETDATE()) AS VARCHAR(4)) + '-%';

            SET @po_no = 'VPO-' + CAST(YEAR(GETDATE()) AS VARCHAR(4)) + '-'
                + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

            INSERT INTO dbo.po_request_info (
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno, pr_basic_sno,
                po_date, required_date, purpose, is_active, workflow_types_id,
                current_approver_id, status, po_df_no
            )
            VALUES (
                @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, @pr_basic_sno,
                CAST(GETDATE() AS DATE), @required_date, @purpose, 'Y', @workflow_types_id,
                NULL, 'A', @po_no
            );

            SET @po_basic_sno = SCOPE_IDENTITY();

            INSERT INTO dbo.po_item_details (
                po_basic_sno, pr_item_sno, prod_sno, prod_name, specification,
                qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct,
                tax_pct, net_cost, remarks, po_section, created_by, created_date, is_active
            )
            SELECT
                @po_basic_sno,
                pid.pr_item_sno,
                pid.prod_sno,
                COALESCE(pid.item_description, product.prod_name),
                pid.specification,
                pid.qty,
                pid.unit,
                uom.uom_name,
                pvid.item_rate,
                pvid.taxable_amount,
                pvid.discount_pct,
                pvid.gst_pct,
                pid.total_cost,
                pid.remarks,
                'MATERIAL',
                @created_by,
                GETDATE(),
                '1'
            FROM dbo.pr_item_details pid
            INNER JOIN dbo.pr_vendor_driven_item_details pvid ON pvid.pr_item_sno = pid.pr_item_sno
            LEFT JOIN dbo.product_master product ON product.prod_sno = pid.prod_sno
            LEFT JOIN dbo.uom_master uom ON uom.uom_sno = pid.unit
            WHERE pid.pr_basic_sno = @pr_basic_sno
              AND pid.is_active = 'Y';

            IF @@ROWCOUNT = 0
                THROW 59022, 'Vendor-driven PR has no active item lines.', 1;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        @po_basic_sno AS po_basic_sno,
        @po_no AS po_no,
        'SUCCESS' AS result,
        CONVERT(VARCHAR(10), po.po_date, 120) AS po_date,
        CONVERT(VARCHAR(10), po.required_date, 120) AS required_date,
        po.purpose,
        po.vendor_sno,
        k.company_name,
        k.email,
        (
            SELECT
                poi.prod_name,
                poi.qty,
                poi.unit_name,
                poi.agreed_unit_price AS rate,
                poi.discount_pct,
                poi.tax_pct AS gst_pct,
                poi.net_cost AS total_amount
            FROM dbo.po_item_details poi
            WHERE poi.po_basic_sno = @po_basic_sno
              AND poi.is_active = '1'
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info po
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = po.vendor_sno
    WHERE po.po_basic_sno = @po_basic_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_CreateWorkflowMaster
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateWorkflowMaster]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        -- Input validation
        IF @jsonInput IS NULL OR @jsonInput = ''
        BEGIN
            SELECT 'Failed' AS Status, 'JSON input is required' AS ErrorMessage;
            RETURN;
        END

        -- Validate JSON format
        IF ISJSON(@jsonInput) = 0
        BEGIN
            SELECT 'Failed' AS Status, 'Invalid JSON format' AS ErrorMessage;
            RETURN;
        END

        BEGIN TRANSACTION;

        DECLARE @InsertedCount INT;

        -- Insert records into approval_workflow_master
        INSERT INTO [Non_trade_Dev].[dbo].[approval_workflow_master] (
            workflow_name,
            workflow_code,
            entity_type,
            [description],
            is_active,
            created_by,
            created_at
        )
        SELECT
            LTRIM(RTRIM(workflow_name))   AS workflow_name,
            LTRIM(RTRIM(workflow_code))   AS workflow_code,
            LTRIM(RTRIM(entity_type))     AS entity_type,
            [description],
            ISNULL(is_active, 'Y')        AS is_active,   -- default 'Y' if not provided
            created_by,
            ISNULL(created_at, GETDATE()) AS created_at   -- default current timestamp
        FROM OPENJSON(@jsonInput)
        WITH (
            workflow_name  VARCHAR(200) '$.workflow_name',
            workflow_code  VARCHAR(100) '$.workflow_code',
            entity_type    VARCHAR(100) '$.entity_type',
            [description]  NVARCHAR(MAX) '$.description',
            is_active      CHAR(1)       '$.is_active',
            created_by     INT           '$.created_by',
            created_at     DATETIME      '$.created_at'
        );

        SET @InsertedCount = @@ROWCOUNT;

        COMMIT TRANSACTION;

        -- Return success message with count
        SELECT
            'Success'                                                    AS Status,
            CONCAT('Successfully inserted ', @InsertedCount, ' workflow record(s)') AS Message,
            @InsertedCount                                               AS RecordsInserted;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber   INT            = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();

        -- Return structured error instead of re-throwing (optional: use THROW to bubble up)
        SELECT
            'Failed'         AS Status,
            @ErrorMessage    AS ErrorMessage,
            @ErrorNumber     AS ErrorNumber,
            @ErrorSeverity   AS ErrorSeverity;

        -- Uncomment below if you want to re-throw to the caller instead:
        -- THROW;
    END CATCH
END

GO
-- [F2. procedures] dbo.sp_nt_DeleteInventoryItem
CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno   INT         = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @updated_by VARCHAR(50) = JSON_VALUE(@jsonInput, '$.updated_by');

    UPDATE dbo.nt_inventory_items
    SET status     = 'Discontinued',
        updated_by = @updated_by,
        updated_at = GETDATE()
    WHERE item_sno = @item_sno;

    SELECT item_sno, item_code, item_name, status, com_sno, div_sno, brn_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_DeleteLoanPrincipalTxn  (new)
-- @jsonInput: { txn_sno } — only a manually entered movement, and only for a period not yet billed.
CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteLoanPrincipalTxn
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @txn_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.txn_sno') AS INT);
        IF @txn_sno IS NULL THROW 58460, 'txn_sno is required.', 1;

        BEGIN TRANSACTION;
        DECLARE @agreement_sno INT, @txn_date DATE, @voucher_sno INT, @active CHAR(1), @cap DECIMAL(18,2);
        SELECT @agreement_sno = t.agreement_sno, @txn_date = t.txn_date, @voucher_sno = t.voucher_sno, @active = t.is_active,
               @cap = CASE WHEN s.facility_type = 'CASH_CREDIT' THEN ISNULL(s.drawing_power, s.sanctioned_amount) ELSE s.sanctioned_amount END
        FROM dbo.loan_principal_txn t WITH (UPDLOCK)
        JOIN dbo.service_agreement_statutory s ON s.agreement_sno = t.agreement_sno
        WHERE t.txn_sno = @txn_sno;

        IF @agreement_sno IS NULL OR @active <> 'Y' THROW 58468, 'Principal movement not found.', 1;
        IF @voucher_sno IS NOT NULL THROW 58469, 'This repayment came from a bank payment voucher and cannot be removed here.', 1;

        DECLARE @locked DATE = dbo.fn_LoanLockedThrough(@agreement_sno), @msg NVARCHAR(400);
        IF @txn_date < @locked
        BEGIN
            SET @msg = N'This movement falls in a period that is already billed (up to ' + CONVERT(NVARCHAR(11), @locked, 106) + N') and cannot be removed.';
            THROW 58465, @msg, 1;
        END

        UPDATE dbo.loan_principal_txn SET is_active = 'N' WHERE txn_sno = @txn_sno;

        IF EXISTS (
            SELECT 1 FROM (SELECT DISTINCT txn_date AS d FROM dbo.loan_principal_txn WHERE agreement_sno = @agreement_sno AND is_active = 'Y' AND txn_date >= @txn_date) x
            WHERE dbo.fn_LoanPrincipalAt(@agreement_sno, x.d) < 0 OR dbo.fn_LoanPrincipalAt(@agreement_sno, x.d) > @cap
        )
            THROW 58467, 'Removing this movement would leave a later repayment or drawdown out of range. Remove those first.', 1;

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, @txn_sno AS txn_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_DeleteLoanRatePeriod  (new)
-- @jsonInput: { rate_period_sno }
CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteLoanRatePeriod
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @rate_period_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_period_sno') AS INT);
        IF @rate_period_sno IS NULL THROW 58450, 'rate_period_sno is required.', 1;

        BEGIN TRANSACTION;
        DECLARE @agreement_sno INT, @effective_from DATE;
        SELECT @agreement_sno = agreement_sno, @effective_from = effective_from FROM dbo.loan_rate_period WITH (UPDLOCK) WHERE rate_period_sno = @rate_period_sno;
        IF @agreement_sno IS NULL THROW 58459, 'Rate entry not found.', 1;

        DECLARE @locked DATE = dbo.fn_LoanLockedThrough(@agreement_sno), @msg NVARCHAR(400);
        IF @effective_from < @locked
        BEGIN
            SET @msg = N'This rate falls in a period that is already billed (up to ' + CONVERT(NVARCHAR(11), @locked, 106) + N') and cannot be removed.';
            THROW 58453, @msg, 1;
        END

        DELETE FROM dbo.loan_rate_period WHERE rate_period_sno = @rate_period_sno;
        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, @rate_period_sno AS rate_period_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_DeleteProductStockLevel  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteProductStockLevel
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @stock_level_sno INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.stock_level_sno') AS INT),
            @modified_by     VARCHAR(20) = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @stock_level_sno IS NULL
    BEGIN
        THROW 59520, N'stock_level_sno is required.', 1;
        RETURN;
    END;

    UPDATE dbo.product_stock_level_master
    SET is_active = 'N', modified_by = @modified_by, modified_date = GETDATE()
    WHERE stock_level_sno = @stock_level_sno;

    SELECT @stock_level_sno AS stock_level_sno, N'SUCCESS' AS status,
           N'Stock level configuration deleted successfully.' AS message;
END;
GO
-- [F2. procedures] dbo.sp_nt_DirectIssueServicePO
CREATE OR ALTER PROCEDURE dbo.sp_nt_DirectIssueServicePO
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @com_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno     INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @vendor_sno   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @pr_basic_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);
        DECLARE @pr_item_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_item_sno') AS INT);
        DECLARE @service_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @qty          DECIMAL(18,4) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4)), 1);
        DECLARE @uom_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.uom_sno') AS INT);
        DECLARE @unit_price   DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit_price') AS DECIMAL(18,2));
        DECLARE @required_date DATE         = TRY_CAST(JSON_VALUE(@jsonInput, '$.required_date') AS DATE);
        DECLARE @purpose      VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.purpose');
        DECLARE @issued_by    VARCHAR(20)   = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @vendor_sno IS NULL OR @pr_basic_sno IS NULL OR @service_sno IS NULL OR @unit_price IS NULL
            THROW 58201, 'com_sno, div_sno, brn_sno, dept_sno, vendor_sno, pr_basic_sno, service_sno and unit_price are required.', 1;

        DECLARE @service_type_sno INT;
        SELECT @service_type_sno = service_type_sno FROM dbo.service_master WHERE service_sno = @service_sno AND is_active = 'Y';
        IF @service_type_sno IS NULL
            THROW 58202, 'Unknown or inactive service_sno.', 1;

        DECLARE @net_cost DECIMAL(18,4) = @qty * @unit_price;

        BEGIN TRANSACTION;

        DECLARE @po_year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @po_seq  INT;
        SELECT @po_seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE po_df_no LIKE 'SVO-' + @po_year + '-%';
        DECLARE @po_no VARCHAR(50) = 'SVO-' + @po_year + '-' + RIGHT('0000' + CAST(@po_seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.po_request_info (
            vendor_sno, brn_sno, dept_sno, com_sno, div_sno, budget_sno, budget_code, pr_basic_sno,
            po_date, required_date, purpose, terms_conditions, delivery_address,
            is_active, workflow_types_id, current_approver_id, status, po_df_no, service_type_sno
        )
        VALUES (
            @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, NULL, NULL, @pr_basic_sno,
            CAST(GETDATE() AS DATE), ISNULL(@required_date, CAST(GETDATE() AS DATE)), @purpose, NULL, NULL,
            'Y', NULL, NULL, 'A', @po_no, @service_type_sno
        );
        DECLARE @po_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.po_item_details (
            po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
            qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
            remarks, po_section, created_by, created_date, is_active
        )
        SELECT
            @po_basic_sno, @pr_item_sno, @service_sno, sm.service_name, '',
            @qty, @uom_sno, um.uom_name, @unit_price, @net_cost, 0, 0, @net_cost,
            @purpose, 'SERVICE', @issued_by, GETDATE(), '1'
        FROM dbo.service_master sm
        LEFT JOIN dbo.uom_master um ON um.uom_sno = @uom_sno
        WHERE sm.service_sno = @service_sno;

        INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
        VALUES (@po_basic_sno, 'AUTO_ISSUED', @issued_by, N'Direct-issued from an approved Service Agreement, no separate PO approval required.', 'Y');

        COMMIT TRANSACTION;

        SET @out_result = 'SUCCESS';
        SET @out_po_basic_sno = @po_basic_sno;
        SET @out_po_no = @po_no;

        IF @silent = 0
            SELECT 'SUCCESS' AS result, @po_basic_sno AS po_basic_sno, @po_no AS po_no;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @out_result = 'ERROR';
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_ExpireServiceAgreements
CREATE OR ALTER PROCEDURE dbo.sp_nt_ExpireServiceAgreements
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @expired TABLE (agreement_sno INT);

    UPDATE dbo.service_agreement
    SET status = 'X'
    OUTPUT inserted.agreement_sno INTO @expired
    WHERE status = 'A' AND is_active = 'Y' AND period_end_date < CAST(GETDATE() AS DATE);

    UPDATE ver
    SET outcome = 'EXPIRED'
    FROM dbo.service_agreement_version ver
    JOIN @expired e ON e.agreement_sno = ver.agreement_sno
    WHERE ver.version_no = (SELECT MAX(v2.version_no) FROM dbo.service_agreement_version v2 WHERE v2.agreement_sno = ver.agreement_sno);

    INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
    SELECT e.agreement_sno, 'EXPIRED', 'SYSTEM', N'Period end date passed — renew this agreement to continue the service.',
           (SELECT MAX(v.version_no) FROM dbo.service_agreement_version v WHERE v.agreement_sno = e.agreement_sno)
    FROM @expired e;

    SELECT COUNT(*) AS expired_count FROM @expired;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetAgreementsDueForNotification
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAgreementsDueForNotification
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @due TABLE (agreement_sno INT, due_date DATE);

    INSERT INTO @due (agreement_sno, due_date)
    SELECT sa.agreement_sno, DATEADD(DAY, sa.notify_days_before, @today)
    FROM dbo.service_agreement sa
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.status = 'A' AND sa.is_active = 'Y' AND sa.notify_days_before > 0
      AND DATEADD(DAY, sa.notify_days_before, @today) BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
             AND DAY(DATEADD(DAY, sa.notify_days_before, @today)) = CASE WHEN sa.po_generation_day > DAY(EOMONTH(DATEADD(DAY, sa.notify_days_before, @today))) THEN DAY(EOMONTH(DATEADD(DAY, sa.notify_days_before, @today))) ELSE sa.po_generation_day END
             AND DATEDIFF(MONTH, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
             AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) / rc.interval_value) * rc.interval_value, sa.period_start_date) = DATEADD(DAY, sa.notify_days_before, @today))
          )
      AND NOT EXISTS (SELECT 1 FROM dbo.service_agreement_notification_log l WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = DATEADD(DAY, sa.notify_days_before, @today));

    DECLARE @claimed TABLE (agreement_sno INT, due_date DATE);
    DECLARE @a_sno INT, @d_date DATE;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, due_date FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @a_sno, @d_date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.service_agreement_notification_log (agreement_sno, billing_period_start, status)
            VALUES (@a_sno, @d_date, 'PENDING');
            INSERT INTO @claimed (agreement_sno, due_date) VALUES (@a_sno, @d_date);
        END TRY
        BEGIN CATCH
            -- Unique-key collision: another sweep already claimed this row. Skip it.
        END CATCH
        FETCH NEXT FROM cur INTO @a_sno, @d_date;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT sa.agreement_sno, sa.agreement_no, sa.created_by AS notify_ecno, sm.service_name,
           sa.rate_amount, sa.po_generation_day, sa.notify_days_before, c.due_date
    FROM @claimed c
    JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetAllGRNs
-- ============================================================
-- Company/Division/Branch access scoping for grn-service list endpoints.
-- Database: Non_trade_Dev (MSSQL)
--
-- Companion to backend-stpl/sql/78_hierarchy_scope_wiring.sql — same
-- convention: an optional @HierarchyJson (or jsonInput.hierarchy for procs
-- that already take a single JSON blob) array of {com_sno, div_sno,
-- brn_sno}. NULL/absent = unfiltered (kept for internal/ops callers that
-- intentionally want everything). The Node layer always sends an actual
-- array — '[]' for an ecno with no assigned hierarchy — never omits it, so
-- the fail-closed "sees nothing until granted" default lives in
-- grn-service/src/middleware/hierarchyScope.js, not here.
--
-- sp_nt_GetStockSummary already had this (grn-service/sql/29_inventory_
-- stock_level_reference.sql) — needed no SQL change, only Node wiring.
-- This file extends the same pattern to the other org-scoped list procs:
-- GRN (grn_basic_info has com/div/brn), Inventory items (nt_inventory_items
-- has com/div/brn) and Stock Requests (nt_stock_requests has com/div/brn).
-- Each proc pulled fresh via OBJECT_DEFINITION() before editing, per
-- backend-stpl's established convention — the on-disk files these are
-- based on had already drifted from live in prior sessions.
-- ============================================================

-- ── sp_nt_GetAllGRNs ─────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAllGRNs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL;
    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status = JSON_VALUE(@jsonInput, '$.status');
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');
    END

    SELECT
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.gate_entry_sno,
        ge.gate_entry_no,
        b.po_basic_sno,
        p.po_df_no                                 AS po_no,
        b.vendor_sno,
        k.company_name                              AS vendor_name,
        CONVERT(VARCHAR(10), b.received_date, 120)  AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
        b.created_by                                AS received_by_name,
        CONVERT(VARCHAR(30), b.created_date, 120)    AS created_at,
        (
            SELECT
                gi.grn_item_sno,
                gi.po_item_sno,
                gi.prod_sno,
                gi.prod_name,
                gi.specification,
                gi.po_qty                            AS ordered_qty,
                gi.received_qty,
                gi.rejected_qty,
                gi.unit_name,
                gi.condition,
                gi.hsn_code,
                gi.remarks,
                gi.warehouse_location_sno,
                gi.warehouse_location_name
            FROM dbo.grn_item_details gi
            WHERE gi.grn_basic_sno = b.grn_basic_sno
              AND gi.is_active = 'Y'
            FOR JSON PATH
        )                                            AS items
    FROM dbo.grn_basic_info b
    LEFT JOIN dbo.nt_gate_entry ge   ON ge.gate_entry_sno = b.gate_entry_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE b.is_active = 'Y'
      AND (@status IS NULL OR b.status = @status)
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = b.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = b.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = b.brn_sno)
          )
      )
    ORDER BY b.grn_basic_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetAllUsersSignUp

  
  
  CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetAllUsersSignUp]  
     
AS  
BEGIN  
    SET NOCOUNT ON;  
     
  Select ntsp.nt_sign_up_sno,ntsp.ecno,vve.ename,vve.dept from nt_sign_up ntsp   
  inner join [Non_trade_Dev].[dbo].[vw_verified_employees] vve on ntsp.ecno=vve.ecno   
  --where ntsp.is_active='N'  
     
     
      
         
    END  
GO
-- [F2. procedures] dbo.sp_nt_GetApplicableStockLevel  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetApplicableStockLevel
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @prod_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.prod_sno') AS INT),
            @com_sno      INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
            @div_sno      INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT),
            @brn_sno      INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT),
            @location_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.location_sno') AS INT);

    SELECT TOP 1
        p.stock_level_sno, p.scope_type, p.min_qty, p.max_qty, p.reorder_level,
        CASE
            WHEN p.scope_type = 'LOCATION' THEN 100
            WHEN p.brn_sno IS NOT NULL THEN 3
            WHEN p.div_sno IS NOT NULL THEN 2
            ELSE 1
        END AS specificity
    FROM dbo.product_stock_level_master p
    WHERE p.prod_sno = @prod_sno
      AND p.is_active = 'Y'
      AND (
            (p.scope_type = 'LOCATION' AND @location_sno IS NOT NULL AND p.location_sno = @location_sno)
         OR (p.scope_type = 'ORG' AND p.com_sno = @com_sno
             AND (p.div_sno IS NULL OR p.div_sno = @div_sno)
             AND (p.brn_sno IS NULL OR p.brn_sno = @brn_sno))
          )
    ORDER BY specificity DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetApprovedPRsForPurchase
-- ============================================================
-- Exclude vendor-driven PRs from the Purchase Team screen
-- Database: Non_trade_Dev (MSSQL)
--
-- sp_nt_GetApprovedPRsForPurchase (predates this repo's sql/ convention —
-- reproduced byte-for-byte from OBJECT_DEFINITION(), same convention as
-- 33_nonstaff_approver_name_display.sql / 63_vw_pr_basic_info_vendor_driven.sql)
-- lists every status='A' PR that has no supplier_quotation_history row yet,
-- with no request_mode filter at all. Vendor-driven PRs never go through
-- the quotation flow, so they never get a supplier_quotation_history row —
-- they were showing up in the Purchase Team screen permanently, even after
-- their PO was already auto-created and emailed to the vendor
-- (sp_nt_CreateVendorDrivenPOFromPR / PR.controller.js#approvePr). Vendor-
-- driven PRs have their own dedicated queue (sp_nt_GetVendorDrivenApprovedPRs)
-- and don't belong here at all, at any stage — a straight request_mode
-- exclusion, not a "has a PO yet" check.
--
-- Only additive change: pbf.request_mode is now selected through the CTE,
-- and the final WHERE excludes it. Every other line is unchanged from the
-- live definition.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetApprovedPRsForPurchase
    @HierarchyJson NVARCHAR(MAX) = NULL
AS
BEGIN TRY

    WITH pr_with_groups AS
    (
        SELECT
            pbf.pr_basic_sno,
            pbf.brn_sno,
            vadr.brn_name,
            vadr.brn_prefix,
            vadr.dept_name,
            vadr.div_prefix,
            vadr.div_name,
            vadr.div_sno,
            vadr.com_name,
            vadr.com_sno,
            vve.ename                     AS created_by_name,
            pbf.dept_sno,
            pbf.reg_date,
            pbf.required_date,
            pbf.priority_sno,
            pbf.purpose,
            pbf.is_active,
            pbf.created_by,
            pbf.created_date,
            pbf.modified_by,
            pbf.modified_date,
            pbf.request_mode,
            g.grp                         AS [group],
            CASE
                WHEN g.grp IS NOT NULL AND g.group_count > 1
                    THEN pbf.pr_no + '/' + CAST(g.grp AS VARCHAR(10))
                ELSE pbf.pr_no
            END                            AS pr_no,
            pbf.workflow_types_id,
            pbf.current_approver_id,
            pbf.status,
            pbf.pr_no                     AS base_pr_no,  -- Keep base pr_no for joining

            (
                SELECT
                    pid.pr_item_sno,
                    pid.pr_basic_sno,
                    pid.prod_sno,
                    pm.prod_name,
                    pm.prod_code,
                    pm.prod_notes,
                    pid.specification,
                    pid.qty,
                    pid.unit,
                    uom.uom_name,
                    uom.uom_code,
                    pid.est_cost,
                    pid.total_cost,
                    pid.remarks,
                    pid.created_by,
                    pid.created_date,
                    pid.modified_by,
                    pid.modified_date,
                    pid.is_active,
                    pid.[group],
                    pid.pr_no
                FROM pr_item_details pid
                INNER JOIN uom_master uom
                    ON uom.uom_sno = pid.unit
                INNER JOIN product_master pm
                    ON pid.prod_sno = pm.prod_sno
                WHERE pid.pr_basic_sno = pbf.pr_basic_sno
                  AND pid.is_active = 'Y'
                  AND (pid.[group] = g.grp OR (pid.[group] IS NULL AND g.grp IS NULL))
                FOR JSON PATH
            ) AS pr_item_details,

            (
                SELECT ws.stage_order_json
                FROM workflow_stage ws
                WHERE ws.workflow_types_id = pbf.workflow_types_id
                  AND ws.is_active = 'Y'
            ) AS stage_order_json,

            (
                SELECT
                    phd.status_by,
                    vve.ename,
                    phd.status_date,
                    phd.commends,
                    phd.pr_edit_data
                FROM pr_history_data phd
                INNER JOIN vw_verified_employees vve
                    ON phd.status_by = vve.ecno
                WHERE phd.pr_basic_sno = pbf.pr_basic_sno
                FOR JSON PATH
            ) AS pr_history_data,

            g.group_count

        FROM pr_basic_info pbf
        INNER JOIN workflow_types wt
            ON pbf.workflow_types_id = wt.workflow_types_id
        INNER JOIN vw_ActiveDeptRecords vadr
            ON pbf.brn_sno = vadr.brn_sno
           AND pbf.dept_sno = vadr.dept_sno
        INNER JOIN vw_verified_employees vve
            ON pbf.created_by = vve.ecno
        OUTER APPLY
        (
            SELECT
                pid.[group]        AS grp,
                COUNT(*) OVER ()   AS group_count
            FROM pr_item_details pid
            WHERE pid.pr_basic_sno = pbf.pr_basic_sno
              AND pid.is_active = 'Y'
            GROUP BY pid.[group]
        ) g
    )

    SELECT
        pr_basic_sno,
        brn_sno,
        brn_name,
        brn_prefix,
        dept_name,
        div_prefix,
        div_name,
        div_sno,
        com_name,
        com_sno,
        created_by_name,
        dept_sno,
        reg_date,
        required_date,
        priority_sno,
        purpose,
        is_active,
        created_by,
        created_date,
        modified_by,
        modified_date,
        [group],
        pr_no,
        workflow_types_id,
        current_approver_id,
        status,
        pr_item_details,
        stage_order_json,
        pr_history_data,
        CASE
            WHEN (SELECT COUNT(sqi.pr_no)
                  FROM supplier_quotation_info sqi
                  WHERE sqi.pr_no = p.pr_no) > 0
                THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END AS isQuotationSubmitted
    FROM pr_with_groups p
    WHERE status = 'A'
      AND (p.request_mode IS NULL OR p.request_mode <> 'VENDOR_DRIVEN')
      AND NOT EXISTS
      (
          SELECT 1
          FROM supplier_quotation_history sqh
          WHERE sqh.pr_no = p.pr_no
            AND sqh.is_active = 1
      )
      AND (
          @HierarchyJson IS NULL
          OR EXISTS
          (
              SELECT 1
              FROM OPENJSON(@HierarchyJson)
              WITH (
                  com_sno INT '$.com_sno',
                  div_sno INT '$.div_sno',
                  brn_sno INT '$.brn_sno'
              ) h
              WHERE h.com_sno = p.com_sno
                AND (h.div_sno IS NULL OR h.div_sno = p.div_sno)
                AND (h.brn_sno IS NULL OR h.brn_sno = p.brn_sno)
          )
      );

END TRY
BEGIN CATCH
    DECLARE @ErrorMessage2  NVARCHAR(4000) = ERROR_MESSAGE(),
            @ErrorSeverity2 INT            = ERROR_SEVERITY(),
            @ErrorState2    INT            = ERROR_STATE();

    RAISERROR(@ErrorMessage2, @ErrorSeverity2, @ErrorState2);
END CATCH;
GO
-- [F2. procedures] dbo.sp_nt_GetBankPaymentVoucher  (new)
-- One voucher in full (for the view / print dialog). @jsonInput: { voucher_sno }
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetBankPaymentVoucher
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @voucher_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.voucher_sno') AS INT);
    IF @voucher_sno IS NULL THROW 58421, 'voucher_sno is required.', 1;

    SELECT v.*, sa.agreement_no, sm.service_name, k.company_name AS vendor_name, k.supp_code AS vendor_code,
           s.facility_type, s.facility_ref_no, s.rate_type, s.benchmark_name, s.sanctioned_amount, s.disbursed_amount,
           s.disbursement_date, s.interest_payment_day, s.day_count_basis AS facility_day_count_basis,
           c.com_name, dv.div_name, br.brn_name, dp.dept_name,
           (
               SELECT TOP 1 b.ac_holder_name, b.ac_number, b.ifsc, b.bank_name, b.bank_branch_name
               FROM dbo.kyc_bank_info b
               WHERE b.kyc_basic_info_sno = v.vendor_sno AND b.is_active = 'Y'
               ORDER BY CASE WHEN b.is_primary = 'Y' THEN 0 ELSE 1 END, b.kyc_address_sno
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
           ) AS beneficiary_json,
           (
               SELECT h.action_type, h.status_by, h.comment, h.created_at
               FROM dbo.bank_payment_voucher_history h WHERE h.voucher_sno = v.voucher_sno
               ORDER BY h.history_sno
               FOR JSON PATH
           ) AS history_json,
           (
               SELECT ws.stage_order_json FROM dbo.workflow_stage ws
               WHERE ws.workflow_types_id = v.workflow_types_id AND ws.is_active = 'Y'
           ) AS stage_order_json
    FROM dbo.bank_payment_voucher v
    JOIN dbo.service_agreement sa ON sa.agreement_sno = v.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.service_agreement_statutory s ON s.agreement_sno = v.agreement_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = v.vendor_sno
    LEFT JOIN dbo.company_master c ON c.com_sno = v.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = v.div_sno
    LEFT JOIN dbo.branch_master br ON br.brn_sno = v.brn_sno
    LEFT JOIN dbo.dept_master dp ON dp.dept_sno = v.dept_sno
    WHERE v.voucher_sno = @voucher_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetBankPaymentVouchers  (new)
-- @jsonInput (optional): { agreement_sno, status, com_sno, div_sno, brn_sno, dept_sno }
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetBankPaymentVouchers
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @agreement_sno INT = NULL, @status VARCHAR(20) = NULL, @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @agreement_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        SET @status       = NULLIF(JSON_VALUE(@jsonInput, '$.status'), '');
        SET @com_sno      = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno      = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno      = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno     = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    END

    SELECT v.voucher_sno, v.voucher_no, v.agreement_sno, sa.agreement_no, sm.service_name,
           k.company_name AS vendor_name, s.facility_type, s.facility_ref_no,
           v.period_from, v.period_to, v.days, v.opening_principal, v.principal_on_payment, v.interest_amount,
           v.principal_repayment, v.total_payable, v.principal_after, v.rate_pct, v.next_due_date, v.next_est_interest,
           v.status, v.current_approver_id, v.created_by, v.created_at, v.approved_at,
           v.paid_on, v.payment_mode, v.payment_ref_no, v.paid_from_bank
    FROM dbo.bank_payment_voucher v
    JOIN dbo.service_agreement sa ON sa.agreement_sno = v.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.service_agreement_statutory s ON s.agreement_sno = v.agreement_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = v.vendor_sno
    WHERE (@agreement_sno IS NULL OR v.agreement_sno = @agreement_sno)
      AND (@status IS NULL OR v.status = @status)
      AND (@com_sno IS NULL OR v.com_sno = @com_sno) AND (@div_sno IS NULL OR v.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR v.brn_sno = @brn_sno) AND (@dept_sno IS NULL OR v.dept_sno = @dept_sno)
    ORDER BY v.voucher_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetBankPaymentVouchersForApproval  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetBankPaymentVouchersForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT v.voucher_sno, v.voucher_no, v.agreement_sno, sa.agreement_no, sm.service_name,
           k.company_name AS vendor_name, s.facility_type, s.facility_ref_no, s.rate_type, s.benchmark_name,
           s.sanctioned_amount, s.interest_payment_day,
           v.period_from, v.period_to, v.days, v.day_count_basis, v.opening_principal, v.principal_on_payment,
           v.interest_amount, v.principal_repayment, v.total_payable, v.principal_after, v.rate_pct,
           v.segments_json, v.next_due_date, v.next_days, v.next_est_interest, v.next_segments_json,
           v.remarks, v.status, v.current_approver_id, v.created_by, v.created_at,
           (
               SELECT ws.stage_order_json FROM dbo.workflow_stage ws
               WHERE ws.workflow_types_id = v.workflow_types_id AND ws.is_active = 'Y'
           ) AS stage_order_json
    FROM dbo.bank_payment_voucher v
    JOIN dbo.service_agreement sa ON sa.agreement_sno = v.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.service_agreement_statutory s ON s.agreement_sno = v.agreement_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = v.vendor_sno
    WHERE v.status = 'PENDING_APPROVAL' AND v.current_approver_id = @Ecno
    ORDER BY v.voucher_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetBranchesRecords
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetBranchesRecords]
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');

    BEGIN TRY
        SELECT v.*
        FROM ActiveBranches v
        WHERE (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = v.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = v.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = v.brn_sno)
            )
        );
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
-- [F2. procedures] dbo.sp_nt_GetCompanyRecords
-- ============================================================
-- Company/Division/Branch access scoping for the Masters generic CRUD
-- dispatch (backend-stpl/src/Masters/Routes/CommonMasterRoutes.js's
-- GET /:masterField, dispatched by CommonMasterRepo.storedProcedureMap).
-- Database: Non_trade_Dev (MSSQL)
--
-- Only the 5 masterFields whose rows actually carry a company/division/
-- branch identity get this treatment: CompanyMaster, DivisionMaster,
-- BranchMaster, DeptMaster, WarehouseLocationMaster. The other ~20 master
-- types dispatched through the same generic route (UomMaster, CategoryMaster,
-- ProductMaster, WorkflowMaster, etc.) are global reference data with no
-- org concept and are deliberately left untouched — see
-- [project-ecno-org-scope-and-grn-fifo] memory for the full triage.
--
-- Convention matches every other @HierarchyJson filter added this session:
-- an OPENJSON array of {com_sno, div_sno, brn_sno}, NULL = unfiltered (kept
-- for internal callers), empty array '[]' = sees nothing. The Node layer
-- (CommonMasterRepo.getAllCommonMasters) only attaches `hierarchy` for
-- these 5 masterFields — every other masterField keeps calling these SPs
-- with zero parameters exactly as before, so no other master type is
-- affected by this migration.
--
-- KNOWN LIMITATION: sp_nt_GetUserHierarchy (the source of every
-- @HierarchyJson value across this whole rollout) only returns
-- com_sno/div_sno/brn_sno — it drops dept_sno even though nt_user_
-- permissions_json.hierarchy_json can carry a dept_sno per row. So
-- DeptMaster filtering below can only narrow to "which branches", not
-- "which specific department within an allowed branch" — a department-
-- scoped permission grant is treated as full-branch access here. This is a
-- pre-existing gap in the shared hierarchy-resolution proc, not something
-- introduced by this file; fixing it means threading dept_sno through
-- sp_nt_GetUserHierarchy and every consumer, a larger follow-up.
-- ============================================================

CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetCompanyRecords]
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');

    BEGIN TRY
        SELECT v.*
        FROM vw_company_address v
        WHERE (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno') h
                WHERE h.com_sno = v.com_sno
            )
        );
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
-- [F2. procedures] dbo.sp_nt_GetDeptRecords
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetDeptRecords]
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');

    BEGIN TRY
        SELECT v.*
        FROM vw_ActiveDeptRecords v
        WHERE (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = v.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = v.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = v.brn_sno)
            )
        );
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
-- [F2. procedures] dbo.sp_nt_GetDivisionsRecords
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetDivisionsRecords]
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');

    BEGIN TRY
        SELECT v.*
        FROM vw_ActiveDivisions v
        WHERE (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno') h
                WHERE h.com_sno = v.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = v.div_sno)
            )
        );
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
-- [F2. procedures] dbo.sp_nt_GetGRNItemsForInventorySync
-- ── sp_nt_GetGRNItemsForInventorySync — add received_date + received_unit_price ──
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNItemsForInventorySync
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn_basic_sno INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno');

    SELECT
        gi.grn_item_sno, gi.grn_basic_sno, gi.po_item_sno, gi.prod_sno, gi.prod_name,
        gi.unit_name, gi.received_qty, gi.rejected_qty, gi.warehouse_location_sno,
        gi.inventory_sync_status, gi.received_unit_price,
        gb.com_sno, gb.div_sno, gb.brn_sno, gb.dept_sno, gb.created_by,
        gb.received_date,
        'GRN-' + CAST(YEAR(gb.created_date) AS VARCHAR(4)) + '-'
            + RIGHT('000000' + CAST(gb.grn_no AS VARCHAR(6)), 6) AS grn_no
    FROM dbo.grn_item_details gi
    JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
    WHERE gi.grn_basic_sno = @grn_basic_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetGRNsByPO
-- ── sp_nt_GetGRNsByPO ────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNsByPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');
    DECLARE @HierarchyJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');

    SELECT
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.gate_entry_sno,
        ge.gate_entry_no,
        b.po_basic_sno,
        p.po_df_no                                  AS po_no,
        b.vendor_sno,
        k.company_name                              AS vendor_name,
        CONVERT(VARCHAR(10), b.received_date, 120)   AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
        b.created_by                                 AS received_by,
        b.created_by                                 AS received_by_name,
        CONVERT(VARCHAR(30), b.created_date, 120)     AS created_at,
        (
            SELECT
                gi.grn_item_sno,
                gi.po_item_sno,
                gi.prod_sno,
                gi.prod_name,
                gi.specification,
                gi.po_qty                            AS ordered_qty,
                gi.received_qty,
                gi.rejected_qty,
                gi.unit_name,
                gi.condition,
                gi.hsn_code,
                gi.remarks,
                gi.warehouse_location_sno,
                gi.warehouse_location_name
            FROM dbo.grn_item_details gi
            WHERE gi.grn_basic_sno = b.grn_basic_sno
              AND gi.is_active = 'Y'
            FOR JSON PATH
        ) AS items
    FROM dbo.grn_basic_info b
    LEFT JOIN dbo.nt_gate_entry ge
        ON ge.gate_entry_sno = b.gate_entry_sno
    LEFT JOIN dbo.po_request_info p
        ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k
        ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE b.po_basic_sno = @po_basic_sno
      AND b.is_active = 'Y'
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = b.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = b.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = b.brn_sno)
          )
      )
    ORDER BY b.grn_basic_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetInventoryItems
-- ── sp_nt_GetInventoryItems: HierarchyJson now also matches dept_sno ─────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetInventoryItems
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @category  VARCHAR(50)  = NULL;
    DECLARE @warehouse VARCHAR(100) = NULL;
    DECLARE @status    VARCHAR(20)  = NULL;
    DECLARE @com_sno   INT          = NULL;
    DECLARE @div_sno   INT          = NULL;
    DECLARE @brn_sno   INT          = NULL;
    DECLARE @dept_sno  INT          = NULL;
    DECLARE @exclude_non_regular BIT = 0;
    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @category  = JSON_VALUE(@jsonInput, '$.category');
        SET @warehouse = JSON_VALUE(@jsonInput, '$.warehouse');
        SET @status    = JSON_VALUE(@jsonInput, '$.status');
        SET @com_sno   = JSON_VALUE(@jsonInput, '$.com_sno');
        SET @div_sno   = JSON_VALUE(@jsonInput, '$.div_sno');
        SET @brn_sno   = JSON_VALUE(@jsonInput, '$.brn_sno');
        SET @dept_sno  = JSON_VALUE(@jsonInput, '$.dept_sno');
        SET @exclude_non_regular = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.exclude_non_regular') AS BIT), 0);
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');
    END

    SELECT
        i.item_sno, i.item_code, i.item_name, i.category, i.sub_category, i.uom,
        i.current_stock, i.min_stock, i.max_stock, i.reorder_qty, i.warehouse,
        i.location AS location_code,
        wl.location_name,
        i.cost_price, i.selling_price, i.status, i.hsn_code, i.description, i.prod_sno,
        i.com_sno, c.com_name,
        i.div_sno, dv.div_name,
        i.brn_sno, br.brn_name,
        i.dept_sno, dp.dept_name,
        sl.min_qty       AS master_min_qty,
        sl.max_qty       AS master_max_qty,
        sl.reorder_level AS master_reorder_level,
        sl.scope_type    AS master_scope_type,
        scm.subcat_stock_type,
        scm.perishable_days,
        CONVERT(VARCHAR(10), lr.last_received_date, 120) AS last_received_date,
        CASE WHEN lr.last_received_date IS NOT NULL
             THEN DATEDIFF(DAY, lr.last_received_date, GETDATE())
             ELSE NULL END AS days_since_last_received,
        CASE WHEN scm.subcat_stock_type = 'Perishable'
                  AND scm.perishable_days IS NOT NULL
                  AND i.current_stock > 0
                  AND lr.last_received_date IS NOT NULL
                  AND DATEDIFF(DAY, lr.last_received_date, GETDATE()) > scm.perishable_days
             THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_expiry_stock,
        CONVERT(VARCHAR(30), i.created_at, 120) AS created_at,
        CONVERT(VARCHAR(30), i.updated_at, 120) AS updated_at
    FROM dbo.nt_inventory_items i
    LEFT JOIN dbo.company_master c   ON c.com_sno  = i.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = i.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = i.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = i.dept_sno
    LEFT JOIN dbo.product_master pm      ON pm.prod_sno   = i.prod_sno
    LEFT JOIN dbo.subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
    LEFT JOIN dbo.warehouse_location_master wl ON wl.location_code = i.location
    OUTER APPLY (
        SELECT TOP 1
            p.min_qty, p.max_qty, p.reorder_level, p.scope_type,
            CASE
                WHEN p.scope_type = 'LOCATION' THEN 100
                WHEN p.brn_sno IS NOT NULL THEN 3
                WHEN p.div_sno IS NOT NULL THEN 2
                ELSE 1
            END AS specificity
        FROM dbo.product_stock_level_master p
        WHERE i.prod_sno IS NOT NULL
          AND p.prod_sno = i.prod_sno
          AND p.is_active = 'Y'
          AND (
                (p.scope_type = 'LOCATION' AND wl.location_sno IS NOT NULL AND p.location_sno = wl.location_sno)
             OR (p.scope_type = 'ORG' AND p.com_sno = i.com_sno
                 AND (p.div_sno IS NULL OR p.div_sno = i.div_sno)
                 AND (p.brn_sno IS NULL OR p.brn_sno = i.brn_sno))
              )
        ORDER BY specificity DESC
    ) sl
    OUTER APPLY (
        SELECT MAX(gb.received_date) AS last_received_date
        FROM dbo.grn_item_details gi
        JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
        WHERE i.prod_sno IS NOT NULL
          AND gi.prod_sno = i.prod_sno
          AND gi.is_active = 'Y'
          AND gb.is_active = 'Y'
    ) lr
    WHERE (@category  IS NULL OR i.category  = @category)
      AND (@warehouse IS NULL OR i.warehouse = @warehouse)
      AND (@status    IS NULL OR i.status    = @status)
      AND (@com_sno   IS NULL OR i.com_sno   = @com_sno)
      AND (@div_sno   IS NULL OR i.div_sno   = @div_sno)
      AND (@brn_sno   IS NULL OR i.brn_sno   = @brn_sno)
      AND (@dept_sno  IS NULL OR i.dept_sno  = @dept_sno)
      AND (@exclude_non_regular = 0 OR ISNULL(scm.subcat_stock_type, 'Regular') NOT IN ('Non-Regular', 'Perishable'))
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno') h
                WHERE h.com_sno = i.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = i.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = i.brn_sno)
                  AND (h.dept_sno IS NULL OR h.dept_sno = i.dept_sno)
          )
      )
    ORDER BY i.item_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetLoanAccounts  (new)
-- The loans in process: every Approved (or Expired) Statutory agreement, with the
-- figures as of today. @jsonInput (optional): { com_sno, div_sno, brn_sno, dept_sno }
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetLoanAccounts
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    END
    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    SELECT b.*, rt.current_rate_pct, ISNULL(acc.accrued_interest, 0) AS accrued_interest,
           dbo.fn_LoanPrincipalAt(b.agreement_sno, @today) AS principal_outstanding,
           CASE WHEN b.billed_through >= b.period_end_date THEN NULL
                WHEN dbo.fn_LoanNextDueDate(b.interest_payment_day, b.billed_through) > b.period_end_date THEN b.period_end_date
                ELSE dbo.fn_LoanNextDueDate(b.interest_payment_day, b.billed_through) END AS next_due_date,
           pv.pending_voucher_sno, pv.pending_voucher_no,
           uv.unpaid_voucher_sno, uv.unpaid_voucher_no,
           ISNULL(tot.voucher_count, 0) AS voucher_count, ISNULL(tot.interest_billed, 0) AS interest_billed
    FROM (
        SELECT sa.agreement_sno, sa.agreement_no, sa.status AS agreement_status,
               sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno, sa.vendor_sno, k.company_name AS vendor_name,
               sm.service_name, sa.period_start_date, sa.period_end_date,
               s.facility_type, s.facility_ref_no, s.sanctioned_amount, s.drawing_power, s.rate_type, s.benchmark_name,
               s.benchmark_rate_pct, s.spread_pct, s.interest_rate_pct AS sanctioned_rate_pct,
               s.disbursed_amount, s.disbursement_date, s.interest_payment_day, s.day_count_basis,
               dbo.fn_LoanBilledThrough(sa.agreement_sno) AS billed_through
        FROM dbo.service_agreement sa
        JOIN dbo.service_agreement_statutory s ON s.agreement_sno = sa.agreement_sno
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
        WHERE sa.status IN ('A', 'X') AND sa.is_active = 'Y'
          AND s.disbursement_date IS NOT NULL AND s.interest_payment_day IS NOT NULL
          AND (@com_sno IS NULL OR sa.com_sno = @com_sno) AND (@div_sno IS NULL OR sa.div_sno = @div_sno)
          AND (@brn_sno IS NULL OR sa.brn_sno = @brn_sno) AND (@dept_sno IS NULL OR sa.dept_sno = @dept_sno)
    ) b
    OUTER APPLY (SELECT TOP 1 r.interest_rate_pct AS current_rate_pct FROM dbo.fn_LoanRateAt(b.agreement_sno, @today) r) rt
    OUTER APPLY (
        SELECT SUM(g.interest) AS accrued_interest
        FROM dbo.fn_LoanInterestSegments(b.agreement_sno, b.billed_through,
                 CASE WHEN @today > b.period_end_date THEN b.period_end_date ELSE @today END, 0) g
    ) acc
    OUTER APPLY (SELECT TOP 1 v.voucher_sno AS pending_voucher_sno, v.voucher_no AS pending_voucher_no
                 FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = b.agreement_sno AND v.status = 'PENDING_APPROVAL') pv
    OUTER APPLY (SELECT TOP 1 v.voucher_sno AS unpaid_voucher_sno, v.voucher_no AS unpaid_voucher_no
                 FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = b.agreement_sno AND v.status = 'APPROVED' ORDER BY v.voucher_sno) uv
    OUTER APPLY (SELECT COUNT(*) AS voucher_count, SUM(v.interest_amount) AS interest_billed
                 FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = b.agreement_sno AND v.status IN ('APPROVED', 'PAID')) tot
    ORDER BY b.agreement_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetLoanDetail  (new)
-- One loan's history as JSON columns (parsed by the Node service):
--   rates_json     sanctioned rate + every entered rate, each with its end date
--   txns_json      opening disbursement + every principal movement, with a running balance
--   vouchers_json  the loan's bank payment vouchers, newest first
-- @jsonInput: { agreement_sno }
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetLoanDetail
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    IF @agreement_sno IS NULL THROW 58400, 'agreement_sno is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement_statutory WHERE agreement_sno = @agreement_sno)
        THROW 58400, 'Loan facility not found for this agreement.', 1;

    DECLARE @locked DATE = dbo.fn_LoanLockedThrough(@agreement_sno);

    SELECT @agreement_sno AS agreement_sno,
           dbo.fn_LoanBilledThrough(@agreement_sno) AS billed_through,
           @locked AS locked_through,
           (
               SELECT r.rate_period_sno, r.effective_from,
                      DATEADD(DAY, -1, LEAD(r.effective_from) OVER (ORDER BY r.effective_from)) AS effective_to,
                      r.benchmark_rate_pct, r.spread_pct, r.interest_rate_pct, r.source, r.remarks, r.created_by, r.created_at,
                      CASE WHEN r.source = 'ENTERED' AND r.effective_from >= @locked THEN 1 ELSE 0 END AS can_delete
               FROM (
                   SELECT CAST(NULL AS INT) AS rate_period_sno, s.disbursement_date AS effective_from, s.benchmark_rate_pct, s.spread_pct,
                          s.interest_rate_pct, 'SANCTIONED' AS source, CAST(N'Rate at sanction' AS NVARCHAR(300)) AS remarks,
                          CAST(NULL AS VARCHAR(30)) AS created_by, CAST(NULL AS DATETIME) AS created_at
                   FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno
                   UNION ALL
                   SELECT p.rate_period_sno, p.effective_from, p.benchmark_rate_pct, p.spread_pct, p.interest_rate_pct, 'ENTERED',
                          p.remarks, p.created_by, p.created_at
                   FROM dbo.loan_rate_period p WHERE p.agreement_sno = @agreement_sno
               ) r
               ORDER BY r.effective_from
               FOR JSON PATH
           ) AS rates_json,
           (
               SELECT m.txn_sno, m.txn_date, m.txn_type, m.amount, m.voucher_sno, m.remarks, m.created_by, m.source,
                      SUM(CASE m.txn_type WHEN 'DRAWDOWN' THEN m.amount ELSE -m.amount END)
                          OVER (ORDER BY m.txn_date, m.ord, m.txn_sno ROWS UNBOUNDED PRECEDING) AS principal_after,
                      CASE WHEN m.source = 'MANUAL' AND m.txn_date >= @locked THEN 1 ELSE 0 END AS can_delete
               FROM (
                   SELECT CAST(NULL AS INT) AS txn_sno, s.disbursement_date AS txn_date, 'DRAWDOWN' AS txn_type, s.disbursed_amount AS amount,
                          CAST(NULL AS INT) AS voucher_sno, CAST(N'Disbursement' AS NVARCHAR(300)) AS remarks, CAST(NULL AS VARCHAR(30)) AS created_by,
                          'OPENING' AS source, 0 AS ord
                   FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno AND ISNULL(s.disbursed_amount, 0) > 0
                   UNION ALL
                   SELECT t.txn_sno, t.txn_date, t.txn_type, t.amount, t.voucher_sno, t.remarks, t.created_by,
                          CASE WHEN t.voucher_sno IS NULL THEN 'MANUAL' ELSE 'VOUCHER' END, 1
                   FROM dbo.loan_principal_txn t WHERE t.agreement_sno = @agreement_sno AND t.is_active = 'Y'
               ) m
               ORDER BY m.txn_date, m.ord, m.txn_sno
               FOR JSON PATH
           ) AS txns_json,
           (
               SELECT v.voucher_sno, v.voucher_no, v.period_from, v.period_to, v.days, v.interest_amount, v.principal_repayment,
                      v.total_payable, v.principal_after, v.rate_pct, v.status, v.created_at, v.paid_on
               FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = @agreement_sno
               ORDER BY v.voucher_sno DESC
               FOR JSON PATH
           ) AS vouchers_json;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetMyPRTracking
-- ============================================================
-- PR Tracking — surface approver NAMES and the full multi-stage chain
-- Database : Non_trade_Dev (MSSQL, 10.0.21.8)
--
-- Follow-up to sql/29_pr_tracking.sql, based on user feedback after the
-- first live walkthrough: the "PR Approval" stage only showed a generic
-- "Pending" status with no indication of WHO it's pending with, and no view
-- of the full approval chain (e.g. "Stage 1: KTM1148 -> Stage 2: KTM1006").
--
-- All 4 objects touched here are ones this feature itself created in file
-- 29 (not pre-existing/UAT procedures) — CREATE OR ALTER is safe, same as
-- every other proc in that file.
--
-- Root cause: the existing (pre-dates this feature, NOT touched)
-- vw_PR_Basic_Info.pr_history_data subquery omits status/approver_ecno/
-- ordering — it only has {status_by, ename, status_date, commends,
-- pr_edit_data}, no way to tell approve vs reject or which stage. Rather
-- than alter that view (also read by sp_get_pr_details_for_approval, which
-- UAT is actively using), this adds two new result sets to
-- sp_nt_GetPRTrackingTimeline that resolve the full stage chain (from
-- workflow_stage.stage_order_json) and the full ordered history (straight
-- from pr_history_data, not the view) independently.
-- ============================================================

-- ── 1. sp_nt_GetMyPRTracking — add current_approver_name ───────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetMyPRTracking
    @ecno VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pbf.pr_basic_sno,
        pbf.pr_no,
        pbf.status                 AS pr_status,
        pbf.purpose,
        pbf.required_date,
        pbf.created_date,
        vadr.com_name, vadr.div_name, vadr.brn_name, vadr.dept_name,
        pbf.current_approver_id,
        vve_approver.ename         AS current_approver_name,
        sq.sq_basic_sno,
        sq.status                  AS quotation_status,
        po.po_basic_sno,
        po.status                  AS po_status,
        po.supplier_ack_status,
        po.po_pdf_url,
        ds.dispatch_slip_sno,
        ge.gate_entry_sno,
        ge.status                  AS gate_entry_status,
        grn.grn_basic_sno,
        grn.status                 AS grn_status,
        CASE
            WHEN grn.grn_basic_sno IS NOT NULL AND grn.status IN ('Received', 'Partial') THEN 'Received Stock'
            WHEN grn.grn_basic_sno IS NOT NULL                                            THEN 'GRN'
            WHEN ge.gate_entry_sno IS NOT NULL                                             THEN 'Gate Entry'
            WHEN ds.dispatch_slip_sno IS NOT NULL                                          THEN 'Dispatched'
            WHEN po.po_basic_sno IS NOT NULL AND po.status = 'A'                           THEN 'PO Sent / In Transit'
            WHEN po.po_basic_sno IS NOT NULL                                               THEN 'PO Approval'
            WHEN sq.sq_basic_sno IS NOT NULL                                               THEN 'Purchase Quotation'
            WHEN pbf.status = 'A'                                                          THEN 'PR Approved — Awaiting Quotation/PO'
            WHEN pbf.status = 'R'                                                          THEN 'PR Rejected'
            ELSE 'PR Approval Pending'
        END AS current_stage
    FROM dbo.pr_basic_info pbf
    INNER JOIN dbo.vw_ActiveDeptRecords vadr
        ON pbf.brn_sno = vadr.brn_sno AND pbf.dept_sno = vadr.dept_sno
    LEFT JOIN dbo.vw_verified_employees vve_approver
        ON vve_approver.ecno = pbf.current_approver_id
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.supplier_quotation_info
        WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY sq_basic_sno DESC
    ) sq
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.po_request_info
        WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY po_basic_sno DESC
    ) po
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.nt_dispatch_slip
        WHERE po_basic_sno = po.po_basic_sno ORDER BY dispatch_slip_sno DESC
    ) ds
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.nt_gate_entry
        WHERE po_basic_sno = po.po_basic_sno ORDER BY gate_entry_sno DESC
    ) ge
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.grn_basic_info
        WHERE po_basic_sno = po.po_basic_sno ORDER BY grn_basic_sno DESC
    ) grn
    WHERE pbf.created_by = @ecno AND pbf.is_active = 'Y'
    ORDER BY pbf.created_date DESC, pbf.pr_basic_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetPayableBills
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPayableBills
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    SELECT
        iad.invoice_alloc_sno AS bill_sno,
        i.invoice_no          AS bill_no,
        i.vendor_invoice_no   AS supplier_invoice_no,
        p.po_df_no            AS po_no,
        i.vendor_sno,
        k.company_name        AS vendor_name,
        i.invoice_date,
        i.due_date,
        pr.request_mode,
        pvd.payment_cycle_days,
        CONVERT(VARCHAR(10), arrivals.last_received_date, 120) AS received_date,
        iad.bucket_type,
        iad.allocated_amount,
        iad.hold_amount,
        iad.matched_qty_ratio,
        iad.release_amount AS net_payable,
        ISNULL(paid.paidSoFar, 0) AS paid_amount,
        iad.release_amount - ISNULL(paid.paidSoFar, 0) AS outstanding,
        qty.requested_qty,
        qty.received_qty
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.pr_basic_info pr ON pr.pr_basic_sno = p.pr_basic_sno
    LEFT JOIN dbo.pr_vendor_driven_info pvd ON pvd.pr_basic_sno = pr.pr_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (
        SELECT MAX(g.received_date) AS last_received_date
        FROM dbo.grn_basic_info g WHERE g.po_basic_sno = p.po_basic_sno AND g.is_active = 'Y'
    ) arrivals
    OUTER APPLY (
        SELECT ISNULL(SUM(pad.amount), 0) AS paidSoFar
        FROM dbo.payment_allocation_details pad WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
    ) paid
    OUTER APPLY (
        SELECT
            SUM(poi.qty) AS requested_qty,
            SUM(rq.line_received_qty) AS received_qty
        FROM dbo.po_item_details poi
        CROSS APPLY (
            SELECT ISNULL(SUM(g.received_qty - ISNULL(g.rejected_qty, 0)), 0) AS line_received_qty
            FROM dbo.grn_item_details g
            WHERE g.po_item_sno = poi.po_item_sno AND g.is_active = 'Y'
        ) rq
        WHERE poi.po_basic_sno = p.po_basic_sno AND poi.is_active IN ('1', 'Y')
    ) qty
    WHERE iad.is_active = 'Y'
      AND iad.release_amount > ISNULL(paid.paidSoFar, 0) + 0.01
      AND (@vendor_sno IS NULL OR i.vendor_sno = @vendor_sno)
    ORDER BY arrivals.last_received_date, iad.invoice_alloc_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetPrLinesForPoGrouping
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPrLinesForPoGrouping
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @pr_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);

    IF @pr_basic_sno IS NULL
    BEGIN
        RAISERROR('pr_basic_sno is required.', 16, 1);
        RETURN;
    END

    ;WITH pr_lines AS (
        SELECT
            pid.pr_item_sno,
            pid.item_type,
            pid.prod_sno,
            pm.prod_name,
            pid.qty,
            pid.remarks,
            sq.vendor_sno,
            k.company_name AS vendor_name
        FROM dbo.pr_item_details pid
        LEFT JOIN dbo.product_master pm ON pm.prod_sno = pid.prod_sno
        LEFT JOIN dbo.supplier_quotation_items sqi ON sqi.pr_item_sno = pid.pr_item_sno AND sqi.is_active = 1
        LEFT JOIN dbo.supplier_quotation_info sq ON sq.sq_basic_sno = sqi.sq_basic_sno AND sq.is_selected = 1
        LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sq.vendor_sno
        WHERE pid.pr_basic_sno = @pr_basic_sno AND pid.is_active = 'Y'
    )
    SELECT
        vendor_sno,
        vendor_name,
        item_type AS line_type,
        (
            SELECT pl2.pr_item_sno, pl2.item_type, pl2.prod_sno, pl2.prod_name,
                   pl2.qty, pl2.remarks
            FROM pr_lines pl2
            WHERE ISNULL(pl2.vendor_sno, -1) = ISNULL(pr_lines.vendor_sno, -1)
              AND pl2.item_type = pr_lines.item_type
            FOR JSON PATH
        ) AS lines,
        (
            SELECT TOP 1 po_basic_sno FROM dbo.po_request_info
            WHERE pr_basic_sno = @pr_basic_sno AND vendor_sno = pr_lines.vendor_sno AND is_active = 'Y'
        ) AS existing_po_basic_sno
    FROM pr_lines
    GROUP BY vendor_sno, vendor_name, item_type
    ORDER BY vendor_name, item_type;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetProductRecords
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetProductRecords]
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        -- NOTE: must NOT use a bare `SELECT *` here — uom_master is joined
        -- twice (um for the purchase UOM, cuom for the conversion unit), and
        -- node-mssql silently collapses same-named duplicate columns
        -- (uom_name, uom_code, uom_class, ...) into arrays rather than erroring,
        -- which would corrupt every existing consumer expecting a plain string.
        -- pm.*/cm.*/scm.*/um.* reproduces exactly what the old bare `SELECT *`
        -- returned (same 4 tables, no cuom.* mixed in); only the two aliased
        -- cuom columns are new.
        SELECT pm.*, cm.*, scm.*, um.*,
               cuom.uom_name AS con_uom_name,
               cuom.uom_code AS con_uom_code
        FROM product_master pm
        INNER JOIN category_master cm ON pm.cat_sno = cm.cat_sno
        INNER JOIN subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
        INNER JOIN uom_master um ON um.uom_sno = pm.uom_sno
        LEFT JOIN uom_master cuom ON cuom.uom_sno = pm.prod_uom_con_uom_sno
        WHERE prod_active = 'Y'
        ORDER BY prod_sno;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
-- [F2. procedures] dbo.sp_nt_GetProductStockLevels  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetProductStockLevels
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.stock_level_sno,
        p.prod_sno, pm.prod_name, pm.prod_code,
        p.scope_type,
        p.com_sno,  c.com_name,
        p.div_sno,  d.div_name,
        p.brn_sno,  b.brn_name,
        p.location_sno, wl.location_name, wl.location_code,
        CASE
            WHEN p.scope_type = 'LOCATION' THEN N'Warehouse: ' + ISNULL(wl.location_name, N'(deleted)')
            WHEN p.brn_sno IS NOT NULL THEN c.com_name + N' / ' + d.div_name + N' / ' + b.brn_name
            WHEN p.div_sno IS NOT NULL THEN c.com_name + N' / ' + d.div_name + N' / All Branches'
            ELSE c.com_name + N' / All Divisions'
        END AS scope_label,
        p.min_qty, p.max_qty, p.reorder_level,
        p.is_active,
        p.created_by,
        CONVERT(VARCHAR(30), p.created_date, 120)  AS created_date,
        p.modified_by,
        CONVERT(VARCHAR(30), p.modified_date, 120) AS modified_date
    FROM dbo.product_stock_level_master p
    JOIN dbo.product_master pm            ON pm.prod_sno = p.prod_sno
    LEFT JOIN dbo.company_master c         ON c.com_sno  = p.com_sno
    LEFT JOIN dbo.division_master d        ON d.div_sno  = p.div_sno
    LEFT JOIN dbo.branch_master b          ON b.brn_sno  = p.brn_sno
    LEFT JOIN dbo.warehouse_location_master wl ON wl.location_sno = p.location_sno
    WHERE p.is_active = 'Y'
    ORDER BY pm.prod_name, p.scope_type, c.com_name, d.div_name, b.brn_name;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetScreenPermissionRecords
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetScreenPermissionRecords]

AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT * 
        FROM [Non_trade_Dev].[dbo].[permissions] WHERE is_active='Y';
    END TRY

    BEGIN CATCH
        SELECT  
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_LINE() AS ErrorLine,
            ERROR_PROCEDURE() AS ErrorProcedure;
    END CATCH
END
GO
-- [F2. procedures] dbo.sp_nt_GetScreenRecords
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetScreenRecords]

AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT * 
        FROM [Non_trade_Dev].[dbo].[screens] WHERE is_active='Y';
    END TRY

    BEGIN CATCH
        SELECT  
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_LINE() AS ErrorLine,
            ERROR_PROCEDURE() AS ErrorProcedure;
    END CATCH
END
GO
-- [F2. procedures] dbo.sp_nt_GetServiceAgreementHistory  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceAgreementHistory
    @agreement_sno INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT sa.agreement_sno, sa.agreement_no, sa.status, sm.service_name, st.service_type_code,
           (
               SELECT ver.version_no, ver.action_type, ver.outcome, ver.period_start_date, ver.period_end_date,
                      ver.submitted_by, ver.submitted_at, ver.decided_at, ver.superseded_at, ver.note,
                      JSON_QUERY(ver.terms_json) AS terms,
                      (
                          SELECT h.action_type, h.status_by, h.comment, h.created_at
                          FROM dbo.service_agreement_history h
                          WHERE h.agreement_sno = ver.agreement_sno AND ISNULL(h.version_no, 1) = ver.version_no
                          ORDER BY h.history_sno
                          FOR JSON PATH
                      ) AS events
               FROM dbo.service_agreement_version ver
               WHERE ver.agreement_sno = sa.agreement_sno
               ORDER BY ver.version_no DESC
               FOR JSON PATH
           ) AS versions_json,
           (
               SELECT c.cycle_sno, c.billing_period_start, c.qty, c.rate_amount, c.discount_pct, c.gst_pct,
                      c.net_cost, c.status, c.entered_by, c.entered_at,
                      (
                          SELECT cv.vendor_sno, kv.company_name AS vendor_name, cv.share_pct, cv.rate_amount,
                                 cv.net_cost, cv.po_basic_sno, po2.po_df_no AS po_no
                          FROM dbo.service_po_cycle_vendor cv
                          LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = cv.vendor_sno
                          LEFT JOIN dbo.po_request_info po2 ON po2.po_basic_sno = cv.po_basic_sno
                          WHERE cv.cycle_sno = c.cycle_sno
                          ORDER BY cv.cycle_vendor_sno
                          FOR JSON PATH
                      ) AS suppliers
               FROM dbo.service_po_cycle c
               WHERE c.agreement_sno = sa.agreement_sno
               ORDER BY c.billing_period_start DESC, c.cycle_sno DESC
               FOR JSON PATH
           ) AS cycles_json
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    WHERE sa.agreement_sno = @agreement_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetServiceAgreements
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceAgreements
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL, @status CHAR(1) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @status   = JSON_VALUE(@jsonInput, '$.status');
    END

    SELECT sa.agreement_sno, sa.agreement_no, sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
           sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
           sa.vendor_sno, k.company_name AS vendor_name,
           (
               SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
               FROM dbo.service_agreement_vendor v
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
               WHERE v.agreement_sno = sa.agreement_sno
               ORDER BY v.sort_order, v.agreement_vendor_sno
               FOR JSON PATH
           ) AS vendors_json,
           (SELECT COUNT(*) FROM dbo.service_agreement_vendor v WHERE v.agreement_sno = sa.agreement_sno) AS supplier_count,
           sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
           sa.recurrence_cadence_sno, rc.cadence_name, rc.interval_unit, rc.interval_value,
           sa.po_generation_day, sa.notify_days_before,
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks, sa.terms_conditions,
           sa.ceiling_amount,
           stt.facility_type, stt.facility_ref_no, stt.sanctioned_amount, stt.drawing_power,
           stt.rate_type, stt.benchmark_rate_pct, stt.spread_pct, stt.interest_rate_pct,
           stt.benchmark_name, stt.disbursed_amount, stt.disbursement_date, stt.interest_payment_day, stt.day_count_basis,
           (SELECT MAX(ver.version_no) FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno) AS version_no,
           (SELECT COUNT(*) FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno AND ver.action_type = 'RENEWED') AS renewal_count,
           sa.current_approver_id, sa.status, sa.created_by, sa.created_at
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    LEFT JOIN dbo.service_agreement_statutory stt ON stt.agreement_sno = sa.agreement_sno
    WHERE sa.is_active = 'Y'
      AND (@com_sno IS NULL OR sa.com_sno = @com_sno)
      AND (@div_sno IS NULL OR sa.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR sa.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR sa.dept_sno = @dept_sno)
      AND (@status IS NULL OR sa.status = @status)
    ORDER BY sa.agreement_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetServiceAgreementsForApproval
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT sa.agreement_sno, sa.agreement_no, sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
           sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
           sa.vendor_sno, k.company_name AS vendor_name,
           (
               SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
               FROM dbo.service_agreement_vendor v
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
               WHERE v.agreement_sno = sa.agreement_sno
               ORDER BY v.sort_order, v.agreement_vendor_sno
               FOR JSON PATH
           ) AS vendors_json,
           sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
           sa.recurrence_cadence_sno, rc.cadence_name,
           sa.po_generation_day, sa.notify_days_before,
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks, sa.terms_conditions,
           sa.ceiling_amount,
           stt.facility_type, stt.facility_ref_no, stt.sanctioned_amount, stt.drawing_power,
           stt.rate_type, stt.benchmark_rate_pct, stt.spread_pct, stt.interest_rate_pct,
           stt.benchmark_name, stt.disbursed_amount, stt.disbursement_date, stt.interest_payment_day, stt.day_count_basis,
           cv.cur_version AS version_no,
           (SELECT ver.action_type FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno AND ver.version_no = cv.cur_version) AS submit_action,
           (SELECT ver.terms_json FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno AND ver.version_no = cv.cur_version - 1) AS prev_terms_json,
           sa.current_approver_id, sa.status, sa.created_by, sa.created_at,
           (
               SELECT ws.stage_order_json
               FROM dbo.workflow_stage ws
               WHERE ws.workflow_types_id = sa.workflow_types_id AND ws.is_active = 'Y'
           ) AS stage_order_json
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    LEFT JOIN dbo.service_agreement_statutory stt ON stt.agreement_sno = sa.agreement_sno
    OUTER APPLY (SELECT MAX(ver.version_no) AS cur_version FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno) cv
    WHERE sa.is_active = 'Y' AND sa.status = 'P' AND sa.current_approver_id = @Ecno
    ORDER BY sa.agreement_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetServicePoCycles  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServicePoCycles
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    END

    SELECT spc.cycle_sno, spc.agreement_sno, sa.agreement_no,
           spc.com_sno, spc.div_sno, spc.brn_sno, spc.dept_sno,
           sm.service_name, st.service_type_code, st.service_type_name,
           k.company_name AS vendor_name,
           (
               SELECT cv.vendor_sno, kv.company_name AS vendor_name, cv.share_pct, cv.rate_amount, cv.net_cost,
                      cv.po_basic_sno, po2.po_df_no AS po_no
               FROM dbo.service_po_cycle_vendor cv
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = cv.vendor_sno
               LEFT JOIN dbo.po_request_info po2 ON po2.po_basic_sno = cv.po_basic_sno
               WHERE cv.cycle_sno = spc.cycle_sno
               ORDER BY cv.cycle_vendor_sno
               FOR JSON PATH
           ) AS vendors_json,
           (
               SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
               FROM dbo.service_agreement_vendor v
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
               WHERE v.agreement_sno = spc.agreement_sno
               ORDER BY v.sort_order, v.agreement_vendor_sno
               FOR JSON PATH
           ) AS agreement_vendors_json,
           spc.billing_period_start, spc.qty, spc.rate_amount, spc.discount_pct, spc.gst_pct, spc.net_cost,
           sa.ceiling_amount, spc.status, spc.current_approver_id,
           stt.facility_type, stt.rate_type, stt.interest_rate_pct, stt.sanctioned_amount,
           spc.po_basic_sno, po.po_df_no AS po_no, po.po_date,
           spc.entered_by, spc.entered_at, spc.created_at
    FROM dbo.service_po_cycle spc
    JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = spc.po_basic_sno
    LEFT JOIN dbo.service_agreement_statutory stt ON stt.agreement_sno = sa.agreement_sno
    WHERE (@com_sno IS NULL OR spc.com_sno = @com_sno)
      AND (@div_sno IS NULL OR spc.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR spc.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR spc.dept_sno = @dept_sno)
    ORDER BY spc.cycle_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetServicePoCyclesForApproval  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServicePoCyclesForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT spc.cycle_sno, spc.agreement_sno, sa.agreement_no,
           sm.service_name, st.service_type_code, st.service_type_name,
           k.company_name AS vendor_name,
           (
               SELECT cv.vendor_sno, kv.company_name AS vendor_name, cv.share_pct, cv.rate_amount, cv.net_cost
               FROM dbo.service_po_cycle_vendor cv
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = cv.vendor_sno
               WHERE cv.cycle_sno = spc.cycle_sno
               ORDER BY cv.cycle_vendor_sno
               FOR JSON PATH
           ) AS vendors_json,
           spc.billing_period_start, spc.qty, spc.rate_amount, spc.discount_pct, spc.gst_pct, spc.net_cost,
           sa.ceiling_amount, spc.status, spc.current_approver_id, spc.entered_by, spc.entered_at,
           stt.facility_type, stt.rate_type, stt.interest_rate_pct, stt.sanctioned_amount,
           (
               SELECT ws.stage_order_json
               FROM dbo.workflow_stage ws
               WHERE ws.workflow_types_id = spc.workflow_types_id AND ws.is_active = 'Y'
           ) AS stage_order_json
    FROM dbo.service_po_cycle spc
    JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.service_agreement_statutory stt ON stt.agreement_sno = sa.agreement_sno
    WHERE spc.status = 'PENDING_APPROVAL' AND spc.current_approver_id = @Ecno
    ORDER BY spc.cycle_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetServicePoDispatchInfo  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServicePoDispatchInfo
    @po_basic_sno INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1
        'S' AS dispatch_type, CAST(NULL AS VARCHAR(30)) AS incharge_ecno,
        po.po_basic_sno, po.po_df_no AS po_no, po.po_date, po.required_date,
        pid.qty, pid.agreed_unit_price AS rate_amount, pid.service_sno, sm.service_name,
        sa.agreement_sno, sa.agreement_no, sa.created_by,
        k.company_name AS vendor_name, k.email AS vendor_email
    FROM dbo.po_request_info po
    JOIN dbo.po_item_details pid ON pid.po_basic_sno = po.po_basic_sno AND pid.is_active = '1'
    JOIN dbo.service_master sm ON sm.service_sno = pid.service_sno
    LEFT JOIN dbo.pr_item_details prd ON prd.pr_basic_sno = po.pr_basic_sno AND prd.agreement_sno IS NOT NULL
    LEFT JOIN dbo.service_agreement sa ON sa.agreement_sno = prd.agreement_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = po.vendor_sno
    WHERE po.po_basic_sno = @po_basic_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetServiceRecords
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceRecords
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @service_type_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @service_type_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT);

    SELECT sm.service_sno, sm.service_name, sm.service_code, sm.service_type_sno,
           st.service_type_code, st.service_type_name,
           sm.default_uom_sno, um.uom_name AS default_uom_name,
           sm.description, sm.is_active
    FROM dbo.service_master sm
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sm.default_uom_sno
    WHERE sm.is_active = 'Y'
      AND (@service_type_sno IS NULL OR sm.service_type_sno = @service_type_sno)
    ORDER BY sm.service_name;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetServiceTypeRecords
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceTypeRecords
AS
BEGIN
    SET NOCOUNT ON;
    SELECT service_type_sno, service_type_code, service_type_name, is_active
    FROM dbo.service_type_master
    WHERE is_active = 'Y'
    ORDER BY service_type_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetStockBatches  (new)
-- ── sp_nt_GetStockBatches — FIFO-ordered batch list for one item ─────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStockBatches
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @item_sno INT = JSON_VALUE(@jsonInput, '$.item_sno');

    SELECT
        b.batch_sno, b.batch_no, b.item_sno, b.grn_basic_sno, b.grn_item_sno, b.grn_no,
        b.received_qty, b.remaining_qty, b.unit_cost,
        CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
        b.uom, b.status, b.created_by,
        CONVERT(VARCHAR(30), b.created_at, 120) AS created_at
    FROM dbo.nt_stock_batches b
    WHERE b.item_sno = @item_sno
    ORDER BY b.received_date ASC, b.batch_sno ASC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetStockMovements
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStockMovements
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno INT = JSON_VALUE(@jsonInput, '$.item_sno');

    SELECT
        movement_sno, item_sno, item_code, item_name, movement_type, quantity,
        balance_after, uom, reference_no, warehouse, reason, batch_sno, created_by,
        CONVERT(VARCHAR(30), created_at, 120) AS created_at
    FROM dbo.nt_stock_movements
    WHERE item_sno = @item_sno
    ORDER BY movement_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetStockRequests
-- ── sp_nt_GetStockRequests ───────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStockRequests
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status       VARCHAR(30) = NULL;
    DECLARE @requested_by VARCHAR(50) = NULL;
    DECLARE @com_sno      INT         = NULL;
    DECLARE @div_sno      INT         = NULL;
    DECLARE @brn_sno      INT         = NULL;
    DECLARE @dept_sno     INT         = NULL;
    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status       = JSON_VALUE(@jsonInput, '$.status');
        SET @requested_by = JSON_VALUE(@jsonInput, '$.requested_by');
        SET @com_sno      = JSON_VALUE(@jsonInput, '$.com_sno');
        SET @div_sno      = JSON_VALUE(@jsonInput, '$.div_sno');
        SET @brn_sno      = JSON_VALUE(@jsonInput, '$.brn_sno');
        SET @dept_sno     = JSON_VALUE(@jsonInput, '$.dept_sno');
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');
    END

    SELECT
        r.request_sno, r.request_no, r.requested_by, r.requested_name, r.department,
        r.purpose, r.status, r.reject_reason, r.issued_by,
        r.source_type, r.pr_basic_sno, r.pr_no, r.grn_basic_sno,
        r.received_by_ecno, r.received_by_name,
        r.com_sno, c.com_name,
        r.div_sno, dv.div_name,
        r.brn_sno, br.brn_name,
        r.dept_sno, dp.dept_name,
        (SELECT COUNT(*)                 FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS item_count,
        (SELECT ISNULL(SUM(requested_qty), 0) FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS total_requested_qty,
        (SELECT ISNULL(SUM(issued_qty), 0)    FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS total_issued_qty,
        CONVERT(VARCHAR(30), r.issued_at, 120)  AS issued_at,
        CONVERT(VARCHAR(30), r.created_at, 120) AS created_at,
        CONVERT(VARCHAR(30), r.updated_at, 120) AS updated_at
    FROM dbo.nt_stock_requests r
    LEFT JOIN dbo.company_master c   ON c.com_sno  = r.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = r.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = r.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = r.dept_sno
    WHERE (@status       IS NULL OR r.status       = @status)
      AND (@requested_by IS NULL OR r.requested_by = @requested_by)
      AND (@com_sno      IS NULL OR r.com_sno      = @com_sno)
      AND (@div_sno      IS NULL OR r.div_sno      = @div_sno)
      AND (@brn_sno      IS NULL OR r.brn_sno      = @brn_sno)
      AND (@dept_sno     IS NULL OR r.dept_sno     = @dept_sno)
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = r.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = r.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = r.brn_sno)
          )
      )
    ORDER BY r.request_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetSupplierQuotations
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetSupplierQuotations]  
    @pr_basic_sno INT,  
    @pr_no        VARCHAR(20)  
AS  
BEGIN  
    SET NOCOUNT ON;  
  
    SELECT  
        sq.*,  
        (  
            SELECT  
                sqi.sq_item_sno,  
                sqi.sq_basic_sno,  
                sqi.pr_item_sno,  
                sqi.prod_sno,  
                pm.prod_name,  
                sqi.specification,  
                sqi.qty        AS unit,  
                sqi.unit_price,  
                sqi.discount_pct,  
                sqi.tax_pct,  
                sqi.total_amount,  
                sqi.delivery_days,  
                sqi.remarks,  
                sqi.is_active  
            FROM supplier_quotation_items sqi  
            INNER JOIN product_master pm  
                ON sqi.prod_sno = pm.prod_sno  
            WHERE sqi.sq_basic_sno = sq.sq_basic_sno  
            FOR JSON PATH  
        ) AS sq_items,
        (
            SELECT
                sa.sq_adv_sno,
                sa.sq_basic_sno,
                sa.quotation_ref_no,
                sa.payment_terms,
                sa.advance_payment_pct,
                sa.gst_applicable,
                sa.gst_pct,
                sa.reason,
                sa.note,
                sa.adv_issue_stages,
                sa.is_active,
                sa.created_by,
                sa.created_date
            FROM [Non_trade_Dev].[dbo].[supplier_advance] sa
            WHERE sa.sq_basic_sno = sq.sq_basic_sno
            FOR JSON PATH
        ) AS supplier_advance
    FROM supplier_quotation_info sq  
    WHERE  
        sq.is_active   = 1  
        AND sq.pr_basic_sno = @pr_basic_sno  
        AND sq.pr_no        = @pr_no;  
END;

GO
-- [F2. procedures] dbo.sp_nt_GetTermsConditionsRecords
-- ============================================================
-- Company/Division/Branch access scoping — finish wiring an already
-- partially-built feature.
-- Database: Non_trade_Dev (MSSQL)
--
-- sp_nt_GetUserHierarchy, sp_get_pr_details_for_approval and
-- sp_nt_GetQuotationsForApproval already exist live with an @HierarchyJson
-- parameter (a prior, half-finished attempt at this same feature — no
-- matching Node code was ever committed). Those three needed NO SQL change,
-- only Node-side wiring (see backend-stpl/src/Middleware/hierarchyScope.js
-- and the PR/PO repository changes in this same commit).
--
-- sp_nt_GetApprovedPRsForPurchase also already has @HierarchyJson and uses
-- it correctly — its bug was purely on the Node side (PurchaseTeamRepository
-- wrapped it in a generic @jsonInput blob the SP never declared, so the
-- param was silently never bound). Also fixed in Node only, no SQL change.
--
-- This file's only actual schema/proc change: sp_nt_GetTermsConditionsRecords
-- had no scoping at all — every caller saw every company's T&C rows. Adding
-- the same optional @HierarchyJson pattern as the other procs above.
--
-- Convention (matches the existing procs, do not deviate): @HierarchyJson is
-- an OPENJSON array of {com_sno, div_sno, brn_sno}. NULL means "no filter"
-- (kept only for callers that intentionally want everything, e.g. future
-- admin tooling). The application layer is responsible for the actual
-- access-control default: an ecno with zero hierarchy_json rows must be
-- sent '[]' (an empty JSON array), never NULL, so EXISTS(...) is false for
-- every row and the caller sees nothing until an admin assigns them a
-- company/division/branch. See hierarchyScope.js for where that's enforced.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetTermsConditionsRecords
    @HierarchyJson NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.tc_sno,
        t.tc_title,
        t.tc_text,
        t.com_sno,  c.com_name,
        t.div_sno,  d.div_name,
        t.brn_sno,  b.brn_name,
        t.dept_sno, dm.dept_name,
        t.is_default,
        t.is_active,
        t.created_by,
        CONVERT(VARCHAR(30), t.created_date, 120)  AS created_date,
        t.modified_by,
        CONVERT(VARCHAR(30), t.modified_date, 120) AS modified_date
    FROM dbo.terms_conditions_master t
    JOIN dbo.company_master  c  ON c.com_sno   = t.com_sno
    JOIN dbo.division_master d  ON d.div_sno   = t.div_sno
    JOIN dbo.branch_master   b  ON b.brn_sno   = t.brn_sno
    JOIN dbo.dept_master     dm ON dm.dept_sno = t.dept_sno
    WHERE t.is_active = 'Y'
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = t.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = t.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = t.brn_sno)
          )
      )
    ORDER BY c.com_name, d.div_name, b.brn_name, dm.dept_name, t.is_default DESC, t.tc_title;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetUserHierarchy
-- ============================================================
-- Fix: department-level access grants were silently widened to full-branch
-- access, and inventory items never carried a department at all.
-- Database: Non_trade_Dev (MSSQL)
--
-- Root cause (KTM1006's "given access only to Canteen but sees all
-- inventory" report, 2026-09-15):
--
-- 1. sp_nt_GetUserHierarchy (the single shared source every @HierarchyJson
--    filter in this rollout reads from — see [project-ecno-org-scope-and-
--    grn-fifo] memory) only ever returned com_sno/div_sno/brn_sno. Even a
--    correctly department-scoped hierarchy_json row like {com:1,div:3,
--    brn:4,dept:16} came back as just {com:1,div:3,brn:4} — indistinguishable
--    from real full-branch access. Fixed here: dept_sno now included.
--    Safe/additive for every other already-scoped endpoint (PR/PO/
--    PurchaseTeam/TermsConditions/GRN/StockRequests/Masters) — their own
--    OPENJSON...WITH clauses don't project dept_sno, so the extra field is
--    silently ignored there; only a consumer that explicitly adds a
--    dept_sno column to its WITH clause (sp_nt_GetInventoryItems below)
--    actually gains department precision.
--
-- 2. Separately, UserRoleApprovalScreen.tsx's buildHierarchyPayload()
--    treats selectedCompanies/selectedDivisions/selectedBranches/
--    selectedDepartments as four INDEPENDENT arrays and writes one
--    hierarchy_json row per selected id at EVERY level, not just the
--    deepest one. Drilling down through the company/division/branch
--    pickers to reach a department (a natural interaction, since each
--    list is filtered by the parent's selection) checks each intermediate
--    level along the way, and each becomes its own full-width grant. This
--    is why KTM1006 ended up with three rows — {com:1}, {com:1,div:3},
--    {com:1,div:3,brn:4} — and no dept:16 row at all: the department step
--    was never actually reached/checked. Not fixed by this SQL file (it's
--    a frontend/UX issue) — KTM1006's bad rows are corrected by hand below,
--    and admins granting department-only access need to leave the
--    Company/Division/Branch pickers unchecked and select only the
--    Department, until that screen is reworked.
--
-- 3. Even with correct hierarchy_json, nt_inventory_items never had a
--    dept_sno populated on receipt — sp_nt_UpsertInventoryItemByProduct
--    (called from grn-service's receiveFromGRN, which DOES already
--    resolve dept_sno from the GRN's own org context) never accepted or
--    stored it. Fixed in grn-service/sql/34_inventory_dept_scope_fix.sql,
--    which also backfills the 3 existing Canteen items (Carrot/Tomato/
--    Onion, all received under dept_sno=16 per their real GRN history)
--    since they predate this fix and would otherwise stay invisible to a
--    correctly department-scoped user forever.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetUserHierarchy
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX);
    SELECT TOP 1 @HierarchyJson = hierarchy_json
    FROM dbo.nt_user_permissions_json
    WHERE ecno = @Ecno AND is_active = 'Y'
    ORDER BY user_perm_json_sno DESC;

    SELECT com_sno, div_sno, brn_sno, dept_sno
    FROM OPENJSON(@HierarchyJson)
    WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno');
END;
GO
-- [F2. procedures] dbo.sp_nt_GetVendorDrivenApprovedPRs  (new)
-- Surfaces the new header-level attachment alongside the item list. Existing
-- item rows created before this migration may still carry their own
-- pr_prod_file — kept as-is, still returned, just no longer written to.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetVendorDrivenApprovedPRs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.pr_basic_sno,
        p.pr_no,
        p.com_sno,
        c.com_name,
        p.div_sno,
        dv.div_name,
        p.brn_sno,
        br.brn_name,
        p.dept_sno,
        dp.dept_name,
        CONVERT(VARCHAR(10), p.reg_date, 120) AS reg_date,
        CONVERT(VARCHAR(10), p.required_date, 120) AS required_date,
        p.priority_sno,
        pm.priority_name,
        p.purpose,
        p.request_mode,
        pvd.vendor_sno,
        k.company_name AS vendor_name,
        pvd.payment_cycle_days,
        pvd.attachment,
        p.created_by,
        p.created_date,
        p.status,
        (
            SELECT
                pid.pr_item_sno,
                pid.prod_sno,
                COALESCE(pid.item_description, product.prod_name) AS prod_name,
                pid.qty,
                pid.unit,
                uom.uom_name AS unit_name,
                pvid.item_rate AS rate,
                pvid.gst_pct,
                pvid.discount_pct,
                pvid.taxable_amount,
                pvid.gst_amount,
                pid.total_cost,
                pid.remarks,
                pid.pr_prod_file AS item_attachment
            FROM dbo.pr_item_details pid
            INNER JOIN dbo.pr_vendor_driven_item_details pvid ON pvid.pr_item_sno = pid.pr_item_sno
            LEFT JOIN dbo.product_master product ON product.prod_sno = pid.prod_sno
            LEFT JOIN dbo.uom_master uom ON uom.uom_sno = pid.unit
            WHERE pid.pr_basic_sno = p.pr_basic_sno
              AND pid.is_active = 'Y'
            FOR JSON PATH
        ) AS pr_item_details
    FROM dbo.pr_basic_info p
    INNER JOIN dbo.pr_vendor_driven_info pvd ON pvd.pr_basic_sno = p.pr_basic_sno
    LEFT JOIN dbo.company_master c ON c.com_sno = p.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = p.div_sno
    LEFT JOIN dbo.branch_master br ON br.brn_sno = p.brn_sno
    LEFT JOIN dbo.dept_master dp ON dp.dept_sno = p.dept_sno
    LEFT JOIN dbo.priority_master pm ON pm.priority_sno = p.priority_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pvd.vendor_sno
    WHERE p.is_active = 'Y'
      AND p.request_mode = 'VENDOR_DRIVEN'
      AND p.status = 'A'
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.po_request_info po
          WHERE po.pr_basic_sno = p.pr_basic_sno
            AND po.is_active = 'Y'
      )
    ORDER BY p.pr_basic_sno DESC;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetVendorDrivenBillableChildPOs  (new)
-- ============================================================
-- Vendor-driven billing/payment: join the new pr_vendor_driven_info
-- extension table for vendor_sno/payment_cycle_days instead of reading
-- them off pr_basic_info directly (see backend-stpl/sql/74_
-- vendor_driven_extension_tables.sql — payment_cycle_days moved off
-- pr_basic_info into pr_vendor_driven_info). The request_mode filter/
-- column stays against pr_basic_info — that column did not move.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetVendorDrivenBillableChildPOs
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    IF @vendor_sno IS NULL
        THROW 61001, 'vendor_sno is required.', 1;

    SELECT
        po.po_basic_sno,
        po.po_df_no,
        CONVERT(VARCHAR(10), po.po_date, 120) AS po_date,
        po.vendor_sno,
        k.company_name AS vendor_name,
        po.com_sno,
        po.div_sno,
        po.brn_sno,
        po.dept_sno,
        pr.pr_basic_sno,
        pr.pr_no,
        pvd.payment_cycle_days,
        ge.vendor_invoice_no,
        ge.vendor_invoice_date,
        (
            SELECT
                poi.po_item_sno,
                poi.prod_sno,
                ISNULL(poi.prod_name, pm.prod_name) AS prod_name,
                poi.qty AS requested_qty,
                poi.unit_name,
                poi.net_cost AS line_value,
                (
                    SELECT ISNULL(SUM(g.received_qty - ISNULL(g.rejected_qty, 0)), 0)
                    FROM dbo.grn_item_details g
                    WHERE g.po_item_sno = poi.po_item_sno AND g.is_active = 'Y'
                ) AS received_qty
            FROM dbo.po_item_details poi
            LEFT JOIN dbo.product_master pm ON pm.prod_sno = poi.prod_sno
            WHERE poi.po_basic_sno = po.po_basic_sno
              AND poi.is_active IN ('1', 'Y')
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info po
    JOIN dbo.pr_basic_info pr ON pr.pr_basic_sno = po.pr_basic_sno
    JOIN dbo.pr_vendor_driven_info pvd ON pvd.pr_basic_sno = pr.pr_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = po.vendor_sno
    OUTER APPLY (
        SELECT TOP 1 g.vendor_invoice_no, g.vendor_invoice_date
        FROM (
            SELECT ge.invoice_no AS vendor_invoice_no, ge.invoice_date AS vendor_invoice_date, ge.received_date
            FROM dbo.grn_basic_info gb
            JOIN dbo.nt_gate_entry ge ON ge.gate_entry_sno = gb.gate_entry_sno
            WHERE gb.po_basic_sno = po.po_basic_sno AND gb.is_active = 'Y'
        ) g
        ORDER BY g.received_date DESC
    ) ge
    WHERE pr.request_mode = 'VENDOR_DRIVEN'
      AND po.vendor_sno = @vendor_sno
      AND po.is_active = 'Y'
      AND po.status = 'A'
      AND EXISTS (
          SELECT 1 FROM dbo.grn_basic_info gb
          WHERE gb.po_basic_sno = po.po_basic_sno AND gb.is_active = 'Y'
      )
      AND NOT EXISTS (
          SELECT 1 FROM dbo.invoice_info inv
          WHERE inv.po_basic_sno = po.po_basic_sno AND inv.is_active = 'Y'
      )
    ORDER BY po.po_basic_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_GetWarehouseLocationRecords
-- warehouse_location_master stores com_snos/div_snos/brn_snos as JSON
-- ARRAYS (one location can serve several companies/divisions/branches at
-- once) — a different shape from the single-value columns above, so the
-- match is "does any hierarchy row's com/div/brn appear in this location's
-- arrays" rather than a plain equality. A NULL/empty div_snos or brn_snos
-- array is treated as "not restricted at that level" (company- or
-- division-wide location), mirroring the div_sno/brn_sno IS NULL wildcard
-- used everywhere else in this rollout.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetWarehouseLocationRecords
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');

    SELECT
        l.location_sno,
        l.location_code,
        l.location_name,
        l.description,
        l.com_snos,
        l.div_snos,
        l.brn_snos,
        cn.com_names,
        dn.div_names,
        bn.brn_names,
        l.is_active,
        l.created_by,
        CONVERT(VARCHAR(30), l.created_at, 120)  AS created_at,
        l.modified_by,
        CONVERT(VARCHAR(30), l.modified_at, 120) AS modified_at
    FROM dbo.warehouse_location_master l
    OUTER APPLY (
        SELECT STRING_AGG(c.com_name, ', ') AS com_names
        FROM OPENJSON(l.com_snos) j
        JOIN dbo.company_master c ON c.com_sno = TRY_CAST(j.value AS INT)
    ) cn
    OUTER APPLY (
        SELECT STRING_AGG(d.div_name, ', ') AS div_names
        FROM OPENJSON(l.div_snos) j
        JOIN dbo.division_master d ON d.div_sno = TRY_CAST(j.value AS INT)
    ) dn
    OUTER APPLY (
        SELECT STRING_AGG(b.brn_name, ', ') AS brn_names
        FROM OPENJSON(l.brn_snos) j
        JOIN dbo.branch_master b ON b.brn_sno = TRY_CAST(j.value AS INT)
    ) bn
    WHERE l.is_active = 'Y'
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE EXISTS (
                    SELECT 1 FROM OPENJSON(l.com_snos) cj WHERE TRY_CAST(cj.value AS INT) = h.com_sno
                )
                AND (
                    h.div_sno IS NULL
                    OR l.div_snos IS NULL
                    OR NOT EXISTS (SELECT 1 FROM OPENJSON(l.div_snos))
                    OR EXISTS (SELECT 1 FROM OPENJSON(l.div_snos) dj WHERE TRY_CAST(dj.value AS INT) = h.div_sno)
                )
                AND (
                    h.brn_sno IS NULL
                    OR l.brn_snos IS NULL
                    OR NOT EXISTS (SELECT 1 FROM OPENJSON(l.brn_snos))
                    OR EXISTS (SELECT 1 FROM OPENJSON(l.brn_snos) bj WHERE TRY_CAST(bj.value AS INT) = h.brn_sno)
                )
            )
      )
    ORDER BY l.location_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_GrantScreenToUser
CREATE OR ALTER PROCEDURE dbo.sp_nt_GrantScreenToUser
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ecno VARCHAR(50) = JSON_VALUE(@jsonInput, '$.ecno');
    DECLARE @screen_id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.screen_id') AS INT);
    DECLARE @permission_ids NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.permission_ids');

    IF @ecno IS NULL OR @screen_id IS NULL OR @permission_ids IS NULL
        THROW 58230, 'ecno, screen_id and permission_ids are required.', 1;

    DECLARE @user_perm_json_sno INT, @screens_json NVARCHAR(MAX);
    SELECT TOP 1 @user_perm_json_sno = user_perm_json_sno, @screens_json = RTRIM(screens_json)
    FROM dbo.nt_user_permissions_json
    WHERE ecno = @ecno AND is_active = 'Y'
    ORDER BY user_perm_json_sno DESC;

    IF @user_perm_json_sno IS NULL
        THROW 58231, 'No active nt_user_permissions_json row for this ecno.', 1;

    IF EXISTS (SELECT 1 FROM OPENJSON(@screens_json) WITH (screen_id INT '$.screen_id') WHERE screen_id = @screen_id)
    BEGIN
        SELECT 'ALREADY_GRANTED' AS result, @user_perm_json_sno AS user_perm_json_sno;
        RETURN;
    END

    DECLARE @newEntry NVARCHAR(MAX) = (SELECT @screen_id AS screen_id, JSON_QUERY(@permission_ids) AS permissions FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @updatedScreens NVARCHAR(MAX);
    IF @screens_json IS NULL OR @screens_json IN ('[]', '')
        SET @updatedScreens = '[' + @newEntry + ']';
    ELSE
        SET @updatedScreens = LEFT(@screens_json, LEN(@screens_json) - 1) + ',' + @newEntry + ']';

    UPDATE dbo.nt_user_permissions_json
    SET screens_json = @updatedScreens, updated_date = GETDATE()
    WHERE user_perm_json_sno = @user_perm_json_sno;

    SELECT 'GRANTED' AS result, @user_perm_json_sno AS user_perm_json_sno, @updatedScreens AS screens_json;
END;
GO
-- [F2. procedures] dbo.sp_nt_IssueRecurringServicePOCycle
CREATE OR ALTER PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT,
    @out_pr_basic_sno INT = NULL OUTPUT,
    @out_pr_no VARCHAR(20) = NULL OUTPUT,
    @out_cycle_sno INT = NULL OUTPUT,
    @out_cycle_status VARCHAR(20) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    DECLARE @billing_period_start DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
    DECLARE @issued_by VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

    -- Captured before any statement that could fail, so the CATCH block can
    -- always tell (a) whether a caller transaction was already open, and
    -- (b) whether THIS proc actually opened a transaction/savepoint of its
    -- own that it is responsible for undoing.
    DECLARE @outer_trancount INT = @@TRANCOUNT;
    DECLARE @own_scope_opened BIT = 0;

    BEGIN TRY
        IF @agreement_sno IS NULL OR @billing_period_start IS NULL
            THROW 58210, 'agreement_sno and billing_period_start are required.', 1;

        IF EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start)
        BEGIN
            SET @out_result = 'SKIPPED_ALREADY_CLAIMED';
            IF @silent = 0 SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END

        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                @qty DECIMAL(18,4), @rate_amount DECIMAL(18,2), @rate_uom_sno INT, @agreement_no VARCHAR(30),
                @service_name NVARCHAR(150), @agr_status CHAR(1), @period_end DATE, @service_type_code VARCHAR(30);

        SELECT @com_sno = sa.com_sno, @div_sno = sa.div_sno, @brn_sno = sa.brn_sno, @dept_sno = sa.dept_sno,
               @service_sno = sa.service_sno, @vendor_sno = sa.vendor_sno, @qty = sa.qty, @rate_amount = sa.rate_amount,
               @rate_uom_sno = sa.rate_uom_sno, @agreement_no = sa.agreement_no, @agr_status = sa.status,
               @period_end = sa.period_end_date, @service_name = sm.service_name, @service_type_code = st.service_type_code
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @agr_status IS NULL THROW 58211, 'Agreement not found.', 1;
        IF @agr_status <> 'A' THROW 58212, 'Agreement is not Approved.', 1;

        -- sql/89: a Statutory agreement is a LOAN. It raises no PR / PO / cycle -- interest
        -- is billed through Bank Payment Vouchers (Loan Payments) instead.
        IF @service_type_code = 'STATUTORY'
        BEGIN
            SET @out_result = 'SKIPPED_STATUTORY';
            IF @silent = 0 SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END
        IF @billing_period_start > @period_end THROW 58213, 'billing_period_start is past the agreement period_end_date.', 1;

        -- Claim the slot before doing any real work, outside the main
        -- transaction, so it survives a rollback and guarantees idempotency
        -- even under a concurrent sweep.
        INSERT INTO dbo.service_agreement_recurring_pr_log (agreement_sno, billing_period_start, status)
        VALUES (@agreement_sno, @billing_period_start, 'PENDING');

        -- Nestable-safe: reuse the caller's transaction via a savepoint
        -- instead of opening our own when one is already open (see file
        -- header) — a failure below then only undoes this proc's own
        -- work, never the caller's.
        IF @outer_trancount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION svp_IssueCycle;
        SET @own_scope_opened = 1;

        DECLARE @default_priority_sno INT;
        SELECT TOP 1 @default_priority_sno = priority_sno
        FROM dbo.priority_master
        WHERE is_active = 'Y'
        ORDER BY CASE WHEN priority_name = 'Medium' THEN 0 ELSE 1 END, priority_sno;
        IF @default_priority_sno IS NULL
            THROW 58214, 'No active priority_master row found to assign to the auto-generated PR.', 1;

        DECLARE @current_year VARCHAR(10) = dbo.fn_GetFinancialYear(GETDATE());
        DECLARE @pr_prefix VARCHAR(20) = 'PR' + @current_year;
        DECLARE @pr_seq INT;
        SELECT @pr_seq = ISNULL(MAX(CASE WHEN pr_no LIKE @pr_prefix + '%' THEN TRY_CAST(SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no)) AS INT) ELSE 0 END), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';
        DECLARE @pr_no VARCHAR(20) = @pr_prefix + RIGHT('0000' + CAST(@pr_seq AS VARCHAR(4)), 4);

        -- Auto-approved: status='A', no workflow — same audit-trail-only PR
        -- as before this file, untouched.
        INSERT INTO dbo.pr_basic_info (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date, priority_sno, purpose,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start, @billing_period_start, @default_priority_sno,
            N'Auto-generated recurring PR — Service Agreement ' + @agreement_no,
            'Y', @issued_by, GETDATE(), NULL, NULL, 'A'
        );
        DECLARE @pr_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost, remarks, specification,
            item_type, service_sno, agreement_sno, is_active, created_by, created_date
        )
        VALUES (
            @pr_no, @pr_basic_sno, NULL, @qty, @rate_uom_sno, @rate_amount, @rate_amount * @qty, '', '',
            'service', @service_sno, @agreement_sno, 'Y', @issued_by, GETDATE()
        );

        -- ── Queue a service_po_cycle instead of issuing the PO directly.
        --    Fixed: nothing to enter, straight to Pending Approval with the
        --    agreement's already-agreed rate/qty. Unfixed: Pending Entry,
        --    rate resolved later by sp_nt_SubmitServicePoEntry. ───────────
        DECLARE @cycle_status VARCHAR(20), @cycle_workflow_types_id INT = NULL, @cycle_approver VARCHAR(30) = NULL,
                @cycle_rate DECIMAL(18,2) = NULL, @cycle_net_cost DECIMAL(18,2) = NULL;

        IF @service_type_code = 'FIXED_RECURRING'
        BEGIN
            SET @cycle_status = 'PENDING_APPROVAL';
            SET @cycle_rate = @rate_amount;
            SET @cycle_net_cost = @rate_amount * @qty;
            EXEC dbo.sp_nt_ResolveServicePoWorkflow
                @com_sno = @com_sno, @div_sno = @div_sno, @brn_sno = @brn_sno, @dept_sno = @dept_sno,
                @workflow_types_id = @cycle_workflow_types_id OUTPUT, @first_approver = @cycle_approver OUTPUT;
        END
        ELSE
            SET @cycle_status = 'PENDING_ENTRY';

        INSERT INTO dbo.service_po_cycle (
            agreement_sno, com_sno, div_sno, brn_sno, dept_sno, billing_period_start,
            pr_basic_sno, pr_no, qty, rate_amount, net_cost, status,
            workflow_types_id, current_approver_id
        )
        VALUES (
            @agreement_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start,
            @pr_basic_sno, @pr_no, @qty, @cycle_rate, @cycle_net_cost, @cycle_status,
            @cycle_workflow_types_id, @cycle_approver
        );
        DECLARE @cycle_sno INT = SCOPE_IDENTITY();

        -- sql/88: a Fixed cycle already knows its rate, so split it across the
        -- agreement's suppliers now (Unfixed/Statutory do this when the rate is entered).
        IF @cycle_status = 'PENDING_APPROVAL'
        BEGIN
            DECLARE @split_net DECIMAL(18,2);
            EXEC dbo.sp_nt_BuildServicePoCycleSplit
                @cycle_sno = @cycle_sno, @agreement_sno = @agreement_sno, @rate_amount = @rate_amount, @qty = @qty,
                @discount_pct = 0, @gst_pct = 0, @out_net_cost = @split_net OUTPUT;
            UPDATE dbo.service_po_cycle SET net_cost = @split_net WHERE cycle_sno = @cycle_sno;
        END

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'CYCLE_CREATED', @issued_by,
                CASE WHEN @cycle_status = 'PENDING_APPROVAL' THEN N'Fixed agreement — queued directly for approval.' ELSE N'Unfixed agreement — awaiting rate/GST entry.' END);

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'CREATED', pr_basic_sno = @pr_basic_sno, pr_no = @pr_no, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start;

        IF @outer_trancount = 0
            COMMIT TRANSACTION;

        SET @out_result = 'SUCCESS';
        SET @out_pr_basic_sno = @pr_basic_sno;
        SET @out_pr_no = @pr_no;
        SET @out_cycle_sno = @cycle_sno;
        SET @out_cycle_status = @cycle_status;

        IF @silent = 0
            SELECT 'SUCCESS' AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start,
                   @pr_basic_sno AS pr_basic_sno, @pr_no AS pr_no, @cycle_sno AS cycle_sno, @cycle_status AS cycle_status;
    END TRY
    BEGIN CATCH
        IF @own_scope_opened = 1 AND XACT_STATE() <> 0
        BEGIN
            IF @outer_trancount = 0 OR XACT_STATE() = -1
                ROLLBACK TRANSACTION;
            ELSE
                ROLLBACK TRANSACTION svp_IssueCycle;
        END

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'FAILED', error_message = ERROR_MESSAGE(), modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start AND status = 'PENDING';

        SET @out_result = 'ERROR';
        IF @silent = 0 THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_IssueStockRequest
-- sp_nt_IssueStockRequest's Recordset 1 (header) — add com/div/brn so the
-- issue broadcast can be org-scoped too (Recordset 2/movements already had
-- them from the FIFO migration in 32_grn_stock_batches_fifo.sql).
CREATE OR ALTER PROCEDURE dbo.sp_nt_IssueStockRequest
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @request_sno     INT         = JSON_VALUE(@jsonInput, '$.request_sno');
    DECLARE @issued_by       VARCHAR(50) = JSON_VALUE(@jsonInput, '$.issued_by');
    DECLARE @received_by_ecno VARCHAR(50) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.received_by_ecno'))), '');

    IF @request_sno IS NULL OR @issued_by IS NULL
    BEGIN
        RAISERROR('request_sno and issued_by are required.', 16, 1);
        RETURN;
    END

    IF @received_by_ecno IS NULL
    BEGIN
        RAISERROR('received_by_ecno (the receiving employee''s ECNO) is required.', 16, 1);
        RETURN;
    END

    DECLARE @received_by_name VARCHAR(255);
    SELECT @received_by_name = ename FROM dbo.vw_verified_employees WHERE ecno = @received_by_ecno;

    IF @received_by_name IS NULL
    BEGIN
        RAISERROR('Receiving employee not found or not verified.', 16, 1);
        RETURN;
    END

    DECLARE @request_no VARCHAR(30), @req_status VARCHAR(30);
    DECLARE @requested_by VARCHAR(50);
    SELECT @request_no = request_no, @req_status = status, @requested_by = requested_by
    FROM dbo.nt_stock_requests
    WHERE request_sno = @request_sno;

    IF @request_no IS NULL
    BEGIN
        RAISERROR('Stock request not found.', 16, 1);
        RETURN;
    END

    IF @req_status NOT IN ('Pending', 'Partially Issued')
    BEGIN
        RAISERROR('Only Pending or Partially Issued requests can be issued (current status: %s).', 16, 1, @req_status);
        RETURN;
    END

    DECLARE @issue TABLE (
        sr_item_sno INT,
        issue_qty   DECIMAL(18,2)
    );

    INSERT INTO @issue (sr_item_sno, issue_qty)
    SELECT sr_item_sno, issue_qty
    FROM OPENJSON(@jsonInput, '$.items')
    WITH (
        sr_item_sno INT           '$.sr_item_sno',
        issue_qty   DECIMAL(18,2) '$.issue_qty'
    )
    WHERE issue_qty IS NOT NULL AND issue_qty > 0;

    IF NOT EXISTS (SELECT 1 FROM @issue)
    BEGIN
        RAISERROR('No issue quantities supplied.', 16, 1);
        RETURN;
    END

    IF EXISTS (
        SELECT 1 FROM @issue x
        LEFT JOIN dbo.nt_stock_request_items l
               ON l.sr_item_sno = x.sr_item_sno AND l.request_sno = @request_sno
        WHERE l.sr_item_sno IS NULL
    )
    BEGIN
        RAISERROR('One or more lines do not belong to this request.', 16, 1);
        RETURN;
    END

    BEGIN TRANSACTION;
    BEGIN TRY
        IF EXISTS (
            SELECT 1 FROM @issue x
            JOIN dbo.nt_stock_request_items l WITH (UPDLOCK, HOLDLOCK)
              ON l.sr_item_sno = x.sr_item_sno
            WHERE x.issue_qty > (l.requested_qty - l.issued_qty)
        )
        BEGIN
            RAISERROR('Issue quantity exceeds the pending quantity on a line.', 16, 1);
            RETURN;
        END

        IF EXISTS (
            SELECT 1 FROM @issue x
            JOIN dbo.nt_stock_request_items l ON l.sr_item_sno = x.sr_item_sno
            JOIN dbo.nt_inventory_items i WITH (UPDLOCK, HOLDLOCK)
              ON i.item_sno = l.item_sno
            WHERE x.issue_qty > i.current_stock
        )
        BEGIN
            RAISERROR('Insufficient stock for one or more items.', 16, 1);
            RETURN;
        END

        DECLARE @movements TABLE (movement_sno INT);

        DECLARE @sr_item_sno INT, @issue_qty DECIMAL(18,2);
        DECLARE issue_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT sr_item_sno, issue_qty FROM @issue;

        OPEN issue_cur;
        FETCH NEXT FROM issue_cur INTO @sr_item_sno, @issue_qty;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @item_sno INT, @new_stock DECIMAL(18,2);
            DECLARE @item_code VARCHAR(50), @item_name VARCHAR(255), @uom VARCHAR(20), @warehouse VARCHAR(100);
            DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT;

            SELECT @item_sno = item_sno
            FROM dbo.nt_stock_request_items
            WHERE sr_item_sno = @sr_item_sno;

            UPDATE dbo.nt_inventory_items
            SET current_stock = current_stock - @issue_qty,
                updated_by    = @issued_by,
                updated_at    = GETDATE(),
                @new_stock    = current_stock - @issue_qty,
                @item_code    = item_code,
                @item_name    = item_name,
                @uom          = uom,
                @warehouse    = warehouse,
                @com_sno      = com_sno,
                @div_sno      = div_sno,
                @brn_sno      = brn_sno,
                @dept_sno     = dept_sno
            WHERE item_sno = @item_sno;

            DECLARE @remaining_to_issue DECIMAL(18,2) = @issue_qty;
            DECLARE @b_batch_sno INT, @b_available DECIMAL(18,2), @draw_qty DECIMAL(18,2);

            DECLARE batch_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT batch_sno, remaining_qty
                FROM dbo.nt_stock_batches WITH (UPDLOCK, HOLDLOCK)
                WHERE item_sno = @item_sno AND remaining_qty > 0
                ORDER BY received_date ASC, batch_sno ASC;

            OPEN batch_cur;
            FETCH NEXT FROM batch_cur INTO @b_batch_sno, @b_available;
            WHILE @@FETCH_STATUS = 0 AND @remaining_to_issue > 0
            BEGIN
                SET @draw_qty = CASE WHEN @b_available <= @remaining_to_issue THEN @b_available ELSE @remaining_to_issue END;

                UPDATE dbo.nt_stock_batches
                SET remaining_qty = remaining_qty - @draw_qty,
                    status = CASE WHEN remaining_qty - @draw_qty <= 0 THEN 'Exhausted' ELSE 'Active' END
                WHERE batch_sno = @b_batch_sno;

                INSERT INTO dbo.nt_stock_movements (
                    item_sno, item_code, item_name, movement_type, quantity,
                    balance_after, uom, reference_no, warehouse, reason,
                    com_sno, div_sno, brn_sno, dept_sno, created_by, created_at,
                    received_by_ecno, received_by_name, batch_sno
                )
                VALUES (
                    @item_sno, @item_code, @item_name, 'OUT', @draw_qty,
                    @new_stock, @uom, @request_no, @warehouse,
                    'Stock Request Issue (' + @requested_by + ')',
                    @com_sno, @div_sno, @brn_sno, @dept_sno, @issued_by, GETDATE(),
                    @received_by_ecno, @received_by_name, @b_batch_sno
                );
                INSERT INTO @movements (movement_sno) VALUES (SCOPE_IDENTITY());

                SET @remaining_to_issue -= @draw_qty;
                FETCH NEXT FROM batch_cur INTO @b_batch_sno, @b_available;
            END
            CLOSE batch_cur;
            DEALLOCATE batch_cur;

            IF @remaining_to_issue > 0
            BEGIN
                INSERT INTO dbo.nt_stock_movements (
                    item_sno, item_code, item_name, movement_type, quantity,
                    balance_after, uom, reference_no, warehouse, reason,
                    com_sno, div_sno, brn_sno, dept_sno, created_by, created_at,
                    received_by_ecno, received_by_name, batch_sno
                )
                VALUES (
                    @item_sno, @item_code, @item_name, 'OUT', @remaining_to_issue,
                    @new_stock, @uom, @request_no, @warehouse,
                    'Stock Request Issue (' + @requested_by + ')',
                    @com_sno, @div_sno, @brn_sno, @dept_sno, @issued_by, GETDATE(),
                    @received_by_ecno, @received_by_name, NULL
                );
                INSERT INTO @movements (movement_sno) VALUES (SCOPE_IDENTITY());
            END

            UPDATE dbo.nt_stock_request_items
            SET issued_qty  = issued_qty + @issue_qty,
                line_status = CASE WHEN issued_qty + @issue_qty >= requested_qty
                                   THEN 'Issued' ELSE 'Partially Issued' END
            WHERE sr_item_sno = @sr_item_sno;

            FETCH NEXT FROM issue_cur INTO @sr_item_sno, @issue_qty;
        END
        CLOSE issue_cur;
        DEALLOCATE issue_cur;

        DECLARE @new_status VARCHAR(30) =
            CASE WHEN EXISTS (
                    SELECT 1 FROM dbo.nt_stock_request_items
                    WHERE request_sno = @request_sno AND issued_qty < requested_qty
                 )
                 THEN 'Partially Issued' ELSE 'Issued' END;

        UPDATE dbo.nt_stock_requests
        SET status           = @new_status,
            issued_by        = @issued_by,
            issued_at        = GETDATE(),
            received_by_ecno = @received_by_ecno,
            received_by_name = @received_by_name,
            updated_at       = GETDATE()
        WHERE request_sno = @request_sno;

        COMMIT TRANSACTION;

        -- Recordset 1: updated header (now includes com/div/brn)
        SELECT
            r.request_sno, r.request_no, r.requested_by, r.requested_name, r.department,
            r.purpose, r.status, r.issued_by, r.received_by_ecno, r.received_by_name,
            r.com_sno, r.div_sno, r.brn_sno,
            (SELECT ISNULL(SUM(issued_qty), 0) FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS total_issued_qty,
            CONVERT(VARCHAR(30), r.issued_at, 120) AS issued_at
        FROM dbo.nt_stock_requests r
        WHERE r.request_sno = @request_sno;

        -- Recordset 2: the movements this issue created
        SELECT
            m.movement_sno, m.item_sno, m.item_code, m.item_name, m.movement_type,
            m.quantity, m.balance_after, m.uom, m.reference_no, m.warehouse, m.reason,
            m.received_by_ecno, m.received_by_name, m.batch_sno,
            m.created_by, CONVERT(VARCHAR(30), m.created_at, 120) AS created_at
        FROM dbo.nt_stock_movements m
        JOIN @movements x ON x.movement_sno = m.movement_sno
        ORDER BY m.movement_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_LogPOSentToSupplier
-- ============================================================
-- PR Requester Tracking — read-only aggregation layer
-- Database : Non_trade_Dev (MSSQL, 10.0.21.8)
-- Used by  : new backend-stpl/src/PRTracking module (Node)
--
-- IMPORTANT — nothing existing is touched. UAT is currently exercising
-- usp_InsertPurchaseRequest / sp_approve_pr_datas / the quotation and PO
-- approval procedures live, so this file creates ONLY brand-new objects
-- (no CREATE OR ALTER, no DROP+CREATE on anything that already exists) and
-- reads from existing tables/views without writing to any of them except
-- one new additive INSERT-only procedure (#1 below). Nothing here can change
-- the behaviour of a procedure UAT is currently mid-flow on.
--
-- Discovery note: pr_history_data (pr_basic_sno, pr_edit_data, is_active,
-- workflow_types_id, approver_ecno, status, status_by, status_date, commends,
-- pr_no) already exists live and is already populated by sp_approve_pr_datas
-- on every approve/reject — it was simply never checked into this repo's sql/
-- folder before now (same situation usp_InsertPurchaseRequest was in until
-- 06_usp_InsertPurchaseRequest_v2.sql). No new PR audit table is needed —
-- this file only reads it, via the existing vw_PR_Basic_Info view which
-- already nests it as JSON.
--
-- Contents:
--   1. sp_nt_LogPOSentToSupplier   — new, additive INSERT into the existing
--      po_history_data table. Call this from PurchaseTeamService.sendPOEmail
--      right after a successful send; today nothing logs that transition.
--   2. sp_nt_GetPRTrackingTimeline — new, one PR's full journey (PR header +
--      history, Quotation, PO + history, Dispatch, Gate Entry, GRN + history,
--      Inventory movements) as multiple result sets, all joined via
--      pr_basic_sno -> po_request_info.pr_basic_sno -> po_basic_sno, the same
--      FK chain every existing downstream table already uses.
--   3. sp_nt_GetMyPRTracking       — new, the caller's own PRs with a
--      computed current_stage, for a "My Requests" list.
--   4. sp_nt_GetOrgPRTracking      — new, pending/active PRs within an org
--      scope (com/div/brn/dept), for the permission-gated "Team / Org View".
--   5. sp_nt_GetPrNoByPoBasicSno   — new, tiny lookup so grn-service/PurchaseTeam
--      touch points (which only carry po_basic_sno) can resolve which
--      pr:track:{pr_no} room to broadcast into.
--   6. sp_nt_HasScreenPermission   — new, server-side check of the existing
--      screens/permissions grant, gating the "Team / Org View" endpoint.
--   7. Screens row for the new PRTrackingPage, same pattern as every prior
--      screen registration in this series (e.g.
--      24_service_bill_request_screens_and_backfill.sql) — reuses the
--      existing sp_nt_GrantScreenToUser, no new grant mechanism.
--
-- Deliberately NOT done: no org columns added to nt_gate_entry /
-- nt_dispatch_slip / nt_dispatch_slip_delivery / nt_transport_master — every
-- query below reaches them through po_basic_sno, which is already resolved
-- from a com/div/brn/dept-scoped pr_basic_info/po_request_info row.
-- ============================================================

-- ── 1. sp_nt_LogPOSentToSupplier ────────────────────────────────────────────
-- Additive audit row only. Never called in a way that can fail the actual
-- PO-send response — see PurchaseTeamService.sendPOEmail wiring.
CREATE OR ALTER PROCEDURE dbo.sp_nt_LogPOSentToSupplier
    @po_basic_sno INT,
    @status_by    VARCHAR(20),
    @comment      VARCHAR(250) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
    VALUES (@po_basic_sno, 'SENT_TO_SUPPLIER', @status_by, @comment, 'Y');

    SELECT 'LOGGED' AS result, @po_basic_sno AS po_basic_sno, SCOPE_IDENTITY() AS po_history_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_MarkAgreementNotificationSent
CREATE OR ALTER PROCEDURE dbo.sp_nt_MarkAgreementNotificationSent
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    DECLARE @billing_period_start DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
    DECLARE @status VARCHAR(20) = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @notif_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.notif_sno') AS INT);
    DECLARE @error_message NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.error_message');

    IF @agreement_sno IS NULL OR @billing_period_start IS NULL OR @status NOT IN ('SENT', 'FAILED')
        THROW 58220, 'agreement_sno, billing_period_start and a valid status (SENT|FAILED) are required.', 1;

    UPDATE dbo.service_agreement_notification_log
    SET status = @status, notif_sno = @notif_sno, error_message = @error_message, modified_at = GETDATE()
    WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start;

    SELECT @@ROWCOUNT AS rows_updated;
END;
GO
-- [F2. procedures] dbo.sp_nt_MarkBankPaymentVoucherPaid  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_MarkBankPaymentVoucherPaid
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @voucher_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.voucher_sno') AS INT),
                @paid_on        DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.paid_on') AS DATE),
                @mode           VARCHAR(10)   = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_mode'))),
                @ref_no         NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_ref_no'))), ''),
                @from_bank      NVARCHAR(150) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.paid_from_bank'))), ''),
                @paid_by        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.paid_by'),
                @remarks        NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), '');

        IF @voucher_sno IS NULL OR @paid_by IS NULL OR @paid_on IS NULL
            THROW 58440, 'voucher_sno, paid_on and paid_by are required.', 1;
        IF @mode IS NULL OR @mode NOT IN ('NEFT', 'RTGS', 'Cheque', 'DD', 'UPI', 'ECS', 'Cash')
            THROW 58441, 'payment_mode must be one of NEFT, RTGS, Cheque, DD, UPI, ECS, Cash.', 1;
        IF @mode <> 'Cash' AND @ref_no IS NULL
            THROW 58442, 'The bank reference / UTR / cheque number is required for a non-cash payment.', 1;
        IF @paid_on > CAST(GETDATE() AS DATE)
            THROW 58443, 'The payment date cannot be in the future - record the payment once it has been made.', 1;

        BEGIN TRANSACTION;

        DECLARE @status VARCHAR(20), @voucher_no VARCHAR(30);
        SELECT @status = status, @voucher_no = voucher_no
        FROM dbo.bank_payment_voucher WITH (UPDLOCK, HOLDLOCK) WHERE voucher_sno = @voucher_sno;

        IF @status IS NULL THROW 58421, 'Bank payment voucher not found.', 1;
        IF @status <> 'APPROVED' THROW 58444, 'Only an approved voucher that has not been paid yet can be marked paid.', 1;

        UPDATE dbo.bank_payment_voucher
        SET status = 'PAID', paid_on = @paid_on, payment_mode = @mode, payment_ref_no = @ref_no,
            paid_from_bank = @from_bank, paid_by = @paid_by, paid_recorded_at = GETDATE()
        WHERE voucher_sno = @voucher_sno;

        INSERT INTO dbo.bank_payment_voucher_history (voucher_sno, action_type, status_by, comment)
        VALUES (@voucher_sno, 'PAID', @paid_by,
                @mode + ISNULL(N' ' + @ref_no, N'') + ISNULL(N' - ' + @remarks, N''));

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, @voucher_sno AS voucher_sno, @voucher_no AS voucher_no, 'PAID' AS status;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_MatchInvoiceBucket
CREATE OR ALTER PROCEDURE dbo.sp_nt_MatchInvoiceBucket
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @invoice_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
        IF @invoice_sno IS NULL
            THROW 54010, 'invoice_sno is required.', 1;

        -- Ratio from GRN receipts. The Service Entry-based branch was
        -- removed along with the Service Agreement/Service Entry feature.
        UPDATE iad
        SET matched_qty_ratio = ratios.ratio,
            hold_amount       = iad.allocated_amount * (1 - ratios.ratio),
            release_amount    = iad.allocated_amount * ratios.ratio,
            match_status      = CASE WHEN ratios.ratio >= 0.999999 THEN 'Matched' ELSE 'Partial' END
        FROM dbo.invoice_allocation_details iad
        JOIN dbo.po_item_details pid ON pid.po_item_sno = iad.po_item_sno
        CROSS APPLY (
            SELECT
                received_qty = (
                    SELECT ISNULL(SUM(gi.received_qty - ISNULL(gi.rejected_qty, 0)), 0)
                    FROM dbo.grn_item_details gi
                    WHERE gi.po_item_sno = pid.po_item_sno AND gi.is_active = 'Y'
                )
        ) raw
        CROSS APPLY (
            SELECT rawRatio = CASE
                WHEN ISNULL(pid.qty, 0) = 0 THEN 0
                ELSE CAST(raw.received_qty AS DECIMAL(18,6)) / pid.qty
            END
        ) computed
        CROSS APPLY (SELECT ratio = CASE WHEN computed.rawRatio > 1 THEN 1.0 ELSE computed.rawRatio END) ratios
        WHERE iad.invoice_sno = @invoice_sno AND iad.is_active = 'Y';

        DECLARE @totalRelease DECIMAL(18,2), @bucketCount INT, @matchedCount INT;
        SELECT
            @totalRelease = SUM(release_amount),
            @bucketCount  = COUNT(*),
            @matchedCount = SUM(CASE WHEN match_status = 'Matched' THEN 1 ELSE 0 END)
        FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno AND is_active = 'Y';

        UPDATE dbo.invoice_info
        SET net_payable = ISNULL(@totalRelease, 0),
            match_status = CASE WHEN @matchedCount = @bucketCount THEN 'Matched' ELSE 'PartialRelease' END,
            modified_date = GETDATE()
        WHERE invoice_sno = @invoice_sno;

        COMMIT TRANSACTION;

        SELECT invoice_alloc_sno, po_item_sno, bucket_type, allocated_amount, matched_qty_ratio, hold_amount, release_amount, match_status
        FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno AND is_active = 'Y';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_PreviewLoanInterest  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_PreviewLoanInterest
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @agreement_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
            @payment_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE),
            @repay         DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.principal_repayment') AS DECIMAL(18,2)), 0);
    IF @agreement_sno IS NULL
        THROW 58400, 'agreement_sno is required.', 1;

    DECLARE @agreement_no VARCHAR(30), @from DATE, @to DATE, @default_to DATE, @days INT, @basis SMALLINT,
            @opening DECIMAL(18,2), @on_payment DECIMAL(18,2), @interest DECIMAL(18,2), @after DECIMAL(18,2),
            @rate DECIMAL(7,3), @segments NVARCHAR(MAX), @next_due DATE, @next_days INT, @next_interest DECIMAL(18,2),
            @next_segments NVARCHAR(MAX);

    EXEC dbo.sp_nt_CalcLoanVoucher
        @agreement_sno = @agreement_sno, @payment_date = @payment_date, @principal_repayment = @repay,
        @out_agreement_no = @agreement_no OUTPUT, @out_period_from = @from OUTPUT, @out_period_to = @to OUTPUT,
        @out_default_payment_date = @default_to OUTPUT, @out_days = @days OUTPUT, @out_basis = @basis OUTPUT,
        @out_opening_principal = @opening OUTPUT, @out_principal_on_payment = @on_payment OUTPUT,
        @out_interest = @interest OUTPUT, @out_principal_after = @after OUTPUT, @out_rate_pct = @rate OUTPUT,
        @out_segments_json = @segments OUTPUT, @out_next_due = @next_due OUTPUT, @out_next_days = @next_days OUTPUT,
        @out_next_interest = @next_interest OUTPUT, @out_next_segments_json = @next_segments OUTPUT;

    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    SELECT @agreement_sno AS agreement_sno, @agreement_no AS agreement_no,
           @from AS period_from, @to AS period_to, @default_to AS default_payment_date,
           @days AS days, @basis AS day_count_basis,
           @opening AS opening_principal, @on_payment AS principal_on_payment,
           @repay AS principal_repayment, @interest AS interest_amount,
           @interest + @repay AS total_payable, @after AS principal_after, @rate AS rate_pct,
           @segments AS segments_json,
           @next_due AS next_due_date, @next_days AS next_days, @next_interest AS next_est_interest,
           @next_segments AS next_segments_json,
           s.rate_type, s.benchmark_name, s.interest_payment_day,
           CASE WHEN s.rate_type = 'FLOATING' AND @to > @today THEN 1 ELSE 0 END AS is_projected,
           CASE WHEN s.rate_type = 'FLOATING' AND @to > @today THEN DATEDIFF(DAY, @today, @to) ELSE 0 END AS projected_days,
           (SELECT effective_from FROM dbo.fn_LoanRateAt(@agreement_sno, @to)) AS rate_effective_from,
           (SELECT TOP 1 v.voucher_sno FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = @agreement_sno AND v.status = 'PENDING_APPROVAL') AS open_voucher_sno,
           (SELECT TOP 1 v.voucher_no FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = @agreement_sno AND v.status = 'PENDING_APPROVAL') AS open_voucher_no
    FROM dbo.service_agreement_statutory s
    WHERE s.agreement_sno = @agreement_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_ProcessDueRecurringServiceAgreements
CREATE OR ALTER PROCEDURE dbo.sp_nt_ProcessDueRecurringServiceAgreements
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @due TABLE (agreement_sno INT, billing_period_start DATE);

    INSERT INTO @due (agreement_sno, billing_period_start)
    SELECT sa.agreement_sno, @today
    FROM dbo.service_agreement sa
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.status = 'A' AND sa.is_active = 'Y'
      -- sql/89: loans (Statutory) are billed through Bank Payment Vouchers, never PO cycles
      AND NOT EXISTS (SELECT 1 FROM dbo.service_master smx JOIN dbo.service_type_master stx ON stx.service_type_sno = smx.service_type_sno
                      WHERE smx.service_sno = sa.service_sno AND stx.service_type_code = 'STATUTORY')
      AND @today BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, @today) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
             AND DAY(@today) = CASE WHEN sa.po_generation_day > DAY(EOMONTH(@today)) THEN DAY(EOMONTH(@today)) ELSE sa.po_generation_day END
             AND DATEDIFF(MONTH, sa.period_start_date, @today) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
             AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, @today) / rc.interval_value) * rc.interval_value, sa.period_start_date) = @today)
          )
      AND NOT EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log l WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = @today);

    DECLARE @agreement_sno INT, @billing_period_start DATE;
    DECLARE @success_count INT = 0, @skipped_count INT = 0, @failed_count INT = 0;
    DECLARE @row_result VARCHAR(30), @row_po INT, @row_po_no VARCHAR(50), @row_pr INT, @row_pr_no VARCHAR(20), @rowJson NVARCHAR(MAX);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, billing_period_start FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @rowJson = (SELECT @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start, 'SYSTEM' AS issued_by FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_nt_IssueRecurringServicePOCycle
            @jsonInput = @rowJson, @silent = 1,
            @out_result = @row_result OUTPUT, @out_po_basic_sno = @row_po OUTPUT, @out_po_no = @row_po_no OUTPUT,
            @out_pr_basic_sno = @row_pr OUTPUT, @out_pr_no = @row_pr_no OUTPUT;

        IF @row_result = 'SUCCESS' SET @success_count = @success_count + 1;
        ELSE IF @row_result LIKE 'SKIPPED%' SET @skipped_count = @skipped_count + 1;
        ELSE SET @failed_count = @failed_count + 1;

        FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT (SELECT COUNT(*) FROM @due) AS due_count, @success_count AS success_count, @skipped_count AS skipped_count, @failed_count AS failed_count;
END;
GO
-- [F2. procedures] dbo.sp_nt_ResolveBankVoucherWorkflow  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_ResolveBankVoucherWorkflow
    @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
    @workflow_types_id INT OUTPUT,
    @first_approver VARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1 @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
      AND awm.entity_type = 'BankPaymentVoucher' AND wt.is_active = 'Y'
    ORDER BY wt.workflow_types_id;

    IF @workflow_types_id IS NULL
        THROW 58430, 'No BankPaymentVoucher approval workflow is configured for this company/division/branch/department. Configure one in the Approval Workflow Manager first.', 1;

    SELECT TOP 1 @first_approver = JSON_VALUE(j.value, '$.approver_ecno')
    FROM dbo.workflow_stage ws
    CROSS APPLY OPENJSON(ws.stage_order_json) j
    WHERE ws.workflow_types_id = @workflow_types_id AND ws.is_active = 'Y' AND j.[key] = '0';

    IF @first_approver IS NULL
        THROW 58431, 'No approver found for the first stage of the BankPaymentVoucher workflow.', 1;
END;
GO
-- [F2. procedures] dbo.sp_nt_ResolveServicePoWorkflow  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_ResolveServicePoWorkflow
    @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
    @workflow_types_id INT OUTPUT,
    @first_approver VARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
      AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
      AND awm.entity_type = 'ServicePO';

    IF @workflow_types_id IS NULL
        THROW 58310, 'No ServicePO workflow configuration found for this company/division/branch/department.', 1;

    SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages AS ws
    CROSS APPLY OPENJSON(ws.stages_json) AS s
    CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
    WHERE ws.workflow_types_id = @workflow_types_id
      AND s.[key] = '0' AND s2.[key] = '0';

    IF @first_approver IS NULL
        THROW 58311, 'No approver found for the first stage of the ServicePO workflow.', 1;
END;
GO
-- [F2. procedures] dbo.sp_nt_SaveServiceAgreementStatutory  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_SaveServiceAgreementStatutory
    @agreement_sno INT,
    @service_type_code VARCHAR(30),
    @statutory_json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF @service_type_code <> 'STATUTORY'
    BEGIN
        DELETE FROM dbo.service_agreement_statutory WHERE agreement_sno = @agreement_sno;
        RETURN;
    END

    IF @statutory_json IS NULL OR ISJSON(@statutory_json) = 0
        THROW 58160, 'Loan details (type, sanctioned amount, interest rate, disbursement date, interest payment day) are required for a Statutory agreement.', 1;

    DECLARE @facility_type   VARCHAR(15)   = UPPER(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.facility_type')))),
            @facility_ref_no NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.facility_ref_no'))), ''),
            @sanctioned      DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@statutory_json, '$.sanctioned_amount') AS DECIMAL(18,2)),
            @drawing_power   DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@statutory_json, '$.drawing_power') AS DECIMAL(18,2)),
            @rate_type       VARCHAR(10)   = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.rate_type'))), ''), 'FIXED')),
            @benchmark       DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.benchmark_rate_pct') AS DECIMAL(7,3)),
            @spread          DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.spread_pct') AS DECIMAL(7,3)),
            @interest        DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.interest_rate_pct') AS DECIMAL(7,3)),
            @benchmark_name  VARCHAR(30)   = NULLIF(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.benchmark_name'))), ''),
            @disbursed       DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@statutory_json, '$.disbursed_amount') AS DECIMAL(18,2)),
            @disb_date       DATE          = TRY_CAST(JSON_VALUE(@statutory_json, '$.disbursement_date') AS DATE),
            @pay_day         INT           = TRY_CAST(JSON_VALUE(@statutory_json, '$.interest_payment_day') AS INT),
            @basis           INT           = ISNULL(TRY_CAST(JSON_VALUE(@statutory_json, '$.day_count_basis') AS INT), 365);

    IF @facility_type IS NULL OR @facility_type NOT IN ('LOAN', 'REPO', 'CASH_CREDIT')
        THROW 58161, 'facility_type must be LOAN, REPO or CASH_CREDIT.', 1;
    IF @sanctioned IS NULL OR @sanctioned <= 0
        THROW 58162, 'sanctioned_amount (loan amount / limit) must be a positive amount.', 1;
    IF @rate_type NOT IN ('FIXED', 'FLOATING')
        THROW 58163, 'rate_type must be FIXED or FLOATING.', 1;

    IF @rate_type = 'FLOATING'
    BEGIN
        IF @benchmark IS NULL OR @spread IS NULL
            THROW 58164, 'A floating-rate facility needs both the benchmark (e.g. repo) rate and the spread.', 1;
        SET @interest = @benchmark + @spread;
        SET @benchmark_name = ISNULL(@benchmark_name, 'Repo');
    END
    ELSE
    BEGIN
        IF @interest IS NULL
            THROW 58165, 'interest_rate_pct is required for a fixed-rate facility.', 1;
        SET @benchmark = NULL;
        SET @spread = NULL;
        SET @benchmark_name = NULL;
    END

    IF @interest < 0 OR @interest > 100
        THROW 58166, 'The effective interest rate must be between 0 and 100 percent.', 1;

    IF @facility_type <> 'CASH_CREDIT'
        SET @drawing_power = NULL;
    ELSE IF @drawing_power IS NOT NULL AND (@drawing_power <= 0 OR @drawing_power > @sanctioned)
        THROW 58167, 'drawing_power must be positive and not more than the sanctioned limit.', 1;

    -- Loan details (sql/89)
    DECLARE @period_start DATE, @period_end DATE;
    SELECT @period_start = period_start_date, @period_end = period_end_date
    FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno;

    IF @disb_date IS NULL
        THROW 58168, 'The disbursement date (when interest starts) is required.', 1;
    IF @disb_date < @period_start OR @disb_date >= @period_end
        THROW 58169, 'The disbursement date must fall within the loan term (Duration From - Duration To).', 1;
    IF @pay_day IS NULL OR @pay_day NOT BETWEEN 1 AND 31
        THROW 58171, 'The interest payment day of the month (1-31) is required.', 1;
    IF @basis NOT IN (360, 365)
        THROW 58172, 'day_count_basis must be 365 or 360.', 1;

    IF @disbursed IS NULL
        SET @disbursed = CASE WHEN @facility_type = 'CASH_CREDIT' THEN 0 ELSE @sanctioned END;
    IF @disbursed < 0 OR @disbursed > @sanctioned
        THROW 58173, 'The disbursed amount must be between 0 and the sanctioned amount.', 1;
    IF @facility_type <> 'CASH_CREDIT' AND @disbursed = 0
        THROW 58174, 'The disbursed amount must be greater than zero (only a cash-credit limit can start at nil).', 1;

    -- Once interest has been billed, the basis of that billing can't move.
    IF EXISTS (SELECT 1 FROM dbo.bank_payment_voucher WHERE agreement_sno = @agreement_sno AND status <> 'REJECTED')
       AND EXISTS (
            SELECT 1 FROM dbo.service_agreement_statutory s
            WHERE s.agreement_sno = @agreement_sno
              AND (   s.disbursement_date <> @disb_date OR ISNULL(s.disbursed_amount, -1) <> @disbursed
                   OR ISNULL(s.day_count_basis, 0) <> @basis OR s.rate_type <> @rate_type
                   OR ISNULL(s.benchmark_rate_pct, -1) <> ISNULL(@benchmark, -1)
                   OR ISNULL(s.spread_pct, -1) <> ISNULL(@spread, -1)
                   OR s.interest_rate_pct <> @interest)
       )
        THROW 58175, 'Interest vouchers already exist for this loan, so the disbursement date, disbursed amount, day-count basis and interest rate cannot be edited here. Enter a rate change under Loan Payments > Rates instead.', 1;

    UPDATE dbo.service_agreement_statutory
    SET facility_type = @facility_type, facility_ref_no = @facility_ref_no, sanctioned_amount = @sanctioned,
        drawing_power = @drawing_power, rate_type = @rate_type, benchmark_rate_pct = @benchmark,
        spread_pct = @spread, interest_rate_pct = @interest,
        benchmark_name = @benchmark_name, disbursed_amount = @disbursed, disbursement_date = @disb_date,
        interest_payment_day = @pay_day, day_count_basis = @basis, modified_at = GETDATE()
    WHERE agreement_sno = @agreement_sno;

    IF @@ROWCOUNT = 0
        INSERT INTO dbo.service_agreement_statutory (
            agreement_sno, facility_type, facility_ref_no, sanctioned_amount, drawing_power,
            rate_type, benchmark_rate_pct, spread_pct, interest_rate_pct,
            benchmark_name, disbursed_amount, disbursement_date, interest_payment_day, day_count_basis
        )
        VALUES (
            @agreement_sno, @facility_type, @facility_ref_no, @sanctioned, @drawing_power,
            @rate_type, @benchmark, @spread, @interest,
            @benchmark_name, @disbursed, @disb_date, @pay_day, @basis
        );
END;
GO
-- [F2. procedures] dbo.sp_nt_SaveServiceAgreementSuppliers  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_SaveServiceAgreementSuppliers
    @agreement_sno INT,
    @vendors_json NVARCHAR(MAX),
    @fallback_vendor_sno INT,
    @total_amount DECIMAL(18,2),
    @out_primary_vendor_sno INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @parsed TABLE (ord INT NOT NULL, vendor_sno INT NULL, share_amount DECIMAL(18,2) NULL);

    IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1 AND LEFT(LTRIM(@vendors_json), 1) = '['
        INSERT INTO @parsed (ord, vendor_sno, share_amount)
        SELECT CAST(j.[key] AS INT) + 1,
               TRY_CAST(JSON_VALUE(j.[value], '$.vendor_sno') AS INT),
               TRY_CAST(JSON_VALUE(j.[value], '$.share_amount') AS DECIMAL(18,2))
        FROM OPENJSON(@vendors_json) AS j;

    IF NOT EXISTS (SELECT 1 FROM @parsed) AND @fallback_vendor_sno IS NOT NULL
        INSERT INTO @parsed (ord, vendor_sno, share_amount) VALUES (1, @fallback_vendor_sno, @total_amount);

    IF NOT EXISTS (SELECT 1 FROM @parsed)
        THROW 58150, 'At least one supplier is required.', 1;
    IF EXISTS (SELECT 1 FROM @parsed WHERE vendor_sno IS NULL OR share_amount IS NULL OR share_amount <= 0)
        THROW 58151, 'Every supplier needs a vendor and a share amount greater than zero.', 1;
    IF EXISTS (SELECT vendor_sno FROM @parsed GROUP BY vendor_sno HAVING COUNT(*) > 1)
        THROW 58152, 'The same supplier is listed more than once in the split.', 1;
    IF EXISTS (
        SELECT 1 FROM @parsed p
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.kyc_basic_info k
            WHERE k.kyc_basic_info_sno = p.vendor_sno AND k.status = 'A' AND k.is_active = 'Y'
        )
    )
        THROW 58153, 'One or more suppliers are not approved, active vendors.', 1;

    DECLARE @sum DECIMAL(18,2) = (SELECT SUM(share_amount) FROM @parsed);
    IF ABS(@sum - @total_amount) > 0.01
    BEGIN
        DECLARE @msg NVARCHAR(400) =
            N'Supplier shares total ' + CONVERT(NVARCHAR(30), @sum) +
            N' but the amount per cycle (rate x quantity) is ' + CONVERT(NVARCHAR(30), @total_amount) +
            N'. The shares must add up exactly.';
        THROW 58154, @msg, 1;
    END

    DELETE FROM dbo.service_agreement_vendor WHERE agreement_sno = @agreement_sno;

    INSERT INTO dbo.service_agreement_vendor (agreement_sno, vendor_sno, share_amount, share_pct, sort_order)
    SELECT @agreement_sno, vendor_sno, share_amount, ROUND(share_amount * 100.0 / @total_amount, 6), ord
    FROM @parsed
    ORDER BY ord;

    SELECT TOP 1 @out_primary_vendor_sno = vendor_sno FROM @parsed ORDER BY ord;
END;
GO
-- [F2. procedures] dbo.sp_nt_sign_up

CREATE OR ALTER PROCEDURE [dbo].[sp_nt_sign_up]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        BEGIN TRANSACTION;  
       
        -- Validate JSON input  
        IF @jsonInput IS NULL OR @jsonInput = '' OR NOT ISJSON(@jsonInput) = 1  
        BEGIN  
            THROW 50001, 'Invalid or empty JSON input provided', 1;  
        END  
          
        -- Insert into nt_sign_up table with lookup from vw_verified_employees
        INSERT INTO nt_sign_up (  
            ecno, com_sno, div_sno, brn_sno, dept_sno, sign_up_cug,   
            sign_up_pass, sign_up_otp, nt_menu_sno, fingerprint_mantra_mfs, branch, dept ,is_active,workflow_id
        )  
        SELECT  
            CAST(j.ecno AS VARCHAR(10)),   
            CAST(j.com_sno AS INT),   
            CAST(j.div_sno AS INT),   
            CAST(j.brn_sno AS INT),   
            CAST(j.dept_sno AS INT),   
            CASE   
                WHEN j.sign_up_cug = '' OR j.sign_up_cug IS NULL THEN NULL   
                ELSE CAST(j.sign_up_cug AS BIGINT)   
            END,  
            CASE   
                WHEN LEN(j.sign_up_pass) > 15 THEN LEFT(CAST(j.sign_up_pass AS NVARCHAR(15)), 15)  
                ELSE CAST(j.sign_up_pass AS NVARCHAR(15))  
            END,  
            CASE   
                WHEN j.sign_up_otp = '' OR j.sign_up_otp IS NULL THEN NULL   
                ELSE CAST(j.sign_up_otp AS INT)   
            END,  
            CAST(j.nt_menu_sno AS NVARCHAR(MAX)),  
            CASE   
                WHEN LEN(j.fingerprint_mantra_mfs) > 100 THEN LEFT(CAST(j.fingerprint_mantra_mfs AS NVARCHAR(100)), 100)  
                ELSE CAST(j.fingerprint_mantra_mfs AS NVARCHAR(100))  
            END,
            v.branch,  -- Lookup from view
            v.dept,-- Lookup from view
            'Y',
            8
        FROM OPENJSON(@jsonInput)  
        WITH (  
            ecno NVARCHAR(50) '$.ecno',  
            com_sno NVARCHAR(50) '$.com_sno',  
            div_sno NVARCHAR(50) '$.div_sno',  
            brn_sno NVARCHAR(50) '$.brn_sno',  
            dept_sno NVARCHAR(50) '$.dept_sno',  
            sign_up_cug NVARCHAR(50) '$.sign_up_cug',  
            sign_up_pass NVARCHAR(MAX) '$.sign_up_pass',  
            sign_up_otp NVARCHAR(50) '$.sign_up_otp',  
            nt_menu_sno NVARCHAR(MAX) '$.nt_menu_sno',  
            fingerprint_mantra_mfs NVARCHAR(MAX) '$.fingerprint_mantra_mfs'  
        ) AS j
        LEFT JOIN [Non_trade_Dev].[dbo].[vw_verified_employees] v ON v.ecno = j.ecno;
          
        -- Return success message with row count  
        SELECT 'SUCCESS' as Status, @@ROWCOUNT as RowsAffected;  
          
        COMMIT TRANSACTION;  
          
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
        -- Return detailed error information  
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
        DECLARE @ErrorState INT = ERROR_STATE();  
          
        SELECT   
            'ERROR' as Status,  
            @ErrorNumber as ErrorNumber,  
            @ErrorMessage as ErrorMessage,  
            @ErrorSeverity as ErrorSeverity,  
            @ErrorState as ErrorState;  
          
        -- Re-throw the error for upstream handling  
        THROW;  
    END CATCH  
END

GO
-- [F2. procedures] dbo.sp_nt_SnapshotServiceAgreementVersion  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_SnapshotServiceAgreementVersion
    @agreement_sno INT,
    @action_type VARCHAR(20),
    @submitted_by VARCHAR(30),
    @submitted_at DATETIME = NULL,
    @outcome VARCHAR(10) = 'PENDING',
    @note NVARCHAR(300) = NULL,
    @out_version_no INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @terms NVARCHAR(MAX) = (
        SELECT sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
               sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
               sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
               sa.recurrence_cadence_sno, rc.cadence_name, sa.po_generation_day, sa.notify_days_before,
               sa.period_start_date, sa.period_end_date, sa.agreement_doc_url,
               sa.remarks, sa.terms_conditions, sa.ceiling_amount,
               (
                   SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
                   FROM dbo.service_agreement_vendor v
                   LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
                   WHERE v.agreement_sno = sa.agreement_sno
                   ORDER BY v.sort_order, v.agreement_vendor_sno
                   FOR JSON PATH
               ) AS suppliers,
               JSON_QUERY((SELECT s.facility_type, s.facility_ref_no, s.sanctioned_amount, s.drawing_power,
                          s.rate_type, s.benchmark_rate_pct, s.spread_pct, s.interest_rate_pct,
                          s.benchmark_name, s.disbursed_amount, s.disbursement_date, s.interest_payment_day, s.day_count_basis
                   FROM dbo.service_agreement_statutory s
                   WHERE s.agreement_sno = sa.agreement_sno
                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS statutory
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
        LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
        WHERE sa.agreement_sno = @agreement_sno
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    IF @terms IS NULL
        THROW 58180, 'Cannot snapshot: agreement not found.', 1;

    DECLARE @version_no INT =
        ISNULL((SELECT MAX(version_no) FROM dbo.service_agreement_version WITH (UPDLOCK, HOLDLOCK) WHERE agreement_sno = @agreement_sno), 0) + 1;

    UPDATE dbo.service_agreement_version
    SET superseded_at = GETDATE()
    WHERE agreement_sno = @agreement_sno AND superseded_at IS NULL;

    INSERT INTO dbo.service_agreement_version (
        agreement_sno, version_no, action_type, outcome, period_start_date, period_end_date,
        terms_json, note, submitted_by, submitted_at
    )
    SELECT @agreement_sno, @version_no, @action_type, @outcome, sa.period_start_date, sa.period_end_date,
           @terms, @note, @submitted_by, ISNULL(@submitted_at, GETDATE())
    FROM dbo.service_agreement sa
    WHERE sa.agreement_sno = @agreement_sno;

    SET @out_version_no = @version_no;
END;
GO
-- [F2. procedures] dbo.sp_nt_SubmitServicePoEntry  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_SubmitServicePoEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @cycle_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT);
        DECLARE @rate_amount  DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @discount_pct DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.discount_pct') AS DECIMAL(5,2)), 0);
        DECLARE @gst_pct      DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.gst_pct') AS DECIMAL(5,2)), 0);
        DECLARE @remarks      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @submitted_by VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.submitted_by');

        IF @cycle_sno IS NULL OR @rate_amount IS NULL OR @rate_amount <= 0 OR @submitted_by IS NULL
            THROW 58320, 'cycle_sno, rate_amount and submitted_by are required.', 1;
        IF @discount_pct < 0 OR @discount_pct > 100 OR @gst_pct < 0 OR @gst_pct > 100
            THROW 58324, 'discount_pct and gst_pct must be between 0 and 100.', 1;

        DECLARE @agreement_sno INT, @qty DECIMAL(18,4), @status VARCHAR(20),
                @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @ceiling_amount DECIMAL(18,2);
        SELECT @agreement_sno = spc.agreement_sno, @qty = spc.qty, @status = spc.status,
               @com_sno = spc.com_sno, @div_sno = spc.div_sno, @brn_sno = spc.brn_sno, @dept_sno = spc.dept_sno,
               @ceiling_amount = sa.ceiling_amount
        FROM dbo.service_po_cycle spc
        JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
        WHERE spc.cycle_sno = @cycle_sno;

        IF @agreement_sno IS NULL THROW 58321, 'Service PO cycle not found.', 1;
        IF @status <> 'PENDING_ENTRY' THROW 58322, 'This cycle is not awaiting entry.', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        EXEC dbo.sp_nt_ResolveServicePoWorkflow
            @com_sno = @com_sno, @div_sno = @div_sno, @brn_sno = @brn_sno, @dept_sno = @dept_sno,
            @workflow_types_id = @workflow_types_id OUTPUT, @first_approver = @first_approver OUTPUT;

        BEGIN TRANSACTION;

        DECLARE @net_cost DECIMAL(18,2);
        EXEC dbo.sp_nt_BuildServicePoCycleSplit
            @cycle_sno = @cycle_sno, @agreement_sno = @agreement_sno, @rate_amount = @rate_amount, @qty = @qty,
            @discount_pct = @discount_pct, @gst_pct = @gst_pct, @out_net_cost = @net_cost OUTPUT;

        IF @ceiling_amount IS NOT NULL AND @net_cost > @ceiling_amount
            THROW 58323, 'Entered amount exceeds the agreement''s ceiling amount.', 1;

        UPDATE dbo.service_po_cycle
        SET rate_amount = @rate_amount, discount_pct = @discount_pct, gst_pct = @gst_pct, net_cost = @net_cost,
            remarks = @remarks, status = 'PENDING_APPROVAL',
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            entered_by = @submitted_by, entered_at = GETDATE()
        WHERE cycle_sno = @cycle_sno;

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'ENTRY_SUBMITTED', @submitted_by,
                N'Rate ' + CAST(@rate_amount AS VARCHAR(30)) + N', GST ' + CAST(@gst_pct AS VARCHAR(10)) + N'%, Net ' + CAST(@net_cost AS VARCHAR(30)));

        COMMIT TRANSACTION;

        SELECT 'SUCCESS' AS result, @cycle_sno AS cycle_sno, @net_cost AS net_cost;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_UpdateInventoryItem
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @item_name     VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.item_name');
    DECLARE @category      VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.category');
    DECLARE @sub_category  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.sub_category');
    DECLARE @uom           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.uom');
    DECLARE @min_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.min_stock');
    DECLARE @max_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.max_stock');
    DECLARE @reorder_qty   DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.reorder_qty');
    DECLARE @warehouse     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.warehouse');
    DECLARE @location      VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.location');
    DECLARE @cost_price    DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.cost_price');
    DECLARE @selling_price DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.selling_price');
    DECLARE @status        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @hsn_code      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.hsn_code');
    DECLARE @description   VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.description');
    DECLARE @updated_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.updated_by');

    IF @item_sno IS NULL
    BEGIN
        RAISERROR('item_sno is required.', 16, 1);
        RETURN;
    END

    UPDATE dbo.nt_inventory_items
    SET item_name     = ISNULL(@item_name, item_name),
        category      = ISNULL(@category, category),
        sub_category  = @sub_category,
        uom           = ISNULL(@uom, uom),
        min_stock     = ISNULL(@min_stock, min_stock),
        max_stock     = ISNULL(@max_stock, max_stock),
        reorder_qty   = ISNULL(@reorder_qty, reorder_qty),
        warehouse     = ISNULL(@warehouse, warehouse),
        location      = @location,
        cost_price    = ISNULL(@cost_price, cost_price),
        selling_price = ISNULL(@selling_price, selling_price),
        status        = ISNULL(@status, status),
        hsn_code      = @hsn_code,
        description   = @description,
        updated_by    = @updated_by,
        updated_at    = GETDATE()
    WHERE item_sno = @item_sno;

    SELECT item_sno, item_code, item_name, category, uom, current_stock, warehouse, status,
           com_sno, div_sno, brn_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_UpdateProductStockLevel  (new)
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateProductStockLevel
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @stock_level_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.stock_level_sno') AS INT),
            @min_qty         DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.min_qty') AS DECIMAL(18,2)),
            @max_qty         DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.max_qty') AS DECIMAL(18,2)),
            @reorder_level   DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.reorder_level') AS DECIMAL(18,2)),
            @is_active       CHAR(1)       = JSON_VALUE(@jsonInput, '$.is_active'),
            @modified_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @stock_level_sno IS NULL
    BEGIN
        THROW 59515, N'stock_level_sno is required.', 1;
        RETURN;
    END;

    DECLARE @existing_min DECIMAL(18,2), @existing_max DECIMAL(18,2), @existing_reorder DECIMAL(18,2);
    SELECT @existing_min = min_qty, @existing_max = max_qty, @existing_reorder = reorder_level
    FROM dbo.product_stock_level_master WHERE stock_level_sno = @stock_level_sno;

    IF @existing_min IS NULL
    BEGIN
        THROW 59516, N'Stock level configuration not found.', 1;
        RETURN;
    END;

    SET @min_qty       = ISNULL(@min_qty, @existing_min);
    SET @max_qty       = ISNULL(@max_qty, @existing_max);
    SET @reorder_level = ISNULL(@reorder_level, @existing_reorder);

    IF @min_qty < 0 OR @max_qty < 0 OR @reorder_level < 0
    BEGIN
        THROW 59517, N'Min Qty, Max Qty and Reorder Level cannot be negative.', 1;
        RETURN;
    END;

    IF @min_qty > @max_qty
    BEGIN
        THROW 59518, N'Min Qty cannot be greater than Max Qty.', 1;
        RETURN;
    END;

    IF @reorder_level < @min_qty OR @reorder_level > @max_qty
    BEGIN
        THROW 59519, N'Reorder Level must be between Min Qty and Max Qty.', 1;
        RETURN;
    END;

    UPDATE dbo.product_stock_level_master
    SET min_qty       = @min_qty,
        max_qty       = @max_qty,
        reorder_level = @reorder_level,
        is_active     = ISNULL(@is_active, is_active),
        modified_by   = @modified_by,
        modified_date = GETDATE()
    WHERE stock_level_sno = @stock_level_sno;

    SELECT @stock_level_sno AS stock_level_sno, N'SUCCESS' AS status,
           N'Stock level configuration updated successfully.' AS message;
END;
GO
-- [F2. procedures] dbo.sp_nt_UpdateServiceAgreement
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @agreement_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @terms_conditions   NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @edited_by          VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.edited_by');
        DECLARE @vendors_json       NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.vendors');
        DECLARE @statutory_json     NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory');

        IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1
            SET @vendor_sno = ISNULL(TRY_CAST(JSON_VALUE(@vendors_json, '$[0].vendor_sno') AS INT), @vendor_sno);

        IF @agreement_sno IS NULL OR @edited_by IS NULL
            THROW 58120, 'agreement_sno and edited_by are required.', 1;

        DECLARE @current_status CHAR(1), @old_period_end DATE;
        SELECT @current_status = status, @old_period_end = period_end_date
        FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno AND is_active = 'Y';
        IF @current_status IS NULL
            THROW 58121, 'Service agreement not found or inactive.', 1;
        IF @current_status NOT IN ('A', 'R', 'X')
            THROW 58122, 'Only an Approved, Rejected or Expired agreement can be edited or renewed (it is currently Pending approval).', 1;

        DECLARE @is_renewal BIT = CASE WHEN @current_status = 'X' THEN 1 ELSE 0 END;

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @service_sno IS NULL OR @vendor_sno IS NULL
            THROW 58123, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and at least one supplier are required.', 1;
        IF @qty IS NULL OR @qty <= 0
            THROW 58124, 'qty must be a positive quantity.', 1;
        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58125, 'rate_amount must be a positive amount.', 1;
        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58126, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;
        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58127, 'agreement_doc_url is required.', 1;

        IF @is_renewal = 1
        BEGIN
            IF @period_start_date <= @old_period_end
            BEGIN
                DECLARE @renew_msg NVARCHAR(300) = N'A renewal must start after the expired term ended (' + CONVERT(NVARCHAR(10), @old_period_end, 23) + N').';
                THROW 58133, @renew_msg, 1;
            END
            IF @period_end_date < CAST(GETDATE() AS DATE)
                THROW 58134, 'The renewed period has already ended — choose a term that runs beyond today.', 1;
        END

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58128, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;
        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58129, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';
        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING', 'STATUTORY')
            THROW 58135, 'service_sno must reference an active Fixed, Unfixed or Statutory service.', 1;
        IF @service_type_code = 'FIXED_RECURRING'
            SET @ceiling_amount = NULL;
        ELSE IF @ceiling_amount IS NOT NULL AND @ceiling_amount <= 0
            THROW 58132, 'ceiling_amount must be a positive amount when provided.', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';
        IF @workflow_types_id IS NULL
            THROW 58130, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id AND s.[key] = '0' AND s2.[key] = '0';
        IF @first_approver IS NULL
            THROW 58131, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        UPDATE dbo.service_agreement
        SET com_sno = @com_sno, div_sno = @div_sno, brn_sno = @brn_sno, dept_sno = @dept_sno,
            service_sno = @service_sno, vendor_sno = @vendor_sno, qty = @qty, rate_amount = @rate_amount,
            rate_uom_sno = @rate_uom_sno, recurrence_cadence_sno = @recurrence_cadence_sno,
            po_generation_day = @po_generation_day, notify_days_before = @notify_days_before,
            period_start_date = @period_start_date, period_end_date = @period_end_date,
            agreement_doc_url = @agreement_doc_url, remarks = @remarks, terms_conditions = @terms_conditions,
            ceiling_amount = @ceiling_amount,
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            status = 'P', modified_by = @edited_by, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno;

        DECLARE @total_per_cycle DECIMAL(18,2) = ROUND(@rate_amount * @qty, 2), @primary_vendor INT;
        EXEC dbo.sp_nt_SaveServiceAgreementSuppliers
            @agreement_sno = @agreement_sno, @vendors_json = @vendors_json, @fallback_vendor_sno = @vendor_sno,
            @total_amount = @total_per_cycle, @out_primary_vendor_sno = @primary_vendor OUTPUT;
        IF @primary_vendor IS NOT NULL AND @primary_vendor <> @vendor_sno
            UPDATE dbo.service_agreement SET vendor_sno = @primary_vendor WHERE agreement_sno = @agreement_sno;

        EXEC dbo.sp_nt_SaveServiceAgreementStatutory
            @agreement_sno = @agreement_sno, @service_type_code = @service_type_code, @statutory_json = @statutory_json;

        DECLARE @edit_action VARCHAR(20) = CASE WHEN @is_renewal = 1 THEN 'RENEWED' ELSE 'RESUBMITTED' END;
        DECLARE @version_no INT;
        EXEC dbo.sp_nt_SnapshotServiceAgreementVersion
            @agreement_sno = @agreement_sno, @action_type = @edit_action, @submitted_by = @edited_by,
            @out_version_no = @version_no OUTPUT;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, @edit_action, @edited_by, NULL, @version_no);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, @version_no AS version_no, 'SUCCESS' AS result,
               CASE WHEN @is_renewal = 1 THEN N'Service agreement renewed and submitted for approval.'
                    ELSE N'Service agreement updated and resubmitted for approval.' END AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- [F2. procedures] dbo.sp_nt_UpdateStockRequestStatus
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateStockRequestStatus
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @request_sno INT          = JSON_VALUE(@jsonInput, '$.request_sno');
    DECLARE @status      VARCHAR(30)  = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @reason      VARCHAR(500) = JSON_VALUE(@jsonInput, '$.reason');
    DECLARE @updated_by  VARCHAR(50)  = JSON_VALUE(@jsonInput, '$.updated_by');

    IF @request_sno IS NULL OR @status NOT IN ('Rejected', 'Cancelled')
    BEGIN
        RAISERROR('request_sno and a status of Rejected or Cancelled are required.', 16, 1);
        RETURN;
    END

    DECLARE @cur_status VARCHAR(30), @requested_by VARCHAR(50);
    SELECT @cur_status = status, @requested_by = requested_by
    FROM dbo.nt_stock_requests WHERE request_sno = @request_sno;

    IF @cur_status IS NULL
    BEGIN
        RAISERROR('Stock request not found.', 16, 1);
        RETURN;
    END

    IF @cur_status <> 'Pending'
    BEGIN
        RAISERROR('Only Pending requests can be rejected or cancelled (current status: %s).', 16, 1, @cur_status);
        RETURN;
    END

    IF @status = 'Cancelled' AND (@updated_by IS NULL OR @updated_by <> @requested_by)
    BEGIN
        RAISERROR('Only the requester can cancel a stock request.', 16, 1);
        RETURN;
    END

    UPDATE dbo.nt_stock_requests
    SET status        = @status,
        reject_reason = @reason,
        issued_by     = CASE WHEN @status = 'Rejected' THEN @updated_by ELSE issued_by END,
        updated_at    = GETDATE()
    WHERE request_sno = @request_sno;

    UPDATE dbo.nt_stock_request_items
    SET line_status = @status
    WHERE request_sno = @request_sno AND line_status = 'Pending';

    SELECT request_sno, request_no, requested_by, status, reject_reason, com_sno, div_sno, brn_sno,
           CONVERT(VARCHAR(30), updated_at, 120) AS updated_at
    FROM dbo.nt_stock_requests
    WHERE request_sno = @request_sno;
END;
GO
-- [F2. procedures] dbo.sp_nt_UpsertInventoryItemByProduct
-- ============================================================
-- Fix: nt_inventory_items never carried a department, so department-scoped
-- access (e.g. "Canteen only") could never actually narrow the Inventory
-- list — see backend-stpl/sql/80_dept_scope_fix.sql for the full root-cause
-- writeup (KTM1006's report, 2026-09-15).
-- Database: Non_trade_Dev (MSSQL)
--
-- sp_nt_UpsertInventoryItemByProduct already receives dept_sno in its
-- caller's orgScope (grn-service/src/inventory/inventory.service.js's
-- receiveFromGRN, which resolves it from the GRN's own dept_sno — itself
-- traced from the originating PR) but silently dropped it: not accepted as
-- a parameter, not part of the item-matching WHERE, not stored, not
-- returned. All four fixed here, additively — items with no department
-- context (dept_sno IS NULL on both sides) match exactly as before.
-- ============================================================

CREATE OR ALTER PROCEDURE [dbo].[sp_nt_UpsertInventoryItemByProduct]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @prod_sno     INT          = JSON_VALUE(@jsonInput, '$.prod_sno');
    DECLARE @prod_name    VARCHAR(255) = JSON_VALUE(@jsonInput, '$.prod_name');
    DECLARE @uom_name     VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.uom_name');
    DECLARE @com_sno      INT          = JSON_VALUE(@jsonInput, '$.com_sno');
    DECLARE @div_sno      INT          = JSON_VALUE(@jsonInput, '$.div_sno');
    DECLARE @brn_sno      INT          = JSON_VALUE(@jsonInput, '$.brn_sno');
    DECLARE @dept_sno     INT          = JSON_VALUE(@jsonInput, '$.dept_sno');
    DECLARE @location_sno INT          = JSON_VALUE(@jsonInput, '$.location_sno');

    IF @prod_sno IS NULL
    BEGIN
        RAISERROR('prod_sno is required.', 16, 1);
        RETURN;
    END

    DECLARE @location VARCHAR(100);

    IF @location_sno IS NOT NULL
        SELECT @location = location_code
        FROM dbo.warehouse_location_master
        WHERE location_sno = @location_sno;

    DECLARE @item_sno INT;

    -- NULL-safe match: a receipt with no branch/department hits the
    -- no-branch/no-department row only, never some other branch's or
    -- department's stock.
    SELECT @item_sno = item_sno
    FROM dbo.nt_inventory_items
    WHERE prod_sno = @prod_sno
      AND ((@com_sno  IS NULL AND com_sno  IS NULL) OR com_sno  = @com_sno)
      AND ((@div_sno  IS NULL AND div_sno  IS NULL) OR div_sno  = @div_sno)
      AND ((@brn_sno  IS NULL AND brn_sno  IS NULL) OR brn_sno  = @brn_sno)
      AND ((@dept_sno IS NULL AND dept_sno IS NULL) OR dept_sno = @dept_sno);

    IF @item_sno IS NULL
    BEGIN
        DECLARE @item_code VARCHAR(50) =
            'AUTO-' + CAST(@prod_sno AS VARCHAR(20))
            + CASE WHEN @brn_sno IS NOT NULL
                   THEN '-B' + CAST(@brn_sno AS VARCHAR(20))
                   ELSE ''
              END
            + CASE WHEN @dept_sno IS NOT NULL
                   THEN '-D' + CAST(@dept_sno AS VARCHAR(20))
                   ELSE ''
              END;

        INSERT INTO dbo.nt_inventory_items (
            item_code, item_name, category, uom, current_stock, min_stock,
            max_stock, reorder_qty, warehouse, location, cost_price, selling_price,
            status, prod_sno, com_sno, div_sno, brn_sno, dept_sno, created_by, created_at
        )
        VALUES (
            @item_code,
            ISNULL(@prod_name, 'Product ' + CAST(@prod_sno AS VARCHAR(20))),
            'Raw Material', ISNULL(@uom_name, 'Nos'), 0, 0,
            0, 0, 'Main Warehouse', ISNULL(@location, 'B1'), 0, 0,
            'Active', @prod_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, 'system', GETDATE()
        );

        SET @item_sno = SCOPE_IDENTITY();
    END
    ELSE IF @location IS NOT NULL
    BEGIN
        UPDATE dbo.nt_inventory_items
        SET location   = @location,
            updated_at = GETDATE()
        WHERE item_sno = @item_sno;
    END

    SELECT item_sno, item_code, item_name, uom, current_stock, warehouse, location,
           com_sno, div_sno, brn_sno, dept_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO
-- [F2. procedures] dbo.sp_product_catagory
  CREATE OR ALTER PROCEDURE [dbo].[sp_product_catagory] 
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        SELECT [cat_sno]
      ,[cat_name]
      ,[cat_description]
      ,[cat_notes]
       FROM [Non_trade_Dev].[dbo].[category_master] 
WHERE cat_active='Y' 
ORDER BY cat_sno;
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END
GO
-- [F2. procedures] dbo.sp_product_sub_catagory
CREATE OR ALTER PROCEDURE [dbo].[sp_product_sub_catagory]
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT sc.[subcat_sno]
              ,sc.[subcat_name]
              ,sc.[subcat_description]
              ,sc.[subcat_notes]
              ,sc.[subcat_stock_type]
              ,sc.[cat_sno]
              ,cm.[cat_name]
        FROM [Non_trade_Dev].[dbo].[subcategory_master] sc
        INNER JOIN [Non_trade_Dev].[dbo].[category_master] cm ON cm.cat_sno = sc.cat_sno
        WHERE sc.subcat_active = 'Y'
        ORDER BY sc.subcat_sno;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
-- [F2. procedures] dbo.usp_GetPendingForEcno
CREATE OR ALTER PROCEDURE [dbo].[usp_GetPendingForEcno]
  @ecno NVARCHAR(50)
AS
BEGIN
  SET NOCOUNT ON;

  ;WITH FlowSteps AS (
    SELECT af.nt_app_flow_sno, s.step_no, s.step_ecno
    FROM Non_trade_Dev.dbo.nt_approval_flow af
    CROSS APPLY ( VALUES
       (1, af.nt_app_flow_step1_ecno),
       (2, af.nt_app_flow_step2_ecno),
       (3, af.nt_app_flow_step3_ecno),
       (4, af.nt_app_flow_step4_ecno),
       (5, af.nt_app_flow_step5_ecno),
       (6, af.nt_app_flow_step6_ecno),
       (7, af.nt_app_flow_step7_ecno),
       (8, af.nt_app_flow_step8_ecno),
       (9, af.nt_app_flow_step9_ecno),
       (10, af.nt_app_flow_step10_ecno),
       (11, af.nt_app_flow_step11_ecno),
       (12, af.nt_app_flow_step12_ecno),
       (13, af.nt_app_flow_step13_ecno)
    ) s(step_no, step_ecno)
  ),
ApprovedHistory AS (
    SELECT nh.nt_app_flow_sno,
           TRY_CAST(nh.nt_app_his_auth_selection AS INT) AS step_no
    FROM Non_trade_Dev.dbo.nt_approval_history nh
    WHERE nh.nt_app_his_status = 'A'
      AND nh.is_active = 'Y'
),
RejectedHistory AS (
    SELECT nh.nt_app_flow_sno,
           TRY_CAST(nh.nt_app_his_auth_selection AS INT) AS step_no
    FROM Non_trade_Dev.dbo.nt_approval_history nh
    WHERE nh.nt_app_his_status = 'R'
      AND nh.is_active = 'Y'
),
CurrentStep AS (
    SELECT
      bde.bud_dta_sno,
      bde.bud_sno,
      bde.nt_app_flow_sno,
      (SELECT MIN(fs.step_no)
       FROM FlowSteps fs
       WHERE fs.nt_app_flow_sno = bde.nt_app_flow_sno
         AND fs.step_ecno IS NOT NULL
         AND NOT EXISTS (
             SELECT 1 FROM ApprovedHistory ah
             WHERE ah.nt_app_flow_sno = fs.nt_app_flow_sno
               AND ah.step_no = fs.step_no
         )
         AND NOT EXISTS (
           SELECT 1 FROM FlowSteps prev
           WHERE prev.nt_app_flow_sno = fs.nt_app_flow_sno
             AND prev.step_no < fs.step_no
             AND prev.step_ecno IS NOT NULL
             AND NOT EXISTS (
                 SELECT 1 FROM ApprovedHistory ah2
                 WHERE ah2.nt_app_flow_sno = prev.nt_app_flow_sno
                   AND ah2.step_no = prev.step_no
             )
         )
      ) AS current_step_no
    FROM Non_trade_Dev.dbo.budget_data_entries bde
    WHERE bde.is_active = 'Y'
)
 
SELECT
    cs.bud_dta_sno,
    cs.bud_sno,
    cs.nt_app_flow_sno,
    cs.current_step_no,
    fs.step_ecno AS current_step_ecno,
    bm.bud_code,
    bm.dept_sno,
    bm.com_sno,
    bde.bud_dta_desc,
    bde.bud_dta_ctg,
    bde.bud_dta_req_qty,
    bde.uom_sno,
    bde.bud_dta_unt_cst,
    bde.created_date
FROM CurrentStep cs
INNER JOIN FlowSteps fs
    ON fs.nt_app_flow_sno = cs.nt_app_flow_sno
   AND fs.step_no = cs.current_step_no
   AND fs.step_ecno = @ecno   -- ✅ filter here only for actual current step approver
INNER JOIN Non_trade_Dev.dbo.budget_data_entries bde
    ON bde.bud_dta_sno = cs.bud_dta_sno
LEFT JOIN Non_trade_Dev.dbo.budget_master bm
    ON bm.bud_sno = bde.bud_sno
WHERE cs.current_step_no IS NOT NULL
ORDER BY bde.created_date DESC;

END
GO
-- [F2. procedures] dbo.usp_InsertPurchaseRequest
CREATE OR ALTER PROCEDURE usp_InsertPurchaseRequest
    @jsonInput NVARCHAR(MAX),
    @pr_no     VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno            INT,
                @div_sno            INT,
                @brn_sno            INT,
                @dept_sno           INT,
                @reg_date           DATE,
                @required_date      DATE,
                @priority_sno       INT,
                @purpose            NVARCHAR(500),
                @current_year       VARCHAR(10),
                @pr_prefix          VARCHAR(20),
                @sequence_number    INT,
                @pr_basic_sno       INT,
                @created_by         VARCHAR(20),
                @workflow_types_id  INT,
                @first_approver     VARCHAR(20),
                @workflow_id        INT,
                @items_inserted     INT,
                @requisition_type   VARCHAR(30),
                @category           VARCHAR(20),
                @source_invoice_sno INT;

        SET @current_year = dbo.fn_GetFinancialYear(GETDATE());
        SET @pr_prefix    = 'PR' + @current_year ;

        SELECT @sequence_number = ISNULL(MAX(
            CASE
                WHEN pr_no LIKE @pr_prefix + '%'
                THEN TRY_CAST(
                         SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no))
                     AS INT)
                ELSE 0
            END
        ), 0) + 1
        FROM [Non_trade_Dev].[dbo].[pr_basic_info] WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';

        SET @pr_no = @pr_prefix + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

        SELECT
            @com_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.com_sno'),
            @div_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.div_sno'),
            @brn_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno'),
            @dept_sno           = JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno'),
            @reg_date           = JSON_VALUE(@jsonInput, '$.basicInfo.req_date'),
            @required_date      = JSON_VALUE(@jsonInput, '$.basicInfo.required_date'),
            @priority_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno'),
            @purpose            = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
            @requisition_type   = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.requisition_type'), ''),
            @source_invoice_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.source_invoice_sno') AS INT),
            @created_by         = 'KTM1148';

        SET @category = CASE @requisition_type
            WHEN 'civil_works'     THEN 'CIVIL'
            WHEN 'electrical_works' THEN 'ELECTRICAL'
            WHEN 'transportation'  THEN 'TRANSPORTATION'
            WHEN 'routine'         THEN 'ROUTINE'
            ELSE NULL
        END;

        IF @com_sno IS NULL
            THROW 50010, 'Company (com_sno) is required.', 1;

        IF @div_sno IS NULL
            THROW 50011, 'Division (div_sno) is required.', 1;

        IF @brn_sno IS NULL
            THROW 50001, 'Branch (brn_sno) is required.', 1;

        IF @reg_date IS NULL
            THROW 50002, 'Request date (req_date) is required.', 1;

        IF @required_date IS NULL
            THROW 50003, 'Required date is required.', 1;

        IF @created_by IS NULL
            THROW 50004, 'Created by is required.', 1;

        -- Validate items array has at least one valid PRODUCT line
        -- (prod_sno + unit_sno). Service lines removed along with the
        -- Service Agreement feature.
        IF NOT EXISTS (
            SELECT 1
            FROM OPENJSON(@jsonInput, '$.items')
            WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
              AND JSON_VALUE(value, '$.prod_sno') != ''
              AND JSON_VALUE(value, '$.unit_sno')  IS NOT NULL
              AND JSON_VALUE(value, '$.unit_sno')  != ''
        )
            THROW 50005, 'At least one valid item (prod_sno+unit_sno) is required.', 1;

      SELECT
    @workflow_id       = wt.workflow_id,
    @workflow_types_id = wt.workflow_types_id
FROM workflow_types wt
INNER JOIN approval_workflow_master awm
    ON awm.workflow_id = wt.workflow_id
WHERE wt.brn_sno  = @brn_sno
  AND wt.dept_sno = @dept_sno
  AND wt.com_sno  = @com_sno
  AND wt.div_sno  = @div_sno
  AND awm.entity_type  = 'PurchaseRequisition';
        SELECT @workflow_types_id = workflow_types_id
        FROM workflow_types
       WHERE brn_sno  = @brn_sno
          AND dept_sno = @dept_sno
          AND com_sno=@com_sno
          AND div_sno=@div_sno
          AND workflow_id=@workflow_id;

        IF @workflow_types_id IS NULL
            THROW 50006, 'No workflow configuration found for this branch and department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 50007, 'No approver found for the first stage of the workflow.', 1;

        INSERT INTO [Non_trade_Dev].[dbo].[pr_basic_info]
        (
            [pr_no],               [com_sno],            [div_sno],
            [brn_sno],             [dept_sno],           [reg_date],
            [required_date],       [priority_sno],       [purpose],
            [is_active],           [created_by],         [created_date],
            [workflow_types_id],   [current_approver_id],[status],
            [category],            [source_invoice_sno]
        )
        VALUES
        (
            @pr_no,                @com_sno,             @div_sno,
            @brn_sno,              @dept_sno,            @reg_date,
            @required_date,        @priority_sno,        @purpose,
            'Y',                   @created_by,          GETDATE(),
            @workflow_types_id,    @first_approver,      'P',
            @category,             @source_invoice_sno
        );

        SET @pr_basic_sno = SCOPE_IDENTITY();

        -- ── Insert PR Item Details (product lines only — service_sno/
        -- agreement_sno no longer populated; those columns remain on the
        -- table but are permanently NULL for new rows going forward) ──────
        INSERT INTO [Non_trade_Dev].[dbo].[pr_item_details]
        (
            [pr_no],        [pr_basic_sno],  [prod_sno],
            [qty],          [unit],          [est_cost],
            [total_cost],   [remarks],       [specification],
            [pr_prod_file], [item_type],
            [is_active],
            [created_by],   [created_date]
        )
        SELECT
            @pr_no,
            @pr_basic_sno,
            NULLIF(JSON_VALUE(value, '$.prod_sno'), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.qty'), ''), '0'),
            NULLIF(JSON_VALUE(value, '$.unit_sno'), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.est_cost'), ''), 0),
            ISNULL(NULLIF(JSON_VALUE(value, '$.total_cost'), ''), 0),
            ISNULL(NULLIF(JSON_VALUE(value, '$.remarks'),        ''), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.service_desc'),   ''), ''),
            NULLIF(JSON_VALUE(value, '$.item_attachment'),       ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.item_type'),      ''), 'product'),
            'Y',
            @created_by,
            GETDATE()
        FROM OPENJSON(@jsonInput, '$.items')
        WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
          AND JSON_VALUE(value, '$.prod_sno') != ''
          AND JSON_VALUE(value, '$.unit_sno')  IS NOT NULL
          AND JSON_VALUE(value, '$.unit_sno')  != '';

        SET @items_inserted = @@ROWCOUNT;

        IF @items_inserted = 0
            THROW 50008, 'No items were inserted. Check that items array is valid and non-empty.', 1;

        COMMIT TRANSACTION;

        SELECT
            'PR Data Saved Successfully. PR No: ' + @pr_no AS Message,
            'Success'                                       AS Status,
            @items_inserted                                 AS ItemsInserted;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT    = ERROR_SEVERITY();
        DECLARE @ErrorState    INT            = ERROR_STATE();

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO
-- [F2. procedures] dbo.usp_InsertVendorDrivenPurchaseRequest  (new)
CREATE OR ALTER PROCEDURE dbo.usp_InsertVendorDrivenPurchaseRequest
    @jsonInput NVARCHAR(MAX),
    @pr_no     VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ------------------------------------------------------------------
    -- 1. Parse input JSON
    -- ------------------------------------------------------------------
    DECLARE
        @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.com_sno') AS INT),
        @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.div_sno') AS INT),
        @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno') AS INT),
        @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno') AS INT),
        @reg_date           DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.req_date') AS DATE),
        @required_date      DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.required_date') AS DATE),
        @priority_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno') AS INT),
        @purpose            NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
        @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.vendor_sno') AS INT),
        @payment_cycle_days INT           = COALESCE(TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.payment_cycle_days') AS INT), 15),
        @attachment         NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.attachment'), ''),
        @created_by         VARCHAR(20)   = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.created_by'), ''),
        @items              NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items'),

        @workflow_types_id  INT,
        @workflow_id        INT,
        @first_approver     VARCHAR(20),
        @pr_basic_sno       INT,
        @financial_year     VARCHAR(10),
        @sequence_number    INT,
        @items_inserted     INT;

    DECLARE @insertedItems TABLE
    (
        pr_item_sno    INT,
        item_rate      DECIMAL(18,4),
        gst_pct        DECIMAL(5,2),
        discount_pct   DECIMAL(5,2),
        taxable_amount DECIMAL(18,2),
        gst_amount     DECIMAL(18,2)
    );

    -- ------------------------------------------------------------------
    -- 2. Validate input
    -- ------------------------------------------------------------------
    IF ISJSON(@jsonInput) <> 1
        THROW 59001, 'Invalid vendor-driven requisition payload.', 1;

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
       OR @reg_date IS NULL OR @required_date IS NULL OR @priority_sno IS NULL
       OR @vendor_sno IS NULL OR @created_by IS NULL
        THROW 59002, 'Company, division, branch, department, dates, priority, supplier and creator are required.', 1;

    IF @payment_cycle_days < 1 OR @payment_cycle_days > 365
        THROW 59003, 'payment_cycle_days must be between 1 and 365.', 1;

    IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
        THROW 59004, 'At least one vendor-driven item is required.', 1;

    IF @attachment IS NULL
        THROW 59009, 'A verification document (bill/receipt) for the requisition is required.', 1;

    IF EXISTS (
        SELECT 1
        FROM OPENJSON(@items)
        WHERE TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) <= 0
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) < 0
           OR (
                JSON_VALUE(value, '$.discount_pct') IS NOT NULL
                AND (
                    TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) IS NULL
                    OR TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) < 0
                    OR TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) > 100
                )
              )
    )
        THROW 59005, 'Every vendor-driven item requires product, unit, positive quantity, rate, and (if present) a discount_pct between 0 and 100.', 1;

    -- ------------------------------------------------------------------
    -- 3. Resolve approval workflow
    -- ------------------------------------------------------------------
    SELECT
        @workflow_id       = wt.workflow_id,
        @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno  = @com_sno
      AND wt.div_sno  = @div_sno
      AND wt.brn_sno  = @brn_sno
      AND wt.dept_sno = @dept_sno
      AND awm.entity_type = 'VendorDrivenPurchaseRequisition';

    IF @workflow_types_id IS NULL
        THROW 59006, 'No VendorDrivenPurchaseRequisition workflow is configured for this organisation scope.', 1;

    SELECT @first_approver = JSON_VALUE(stage_member.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages ws
    CROSS APPLY OPENJSON(ws.stages_json) stage_group
    CROSS APPLY OPENJSON(JSON_VALUE(stage_group.value, '$.stage_order_json')) stage_member
    WHERE ws.workflow_types_id = @workflow_types_id
      AND stage_group.[key]  = '0'
      AND stage_member.[key] = '0';

    IF @first_approver IS NULL
        THROW 59007, 'The VendorDrivenPurchaseRequisition workflow has no first approver.', 1;

    -- ------------------------------------------------------------------
    -- 4. Create the requisition
    -- ------------------------------------------------------------------
    BEGIN TRANSACTION;
    BEGIN TRY

        SET @financial_year = dbo.fn_GetFinancialYear(GETDATE());

        SELECT @sequence_number = ISNULL(MAX(TRY_CAST(RIGHT(pr_no, 4) AS INT)), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE 'VPR' + @financial_year + '-%';

        SET @pr_no = 'VPR' + @financial_year + '-' + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

        INSERT INTO dbo.pr_basic_info
        (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date,
            priority_sno, purpose, request_mode, vendor_sno, payment_cycle_days,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES
        (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @reg_date, @required_date,
            @priority_sno, @purpose, 'VENDOR_DRIVEN', @vendor_sno, @payment_cycle_days,
            'Y', @created_by, GETDATE(), @workflow_types_id, @first_approver, 'P'
        );

        SET @pr_basic_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details
        (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost,
            remarks, specification, item_type, is_active,
            created_by, created_date, item_description, item_rate, gst_pct,
            discount_pct, taxable_amount, gst_amount
        )
        OUTPUT
            inserted.pr_item_sno, inserted.item_rate, inserted.gst_pct,
            inserted.discount_pct, inserted.taxable_amount, inserted.gst_amount
        INTO @insertedItems
        SELECT
            @pr_no,
            @pr_basic_sno,
            TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            t.taxable_amount + g2.gst_amount,
            NULLIF(JSON_VALUE(value, '$.remarks'), ''),
            NULLIF(JSON_VALUE(value, '$.specification'), ''),
            'vendor_driven',
            'Y',
            @created_by,
            GETDATE(),
            NULLIF(JSON_VALUE(value, '$.prod_name'), ''),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            base.gst_pct_val,
            base.disc_pct,
            t.taxable_amount,
            g2.gst_amount
        FROM OPENJSON(@items)
        CROSS APPLY (
            SELECT
                gross       = TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4))
                              * TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
                disc_pct    = COALESCE(TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)), 0),
                gst_pct_val = COALESCE(TRY_CAST(JSON_VALUE(value, '$.gst_pct') AS DECIMAL(5,2)), 0)
        ) base
        CROSS APPLY (
            SELECT taxable_amount = ROUND(base.gross * (1 - base.disc_pct / 100), 2)
        ) t
        CROSS APPLY (
            SELECT gst_amount = ROUND(t.taxable_amount * base.gst_pct_val / 100, 2)
        ) g2;

        SET @items_inserted = @@ROWCOUNT;
        IF @items_inserted = 0
            THROW 59008, 'No vendor-driven items were inserted.', 1;

        INSERT INTO dbo.pr_vendor_driven_info (pr_basic_sno, vendor_sno, payment_cycle_days, attachment, created_by, created_date)
        VALUES (@pr_basic_sno, @vendor_sno, @payment_cycle_days, @attachment, @created_by, GETDATE());

        INSERT INTO dbo.pr_vendor_driven_item_details (pr_item_sno, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount)
        SELECT pr_item_sno, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount
        FROM @insertedItems;

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- ------------------------------------------------------------------
    -- 5. Return result
    -- ------------------------------------------------------------------
    SELECT
        @pr_basic_sno   AS pr_basic_sno,
        @pr_no          AS pr_no,
        @items_inserted AS items_inserted,
        'SUCCESS'       AS result;

END;
GO
-- [F2. procedures] dbo.usp_ProcessApprovalAction
CREATE OR ALTER PROCEDURE [dbo].[usp_ProcessApprovalAction]
  @bud_dta_sno INT,
  @nt_app_flow_sno INT,
  @ecno NVARCHAR(50),
  @action NVARCHAR(20),          -- 'Approve', 'Reject', 'Hold'
  @comments NVARCHAR(MAX) = NULL,
  @value_change DECIMAL(18,4) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  BEGIN TRY
    BEGIN TRAN;

    -- basic validation: is ecno the current approver?
    DECLARE @current_step_no INT;
    ;WITH FlowSteps AS (
      SELECT fs.step_no, fs.step_ecno
      FROM Non_trade_Dev.dbo.nt_approval_flow af
      CROSS APPLY ( VALUES
         (1, af.nt_app_flow_step1_ecno),
         (2, af.nt_app_flow_step2_ecno),
         (3, af.nt_app_flow_step3_ecno),
         (4, af.nt_app_flow_step4_ecno),
         (5, af.nt_app_flow_step5_ecno),
         (6, af.nt_app_flow_step6_ecno),
         (7, af.nt_app_flow_step7_ecno),
         (8, af.nt_app_flow_step8_ecno),
         (9, af.nt_app_flow_step9_ecno),
         (10, af.nt_app_flow_step10_ecno),
         (11, af.nt_app_flow_step11_ecno),
         (12, af.nt_app_flow_step12_ecno),
         (13, af.nt_app_flow_step13_ecno)
      ) fs(step_no, step_ecno)
      WHERE af.nt_app_flow_sno = @nt_app_flow_sno
    ),
    Approved AS (
      SELECT TRY_CAST(nh.nt_app_his_auth_selection AS INT) AS step_no
      FROM Non_trade_Dev.dbo.nt_approval_history nh
      WHERE nh.nt_app_flow_sno = @nt_app_flow_sno
        AND nh.nt_app_his_status = 'A'
        AND nh.is_active = 1
    )
    SELECT @current_step_no = MIN(fs.step_no)
    FROM FlowSteps fs
    WHERE fs.step_ecno IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM Approved a WHERE a.step_no = fs.step_no)
      AND NOT EXISTS (  -- ensure earlier steps are approved or absent
         SELECT 1 FROM FlowSteps prev
         WHERE prev.step_no < fs.step_no
           AND prev.step_ecno IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Approved a2 WHERE a2.step_no = prev.step_no)
      );

    IF @current_step_no IS NULL
    BEGIN
      RAISERROR('No pending step found for this flow/item - cannot process approval.', 16, 1);
      ROLLBACK TRAN;
      RETURN;
    END

    -- confirm @ecno matches current step ecno
    DECLARE @expected_ecno NVARCHAR(50);
    SELECT @expected_ecno = fs.step_ecno
    FROM (
      SELECT af.*, fs.step_no, fs.step_ecno
      FROM Non_trade_Dev.dbo.nt_approval_flow af
      CROSS APPLY ( VALUES
         (1, af.nt_app_flow_step1_ecno),
         (2, af.nt_app_flow_step2_ecno),
         (3, af.nt_app_flow_step3_ecno),
         (4, af.nt_app_flow_step4_ecno),
         (5, af.nt_app_flow_step5_ecno),
         (6, af.nt_app_flow_step6_ecno),
         (7, af.nt_app_flow_step7_ecno),
         (8, af.nt_app_flow_step8_ecno),
         (9, af.nt_app_flow_step9_ecno),
         (10, af.nt_app_flow_step10_ecno),
         (11, af.nt_app_flow_step11_ecno),
         (12, af.nt_app_flow_step12_ecno),
         (13, af.nt_app_flow_step13_ecno)
      ) fs(step_no, step_ecno)
      WHERE af.nt_app_flow_sno = @nt_app_flow_sno
    ) AS fs
    WHERE fs.step_no = @current_step_no;

    IF ISNULL(@expected_ecno,'') <> @ecno
    BEGIN
      RAISERROR('User [%s] is not the current approver (expected %s).', 16, 1, @ecno, @expected_ecno);
      ROLLBACK TRAN;
      RETURN;
    END

    -- Insert into history
    INSERT INTO Non_trade_Dev.dbo.nt_approval_history
    (
	--nt_app_flow_sno,
      nt_app_li_sno,
      brn_sno,
      dept_sno,
      com_sno,
      div_sno,
      reference_no,
      nt_app_his_auths,          -- store approver ecno
      nt_app_his_auth_selection, -- store step no
      nt_app_his_status,
      nt_app_his_comments,
      nt_app_his_status_date,
      is_active,
      created_date
    )
    SELECT
      --af.nt_app_flow_sno,
      af.nt_app_li_sno,
      af.brn_sno,
      af.dept_sno,
      af.com_sno,
      af.div_sno,
      NULL, -- reference_no: fill if you have a meaningful ref (e.g. bud_dta_sno)
      @ecno,
      CAST(@current_step_no AS NVARCHAR(10)),
      CASE WHEN @action = 'A' THEN 'A'
           WHEN @action = 'R' THEN 'R'
           WHEN @action = 'P' THEN 'P'
           ELSE @action END,
      @comments,
      GETDATE(),
      1,
      GETDATE()
    FROM Non_trade_Dev.dbo.nt_approval_flow af
    WHERE af.nt_app_flow_sno = @nt_app_flow_sno;

    -- Apply any value change to budget_data_entries if provided (example)
    IF @value_change IS NOT NULL
    BEGIN
      UPDATE Non_trade_Dev.dbo.budget_data_entries
      SET bud_dta_act_unt_cst = @value_change,
          -- track updated date if you have such column, else ignore
          created_date = created_date
      WHERE bud_dta_sno = @bud_dta_sno;
    END

    -- If action = Reject => potentially mark item as rejected (business rule dependent)
    IF @action = 'R'
    BEGIN
      -- mark item inactive or set a status column if exists (example: is_active = 0)
      UPDATE Non_trade_Dev.dbo.budget_data_entries
      SET is_active = 0
      WHERE bud_dta_sno = @bud_dta_sno;
      -- leave transaction and return no next approver
      COMMIT TRAN;
      SELECT NULL AS next_approver_ecno, NULL AS next_step_no, 'R' AS final_status;
      RETURN;
    END

    -- If action was Approve: find next step
    DECLARE @next_step_no INT;
    DECLARE @next_approver_ecno NVARCHAR(50);

    SELECT TOP(1) @next_step_no = fs.step_no, @next_approver_ecno = fs.step_ecno
    FROM (
      SELECT fs.step_no, fs.step_ecno
      FROM Non_trade_Dev.dbo.nt_approval_flow af
      CROSS APPLY ( VALUES
         (1, af.nt_app_flow_step1_ecno),
         (2, af.nt_app_flow_step2_ecno),
         (3, af.nt_app_flow_step3_ecno),
         (4, af.nt_app_flow_step4_ecno),
         (5, af.nt_app_flow_step5_ecno),
         (6, af.nt_app_flow_step6_ecno),
         (7, af.nt_app_flow_step7_ecno),
         (8, af.nt_app_flow_step8_ecno),
         (9, af.nt_app_flow_step9_ecno),
         (10, af.nt_app_flow_step10_ecno),
         (11, af.nt_app_flow_step11_ecno),
         (12, af.nt_app_flow_step12_ecno),
         (13, af.nt_app_flow_step13_ecno)
      ) fs(step_no, step_ecno)
      WHERE af.nt_app_flow_sno = @nt_app_flow_sno
    ) AS fs
    WHERE fs.step_no > @current_step_no
      AND fs.step_ecno IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM Non_trade_Dev.dbo.nt_approval_history nh
        WHERE nh.nt_app_flow_sno = @nt_app_flow_sno
          AND TRY_CAST(nh.nt_app_his_auth_selection AS INT) = fs.step_no
          AND nh.nt_app_his_status = 'A'
          AND nh.is_active = 1
      )
    ORDER BY fs.step_no;

    IF @next_approver_ecno IS NULL
    BEGIN
      -- No more approvers -> mark final state on master if needed (example: update budget_master)
      UPDATE Non_trade_Dev.dbo.budget_master
      SET is_bud_value_approved = 1,
          bud_value_approved_by = @ecno,
          bud_value_approved_date = GETDATE()
      FROM Non_trade_Dev.dbo.budget_master bm
      INNER JOIN Non_trade_Dev.dbo.budget_data_entries bde ON bde.bud_sno = bm.bud_sno
      WHERE bde.bud_dta_sno = @bud_dta_sno;

      COMMIT TRAN;
      SELECT NULL AS next_approver_ecno, NULL AS next_step_no, 'FullyApproved' AS final_status;
      RETURN;
    END

    COMMIT TRAN;
    SELECT @next_approver_ecno AS next_approver_ecno, @next_step_no AS next_step_no, 'InProgress' AS final_status;
    RETURN;

  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRAN;
    DECLARE @errMsg NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR('Error in usp_ProcessApprovalAction: %s',16,1,@errMsg);
    RETURN;
  END CATCH
END

GO