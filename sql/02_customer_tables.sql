-- 02_customer_tables.sql
-- Builds the reusable tables behind the analysis.

-- Very large orders cancelled in full on the same day are not real demand or real returns.
-- Keeping them would add a £168k and a £77k "sale" and "return" that never happened.
CREATE OR REPLACE TABLE reversed_bulk_orders AS
SELECT s.invoice AS sale_invoice, r.invoice AS return_invoice, s.customer_id, s.stock_code, s.line_value
FROM clean_lines s
JOIN clean_lines r
  ON  s.customer_id = r.customer_id
  AND s.stock_code  = r.stock_code
  AND s.quantity    = -r.quantity
  AND s.invoice_ts::DATE = r.invoice_ts::DATE
WHERE s.line_type = 'sale' AND r.line_type = 'return' AND s.line_value >= 10000;

CREATE OR REPLACE TABLE analysis_lines AS
SELECT c.*
FROM clean_lines c
WHERE NOT EXISTS (
    SELECT 1 FROM reversed_bulk_orders b
    WHERE c.stock_code = b.stock_code
      AND c.invoice IN (b.sale_invoice, b.return_invoice)
);

-- One row per order, for customers we can identify.
CREATE OR REPLACE TABLE customer_orders AS
SELECT
    customer_id,
    invoice,
    MIN(invoice_ts)  AS order_ts,
    SUM(line_value)  AS order_value
FROM analysis_lines
WHERE line_type = 'sale' AND customer_id IS NOT NULL
GROUP BY customer_id, invoice;

-- Revenue by customer for each full trading year.
CREATE OR REPLACE TABLE customer_year AS
SELECT
    customer_id,
    SUM(line_value) FILTER (WHERE trading_year LIKE 'Y1%') AS y1_net,
    SUM(line_value) FILTER (WHERE trading_year LIKE 'Y2%') AS y2_net
FROM analysis_lines
WHERE customer_id IS NOT NULL
GROUP BY customer_id;
