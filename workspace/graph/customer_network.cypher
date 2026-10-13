// One selected customer's holdings, address, co-residents and card merchants.
// Limits apply to displayed paths only; analytical query totals are not limited.
MATCH (origin:Customer {namespace:$namespace,enterprise_customer_id:$enterprise_customer_id})
WHERE origin.boa_managed=true
CALL {
  WITH origin
  MATCH path=(origin)
  RETURN path,0 AS kind,origin.enterprise_customer_id AS sort_key
  UNION
  WITH origin
  MATCH path=(origin)-[:HOLDS]->(a:Account)-[:OF_PRODUCT]->(p:Product)
  RETURN path,1 AS kind,a.source_system+'|'+a.source_account_id AS sort_key
  UNION
  WITH origin
  MATCH path=(origin)-[:LIVES_AT]->(address:Address)
  RETURN path,2 AS kind,address.street_address+'|'+address.postcode AS sort_key
  UNION
  WITH origin
  MATCH path=(origin)-[:LIVES_AT]->(:Address)<-[:LIVES_AT]-(neighbor:Customer)
  WHERE neighbor<>origin
  RETURN path,3 AS kind,neighbor.enterprise_customer_id AS sort_key
  UNION
  WITH origin
  MATCH path=(origin)-[:HOLDS]->(a:Account)-[:TRANSACTED_AT]->(merchant:Merchant)
  RETURN path,4 AS kind,a.source_system+'|'+a.source_account_id+'|'+merchant.name+'|'+merchant.mcc AS sort_key
}
WITH path,kind,sort_key
WHERE all(n IN nodes(path) WHERE n.namespace=$namespace AND n.boa_managed=true)
  AND all(r IN relationships(path) WHERE r.namespace=$namespace AND r.boa_managed=true)
RETURN [n IN nodes(path) | {labels:labels(n),properties:properties(n)}] AS nodes,
       [r IN relationships(path) | {kind:type(r),properties:properties(r),
         source:{labels:labels(startNode(r)),properties:properties(startNode(r))},
         target:{labels:labels(endNode(r)),properties:properties(endNode(r))}}] AS edges
ORDER BY kind,sort_key
LIMIT $path_limit
