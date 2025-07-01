# Purpose

This document is to demonstrate how alias_name_source=serviceaccount_name changes the behavior of entity and alias mapping.

## default entity and entity alias setting, for the record before the change
`kubectl exec -it vault-0 -- vault read -format=json /identity/entity/id/531f36c3-de7b-2023-c694-0076a68944b6
{
  "request_id": "6f6e4c8b-021a-b8d9-ba70-9442ffa85c72",
  "lease_id": "",
  "lease_duration": 0,
  "renewable": false,
  "data": {
    "aliases": [
      {
        "canonical_id": "531f36c3-de7b-2023-c694-0076a68944b6",
        "creation_time": "2025-07-01T02:55:15.484933134Z",
        "custom_metadata": null,
        "id": "60d3c7c2-c2ce-0d33-c474-6647e109123b",
        "last_update_time": "2025-07-01T02:55:15.484933134Z",
        "local": false,
        "merged_from_canonical_ids": null,
        "metadata": {
          "service_account_name": "default",
          "service_account_namespace": "default",
          "service_account_secret_name": "",
          "service_account_uid": "68941b8e-3924-49fe-9f19-38f268bea92f"
        },
        "mount_accessor": "auth_kubernetes_75467436",
        "mount_path": "auth/kubernetes/",
        "mount_type": "kubernetes",
        "name": "68941b8e-3924-49fe-9f19-38f268bea92f"
      }
    ],
    "creation_time": "2025-07-01T02:55:15.484928925Z",
    "direct_group_ids": [],
    "disabled": false,
    "group_ids": [],
    "id": "531f36c3-de7b-2023-c694-0076a68944b6",
    "inherited_group_ids": [],
    "last_update_time": "2025-07-01T02:55:15.484928925Z",
    "merged_entity_ids": null,
    "metadata": null,
    "name": "entity_0cc24570",
    "namespace_id": "root",
    "policies": []
  },
  "warnings": null,
  "mount_type": "identity"
}`

`kubectl exec -it vault-0 -- vault read -format=json identity/entity-alias/id/60d3c7c2-c2ce-0d33-c474-6647e109123b

{
  "request_id": "6ef2479d-5d4a-95cd-aaf8-d2ca47f64c7a",
  "lease_id": "",
  "lease_duration": 0,
  "renewable": false,
  "data": {
    "canonical_id": "531f36c3-de7b-2023-c694-0076a68944b6",
    "creation_time": "2025-07-01T02:55:15.484933134Z",
    "custom_metadata": null,
    "id": "60d3c7c2-c2ce-0d33-c474-6647e109123b",
    "last_update_time": "2025-07-01T02:55:15.484933134Z",
    "local": false,
    "merged_from_canonical_ids": null,
    "metadata": {
      "service_account_name": "default",
      "service_account_namespace": "default",
      "service_account_secret_name": "",
      "service_account_uid": "68941b8e-3924-49fe-9f19-38f268bea92f"
    },
    "mount_accessor": "auth_kubernetes_75467436",
    "mount_path": "auth/kubernetes/",
    "mount_type": "kubernetes",
    "name": "68941b8e-3924-49fe-9f19-38f268bea92f",
    "namespace_id": "root"
  },
  "warnings": null,
  "mount_type": "identity"
}`

## after the change (added alias_name_source=serviceaccount_name)



