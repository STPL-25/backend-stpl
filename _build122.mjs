// Generates sql/122_service_approval_forward_send_back.sql (+ rollback) from the LIVE Non_trade_Dev definitions.
import fs from 'node:fs';
import sql from 'mssql';

const p = await sql.connect({ user: 'admin', password: 'admin123', server: '10.0.21.8', port: 1433, database: 'Non_trade_Dev', options: { trustServerCertificate: true, encrypt: false } });
const def = async (n) => (await p.request().query(`select object_definition(object_id('${n}')) d`)).recordset[0].d.replace(/\r\n/g, '\n');

const names = ['sp_approve_service_agreement', 'sp_nt_ApproveServicePoCycle', 'sp_nt_GetServiceAgreementsForApproval', 'sp_nt_GetServicePoCyclesForApproval'];
const orig = {};
for (const n of names) orig[n] = await def(n);

const toAlter = (s) => s.replace(/^[\s\S]*?\bCREATE\s+(OR\s+ALTER\s+)?PROCEDURE/i, 'CREATE OR ALTER PROCEDURE');

function must(s, a, b, label) {
  if (!s.includes(a)) throw new Error('patch miss: ' + label);
  return s.replace(a, () => b);
}

// ── shared patches ─────────────────────────────────────────────────────────
function patchApproveSp(s, o) {
  // o: { id, table, idCol, entity, statusCond, historyInsertCols, ... }
  s = s.replace(/(@action\s+VARCHAR\(30\)\s*=\s*JSON_VALUE\(@jsonInput, '\$\.action'\));/,
    (m, a) => a + ",\n                @send_back_to    VARCHAR(30)   = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.send_back_to'))), '');");
  if (!s.includes('@send_back_to')) throw new Error('patch miss: action decl');
  s = must(s, `NOT IN ('approve', 'reject')`, `NOT IN ('approve', 'reject', 'forward', 'send_back')`, 'action list');
  s = must(s, `RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);`,
    `RAISERROR('Invalid action. Must be ''approve'', ''reject'', ''forward'' or ''send_back''.', 16, 1);`, 'action msg');

  const stagesTbl = o.stagesTbl;
  const block = `
        -- ── Forward / send back (sql/122) ─────────────────────────────────────
        -- Forward hands the item to the NEXT approver in the workflow without
        -- approving it; send back returns it to an EARLIER approver (who then
        -- approves it onward again). Both need the stage's can_forward /
        -- can_backward flag, and only the current approver may use them. The
        -- stage list is read from the workflow itself, not trusted from the client.
        IF @action IN ('forward', 'send_back')
        BEGIN
            DECLARE @fs_json NVARCHAR(MAX) = (
                SELECT TOP 1 ws.stage_order_json
                FROM dbo.workflow_stage ws
                JOIN dbo.${o.table} t ON t.workflow_types_id = ws.workflow_types_id
                WHERE t.${o.idCol} = @${o.idCol} AND ws.is_active = 'Y'
            );
            IF @fs_json IS NULL OR ISJSON(@fs_json) = 0 SET @fs_json = @approval_stages;

            DECLARE @fs TABLE (seq_no INT, approver_ecno VARCHAR(30), stage VARCHAR(100), can_forward CHAR(1), can_backward CHAR(1));
            INSERT INTO @fs (seq_no, approver_ecno, stage, can_forward, can_backward)
            SELECT CAST(j.[key] AS INT), JSON_VALUE(j.[value], '$.approver_ecno'), JSON_VALUE(j.[value], '$.stage'),
                   JSON_VALUE(j.[value], '$.can_forward'), JSON_VALUE(j.[value], '$.can_backward')
            FROM OPENJSON(@fs_json) j;

            IF NOT EXISTS (SELECT 1 FROM dbo.${o.table} WHERE ${o.idCol} = @${o.idCol} AND ${o.statusCond} AND current_approver_id = @approved_by)
            BEGIN
                RAISERROR('Only the current approver can forward or send back this ${o.noun}.', 16, 1);
                RETURN;
            END

            DECLARE @cur_seq INT = (SELECT MIN(seq_no) FROM @fs WHERE approver_ecno = @approved_by);
            IF @cur_seq IS NULL
            BEGIN
                RAISERROR('You are not an approver in this ${o.noun}''s workflow.', 16, 1);
                RETURN;
            END

            DECLARE @target VARCHAR(30) = NULL;
            IF @action = 'forward'
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM @fs WHERE seq_no = @cur_seq AND can_forward = 'Y')
                BEGIN
                    RAISERROR('Forwarding is not enabled for your approval stage.', 16, 1);
                    RETURN;
                END
                SELECT TOP 1 @target = approver_ecno FROM @fs WHERE seq_no > @cur_seq ORDER BY seq_no;
                IF @target IS NULL
                BEGIN
                    RAISERROR('There is no later approver to forward this to.', 16, 1);
                    RETURN;
                END
            END
            ELSE
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM @fs WHERE seq_no = @cur_seq AND can_backward = 'Y')
                BEGIN
                    RAISERROR('Sending back is not enabled for your approval stage.', 16, 1);
                    RETURN;
                END
                IF @send_back_to IS NULL OR NOT EXISTS (SELECT 1 FROM @fs WHERE approver_ecno = @send_back_to AND seq_no < @cur_seq)
                BEGIN
                    RAISERROR('Choose an earlier approver in the workflow to send this back to.', 16, 1);
                    RETURN;
                END
                IF @comments IS NULL OR LTRIM(RTRIM(@comments)) = ''
                BEGIN
                    RAISERROR('A reason is required when sending back.', 16, 1);
                    RETURN;
                END
                SET @target = @send_back_to;
            END

            DECLARE @fs_note NVARCHAR(500) = CASE WHEN @action = 'forward' THEN N'Forwarded to ' ELSE N'Sent back to ' END + @target
                + CASE WHEN NULLIF(LTRIM(RTRIM(@comments)), '') IS NULL THEN N'' ELSE N': ' + LTRIM(RTRIM(@comments)) END;

            ${o.historyInsert}

            UPDATE dbo.${o.table} SET current_approver_id = @target WHERE ${o.idCol} = @${o.idCol};

            -- The new holder must be told even if they were notified about this item earlier in its life.
            UPDATE dbo.approval_notice_log SET status = 'FAILED', error_message = N'Re-notify after ' + @action, modified_at = GETDATE()
            WHERE entity_type = '${o.entity}' AND entity_id = @${o.idCol} AND approver_ecno = @target AND status = 'SENT';

            DROP TABLE ${stagesTbl};
            COMMIT TRANSACTION;
            SELECT CASE WHEN @action = 'forward' THEN 'FORWARDED' ELSE 'SENT_BACK' END AS result,
                   @${o.idCol} AS ${o.idCol}, @approved_by AS actioned_by, @target AS next_approver;
            RETURN;
        END

`;
  s = must(s, `        IF @action = 'reject'\n        BEGIN`, block + `        IF @action = 'reject'\n        BEGIN`, 'reject anchor');
  return s;
}

