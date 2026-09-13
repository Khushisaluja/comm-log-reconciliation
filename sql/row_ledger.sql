-- The same answer from the other direction: all 30 rows, what happened to each,
-- and a subtotal that walks 30 down to 22.
-- Run: sqlite3 -header -column data/comm_log.db < sql/row_ledger.sql

DROP TABLE IF EXISTS temp.ledger;

CREATE TEMP TABLE ledger AS
WITH RECURSIVE
tree(id, root_id) AS (
    SELECT id, id FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, t.root_id FROM campaign c JOIN tree t ON c.parent_id = t.id
),
family AS (
    SELECT root_id, COUNT(*) > 1 AS is_chain FROM tree GROUP BY root_id
),
tagged AS (
    SELECT l.id                       AS log_id,
           l.communication_id         AS campaign,
           t.root_id                  AS chain_root,
           l.customer_id              AS customer,
           CASE l.delivery_status WHEN 900 THEN 'delivered' ELSE 'failed' END AS delivery,
           substr(l.sent_time, 1, 10) AS sent_on,
           c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
               AND c.processing_status = 'processed' AS is_eligible,
           f.is_chain,
           c.creation_status
    FROM communication_log l
    JOIN campaign c ON c.id = l.communication_id
    JOIN tree t     ON t.id = c.id
    JOIN family f   ON f.root_id = t.root_id
),
ranked AS (
    SELECT tagged.*,
           -- position of this attempt among the customer's eligible attempts in the chain
           CASE WHEN is_eligible AND is_chain
                THEN ROW_NUMBER() OVER (PARTITION BY is_eligible, chain_root, customer
                                        ORDER BY sent_on, log_id)
           END AS attempt_no
    FROM tagged
)
SELECT log_id, campaign, chain_root, customer, delivery, sent_on,
       CASE
           WHEN NOT is_eligible     THEN 'excluded'
           WHEN is_chain AND attempt_no > 1 THEN 'collapsed'
           ELSE 'counted'
       END AS outcome,
       CASE
           WHEN NOT is_eligible     THEN 'campaign ' || campaign || ' is ' || creation_status
           WHEN is_chain AND attempt_no > 1
                                    THEN 'attempt ' || attempt_no || ' for ' || customer || ' in chain ' || chain_root
           WHEN is_chain            THEN 'first attempt in chain ' || chain_root
           ELSE 'standalone send, every row counts'
       END AS why
FROM ranked;

SELECT * FROM ledger ORDER BY chain_root, log_id;

SELECT outcome, COUNT(*) AS rows,
       SUM(COUNT(*)) OVER (ORDER BY CASE outcome WHEN 'counted' THEN 1 WHEN 'collapsed' THEN 2 ELSE 3 END) AS running
FROM ledger
GROUP BY outcome
ORDER BY CASE outcome WHEN 'counted' THEN 1 WHEN 'collapsed' THEN 2 ELSE 3 END;
