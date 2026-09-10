/* =========================================================================
   SaaS Customer Support & Success Analytics — SQL Project
   Database: support_saas_full.sqlite
   Tables: plans, accounts, subscriptions, invoices, payments,
           agents, support_tickets, csat_surveys
   ========================================================================= */


/* =========================================================================
   SECTION 1 — TECHNICAL SUPPORT
   ========================================================================= */

-- 1.1 Average first-response time (hours) and resolution time by priority
SELECT
    priority,
    ROUND(AVG((JULIANDAY(first_response_at) - JULIANDAY(created_at)) * 24), 2) AS avg_first_response_hrs,
    ROUND(AVG(CASE WHEN resolved_at != '' THEN
        (JULIANDAY(resolved_at) - JULIANDAY(created_at)) * 24 END), 2) AS avg_resolution_hrs,
    COUNT(*) AS ticket_count
FROM support_tickets
GROUP BY priority
ORDER BY CASE priority WHEN 'Urgent' THEN 1 WHEN 'High' THEN 2 WHEN 'Medium' THEN 3 ELSE 4 END;


-- 1.2 Agent performance: avg resolution time + avg CSAT score, ranked
SELECT
    a.agent_name,
    a.team,
    COUNT(t.ticket_id) AS tickets_handled,
    ROUND(AVG(CASE WHEN t.resolved_at != '' THEN
        (JULIANDAY(t.resolved_at) - JULIANDAY(t.created_at)) * 24 END), 2) AS avg_resolution_hrs,
    ROUND(AVG(s.score), 2) AS avg_csat,
    RANK() OVER (ORDER BY AVG(s.score) DESC) AS csat_rank
FROM agents a
JOIN support_tickets t ON t.agent_id = a.agent_id
LEFT JOIN csat_surveys s ON s.ticket_id = t.ticket_id
GROUP BY a.agent_id
ORDER BY avg_csat DESC;


-- 1.3 Ticket volume by month (spotting spikes)
SELECT
    STRFTIME('%Y-%m', created_at) AS ticket_month,
    COUNT(*) AS tickets_created
FROM support_tickets
GROUP BY ticket_month
ORDER BY ticket_month;


-- 1.4 Open/Pending tickets older than 5 days (SLA breach candidates)
SELECT
    ticket_id, account_id, agent_id, priority, status, created_at,
    ROUND((JULIANDAY('2025-09-01') - JULIANDAY(created_at)), 1) AS days_open
FROM support_tickets
WHERE status IN ('Open','Pending')
  AND JULIANDAY('2025-09-01') - JULIANDAY(created_at) > 5
ORDER BY days_open DESC;


-- 1.5 Category breakdown — which issue types dominate
SELECT
    category,
    COUNT(*) AS total_tickets,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM support_tickets), 1) AS pct_of_total
FROM support_tickets
GROUP BY category
ORDER BY total_tickets DESC;


/* =========================================================================
   SECTION 2 — CUSTOMER SUCCESS
   ========================================================================= */

-- 2.1 At-risk accounts: open/high-priority tickets + low CSAT + active subscription
SELECT
    ac.account_id, ac.region, ac.segment, sub.status AS sub_status, sub.mrr,
    COUNT(DISTINCT t.ticket_id) AS open_or_high_tickets,
    ROUND(AVG(cs.score), 2) AS avg_csat
FROM accounts ac
JOIN subscriptions sub ON sub.account_id = ac.account_id
JOIN support_tickets t ON t.account_id = ac.account_id
LEFT JOIN csat_surveys cs ON cs.ticket_id = t.ticket_id
WHERE sub.status = 'active'
  AND (t.status IN ('Open','Pending') OR t.priority IN ('High','Urgent'))
GROUP BY ac.account_id
HAVING avg_csat IS NULL OR avg_csat <= 2.5
ORDER BY open_or_high_tickets DESC;


-- 2.2 Renewal pipeline: active subscriptions whose most recent invoice is unpaid/failed
WITH last_invoice AS (
    SELECT subscription_id, invoice_date, invoice_status,
           ROW_NUMBER() OVER (PARTITION BY subscription_id ORDER BY invoice_date DESC) AS rn
    FROM invoices
)
SELECT
    sub.account_id, sub.subscription_id, sub.plan_id, sub.mrr, sub.status,
    li.invoice_date AS last_invoice_date,
    li.invoice_status AS last_invoice_status
FROM subscriptions sub
JOIN last_invoice li ON li.subscription_id = sub.subscription_id AND li.rn = 1
WHERE sub.status = 'active'
  AND li.invoice_status = 'open'   -- unpaid/outstanding invoice on an otherwise active sub
