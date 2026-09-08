# github_actions_secret values for repositories whose CI needs real
# secret material with no OIDC-equivalent federation path (unlike the
# AWS-deploying repos above, which never store a static secret at all).
# k3s-apps is the first and, for now, only consumer -- its own CI
# pipeline needs values that today only exist in SOPS (home-infra's
# own secrets.sops.yml, plus k3s-apps' own for nextcloud_tools_app_password).
#
# Deliberately NOT plain values in config.yml the way action_variables
# are -- these are real secrets, committing them in plaintext to git
# would defeat the entire point. config.yml instead declares which
# secret NAMES a repository needs (action_secrets: a list of strings);
# the actual values are looked up here, from these sensitive
# TF_VAR_*-sourced variables, and only the ones a given repository
# actually declared ever reach that repository's own module.repo
# invocation (see main.tf's own action_secrets wiring).
#
# Source these the same way k3s-apps' own local applies already do --
# `source ../../infra/k3s-apps/scripts/export-tf-vars.sh` before
# running terraform plan/apply here (sibling directory layout assumed;
# override HOME_INFRA_DIR the same way that script's own README
# section does if yours differs). Deliberately reusing that script
# rather than duplicating its SOPS-key-to-TF_VAR mapping a second time
# here -- every name below already matches what it exports exactly.

variable "home_agent_ghcr_token" {
  type      = string
  sensitive = true
}

variable "home_agent_openai_api_key" {
  type      = string
  sensitive = true
}

variable "nextcloud_tools_app_password" {
  type      = string
  sensitive = true
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}

variable "blocky_postgres_password" {
  type      = string
  sensitive = true
}

variable "alertmanager_ses_smtp_username" {
  type      = string
  sensitive = true
}

variable "alertmanager_ses_smtp_password" {
  type      = string
  sensitive = true
}

variable "shared_ingress_auth_password_hash" {
  type      = string
  sensitive = true
}

variable "k3s_ingress_acme_dns01_access_key_id" {
  type      = string
  sensitive = true
}

variable "k3s_ingress_acme_dns01_secret_access_key" {
  type      = string
  sensitive = true
}

variable "authelia_session_secret" {
  type      = string
  sensitive = true
}

variable "authelia_storage_encryption_key" {
  type      = string
  sensitive = true
}

variable "authelia_reset_password_jwt_secret" {
  type      = string
  sensitive = true
}

variable "authelia_admin_password_hash" {
  type      = string
  sensitive = true
}

variable "authelia_oidc_hmac_secret" {
  type      = string
  sensitive = true
}

variable "authelia_oidc_issuer_private_key" {
  type      = string
  sensitive = true
}

variable "authelia_oidc_grafana_client_secret_hash" {
  type      = string
  sensitive = true
}

variable "authelia_oidc_openwebui_client_secret_hash" {
  type      = string
  sensitive = true
}

variable "authelia_oidc_grafana_client_secret" {
  type      = string
  sensitive = true
}

variable "authelia_oidc_openwebui_client_secret" {
  type      = string
  sensitive = true
}

locals {
  # Keyed by GitHub secret name (upper snake case, matching GitHub's
  # own convention), not the TF_VAR name -- config.yml's action_secrets
  # lists declare these same keys, so main.tf can look each one up
  # directly with no name-transform logic.
  action_secret_values = {
    HOME_AGENT_GHCR_TOKEN                      = var.home_agent_ghcr_token
    HOME_AGENT_OPENAI_API_KEY                  = var.home_agent_openai_api_key
    NEXTCLOUD_TOOLS_APP_PASSWORD               = var.nextcloud_tools_app_password
    GRAFANA_ADMIN_PASSWORD                     = var.grafana_admin_password
    BLOCKY_POSTGRES_PASSWORD                   = var.blocky_postgres_password
    ALERTMANAGER_SES_SMTP_USERNAME             = var.alertmanager_ses_smtp_username
    ALERTMANAGER_SES_SMTP_PASSWORD             = var.alertmanager_ses_smtp_password
    SHARED_INGRESS_AUTH_PASSWORD_HASH          = var.shared_ingress_auth_password_hash
    K3S_INGRESS_ACME_DNS01_ACCESS_KEY_ID       = var.k3s_ingress_acme_dns01_access_key_id
    K3S_INGRESS_ACME_DNS01_SECRET_ACCESS_KEY   = var.k3s_ingress_acme_dns01_secret_access_key
    AUTHELIA_SESSION_SECRET                    = var.authelia_session_secret
    AUTHELIA_STORAGE_ENCRYPTION_KEY            = var.authelia_storage_encryption_key
    AUTHELIA_RESET_PASSWORD_JWT_SECRET         = var.authelia_reset_password_jwt_secret
    AUTHELIA_ADMIN_PASSWORD_HASH               = var.authelia_admin_password_hash
    AUTHELIA_OIDC_HMAC_SECRET                  = var.authelia_oidc_hmac_secret
    AUTHELIA_OIDC_ISSUER_PRIVATE_KEY           = var.authelia_oidc_issuer_private_key
    AUTHELIA_OIDC_GRAFANA_CLIENT_SECRET_HASH   = var.authelia_oidc_grafana_client_secret_hash
    AUTHELIA_OIDC_OPENWEBUI_CLIENT_SECRET_HASH = var.authelia_oidc_openwebui_client_secret_hash
    AUTHELIA_OIDC_GRAFANA_CLIENT_SECRET        = var.authelia_oidc_grafana_client_secret
    AUTHELIA_OIDC_OPENWEBUI_CLIENT_SECRET      = var.authelia_oidc_openwebui_client_secret
  }
}
