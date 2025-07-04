
## create the approle
```sh
kubectl exec -it vault-0 -- vault write auth/approle/role/myapp \
    secret_id_ttl=24h \
    token_num_uses=5 \
    token_ttl=20m \
    token_max_ttl=30m \
    secret_id_num_uses=40 \
    policies="mysecret"
```
## retrieve the RoleID
```sh
kubectl exec -it vault-0 -- vault read auth/approle/role/myapp/role-id
Key        Value
---        -----
role_id    4db41d61-554b-2267-3423-fe20a500fa3f
```
## retrieve the SecretID

```sh
kubectl exec -it vault-0 -- vault write -f auth/approle/role/myapp/secret-id
Key                   Value
---                   -----
secret_id             ca4bfd38-c299-9758-0bce-0792aaf7f7f9
secret_id_accessor    b252e0c6-6d2a-9ded-af37-e43b3fcadb59
secret_id_num_uses    40
secret_id_ttl         24h
```

## generate a wrapped secret id

```sh
kubectl exec -it vault-0 -- vault write -f -wrap-ttl=6000s auth/approle/role/myapp/secret-id
Key                              Value
---                              -----
wrapping_token:                  hvs....
wrapping_accessor:               YW0jId5jyh11YQvO76Cp5ffr
wrapping_token_ttl:              1h40m
wrapping_token_creation_time:    2025-07-02 01:45:11.696099921 +0000 UTC
wrapping_token_creation_path:    auth/approle/role/myapp/secret-id
wrapped_accessor:                e5159f1b-388a-d5fa-65aa-f2558b1d1dee
```
or, just write out the token itself:

```sh
kubectl exec -it vault-0 -- vault write -f -wrap-ttl=6000s -field=wrapping_token auth/approle/role/myapp/secret-id

```

## retrieve the wrapped secret id

```sh
kubectl exec -it vault-0 -- env VAULT_TOKEN=hvs.... vault unwrap

Key                   Value
---                   -----
secret_id             a539cacc-a3f8-4c57-fce5-4e31218c2caa
secret_id_accessor    e5159f1b-388a-d5fa-65aa-f2558b1d1dee
secret_id_num_uses    40
secret_id_ttl         24h
```

