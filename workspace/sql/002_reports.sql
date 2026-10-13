/*
Design layers: Reports over Gold, governed by Audit publication metadata.
Reads: boa_gold dimensions, daily balances and transaction facts; Audit publication metadata.
Writes: Reporting view definitions and explanatory view comments; no business rows.
Execution order: run after 001_schema.sql in 02_create_schemas.py; 003_integrity.sql follows.
                 Query these views after a successful Gold publication.
All reports use a common published business date and matching publication run IDs.
Context: connected warehouse; no session variables.
*/

-- Expose only facts matching a successfully published date and its publication run.
CREATE OR REPLACE VIEW boa_gold.v_account_snapshot AS
SELECT f.*, d.full_date AS business_date, c.enterprise_customer_id,
       a.source_system,a.source_account_id,p.product_code,
       a.opened_date,a.closed_date,a.currency_code,
       pub.published_run_id,pub.published_at
FROM boa_gold.fact_account_daily_snapshot f
JOIN boa_gold.dim_date d USING(date_sk)
JOIN boa_gold.dim_account a USING(account_sk)
JOIN boa_gold.dim_customer c ON c.customer_sk=f.customer_sk
JOIN boa_gold.dim_product p ON p.product_sk=f.product_sk
JOIN boa_audit.published_day pub ON pub.business_date=d.full_date AND pub.published_run_id=f.load_run_id
JOIN boa_audit.pipeline_run r ON r.run_id=pub.published_run_id AND r.status='SUCCEEDED';

-- Aggregate each customer's daily portfolio once; include zero-holding customers and as-of age.
CREATE OR REPLACE VIEW boa_gold.v_customer_360 AS
WITH totals AS (
  SELECT business_date,customer_sk,
    count(*) FILTER(WHERE account_status='ACTIVE')::integer AS active_account_count,
    count(DISTINCT product_sk) FILTER(WHERE account_status='ACTIVE')::integer AS active_product_category_count,
    bool_or(product_code='SAVINGS' AND account_status='ACTIVE') AS has_savings,
    bool_or(product_code='CREDIT_CARD' AND account_status='ACTIVE') AS has_card,
    bool_or(product_code='LOAN' AND account_status='ACTIVE') AS has_loan,
    sum(savings_balance) AS total_savings,
    sum(card_outstanding) AS total_card_outstanding,
    sum(loan_principal_outstanding) AS total_loan_principal,
    sum(card_outstanding+loan_principal_outstanding) AS total_borrowing,
    sum(card_outstanding) FILTER(WHERE product_code='CREDIT_CARD' AND account_status='ACTIVE') /
      nullif(sum(credit_limit_amount) FILTER(WHERE product_code='CREDIT_CARD' AND account_status='ACTIVE'),0)
      AS credit_card_utilisation
  FROM boa_gold.v_account_snapshot
  GROUP BY business_date,customer_sk
)
SELECT pub.business_date,pub.published_run_id,pub.published_at,
  c.customer_sk,c.enterprise_customer_id,c.full_name,c.email,c.phone,c.date_of_birth,
  c.street_address,c.state,c.postcode,c.country,
  CASE WHEN c.date_of_birth<=pub.business_date THEN extract(year FROM age(pub.business_date,c.date_of_birth))::integer END AS age,
  coalesce(t.active_account_count,0) AS active_account_count,
  coalesce(t.active_product_category_count,0) AS active_product_category_count,
  coalesce(nullif(concat_ws(' + ',CASE WHEN t.has_savings THEN 'SAVINGS' END,
    CASE WHEN t.has_card THEN 'CREDIT_CARD' END,CASE WHEN t.has_loan THEN 'LOAN' END),''),'NONE') AS product_combination,
  coalesce(t.total_savings,0::numeric) AS total_savings,
  coalesce(t.total_card_outstanding,0::numeric) AS total_card_outstanding,
  coalesce(t.total_loan_principal,0::numeric) AS total_loan_principal,
  coalesce(t.total_borrowing,0::numeric) AS total_borrowing,
  t.credit_card_utilisation,
  coalesce(t.has_savings,false) AS has_savings,
  coalesce(t.has_card,false) AS has_card,
  coalesce(t.has_loan,false) AS has_loan
FROM boa_audit.published_day pub
JOIN boa_audit.pipeline_run r ON r.run_id=pub.published_run_id AND r.status='SUCCEEDED'
CROSS JOIN boa_gold.dim_customer c
LEFT JOIN totals t ON t.customer_sk=c.customer_sk AND t.business_date=pub.business_date;

