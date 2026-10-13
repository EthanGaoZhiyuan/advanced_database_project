/*
Layer: Source. Reads: no business data. Writes: public legacy tables and indexes.
Order: before warehouse 001_schema.sql; execute in the savings database.
Context: database connection selects the source; no session variables.
Local IDs may collide with IDs in each of the other source systems.
Transactions use local txn_id and timezone-aware txn_timestamp; cash credits are positive and debits negative.
Product-specific metadata: no product-specific limit.
Source system: savings.
Local identity namespace:
  customers.customer_id, accounts.account_id
Date-of-birth format: YYYY-MM-DD
Balance metric column: closing_balance
Product: SAVINGS
This schema must be applied inside the savings database itself.
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
  CHECK (closed_date IS NULL OR closed_date >= opened_date)
);

-- One daily observation per account; financial values retain exact cents.
CREATE TABLE IF NOT EXISTS public.daily_balances (
  account_id text NOT NULL REFERENCES public.accounts(account_id),
  balance_date date NOT NULL,
  closing_balance numeric(18,2) NOT NULL,
  source_updated_at timestamptz NOT NULL,
  PRIMARY KEY (account_id, balance_date)
);

CREATE INDEX IF NOT EXISTS savings_accounts_customer_idx ON public.accounts(customer_id);
CREATE INDEX IF NOT EXISTS savings_balances_date_idx ON public.daily_balances(balance_date);

-- Savings keeps signed cash movements and timestamp/channel detail in its own namespace.
CREATE TABLE IF NOT EXISTS public.transactions (
  txn_id text PRIMARY KEY, account_id text NOT NULL REFERENCES public.accounts(account_id),
  txn_timestamp timestamptz NOT NULL,
  txn_type text NOT NULL CHECK(txn_type IN ('DEPOSIT','WITHDRAWAL','TRANSFER_IN','TRANSFER_OUT','INTEREST','FEE')),
  amount numeric(18,2) NOT NULL CHECK(amount BETWEEN -9999999999999999.99 AND 9999999999999999.99),
  channel text NOT NULL, description text
);
CREATE INDEX IF NOT EXISTS savings_transactions_date_idx ON public.transactions(txn_timestamp,account_id);
