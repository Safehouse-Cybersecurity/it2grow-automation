#!/usr/bin/env bash
# Azure Arc: install agent + connect using SP certificate from Azure Key Vault (RBAC)
# Works on Rocky Linux 10+ (no packages-microsoft-prod required)

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  arc-install-and-connect.sh \
    --sp-app-id <GUID> \
    --tenant-id <GUID> \
    --resource-group <name> \
    --location <azure-region> \
    --keyvault <kv-name> \
    --kv-cert-name <kv-certificate-name> \
    [--log /var/log/arc-onboard.log]

Requirements:
- Caller running this script must already be 'az login'-ed as an identity with
  **Key Vault Secrets User** on the specified vault (RBAC model). (To read the cert secret) [MS Learn] USAGE
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

# Ensure Azure CLI without packages-microsoft-prod (works on Rocky 9/10)
if ! command -v az >/dev/null 2>&1; then
  log "Installing Azure CLI (yum repo method) ..."
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

# Install Azure Arc Connected Machine agent (official method for RHEL family)
if ! command -v azcmagent >/dev/null 2>&1; then
  log "Installing Azure Connected Machine agent ..."
  set +e
  rpm -Uvh --quiet https://aka.ms/azcmagent-rhel
  RC=$?
  set -e
  if [[ $RC -ne 0 || ! -x "$(command -v azcmagent)" ]]; then
    log "Fallback: download RPM and install via dnf ..."
    curl -fsSL -o /tmp/azcmagent.rpm https://aka.ms/azcmagent-rhel
    dnf -y install /tmp/azcmagent.rpm
  fi
fi

# ---------- Pre-check Azure auth context ----------
if ! az account show >/dev/null 2>&1; then
  log "No active 'az login'. Please 'az login' with an identity that has 'Key Vault Secrets User' on vault '${KV_NAME}'."
  exit 1
fi

# ---------- Download certificate secret from Key Vault (RBAC model) ----------
log "Checking Key Vault secret content type ..."
CONTENT_TYPE="$(az keyvault secret show --vault-name "${KV_NAME}" --name "${KV_CERT_NAME}" --query contentType -o tsv || true)"
log "contentType='${CONTENT_TYPE:-<empty>}'"

log "Downloading certificate secret payload ..."
az keyvault secret download \
  --vault-name "${KV_NAME}" \
  --name "${KV_CERT_NAME}" \
  --file "${CERT_BLOB}" 1>>"${LOGFILE}"
chmod 600 "${CERT_BLOB}"

# Convert to PEM if needed
if [[ "${CONTENT_TYPE,,}" == *"application/x-pem-file"* ]]; then
  log "Detected PEM content; using as-is."
  mv "${CERT_BLOB}" "${CERT_PEM}"
elif [[ "${CONTENT_TYPE,,}" == *"application/x-pkcs12"* || -z "${CONTENT_TYPE}" ]]; then
  log "Detected PFX (or unspecified); converting PFX -> PEM (no passphrase) ..."
  openssl pkcs12 -in "${CERT_BLOB}" -nodes -out "${CERT_PEM}" -passin pass: || {
    log "ERROR converting PFX to PEM. Ensure the secret contains a certificate with private key."
    exit 1
  }
  shred -u "${CERT_BLOB}" || rm -f "${CERT_BLOB}"
else
  log "Unknown contentType; attempting PEM as fallback ..."
  mv "${CERT_BLOB}" "${CERT_PEM}"
fi
chmod 600 "${CERT_PEM}"

# ---------- Login with SP certificate & connect to Arc ----------
log "Authenticating as Service Principal using certificate ..."
az logout --username "${SP_APP_ID}" >/dev/null 2>&1 || true
az login --service-principal \
  --username "${SP_APP_ID}" \
  --tenant "${TENANT_ID}" \
  --password "${CERT_PEM}" 1>>"${LOGFILE}"

HOST="$(hostname -f || hostname)"
log "Connecting host '${HOST}' to Azure Arc (${AZ_LOCATION}) ..."
azcmagent connect \
  --service-principal-id "${SP_APP_ID}" \
  --service-principal-certificate "${CERT_PEM}" \
  --resource-group "${RG}" \
  --tenant-id "${TENANT_ID}" \
  --location "${AZ_LOCATION}" 1>>"${LOGFILE}"

log "Arc status:"
azcmagent show | tee -a "${LOGFILE}"

# ---------- Cleanup onboarding credential ----------
log "Securely deleting PEM (onboarding credential only needed for connect) ..."
shred -u "${CERT_PEM}" || rm -f "${CERT_PEM}"

log "Azure Arc agent installed & machine connected successfully."
log "Note: Arc managed identity credentials are stored under /var/opt/azcmagent/certs with restricted ACLs—do not modify."
exit 0