`kubectl exec -it "$POD" -n "$NAMESPACE" -- vault write auth/kubernetes/role/vault-demo \
    alias_name_source=serviceaccount_name \
    bound_service_account_names=default \
    bound_service_account_namespaces=default \
    policies=default,mysecret \
    ttl=1h

kubectl exec -it vault-0 -- vault read -format=json /identity/entity/id/ceb48de1-ab83-5c44-dc98-64ad9677c71f
{
  "request_id": "f1ea5c12-6343-2522-2f36-12da3b0b08b9",
  "lease_id": "",
  "lease_duration": 0,
  "renewable": false,
  "data": {
    "aliases": [
      {
        "canonical_id": "ceb48de1-ab83-5c44-dc98-64ad9677c71f",
        "creation_time": "2025-07-01T03:40:27.82877668Z",
        "custom_metadata": null,
        "id": "ab001bd4-a008-db67-8f64-76956ef91b4a",
        "last_update_time": "2025-07-01T03:40:27.82877668Z",
        "local": false,
        "merged_from_canonical_ids": null,
        "metadata": {
          "service_account_name": "default",
          "service_account_namespace": "default",
          "service_account_secret_name": "",
          "service_account_uid": "c24c6f43-07c3-4c20-8665-3c24a484ace8"
        },
        "mount_accessor": "auth_kubernetes_e940ba46",
        "mount_path": "auth/kubernetes/",
        "mount_type": "kubernetes",
        "name": "default/default"
      }
    ],
    "creation_time": "2025-07-01T03:40:27.828772596Z",
    "direct_group_ids": [],
    "disabled": false,
    "group_ids": [],
    "id": "ceb48de1-ab83-5c44-dc98-64ad9677c71f",
    "inherited_group_ids": [],
    "last_update_time": "2025-07-01T03:40:27.828772596Z",
    "merged_entity_ids": null,
    "metadata": null,
    "name": "entity_8f1ed23f",
    "namespace_id": "root",
    "policies": []
  },
  "warnings": null,
  "mount_type": "identity"
}`

Notice the name above is now "default/default", intead of the uid in the previous secsion.

## test the deletion of the service account on k8s
### make sure we record the current value
`kubectl get serviceaccount default -n default -o jsonpath='{.metadata.uid}'
c24c6f43-07c3-4c20-8665-3c24a484ace8%`

### delete the service account
`kubectl delete serviceaccount default -n default
kubectl get serviceaccount default -n default -o jsonpath='{.metadata.uid}'
cf60e7c7-6738-40d7-8bc5-61577c8e8ca1%`

### now delete the pod and recreate
`kubectl delete pod vault-demo
kubectl apply -f - <<'EOF'

apiVersion: v1
kind: Pod
metadata:
  name: vault-demo
  namespace: default
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "vault-demo"
    vault.hashicorp.com/agent-inject-secret-mysecret: "kv-v2/data/vault-demo/mysecret"
spec:
  restartPolicy: "OnFailure"
  containers:
    - name: vault-demo
      image: badouralix/curl-jq
      command: ["sh", "-c"]
      resources: {}
      args:
      - |
        VAULT_ADDR="http://vault-internal:8200"
        SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
        VAULT_RESPONSE=$(curl -X POST -H "X-Vault-Request: true" -d '{"jwt": "'"$SA_TOKEN"'", "role": "vault-demo"}' \
          $VAULT_ADDR/v1/auth/kubernetes/login | jq .)

        echo $VAULT_RESPONSE
        echo ""

        VAULT_TOKEN=$(echo $VAULT_RESPONSE | jq -r '.auth.client_token')
        echo $VAULT_TOKEN

        echo "Fetching vault-demo/mysecret from vault...."
        VAULT_SECRET=$(curl -s -H "X-Vault-Token: $VAULT_TOKEN" $VAULT_ADDR/v1/kv-v2/data/vault-demo/mysecret)
        echo $VAULT_SECRET

        sleep infinity
EOF
`
### check the alias and entity again
We can confirm the entity and alias remain the same.

## testing with uid as the alias_name_source (default setting)
Not going to put the process details here but here are two entities and two aliases caused by the deletion (and auto restore) of the service account.  I have also deleted the pod and restarted it so that the sidecar will re-authenticate to Vault.

`kubectl exec -it vault-0 -- vault list /identity/entity-alias/id
Keys
----
13e474db-c3b0-747c-075d-6f21f59f64e5
6a86e203-67e2-3aed-fb28-4e585d1866d8
➜  vault-k8s-demo git:(main) ✗ kubectl exec -it vault-0 -- vault list /identity/entity/id
Keys
----
0334a5c1-7b87-ff9c-4f00-aa6da7e8e1ab
59f44dca-8d49-e5be-2f34-b493bbd3a88a`

