# Replace TENANT_NAME with actual tenant name when provisioning
path "secret/data/tenants/testapp2/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/tenants/testapp2/*" {
  capabilities = ["read", "list"]
}