-- Count distinct active customers per category, including active zero-balance accounts.
CREATE OR REPLACE VIEW boa_gold.v_product_holdings AS
SELECT pub.business_date,p.product_code,
  count(DISTINCT f.customer_sk) FILTER(WHERE f.account_status='ACTIVE')::bigint AS customer_count,
  (SELECT count(*) FROM boa_gold.dim_customer)::bigint AS population_count,
  100.0*count(DISTINCT f.customer_sk) FILTER(WHERE f.account_status='ACTIVE')/
    nullif((SELECT count(*) FROM boa_gold.dim_customer),0) AS percentage
FROM boa_audit.published_day pub
JOIN boa_audit.pipeline_run r ON r.run_id=pub.published_run_id AND r.status='SUCCEEDED'
CROSS JOIN boa_gold.dim_product p
LEFT JOIN boa_gold.v_account_snapshot f ON f.business_date=pub.business_date AND f.product_sk=p.product_sk
GROUP BY pub.business_date,p.product_sk,p.product_code;

-- Stable holding combinations partition the entire accepted customer population per date.
CREATE OR REPLACE VIEW boa_gold.v_product_combinations AS
SELECT business_date,product_combination,count(*)::bigint AS customer_count,
  100.0*count(*)/sum(count(*)) OVER(PARTITION BY business_date) AS percentage
FROM boa_gold.v_customer_360 GROUP BY business_date,product_combination;

-- Always show zero through three active categories, even when a bucket has no customers.
CREATE OR REPLACE VIEW boa_gold.v_product_category_distribution AS
SELECT pub.business_date,c.category_count,
  count(v.enterprise_customer_id)::bigint AS customer_count
FROM boa_audit.published_day pub
JOIN boa_audit.pipeline_run r ON r.run_id=pub.published_run_id AND r.status='SUCCEEDED'
CROSS JOIN generate_series(0,3) AS c(category_count)
LEFT JOIN boa_gold.v_customer_360 v ON v.business_date=pub.business_date
  AND v.active_product_category_count=c.category_count
GROUP BY pub.business_date,c.category_count;

-- Count customers holding each category pair without multiplying multiple same-type accounts.
CREATE OR REPLACE VIEW boa_gold.v_cross_product_ownership AS
SELECT pub.business_date,p1.product_code AS product_a,p2.product_code AS product_b,
  count(c.enterprise_customer_id) FILTER (
    WHERE (CASE p1.product_code WHEN 'SAVINGS' THEN c.has_savings
      WHEN 'CREDIT_CARD' THEN c.has_card WHEN 'LOAN' THEN c.has_loan END)
      AND (CASE p2.product_code WHEN 'SAVINGS' THEN c.has_savings
      WHEN 'CREDIT_CARD' THEN c.has_card WHEN 'LOAN' THEN c.has_loan END)
  )::bigint AS customer_count
FROM boa_audit.published_day pub
JOIN boa_audit.pipeline_run r ON r.run_id=pub.published_run_id AND r.status='SUCCEEDED'
CROSS JOIN boa_gold.dim_product p1 CROSS JOIN boa_gold.dim_product p2
-- Customer/date is already unique and holding flags ignore duplicate accounts.
-- Aggregate the nine category pairs without multiplying account-level observations.
LEFT JOIN boa_gold.v_customer_360 c ON c.business_date=pub.business_date
GROUP BY pub.business_date,p1.product_sk,p1.product_code,p2.product_sk,p2.product_code;

-- Daily borrowing is card debt plus loan principal; savings and cross-date sums are excluded.
CREATE OR REPLACE VIEW boa_gold.v_borrowing_daily AS
SELECT pub.business_date,
  coalesce(sum(f.card_outstanding),0::numeric) AS total_card_outstanding,
  coalesce(sum(f.loan_principal_outstanding),0::numeric) AS total_loan_principal,
  coalesce(sum(f.card_outstanding+f.loan_principal_outstanding),0::numeric) AS total_borrowing
FROM boa_audit.published_day pub
JOIN boa_audit.pipeline_run r ON r.run_id=pub.published_run_id AND r.status='SUCCEEDED'
LEFT JOIN boa_gold.v_account_snapshot f ON f.business_date=pub.business_date
GROUP BY pub.business_date;

