provider "kubernetes" {
  config_path = pathexpand(var.config_path)
}
