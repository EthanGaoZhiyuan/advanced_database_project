/*
Layer: Source. Reads: no business data. Writes: public legacy tables and indexes.
Order: before warehouse 001_schema.sql; execute in the loans database.
Context: database connection selects the source; no session variables.
Local IDs may collide with IDs in each of the other source systems.
Transactions use local event_id and event_date; event_type and payment components determine principal movement.
Product-specific metadata: original_principal.
Source system: loans.
Local identity namespace:
  customers.customer_id, accounts.account_id
Date-of-birth format: YYYYMMDD
Balance metric column: principal_outstanding
Product: LOAN
This schema must be applied inside the loans database itself.
*/

-- Each local customer key is meaningful only within this source database.
CREATE TABLE IF NOT EXISTS public.customers (
  customer_id text PRIMARY KEY,
  full_name text,
  email text,
  phone text,
  date_of_birth_text text,
  street_address text,
  state text,
  postcode text,
  country text,
  source_updated_at timestamptz NOT NULL
);

-- An account has exactly one local owner; closure cannot precede opening.
CREATE TABLE IF NOT EXISTS public.accounts (
  account_id text PRIMARY KEY,
  customer_id text NOT NULL REFERENCES public.customers(customer_id),
  opened_date date NOT NULL,
  closed_date date,
  currency_code text NOT NULL,
  original_principal numeric(18,2) NOT NULL,
  CHECK (closed_date IS NULL OR closed_date >= opened_date)
);

-- One daily observation per account; financial values retain exact cents.
CREATE TABLE IF NOT EXISTS public.daily_balances (
  account_id text NOT NULL REFERENCES public.accounts(account_id),
  balance_date date NOT NULL,
  principal_outstanding numeric(18,2) NOT NULL,
  source_updated_at timestamptz NOT NULL,
  PRIMARY KEY (account_id, balance_date)
);

CREATE INDEX IF NOT EXISTS loans_accounts_customer_idx ON public.accounts(customer_id);
CREATE INDEX IF NOT EXISTS loans_balances_date_idx ON public.daily_balances(balance_date);

-- Lending events distinguish principal and interest components from the full payment amount.
CREATE TABLE IF NOT EXISTS public.transactions (
  event_id text PRIMARY KEY, account_id text NOT NULL REFERENCES public.accounts(account_id),
  event_date date NOT NULL,
  event_type text NOT NULL CHECK(event_type IN ('REPAYMENT','DRAWDOWN','INTEREST_CHARGE','FEE')),
  amount numeric(18,2) NOT NULL CHECK(amount BETWEEN 0 AND 9999999999999999.99),
  principal_component numeric(18,2) NOT NULL CHECK(principal_component BETWEEN 0 AND 9999999999999999.99),
  interest_component numeric(18,2) NOT NULL CHECK(interest_component BETWEEN 0 AND 9999999999999999.99),
  CHECK(amount=principal_component+interest_component)
);
CREATE INDEX IF NOT EXISTS loans_transactions_date_idx ON public.transactions(event_date,account_id);