-- Reuse the accepted daily totals for the two borrowing categories, including zero debt.
CREATE OR REPLACE VIEW boa_gold.v_borrowing_by_product AS
SELECT d.business_date,p.product_code,p.borrowing_amount
FROM boa_gold.v_borrowing_daily d
CROSS JOIN LATERAL (VALUES
  ('CREDIT_CARD'::text,d.total_card_outstanding),
  ('LOAN'::text,d.total_loan_principal)
) p(product_code,borrowing_amount);

COMMENT ON VIEW boa_gold.v_customer_360 IS 'Current customer descriptions and as-of daily metrics; population is every accepted enterprise customer including zero active holdings.';
COMMENT ON VIEW boa_gold.v_product_holdings IS 'Distinct customers per active category; an active zero-balance account counts once per category.';
COMMENT ON VIEW boa_gold.v_borrowing_daily IS 'Daily card debt plus loan principal in AUD; savings excluded; never aggregate balances across dates.';

-- Transaction visibility follows the same successful common-date publication as account snapshots.
CREATE OR REPLACE VIEW boa_gold.v_customer_transactions AS
SELECT f.*,d.full_date AS business_date,c.enterprise_customer_id,c.full_name,
  a.source_system,a.source_account_id,p.product_code,
  t.transaction_type_code,t.transaction_type_name,pub.published_run_id,pub.published_at
FROM boa_gold.fact_transaction f
JOIN boa_gold.dim_date d USING(date_sk)
JOIN boa_gold.dim_account a USING(account_sk)
JOIN boa_gold.dim_customer c ON c.customer_sk=f.customer_sk
JOIN boa_gold.dim_product p ON p.product_sk=f.product_sk
JOIN boa_gold.dim_transaction_type t USING(transaction_type_sk)
JOIN boa_audit.published_day pub ON pub.business_date=d.full_date AND pub.published_run_id=f.load_run_id
JOIN boa_audit.pipeline_run r ON r.run_id=pub.published_run_id AND r.status='SUCCEEDED';

-- Customer-level event totals let all dashboard filters reuse one count and signed-movement definition.
CREATE OR REPLACE VIEW boa_gold.v_customer_transaction_daily AS
SELECT business_date,enterprise_customer_id,product_code,transaction_type_code,
  count(*)::bigint AS transaction_count,sum(signed_amount) AS total_signed_amount
FROM boa_gold.v_customer_transactions
GROUP BY business_date,enterprise_customer_id,product_code,transaction_type_code;

-- Events are additive across dates; positive means an increase in the relevant savings/debt balance.
CREATE OR REPLACE VIEW boa_gold.v_transaction_daily AS
SELECT business_date,product_code,transaction_type_code,
  sum(transaction_count)::bigint AS transaction_count,sum(total_signed_amount) AS total_signed_amount
FROM boa_gold.v_customer_transaction_daily
GROUP BY business_date,product_code,transaction_type_code;

-- Merchant spend counts positive card purchases, excluding explicit initial balance funding.
CREATE OR REPLACE VIEW boa_gold.v_customer_merchant_spend AS
SELECT business_date,enterprise_customer_id,counterparty AS merchant_name,category_code AS merchant_category_code,
  count(*)::bigint AS purchase_count,sum(signed_amount) AS spend_amount
FROM boa_gold.v_customer_transactions
WHERE product_code='CREDIT_CARD' AND transaction_type_code='PURCHASE'
  AND signed_amount>0 AND counterparty IS DISTINCT FROM 'Opening balance'
GROUP BY business_date,enterprise_customer_id,counterparty,category_code;

-- Daily merchant/category totals support a selected thirty-day window without summing daily balances.
CREATE OR REPLACE VIEW boa_gold.v_top_merchants AS
SELECT business_date,merchant_name,merchant_category_code,
  sum(purchase_count)::bigint AS purchase_count,sum(spend_amount) AS spend_amount
FROM boa_gold.v_customer_merchant_spend
GROUP BY business_date,merchant_name,merchant_category_code;

COMMENT ON VIEW boa_gold.v_customer_transactions IS 'Published immutable events with current customer descriptions and Vault transaction lineage.';
COMMENT ON VIEW boa_gold.v_transaction_daily IS 'Daily transaction counts and signed AUD movements; unlike balances, event amounts are additive over dates.';
COMMENT ON VIEW boa_gold.v_top_merchants IS 'Gross positive credit-card PURCHASE spending by merchant and category; opening funding, payments, refunds and fees are excluded.';
