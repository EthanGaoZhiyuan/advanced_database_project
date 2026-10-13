/*
Layer: Audit (shared source input contract).
Reads: source payload arguments and existing verified identity registry rows.
Writes: reusable parsing/validation functions and the registry immutability trigger.
Order: after 003_integrity.sql; before registry seeds and build_silver.sql.
Context: none; caller supplies source system and source record key to validation.
*/

-- PostgreSQL's locale-dependent space class omits characters accepted by Python
-- str.strip()/re \s. Keep that Unicode whitespace contract explicit in shared SQL.
CREATE OR REPLACE FUNCTION boa_audit.boa_whitespace() RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT U&'\0009\000A\000B\000C\000D\001C\001D\001E\001F\0020\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000';
$$;
-- statement-break
CREATE OR REPLACE FUNCTION boa_audit.boa_trim(value text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(btrim(value,boa_audit.boa_whitespace()), '');
$$;
-- statement-break
-- Strict calendar/decimal parsing prevents date guessing and rounding of fractional cents.
CREATE OR REPLACE FUNCTION boa_audit.boa_date(value text, source text DEFAULT 'SAVINGS', record_key text DEFAULT 'UNKNOWN/UNKNOWN')
RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE cleaned text := boa_audit.boa_trim(value); y integer; m integer; d integer;
BEGIN
  IF cleaned IS NULL THEN RETURN NULL; END IF;
  IF source='SAVINGS' AND cleaned ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
    y := substring(cleaned,1,4)::integer; m := substring(cleaned,6,2)::integer;
    d := substring(cleaned,9,2)::integer;
  ELSIF source='CARDS' AND cleaned ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN
    y := substring(cleaned,7,4)::integer; m := substring(cleaned,4,2)::integer;
    d := substring(cleaned,1,2)::integer;
  ELSIF source='LOANS' AND cleaned ~ '^[0-9]{8}$' THEN
    y := substring(cleaned,1,4)::integer; m := substring(cleaned,5,2)::integer;
    d := substring(cleaned,7,2)::integer;
  ELSE
    RAISE EXCEPTION 'INVALID_DATE: unsupported % date format: % [%]', source, value, record_key;
  END IF;
  IF y=0 THEN RAISE EXCEPTION 'INVALID_DATE: year zero is unsupported [%]', record_key; END IF;
  RETURN make_date(y,m,d);
EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
  RAISE EXCEPTION 'INVALID_DATE: invalid calendar date: % [%]', value, record_key;
END $$;
-- statement-break
CREATE OR REPLACE FUNCTION boa_audit.boa_money(value text, record_key text DEFAULT 'UNKNOWN/UNKNOWN') RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE amount numeric;
BEGIN
  amount := boa_audit.boa_trim(value)::numeric;
  IF amount IS NULL OR amount<0 OR amount>=10000000000000000
      OR amount<>trunc(amount,2) THEN
    RAISE EXCEPTION 'INVALID_MONEY: expected a finite nonnegative AUD amount with at most two decimals: % [%]', value, record_key;
  END IF;
  RETURN amount::numeric(18,2);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RAISE EXCEPTION 'INVALID_MONEY: invalid numeric amount: % [%]', value, record_key;
END $$;
-- statement-break

-- Transaction IDs remain source-local; the Bronze source column completes their identity.
CREATE OR REPLACE FUNCTION boa_audit.transaction_key(source text,payload jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT payload->>CASE source WHEN 'SAVINGS' THEN 'txn_id' WHEN 'CARDS' THEN 'auth_id' ELSE 'event_id' END;
$$;
-- statement-break
-- Savings posting dates use UTC rather than the SQL session timezone.
CREATE OR REPLACE FUNCTION boa_audit.transaction_date(source text,payload jsonb)
RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE context_key text := source||'/'||boa_audit.transaction_key(source,payload); value text;
BEGIN
  IF source='SAVINGS' THEN
    value := payload->>'txn_timestamp';
    IF value IS NULL OR value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ].*(Z|[+-][0-9]{2}:[0-9]{2})$' THEN
      RAISE EXCEPTION 'INVALID_TIMESTAMP: transaction timestamp requires an explicit timezone [%]', context_key;
    END IF;
    RETURN (value::timestamptz AT TIME ZONE 'UTC')::date;
  END IF;
  value := payload->>CASE source WHEN 'CARDS' THEN 'posted_date' ELSE 'event_date' END;
  IF boa_audit.boa_date(value,'SAVINGS',context_key) IS NULL THEN
    RAISE EXCEPTION 'INVALID_DATE: transaction posting date is required [%]', context_key;
  END IF;
  RETURN boa_audit.boa_date(value,'SAVINGS',context_key);
EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
  RAISE EXCEPTION 'INVALID_DATE: invalid transaction posting date [%]', context_key;
END $$;
-- statement-break
-- Signed event movements use the same exact-cent/finite range contract as balance amounts.
CREATE OR REPLACE FUNCTION boa_audit.boa_signed_money(value text,record_key text)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE amount numeric;
BEGIN
  amount := boa_audit.boa_trim(value)::numeric;
  PERFORM boa_audit.boa_money(abs(amount)::text,record_key);
  RETURN amount::numeric(18,2);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RAISE EXCEPTION 'INVALID_MONEY: invalid signed transaction amount [%]', record_key;
END $$;
-- statement-break
-- One mapping defines the principal/cash/debt movement used by validation, Silver and provenance guards.
CREATE OR REPLACE FUNCTION boa_audit.normalise_transaction(source text,payload jsonb)
RETURNS TABLE(transaction_date date,transaction_type text,signed_amount numeric,counterparty text,category_code text)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE context_key text := source||'/'||boa_audit.transaction_key(source,payload);
        amount numeric; principal numeric; interest numeric;
BEGIN
  transaction_date := boa_audit.transaction_date(source,payload);
  transaction_type := payload->>CASE source WHEN 'SAVINGS' THEN 'txn_type'
    WHEN 'CARDS' THEN 'txn_kind' ELSE 'event_type' END;
  IF source='SAVINGS' THEN
    signed_amount := boa_audit.boa_signed_money(payload->>'amount',context_key);
    IF transaction_type IS NULL OR transaction_type NOT IN
      ('DEPOSIT','WITHDRAWAL','TRANSFER_IN','TRANSFER_OUT','INTEREST','FEE') THEN
      RAISE EXCEPTION 'INVALID_TRANSACTION_TYPE: unsupported savings transaction type [%]', context_key;
    END IF;
    IF (transaction_type IN ('WITHDRAWAL','TRANSFER_OUT','FEE') AND signed_amount>0)
      OR (transaction_type IN ('DEPOSIT','TRANSFER_IN','INTEREST') AND signed_amount<0) THEN
      RAISE EXCEPTION 'INVALID_TRANSACTION_SIGN: savings type disagrees with signed amount [%]', context_key;
    END IF;
    counterparty := boa_audit.boa_trim(payload->>'description');
    category_code := boa_audit.boa_trim(payload->>'channel');
  ELSIF source='CARDS' THEN
    amount := boa_audit.boa_money(payload->>'amount',context_key);
    IF transaction_type IS NULL OR transaction_type NOT IN ('PURCHASE','PAYMENT','REFUND','FEE','INTEREST') THEN
      RAISE EXCEPTION 'INVALID_TRANSACTION_TYPE: unsupported card transaction kind [%]', context_key;
    END IF;
    signed_amount := CASE WHEN transaction_type IN ('PAYMENT','REFUND') THEN -amount ELSE amount END;
    counterparty := boa_audit.boa_trim(payload->>'merchant_name');
    category_code := boa_audit.boa_trim(payload->>'merchant_category_code');
  ELSIF source='LOANS' THEN
    amount := boa_audit.boa_money(payload->>'amount',context_key);
    principal := boa_audit.boa_money(payload->>'principal_component',context_key);
    interest := boa_audit.boa_money(payload->>'interest_component',context_key);
    IF transaction_type IS NULL OR transaction_type NOT IN ('REPAYMENT','DRAWDOWN','INTEREST_CHARGE','FEE') THEN
      RAISE EXCEPTION 'INVALID_TRANSACTION_TYPE: unsupported lending event type [%]', context_key;
    END IF;
    IF amount<>principal+interest
      OR (transaction_type='INTEREST_CHARGE' AND principal<>0)
      OR (transaction_type IN ('DRAWDOWN','FEE') AND interest<>0) THEN
      RAISE EXCEPTION 'INVALID_TRANSACTION_COMPONENTS: lending amount and principal/interest components disagree [%]', context_key;
    END IF;
    signed_amount := CASE transaction_type WHEN 'REPAYMENT' THEN -principal
      WHEN 'INTEREST_CHARGE' THEN interest ELSE principal END;
    counterparty := transaction_type;
    category_code := NULL;
  ELSE
    RAISE EXCEPTION 'UNSUPPORTED_SOURCE: transaction source must be SAVINGS, CARDS or LOANS [%]', context_key;
  END IF;
  RETURN NEXT;
END $$;
-- statement-break

-- Check customer/account references in the current Bronze extract before loading Silver.
CREATE OR REPLACE FUNCTION boa_audit.validate_source_inventory(input_rows regclass)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE offending text;
BEGIN
  EXECUTE format($query$
    SELECT a.source_system||'/'||a.source_record_key
    FROM %1$s a LEFT JOIN %1$s c ON c.source_system=a.source_system
      AND c.entity_name='customers' AND c.payload->>'customer_id'=a.payload->>'customer_id'
    WHERE a.entity_name='accounts' AND c.source_record_key IS NULL
    ORDER BY a.source_system,a.source_record_key LIMIT 1
  $query$,input_rows) INTO offending;
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'MISSING_CUSTOMER: account owner is absent from the current source inventory [%]', offending;
  END IF;
  EXECUTE format($query$
    SELECT b.source_system||'/'||b.source_record_key
    FROM %1$s b LEFT JOIN %1$s a ON a.source_system=b.source_system
      AND a.entity_name='accounts' AND a.payload->>'account_id'=b.payload->>'account_id'
    WHERE b.entity_name IN ('daily_balances','transactions') AND a.source_record_key IS NULL
    ORDER BY b.source_system,b.source_record_key LIMIT 1
  $query$,input_rows) INTO offending;
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'MISSING_ACCOUNT: observation account is absent from the current source inventory [%]', offending;
  END IF;
END $$;
-- statement-break

-- The verified registry is immutable input; rejected reassignment cannot replace its accepted mapping.
CREATE OR REPLACE FUNCTION boa_audit.guard_identity_registry()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.source_system,NEW.source_customer_id,NEW.enterprise_customer_id)
      IS DISTINCT FROM (OLD.source_system,OLD.source_customer_id,OLD.enterprise_customer_id) THEN
    RAISE EXCEPTION 'IDENTITY_CHANGE: verified customer mappings are immutable [%/%]',
      OLD.source_system,OLD.source_customer_id;
  END IF;
  RETURN NEW;
