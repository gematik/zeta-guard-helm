# gsi-server gsi-fedmaster: 8.5.1 pubkey Secret not needed for gsi-fedmaster: drop it from the state without destroying it.
removed {
  from = kubernetes_secret_v1.sekidp_rp01_pubkey

  lifecycle {
    destroy = false
  }
}
