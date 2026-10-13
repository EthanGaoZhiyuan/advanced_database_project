// Run one section at a time in Neo4j Browser and select the Graph result view.
// Set :param namespace => 'boa' and :param enterprise_customer_id => 'EC000001'.

// Customer -> accounts -> product categories.
MATCH path=(c:Customer {namespace:$namespace,enterprise_customer_id:$enterprise_customer_id,boa_managed:true})
  -[:HOLDS {namespace:$namespace,boa_managed:true}]->(:Account {namespace:$namespace,boa_managed:true})
  -[:OF_PRODUCT {namespace:$namespace,boa_managed:true}]->(:Product {namespace:$namespace,boa_managed:true})
RETURN path LIMIT 30;

// Distinct customers sharing an address; this does not establish identity.
MATCH path=(c:Customer {namespace:$namespace,enterprise_customer_id:$enterprise_customer_id,boa_managed:true})
  -[:LIVES_AT {namespace:$namespace,boa_managed:true}]->(:Address {namespace:$namespace,boa_managed:true})
  <-[:LIVES_AT {namespace:$namespace,boa_managed:true}]-(other:Customer {namespace:$namespace,boa_managed:true})
WHERE c<>other
RETURN path LIMIT 30;

// Shared card merchants; common purchases do not establish a personal relationship.
MATCH path=(c:Customer {namespace:$namespace,enterprise_customer_id:$enterprise_customer_id,boa_managed:true})
  -[:HOLDS {namespace:$namespace,boa_managed:true}]->(:Account {namespace:$namespace,boa_managed:true})
  -[:TRANSACTED_AT {namespace:$namespace,boa_managed:true}]->(:Merchant {namespace:$namespace,boa_managed:true})
  <-[:TRANSACTED_AT {namespace:$namespace,boa_managed:true}]-(:Account {namespace:$namespace,boa_managed:true})
  <-[:HOLDS {namespace:$namespace,boa_managed:true}]-(other:Customer {namespace:$namespace,boa_managed:true})
WHERE c<>other
RETURN path LIMIT 50;
