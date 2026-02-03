#!/usr/bin/env bash
set -euo pipefail

# Azure Arc onboarding script (sanitized / parameterized)
# Requires: Azure CLI, Azure Arc agent, RBAC access to Key Vault secret holding the PEM
# Note: Onboarding credential is needed only for 'connect' and is deleted after. (MS guidance)

usage() {
  cat <<EOF
Usage: $0 \\
  --sp-app-id <GUID> \\
  --tenant-id <GUID> \\
  --resource-group <name> \\
  --location <azure-region> \\
  --keyvault <kv-name> \\
  --kv-cert-name <certificate-name> \\
  [--log /var/log/arc-onboard.log]

Example:
  $0 --sp-app-id 00000000-0000-0000-0000-000000000000 \\
     --tenant-id 11111111-1111-1111-1111-111111111111 \\
     --resource-group rg-arc-prod-weu-001 \\
     --location westeurope \\
     --keyvault kv-arc-prod-weu-001 \\
     --kv-cert-name sp-arc-prod-onboarding
EOF
}

# ---- Parse args ----
LOGFILE="/var/log/arc-onboard.log"
SP_APP_ID=""; TENANT_ID=""; RG=""; AZ_LOCATION=""; KV_NAME=""; KV_CERT_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sp-app-id) SP_APP_ID="$2"; shift 2 ;;
    --tenant-id) TENANT_ID="$2"; shift 2 ;;
    --resource-group) RG="$2"; shift 2 ;;
    --location) AZ_LOCATION="$2"; shift 2 ;;
    --keyvault) KV_NAME="$2"; shift 2 ;;
    --kv-cert-name) KV_CERT_NAME="$2"; shift 2 ;;
    --log) LOGFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

for v in SP_APP_ID TENANT_ID RG AZ_LOCATION KV_NAME KV_CERT_NAME; do
  if [[ -z "${!v:-}" ]]; then echo "Missing --${v//_/-}"; usage; exit 1; fi
done

# ---- Setup ----
WORKDIR="/root/.arc-onboard"
CERT_PEM="${WORKDIR}/arc-onboarding.pem"
mkdir -p "${WORKDIR}"
touch "${LOGFILE}"; chmod 600 "${LOGFILE}"
log(){ echo "[$(date -Is)] $*" | tee -a "${LOGFILE}"; }

# ---- Ensure tools ----
need() { command -v "$1" >/dev/null 2>&1 || dnf -y install "$1"; }
need curl; need unzip

if ! command -v az >/dev/null 2>&1; then
  log "Installing Azure CLI ..."
  rpm --import https://packages.microsoft.com/keys/microsoft.asc
  dnf install -y https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm
  dnf -y install azure-cli
fi

if ! command -v azcmagent >/dev/null 2>&1; then
  log "Installing Azure Connected Machine agent ..."
  rpm -Uvh --quiet https://aka.ms/azcmagent-rhel || true
  if ! command -v azcmagent >/dev/null 2>&1; then
    curl -fsSL -o /tmp/azcmagent.rpm https://aka.ms/azcmagent-rhel
    dnf -y install /tmp/azcmagent.rpm
  fi
fi

# ---- Pre-check Azure auth context for key vault read (RBAC) ----
if ! az account show >/dev/null 2>&1; then
  log "No active 'az login' context. Please 'az login' (user or bootstrap SP) with KV read (Secrets User) on vault '${KV_NAME}'."
  exit 1
fi

# ---- Download PEM (private key) from Key Vault secret (paired to the certificate) ----
log "Downloading certificate secret '${KV_CERT_NAME}' from Key Vault '${KV_NAME}' ..."
az keyvault secret download \
  --vault-name "${KV_NAME}" \
  --name "${KV_CERT_NAME}" \
  --file "${CERT_PEM}" 1>>"${LOGFILE}"
chmod 600 "${CERT_PEM}"

# ---- Switch to SP certificate auth and connect to Arc ----
log "Logging in as Service Principal (cert auth) ..."
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

# ---- Verify & cleanup ----
log "Arc status:"
azcmagent show | tee -a "${LOGFILE}"

log "Securely deleting onboarding PEM ..."
shred -u "${CERT_PEM}" || rm -f "${CERT_PEM}"

log "Done."
