-- Reproduces every number in the reconciliation bridge, in the order I hit them,
-- including the two attempts I threw away.
-- Run: sqlite3 -header -column data/comm_log.db < sql/bridge.sql

WITH RECURSIVE
scoped AS (        
    SELECT l.*, c.parent_id, c.creation_status, c.processing_status
    FROM communication_log l
    JOIN campaign c ON c.id = l.communication_id AND c.merchant_id = l.merchant_id
    WHERE l.merchant_id = 501
      AND l.communication_type = '2'
      AND l.sent_time >= '2026-10-01' AND l.sent_time < '2026-11-01'
      AND c.name LIKE '%diwali%'
),
eligible AS (
    SELECT * FROM scoped
    WHERE creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND processing_status = 'processed'
),
-- First attempt at chains: a single hop, COALESCE(parent_id, id).
one_hop AS (
    SELECT e.*,
           COALESCE(e.parent_id, e.communication_id) AS family_id
    FROM eligible e
),
one_hop_family AS (
    SELECT family_id, COUNT(*) > 1 AS is_chain
    FROM (SELECT DISTINCT o.family_id, c.id
          FROM one_hop o
          JOIN campaign c ON c.id = o.family_id OR c.parent_id = o.family_id)
    GROUP BY family_id
),
-- The fix: walk the whole way up.
tree(id, root_id) AS (
    SELECT id, id FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, t.root_id FROM campaign c JOIN tree t ON c.parent_id = t.id
),
full_family AS (
    SELECT root_id, COUNT(*) > 1 AS is_chain FROM tree GROUP BY root_id
),
steps(step, kept, description, result, reason) AS (
    SELECT '0', 'yes', 'COUNT(*) of in-scope sends',
           (SELECT COUNT(*) FROM scoped),
           'starting point; 8 above target'
    UNION ALL
    SELECT '1', 'yes', 'drop sends from campaigns that have not cleared approval',
           (SELECT COUNT(*) FROM eligible),
           '9004 is approval_awaiting; its 4 sends went out but are not signed off'
    UNION ALL
    SELECT '2', 'no', 'COUNT(DISTINCT customer_id) on eligible sends',
           (SELECT COUNT(DISTINCT customer_id) FROM eligible),
           'one short at 21: also merges C20, whose two sends in standalone 9101 should both count'
    UNION ALL
    SELECT '3', 'no', 'keep only delivered sends (delivery_status = 900)',
           (SELECT COUNT(*) FROM eligible WHERE delivery_status = 900),
           'hits 22 by coincidence; counts rows not customers, breaks on data we do not have (see tests)'
    UNION ALL
    SELECT '4', 'fixed in 5', 'collapse retries into parent with one hop, COALESCE(parent_id, id)',
           (SELECT COUNT(DISTINCT CASE WHEN f.is_chain THEN o.family_id || ':' || o.customer_id
                                       ELSE 'send:' || o.id END)
            FROM one_hop o JOIN one_hop_family f ON f.family_id = o.family_id),
           'right idea, 23: 9003 hangs off 9002 not 9001, so C3 lands in two families'
    UNION ALL
    SELECT '5', 'yes', 'resolve every campaign to its top-level root with a recursive CTE',
           (SELECT COUNT(DISTINCT CASE WHEN f.is_chain THEN t.root_id || ':' || e.customer_id
                                       ELSE 'send:' || e.id END)
            FROM eligible e
            JOIN tree t        ON t.id = e.communication_id
            JOIN full_family f ON f.root_id = t.root_id),
           'C3 now counted once for chain 9001; standalone repeat C20 untouched'
)
SELECT * FROM steps;
