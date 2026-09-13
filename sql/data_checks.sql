-- Checks I ran before trusting any count.
-- Run: sqlite3 -header -column data/comm_log.db < sql/data_checks.sql

-- 1. Integrity: every row has a campaign, merchants agree, nothing outside October,
--    no exact duplicate sends, timestamps behave.
SELECT 'log rows'                              AS check_name, COUNT(*) AS value FROM communication_log
UNION ALL SELECT 'campaigns',                  COUNT(*) FROM campaign
UNION ALL SELECT 'rows with no campaign',      COUNT(*) FROM communication_log l
          WHERE NOT EXISTS (SELECT 1 FROM campaign c WHERE c.id = l.communication_id)
UNION ALL SELECT 'merchant mismatch log vs campaign', COUNT(*) FROM communication_log l
          JOIN campaign c ON c.id = l.communication_id WHERE c.merchant_id <> l.merchant_id
UNION ALL SELECT 'parent_id pointing at nothing', COUNT(*) FROM campaign c
          WHERE c.parent_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM campaign p WHERE p.id = c.parent_id)
UNION ALL SELECT 'sends outside Oct 2026',     COUNT(*) FROM communication_log
          WHERE NOT (sent_time >= '2026-10-01' AND sent_time < '2026-11-01')
UNION ALL SELECT 'communication_type other than ''2''', COUNT(*) FROM communication_log WHERE communication_type <> '2'
UNION ALL SELECT 'exact duplicate rows (all cols but id)', COUNT(*) - (SELECT COUNT(*) FROM (
          SELECT DISTINCT merchant_id, communication_id, customer_id, communication_type, delivery_status,
                          sent_time, scheduled_time, credit_used, channel FROM communication_log))
          FROM communication_log
UNION ALL SELECT 'sent_time <> scheduled_time', COUNT(*) FROM communication_log WHERE sent_time <> scheduled_time
UNION ALL SELECT 'distinct send timestamps',   COUNT(DISTINCT sent_time) FROM communication_log
UNION ALL SELECT 'credits billed (all rows)',  SUM(credit_used) FROM communication_log;

-- 2. Campaign profile: who is approved, how many sends, how many failed.
SELECT c.id, c.parent_id, c.name, c.creation_status, c.processing_status,
       COUNT(l.id)                          AS sends,
       COUNT(DISTINCT l.customer_id)        AS customers,
       SUM(l.delivery_status = 900)         AS delivered,
       SUM(l.delivery_status = 1100)        AS failed,
       MIN(l.sent_time)                     AS first_send,
       MAX(l.sent_time)                     AS last_send
FROM campaign c
LEFT JOIN communication_log l ON l.communication_id = c.id
GROUP BY c.id
ORDER BY c.id;

-- 3. Every customer with more than one send, in time order. This is what showed
--    the two different kinds of repeat (across retry campaigns vs inside one campaign).
SELECT customer_id,
       COUNT(*) AS sends,
       COUNT(DISTINCT communication_id) AS campaigns,
       group_concat(communication_id || ' ' || CASE delivery_status WHEN 900 THEN 'ok' ELSE 'fail' END
                    || ' ' || substr(sent_time, 1, 10), '  ->  ') AS history
FROM (SELECT * FROM communication_log ORDER BY customer_id, sent_time, id)
GROUP BY customer_id
HAVING COUNT(*) > 1;

-- 4. Retry chains, top-down, with depth. 9003 sits two levels below 9001.
WITH RECURSIVE tree(id, root_id, depth, lineage) AS (
    SELECT id, id, 0, CAST(id AS TEXT) FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, t.root_id, t.depth + 1, t.lineage || ' > ' || c.id
    FROM campaign c JOIN tree t ON c.parent_id = t.id
)
SELECT t.root_id, t.depth, t.lineage, c.creation_status
FROM tree t JOIN campaign c ON c.id = t.id
ORDER BY t.root_id, t.lineage;

-- 5. Does each retry actually re-target people from its parent?
--    A retry should be a subset of its parent's audience. 9004 is not.
SELECT r.id                                   AS retry_campaign,
       r.parent_id,
       COUNT(DISTINCT rl.customer_id)         AS retry_customers,
       COUNT(DISTINCT CASE WHEN pl.customer_id IS NULL THEN rl.customer_id END)  AS never_in_parent,
       COUNT(DISTINCT CASE WHEN pl.delivery_status = 900 THEN rl.customer_id END) AS already_delivered_by_parent
FROM campaign r
JOIN communication_log rl ON rl.communication_id = r.id
LEFT JOIN communication_log pl ON pl.communication_id = r.parent_id
                              AND pl.customer_id = rl.customer_id
WHERE r.parent_id IS NOT NULL
GROUP BY r.id, r.parent_id
ORDER BY r.id;