Let's read the two entities:
`kubectl exec -it vault-0 -- vault read -format=json /identity/entity/id/0334a5c1-7b87-ff9c-4f00-aa6da7e8e1ab
{
  "request_id": "80af32fb-220d-9501-e5b5-1b617248d1d0",
  "lease_id": "",
  "lease_duration": 0,
  "renewable": false,
  "data": {
    "aliases": [
      {
        "canonical_id": "0334a5c1-7b87-ff9c-4f00-aa6da7e8e1ab",
        "creation_time": "2025-07-01T03:55:12.291711589Z",
        "custom_metadata": null,
        "id": "6a86e203-67e2-3aed-fb28-4e585d1866d8",
        "last_update_time": "2025-07-01T03:55:12.291711589Z",
        "local": false,
        "merged_from_canonical_ids": null,
        "metadata": {
          "service_account_name": "default",
          "service_account_namespace": "default",
          "service_account_secret_name": "",
          "service_account_uid": "b9d2d93b-b78d-441c-8c48-eedb9ee1481b"
        },
        "mount_accessor": "auth_kubernetes_fb6a78fc",
        "mount_path": "auth/kubernetes/",
        "mount_type": "kubernetes",
        "name": "b9d2d93b-b78d-441c-8c48-eedb9ee1481b"
      }
    ],
    "creation_time": "2025-07-01T03:55:12.291707214Z",
    "direct_group_ids": [],
    "disabled": false,
    "group_ids": [],
    "id": "0334a5c1-7b87-ff9c-4f00-aa6da7e8e1ab",
    "inherited_group_ids": [],
    "last_update_time": "2025-07-01T03:55:12.291707214Z",
    "merged_entity_ids": null,
    "metadata": null,
    "name": "entity_3e2a5f7a",
    "namespace_id": "root",
    "policies": []
  },
  "warnings": null,
  "mount_type": "identity"
}

kubectl exec -it vault-0 -- vault read -format=json /identity/entity/id/59f44dca-8d49-e5be-2f34-b493bbd3a88a
{
  "request_id": "3a95ac99-3cec-5c2b-5887-ba54d39ae8ac",
  "lease_id": "",
  "lease_duration": 0,
  "renewable": false,
  "data": {
    "aliases": [
      {
        "canonical_id": "59f44dca-8d49-e5be-2f34-b493bbd3a88a",
        "creation_time": "2025-07-01T03:56:02.480083542Z",
        "custom_metadata": null,
        "id": "13e474db-c3b0-747c-075d-6f21f59f64e5",
        "last_update_time": "2025-07-01T03:56:02.480083542Z",
        "local": false,
        "merged_from_canonical_ids": null,
        "metadata": {
          "service_account_name": "default",
          "service_account_namespace": "default",
          "service_account_secret_name": "",
          "service_account_uid": "24e5d539-aaa8-4a4b-9467-beb4641e495d"
        },
        "mount_accessor": "auth_kubernetes_fb6a78fc",
        "mount_path": "auth/kubernetes/",
        "mount_type": "kubernetes",
        "name": "24e5d539-aaa8-4a4b-9467-beb4641e495d"
      }
    ],
    "creation_time": "2025-07-01T03:56:02.480079126Z",
    "direct_group_ids": [],
    "disabled": false,
    "group_ids": [],
    "id": "59f44dca-8d49-e5be-2f34-b493bbd3a88a",
    "inherited_group_ids": [],
    "last_update_time": "2025-07-01T03:56:02.480079126Z",
    "merged_entity_ids": null,
    "metadata": null,
    "name": "entity_58aa4e66",
    "namespace_id": "root",
    "policies": []
  },
  "warnings": null,
  "mount_type": "identity"
`
Notice the name above still uses uid as the alias_name_source.