END $$;
-- statement-break
DROP TRIGGER IF EXISTS identity_registry_immutable ON boa_audit.identity_registry;
-- statement-break
CREATE TRIGGER identity_registry_immutable BEFORE UPDATE ON boa_audit.identity_registry
FOR EACH ROW EXECUTE FUNCTION boa_audit.guard_identity_registry();

-- Validate every retained account/date, including the next date affected by a correction.
-- The first observation starts at zero because initial funding is an explicit opening event.
CREATE OR REPLACE FUNCTION boa_audit.transaction_balance_mismatches(
  transaction_rows regclass DEFAULT 'boa_silver.account_transaction'::regclass)
RETURNS TABLE(account_key bigint,balance_date date) LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN QUERY EXECUTE format($query$
    WITH movement AS (
      SELECT account_key,transaction_date,sum(signed_amount) AS amount
      FROM %s GROUP BY account_key,transaction_date
    )
    SELECT b.account_key,b.balance_date
    FROM boa_silver.account_daily_balance b JOIN boa_silver.account a USING(account_key)
    LEFT JOIN boa_silver.account_daily_balance previous
      ON previous.account_key=b.account_key AND previous.balance_date=b.balance_date-1
    LEFT JOIN movement m ON m.account_key=b.account_key AND m.transaction_date=b.balance_date
    WHERE (b.balance_date<>a.opened_date AND previous.account_key IS NULL)
      OR b.savings_balance+b.card_outstanding+b.loan_principal_outstanding
        -coalesce(previous.savings_balance+previous.card_outstanding+previous.loan_principal_outstanding,0)
        IS DISTINCT FROM coalesce(m.amount,0)
  $query$,transaction_rows);
END $$;