ORDER BY li.invoice_date;


-- 2.3 MRR by segment and region
SELECT
    ac.segment, ac.region,
    SUM(sub.mrr) AS total_mrr,
    COUNT(*) AS active_subs
FROM subscriptions sub
JOIN accounts ac ON ac.account_id = sub.account_id
WHERE sub.status = 'active'
GROUP BY ac.segment, ac.region
ORDER BY total_mrr DESC;


-- 2.4 Churned accounts and their last known MRR (revenue lost)
SELECT
    sub.account_id, sub.plan_id, sub.mrr AS lost_mrr, sub.started_at, sub.ended_at
FROM subscriptions sub
WHERE sub.status = 'cancelled'
ORDER BY sub.ended_at DESC;


-- 2.5 Payment health: failure rate by region/segment (early churn signal)
SELECT
    ac.region, ac.segment,
    COUNT(*) AS total_payments,
    SUM(CASE WHEN p.payment_status = 'failed' THEN 1 ELSE 0 END) AS failed_payments,
    ROUND(100.0 * SUM(CASE WHEN p.payment_status = 'failed' THEN 1 ELSE 0 END) / COUNT(*), 2) AS failure_rate_pct
FROM payments p
JOIN invoices inv ON inv.invoice_id = p.invoice_id
JOIN subscriptions sub ON sub.subscription_id = inv.subscription_id
JOIN accounts ac ON ac.account_id = sub.account_id
GROUP BY ac.region, ac.segment
ORDER BY failure_rate_pct DESC;


/* =========================================================================
   SECTION 3 — DATA ANALYSIS
   ========================================================================= */

-- 3.1 Cohort retention: signup month vs active/churned status
SELECT
    STRFTIME('%Y-%m', ac.created_at) AS signup_cohort,
    COUNT(*) AS total_accounts,
    SUM(CASE WHEN sub.status = 'active' THEN 1 ELSE 0 END) AS still_active,
    ROUND(100.0 * SUM(CASE WHEN sub.status = 'active' THEN 1 ELSE 0 END) / COUNT(*), 1) AS retention_pct
FROM accounts ac
JOIN subscriptions sub ON sub.account_id = ac.account_id
GROUP BY signup_cohort
ORDER BY signup_cohort;


-- 3.2 Month-over-month MRR growth (running total + delta) using window functions
WITH monthly AS (
    SELECT STRFTIME('%Y-%m', invoice_date) AS month, SUM(amount_due) AS billed
    FROM invoices
    WHERE invoice_status = 'paid'
    GROUP BY month
)
SELECT
    month,
    billed,
    SUM(billed) OVER (ORDER BY month) AS running_total,
    billed - LAG(billed) OVER (ORDER BY month) AS mom_change
FROM monthly
ORDER BY month;


-- 3.3 Correlation signal: accounts with 3+ tickets vs churn rate
SELECT
    CASE WHEN ticket_count >= 3 THEN '3+ tickets' ELSE '0-2 tickets' END AS ticket_bucket,
    COUNT(*) AS accounts,
    SUM(CASE WHEN status != 'active' THEN 1 ELSE 0 END) AS churned,
    ROUND(100.0 * SUM(CASE WHEN status != 'active' THEN 1 ELSE 0 END) / COUNT(*), 1) AS churn_rate_pct
FROM (
    SELECT sub.account_id, sub.status,
           COUNT(t.ticket_id) AS ticket_count
    FROM subscriptions sub
    LEFT JOIN support_tickets t ON t.account_id = sub.account_id
    GROUP BY sub.account_id
) x
GROUP BY ticket_bucket;


-- 3.4 Rank accounts by MRR within each segment (window function)
SELECT
    ac.segment, sub.account_id, sub.mrr,
    RANK() OVER (PARTITION BY ac.segment ORDER BY sub.mrr DESC) AS mrr_rank_in_segment
FROM subscriptions sub
JOIN accounts ac ON ac.account_id = sub.account_id
WHERE sub.status = 'active'
ORDER BY ac.segment, mrr_rank_in_segment;


-- 3.5 Plan distribution and average seats per plan
SELECT
    p.plan_name,
    COUNT(*) AS num_subscriptions,
    ROUND(AVG(sub.seats), 1) AS avg_seats,
    SUM(sub.mrr) AS total_mrr
FROM subscriptions sub
JOIN plans p ON p.plan_id = sub.plan_id
GROUP BY p.plan_name
ORDER BY total_mrr DESC;

