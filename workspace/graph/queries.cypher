// Read-only relationship examples over a single namespaced published graph export.
// Parameters: namespace (normally 'boa'); enterprise_customer_id for related_customers.
// Money is aggregated as integer cents. Python converts returned cents to Decimal AUD.
// Run one named section at a time; boa.graph.load_queries() reads these markers.

// query: borrowing_customers
// Active credit-card and loan holdings; multiple accounts contribute once each.
MATCH (customer:Customer {namespace: $namespace, boa_managed: true})-[:HOLDS {namespace: $namespace, boa_managed: true}]->(account:Account {namespace: $namespace, boa_managed: true})
      -[:OF_PRODUCT {namespace: $namespace, boa_managed: true}]->(product:Product {namespace: $namespace, boa_managed: true})
WHERE account.status = 'ACTIVE'
WITH customer,collect(DISTINCT product.code) AS active_products,
     sum(CASE WHEN product.code IN ['CREDIT_CARD','LOAN'] THEN account.balance_cents ELSE 0 END) AS total_borrowing_cents
WHERE 'CREDIT_CARD' IN active_products AND 'LOAN' IN active_products
RETURN customer.enterprise_customer_id AS enterprise_customer_id,customer.name AS customer_name,
       total_borrowing_cents
ORDER BY total_borrowing_cents DESC,enterprise_customer_id;

// query: household_borrowing
// Shared addresses are descriptive household groupings, never identity merges.
MATCH (address:Address {namespace: $namespace, boa_managed: true})<-[:LIVES_AT {namespace: $namespace, boa_managed: true}]-(customer:Customer {namespace: $namespace, boa_managed: true})
WITH DISTINCT address,customer ORDER BY customer.enterprise_customer_id
WITH address,collect(customer) AS members
WHERE size(members) > 1
UNWIND members AS customer
CALL {
  WITH customer
  OPTIONAL MATCH (customer)-[:HOLDS {namespace: $namespace, boa_managed: true}]->(account:Account {namespace: $namespace, boa_managed: true})
        -[:OF_PRODUCT {namespace: $namespace, boa_managed: true}]->(product:Product {namespace: $namespace, boa_managed: true})
  WHERE product.code IN ['CREDIT_CARD','LOAN']
  RETURN coalesce(sum(account.balance_cents),0) AS customer_borrowing_cents
}
WITH address,members,sum(customer_borrowing_cents) AS total_borrowing_cents
RETURN address.street_address AS street_address,address.postcode AS postcode,
       size(members) AS customer_count,[member IN members | member.enterprise_customer_id] AS enterprise_customer_ids,
       total_borrowing_cents
ORDER BY total_borrowing_cents DESC,street_address,postcode;

// query: shared_merchants
// Eligibility uses current active holdings; merchant edges retain published purchase history through export date.
MATCH (customer:Customer {namespace: $namespace, boa_managed: true})-[:HOLDS {namespace: $namespace, boa_managed: true}]->(account:Account {namespace: $namespace, boa_managed: true})
      -[:OF_PRODUCT {namespace: $namespace, boa_managed: true}]->(product:Product {namespace: $namespace, boa_managed: true})
WHERE account.status = 'ACTIVE'
WITH customer,collect(DISTINCT product.code) AS active_products
WHERE all(required IN ['SAVINGS','CREDIT_CARD','LOAN'] WHERE required IN active_products)
MATCH (customer)-[:HOLDS {namespace: $namespace, boa_managed: true}]->(card:Account {namespace: $namespace, boa_managed: true})
      -[purchases:TRANSACTED_AT {namespace: $namespace, boa_managed: true}]->(merchant:Merchant {namespace: $namespace, boa_managed: true})
RETURN merchant.name AS merchant_name,merchant.mcc AS merchant_category_code,
       count(DISTINCT customer) AS customer_count,sum(purchases.count) AS purchase_count,
       sum(purchases.total_amount_cents) AS total_purchase_cents
ORDER BY customer_count DESC,total_purchase_cents DESC,merchant_name,merchant_category_code;

// query: related_customers
// A business-neighbor step projects shared Address or Merchant context between distinct customers.
// Address adjacency takes two physical edges; merchant adjacency takes four via the two owned Accounts.
MATCH (origin:Customer {namespace: $namespace,enterprise_customer_id: $enterprise_customer_id,boa_managed: true})
CALL {
  WITH origin
  MATCH (origin)-[:LIVES_AT {namespace: $namespace, boa_managed: true}]->(:Address {namespace: $namespace, boa_managed: true})<-[:LIVES_AT {namespace: $namespace, boa_managed: true}]-(neighbor:Customer {namespace: $namespace, boa_managed: true})
  WHERE neighbor <> origin
  RETURN DISTINCT neighbor
  UNION
  WITH origin
  MATCH (origin)-[:HOLDS {namespace: $namespace, boa_managed: true}]->(:Account {namespace: $namespace, boa_managed: true})-[:TRANSACTED_AT {namespace: $namespace, boa_managed: true}]->(:Merchant {namespace: $namespace, boa_managed: true})
        <-[:TRANSACTED_AT {namespace: $namespace, boa_managed: true}]-(:Account {namespace: $namespace, boa_managed: true})<-[:HOLDS {namespace: $namespace, boa_managed: true}]-(neighbor:Customer {namespace: $namespace, boa_managed: true})
  WHERE neighbor <> origin
  RETURN DISTINCT neighbor
}
WITH origin,collect(DISTINCT neighbor) AS first_neighbors
UNWIND first_neighbors AS middle
CALL {
  WITH origin,middle
  RETURN middle AS related,1 AS business_neighbor_hops
  UNION
  WITH origin,middle
  MATCH (middle)-[:LIVES_AT {namespace: $namespace, boa_managed: true}]->(:Address {namespace: $namespace, boa_managed: true})<-[:LIVES_AT {namespace: $namespace, boa_managed: true}]-(related:Customer {namespace: $namespace, boa_managed: true})
  WHERE related <> origin AND related <> middle
  RETURN DISTINCT related,2 AS business_neighbor_hops
  UNION
  WITH origin,middle
  MATCH (middle)-[:HOLDS {namespace: $namespace, boa_managed: true}]->(:Account {namespace: $namespace, boa_managed: true})-[:TRANSACTED_AT {namespace: $namespace, boa_managed: true}]->(:Merchant {namespace: $namespace, boa_managed: true})
        <-[:TRANSACTED_AT {namespace: $namespace, boa_managed: true}]-(:Account {namespace: $namespace, boa_managed: true})<-[:HOLDS {namespace: $namespace, boa_managed: true}]-(related:Customer {namespace: $namespace, boa_managed: true})
  WHERE related <> origin AND related <> middle
  RETURN DISTINCT related,2 AS business_neighbor_hops
}
WITH related,min(business_neighbor_hops) AS business_neighbor_hops
RETURN related.enterprise_customer_id AS enterprise_customer_id,related.name AS customer_name,
       business_neighbor_hops
ORDER BY business_neighbor_hops,enterprise_customer_id;
