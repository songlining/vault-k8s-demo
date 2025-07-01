Running the script against an existing k8s cluster, it will -
1. install vault server into "default" namespace
2. unseal the vault server and login
3. enable the kubernetes secret engine
4. enable kv-v2 and create a sample secret "mysecret"
5. install a demo app into the same namespace for simplicity
6. a vault sidecar will be injected together with the demo app
7. once everything is running, check /vault/secrets/mysecret file has been populated. This is on the vault-demo container in vault-demo pod.