let agr = patchApproveSp(orig['sp_approve_service_agreement'], {
  table: 'service_agreement', idCol: 'agreement_sno', noun: 'agreement', entity: 'ServiceAgreement', statusCond: `status = 'P'`,
  stagesTbl: '#approval_stages',
  historyInsert: `INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
            VALUES (@agreement_sno, CASE WHEN @action = 'forward' THEN 'FORWARDED' ELSE 'SENT_BACK' END, @approved_by, @fs_note, @cur_version);`,
});
let cyc = patchApproveSp(orig['sp_nt_ApproveServicePoCycle'], {
  table: 'service_po_cycle', idCol: 'cycle_sno', noun: 'cycle', entity: 'ServicePO', statusCond: `status = 'PENDING_APPROVAL'`,
  stagesTbl: '#po_approval_stages',
  historyInsert: `INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
            VALUES (@cycle_sno, CASE WHEN @action = 'forward' THEN 'FORWARDED' ELSE 'SENT_BACK' END, @approved_by, @fs_note);`,
});

// ── list SPs: remarks + recent activity ────────────────────────────────────
let agrList = orig['sp_nt_GetServiceAgreementsForApproval'];
agrList = must(agrList, `           sa.current_approver_id, sa.status, sa.created_by, sa.created_at,\n`,
  `           sa.current_approver_id, sa.status, sa.created_by, sa.created_at,
           (
               SELECT TOP 8 h.action_type, h.status_by, h.comment, h.created_at
               FROM dbo.service_agreement_history h
               WHERE h.agreement_sno = sa.agreement_sno
               ORDER BY h.history_sno DESC
               FOR JSON PATH
           ) AS history_json,\n`, 'agr list');

let cycList = orig['sp_nt_GetServicePoCyclesForApproval'];
cycList = must(cycList, `spc.entered_by, spc.entered_at,\n`,
  `spc.entered_by, spc.entered_at, spc.remarks,
           (
               SELECT TOP 8 h.action_type, h.status_by, h.comment, h.created_at
               FROM dbo.service_po_cycle_history h
               WHERE h.cycle_sno = spc.cycle_sno
               ORDER BY h.history_sno DESC
               FOR JSON PATH
           ) AS history_json,\n`, 'cyc list');

const header = (t) => `-- ${t}\n-- Generated by _build122.mjs from the LIVE Non_trade_Dev definitions (see\n-- [[project-service-agreement-workflow]] memory for the technique).\n\n`;
const out = header('sql/122_service_approval_forward_send_back.sql\n-- Service Agreement + Service PO approval: FORWARD and SEND BACK (the screens only had\n-- approve / reject), plus the entry remarks / recent activity on the approver list.\n-- Re-runnable (CREATE OR ALTER).') +
  [agr, cyc, agrList, cycList].map((s) => toAlter(s).trimEnd() + '\nGO\n').join('\n');
fs.writeFileSync('sql/122_service_approval_forward_send_back.sql', out);

fs.mkdirSync('sql/backups', { recursive: true });
fs.writeFileSync('sql/backups/pre_service_forward_sendback_2026-10-03_ROLLBACK.sql',
  header('ROLLBACK for sql/122 — the four procedures exactly as they were before.') +
  names.map((n) => toAlter(orig[n]).trimEnd() + '\nGO\n').join('\n'));
console.log('written');
process.exit(0);
