# Replace TENANT_NAME with actual tenant name when provisioning
path "secret/data/tenants/TENANT_NAME/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/tenants/TENANT_NAME/*" {
  capabilities = ["read", "list"]
}
