/*
Layer: Source. Reads: no business data. Writes: public legacy tables and indexes.
Order: before warehouse 001_schema.sql; execute in the cards database.
Context: database connection selects the source; no session variables.
Local IDs may collide with IDs in each of the other source systems.
Transactions use local auth_id and posted_date; txn_kind determines the sign of unsigned debt movement.
Product-specific metadata: fixed credit_limit.
Source system: cards.
Local identity namespace:
  customers.customer_id, accounts.account_id
Date-of-birth format: DD/MM/YYYY
Balance metric column: outstanding_balance
Product: CREDIT_CARD
This schema must be applied inside the cards database itself.
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
  credit_limit numeric(18,2) NOT NULL,
  CHECK (closed_date IS NULL OR closed_date >= opened_date)
);

-- One daily observation per account; financial values retain exact cents.
CREATE TABLE IF NOT EXISTS public.daily_balances (
  account_id text NOT NULL REFERENCES public.accounts(account_id),
  balance_date date NOT NULL,
  outstanding_balance numeric(18,2) NOT NULL,
  source_updated_at timestamptz NOT NULL,
  PRIMARY KEY (account_id, balance_date)
);

CREATE INDEX IF NOT EXISTS cards_accounts_customer_idx ON public.accounts(customer_id);
CREATE INDEX IF NOT EXISTS cards_balances_date_idx ON public.daily_balances(balance_date);

-- Cards records unsigned posted authorisations; the transaction kind determines the debt movement.
CREATE TABLE IF NOT EXISTS public.transactions (
  auth_id text PRIMARY KEY, account_id text NOT NULL REFERENCES public.accounts(account_id),
  posted_date date NOT NULL, merchant_name text, merchant_category_code text,
  txn_kind text NOT NULL CHECK(txn_kind IN ('PURCHASE','PAYMENT','REFUND','FEE','INTEREST')),
  amount numeric(18,2) NOT NULL CHECK(amount BETWEEN 0 AND 9999999999999999.99)
);
CREATE INDEX IF NOT EXISTS cards_transactions_date_idx ON public.transactions(posted_date,account_id);
