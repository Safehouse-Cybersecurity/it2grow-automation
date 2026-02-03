#!/usr/bin/env bash
# Azure Arc onboarding for Rocky Linux 10
# - Installs Azure CLI (without packages-microsoft-prod)
# - Installs Arc agent
# - Downloads SP certificate from Key Vault (RBAC)
# - Supports PEM or PFX -> converts to PEM if needed
# - Connects to Azure Arc, then securely deletes the PEM

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  arc-onboard.sh \
    --sp-app-id <GUID> \
    --tenant-id <GUID> \
    --resource-group <name> \
    --location <azure-region> \
    --keyvault <kv-name> \
    --kv-cert-name <kv-certificate-name> \
    [--log /var/log/arc-onboard.log]

Notes:
- Requires an active 'az login' context that can read the secret in Key Vault
  (e.g., a bootstrap SP/user with the **Key Vault Secrets User** role at the vault scope).
- The service principal identified by --sp-app-id must already have a certificate
  stored in Key Vault under --kv-cert-name.

Examples:
  arc-onboard.sh \
    --sp-app-id 00000000-0000-0000-0000-000000000000 \
    --tenant-id 11111111-1111-1111-1111-111111111111 \
    --resource-group rg-arc-prod-weu-001 \
    --location westeurope \
    --keyvault kv-arc-prod-weu-001 \
    --kv-cert-name sp-arc-prod-onboarding
USAGE
}

# ---------- Parse args ----------
SP_APP_ID=""; TENANT_ID=""; RG=""; AZ_LOCATION=""; KV_NAME=""; KV_CERT_NAME=""
LOGFILE="/var/log/arc-onboard.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sp-app-id)      SP_APP_ID="$2"; shift 2 ;;
    --tenant-id)      TENANT_ID="$2"; shift 2 ;;
    --resource-group) RG="$2"; shift 2 ;;
    --location)       AZ_LOCATION="$2"; shift 2 ;;
    --keyvault)       KV_NAME="$2"; shift 2 ;;
    --kv-cert-name)   KV_CERT_NAME="$2"; shift 2 ;;
    --log)            LOGFILE="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

for v in SP_APP_ID TENANT_ID RG AZ_LOCATION KV_NAME KV_CERT_NAME; do
  if [[ -z "${!v:-}" ]]; then echo "Missing --${v//_/-}"; usage; exit 1; fi
done

# ---------- Setup ----------
WORKDIR="/root/.arc-onboard"
CERT_PEM="${WORKDIR}/arc-onboarding.pem"
CERT_BLOB="${WORKDIR}/cert-blob.bin"
mkdir -p "${WORKDIR}"
touch "${LOGFILE}"; chmod 600 "${LOGFILE}"
log(){ echo "[$(date -Is)] $*" | tee -a "${LOGFILE}"; }

# ---------- Ensure tools ----------
need() { command -v "$1" >/dev/null 2>&1 || dnf -y install "$1"; }
need curl
need unzip
need openssl

# Azure CLI (Rocky/RHEL 9+/10) – add yum repo directly (no packages-microsoft-prod)
if ! command -v az >/dev/null 2>&1; then
  log "Installing Azure CLI ..."
  rpm --import https://packages.microsoft.com/keys/microsoft.asc
  tee /etc/yum.repos.d/azure-cli.repo >/dev/null << 'EOF'
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli/
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
  dnf install -y azure-cli
fi

# Arc agent
if ! command -v azcmagent >/dev/null 2>&1; then
  log "Installing Azure Connected Machine agent ..."
  set +e
  rpm -Uvh --quiet https://aka.ms/azcmagent-rhel
  RC=$?
  set -e
  if [[ $RC -ne 0 || ! -x "$(command -v azcmagent)" ]]; then
    log "Fallback: downloading agent RPM explicitly ..."
    curl -fsSL -o /tmp/azcmagent.rpm https://aka.ms/azcmagent-rhel
    dnf -y install /tmp/azcmagent.rpm
  fi
fi

# ---------- Pre-check Azure auth context ----------
if ! az account show >/dev/null 2>&1; then
  log "No active 'az login' found. Please 'az login' with an identity that has Key Vault 'Secrets User' on vault '${KV_NAME}'."
  exit 1
fi

# ---------- Download certificate secret from Key Vault ----------
log "Inspecting Key Vault secret content type ..."
CONTENT_TYPE="$(az keyvault secret show --vault-name "${KV_NAME}" --name "${KV_CERT_NAME}" --query contentType -o tsv || true)"
log "Key Vault secret contentType='${CONTENT_TYPE:-<empty>}'"

log "Downloading certificate secret (binary) ..."
az keyvault secret download \
  --vault-name "${KV_NAME}" \
  --name "${KV_CERT_NAME}" \
  --file "${CERT_BLOB}" 1>>"${LOGFILE}"

chmod 600 "${CERT_BLOB}"

# Convert to PEM if needed
if [[ "${CONTENT_TYPE,,}" == *"application/x-pem-file"* ]]; then
  log "Secret appears to be PEM; renaming to ${CERT_PEM}"
  mv "${CERT_BLOB}" "${CERT_PEM}"
elif [[ "${CONTENT_TYPE,,}" == *"application/x-pkcs12"* || -z "${CONTENT_TYPE}" ]]; then
  log "Secret appears to be PFX (or unspecified). Converting PFX -> PEM (no passphrase) ..."
  # Many KV cert secrets are PFX with empty password
  openssl pkcs12 -in "${CERT_BLOB}" -nodes -out "${CERT_PEM}" -passin pass: || {
    log "ERROR: Failed to convert PFX to PEM. Check that the secret really contains a certificate with private key."
    exit 1
  }
  shred -u "${CERT_BLOB}" || rm -f "${CERT_BLOB}"
else
  log "Unknown contentType. Attempting PEM path as fallback ..."
  mv "${CERT_BLOB}" "${CERT_PEM}"
fi

chmod 600 "${CERT_PEM}"

# ---------- Login as SP with certificate & connect to Arc ----------
log "Logging in with service principal certificate ..."
az logout --username "${SP_APP_ID}" >/dev/null 2>&1 || true
az login --service-principal \
  --username "${SP_APP_ID}" \
  --tenant "${TENANT_ID}" \
  --password "${CERT_PEM}" 1>>"${LOGFILE}"

HOST="$(hostname -f || hostname)"
log "Connecting '${HOST}' to Azure Arc (${AZ_LOCATION}) ..."
azcmagent connect \
  --service-principal-id "${SP_APP_ID}" \
  --service-principal-certificate "${CERT_PEM}" \
  --resource-group "${RG}" \
  --tenant-id "${TENANT_ID}" \
  --location "${AZ_LOCATION}" 1>>"${LOGFILE}"

log "Arc status:"
azcmagent show | tee -a "${LOGFILE}"

# ---------- Cleanup onboarding credential ----------
log "Securely deleting PEM (onboarding credential) ..."
shred -u "${CERT_PEM}" || rm -f "${CERT_PEM}"

log "Azure Arc onboarding completed successfully."
exit 0
