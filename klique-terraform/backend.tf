# Local state by default, so a first run needs nothing but a kubeconfig.
#
# For anything shared, switch to a remote backend: uncomment a block like the
# one below and run `terraform init -backend-config=backend.hcl` (see
# backend.hcl.example). State holds the rendered handoff ConfigMap and — in
# tls.mode = "self-signed-ca" only — the quickstart CA private key, so the
# backend must be encrypted and access-controlled.
#
# terraform {
#   backend "s3" {}
# }
