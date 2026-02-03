#!/usr/bin/env bash
# Azure Arc: install agent + connect using SP certificate from Azure Key Vault (RBAC)
# Works on Rocky Linux 10+ (no packages-microsoft-prod required)
# Updated: Uses dnf to install Arc agent from Microsoft repository

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
  **Key Vault Secrets User** role on the specified vault (RBAC model) to read the certificate secret.
- The Service Principal must have **Azure Connected Machine Onboarding** role on the target Resource Group.
- Machine must not already be Arc-connected (check with: azcmagent show)

Notes:
- Certificate in Key Vault must be in PFX or PEM format with private key included.
- PFX certificates are assumed to have no password (standard for KV-exported certs).
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

CORRELATION_ID="$(uuidgen 2>/dev/null || date +%s)"
log "=== Azure Arc Onboarding Session: ${CORRELATION_ID} ==="

# ---------- Pre-flight checks ----------
if command -v azcmagent >/dev/null 2>&1; then
  if azcmagent show >/dev/null 2>&1; then
    log "ERROR: Machine is already Arc-connected. Run 'sudo azcmagent disconnect' first if re-onboarding is needed."
    exit 1
  fi
fi

# ---------- Ensure tools ----------
need() { 
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Installing $1 ..."
    dnf -y install "$1" >>"${LOGFILE}" 2>&1
  fi
}
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
  dnf install -y azure-cli >>"${LOGFILE}" 2>&1
fi

# Install Azure Arc Connected Machine agent using dnf (cleaner method)
if ! command -v azcmagent >/dev/null 2>&1; then
  log "Installing Azure Connected Machine agent via dnf repository..."
  
  # Import Microsoft GPG key if not already done
  rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null || true
  
  # Add Microsoft repository for Azure Arc
  log "Adding Microsoft Azure Arc repository..."
  tee /etc/yum.repos.d/azure-connected-machine-agent.repo >/dev/null << 'EOF'
[azure-connected-machine-agent]
name=Azure Connected Machine Agent
baseurl=https://packages.microsoft.com/yumrepos/azure-connected-machine-agent/
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

  log "Installing azcmagent package..."
  dnf install -y azcmagent >>"${LOGFILE}" 2>&1
  
  # Verify installation
  if ! command -v azcmagent >/dev/null 2>&1; then
    log "ERROR: azcmagent installation failed. Check ${LOGFILE} for details."
    log "Troubleshooting:"
    log "  - Verify network connectivity: curl -I https://packages.microsoft.com"
    log "  - Check repository: dnf repolist | grep azure"
    log "  - Try manual install: dnf install -y azcmagent"
    exit 1
  fi
  
  log "azcmagent installed successfully: $(azcmagent version)"
fi

# ---------- Pre-check Azure auth context ----------
if ! az account show >/dev/null 2>&1; then
  log "ERROR: No active 'az login' session."
  log "Please authenticate with an identity that has 'Key Vault Secrets User' role on vault '${KV_NAME}'."
  exit 1
fi

CURRENT_SUB=$(az account show --query id -o tsv)
CURRENT_USER=$(az account show --query user.name -o tsv)
log "Authenticated as: ${CURRENT_USER}"
log "Using subscription: ${CURRENT_SUB}"

# ---------- Download certificate secret from Key Vault (RBAC model) ----------
log "Checking Key Vault secret content type ..."
CONTENT_TYPE="$(az keyvault secret show --vault-name "${KV_NAME}" --name "${KV_CERT_NAME}" --query contentType -o tsv 2>>"${LOGFILE}" || true)"
log "contentType='${CONTENT_TYPE:-<empty>}'"

log "Downloading certificate secret payload from vault '${KV_NAME}' ..."
if ! az keyvault secret download \
  --vault-name "${KV_NAME}" \
  --name "${KV_CERT_NAME}" \
  --file "${CERT_BLOB}" 1>>"${LOGFILE}" 2>&1; then
  log "ERROR: Failed to download certificate secret."
  log "Verify that:"
  log "  1. The current identity has 'Key Vault Secrets User' role on vault '${KV_NAME}'"
  log "  2. Certificate '${KV_CERT_NAME}' exists in the vault"
  log "  3. Key Vault firewall allows access from this machine"
  exit 1
fi
chmod 600 "${CERT_BLOB}"

# Convert to PEM if needed
if [[ "${CONTENT_TYPE,,}" == *"application/x-pem-file"* ]]; then
  log "Detected PEM content; using as-is."
  mv "${CERT_BLOB}" "${CERT_PEM}"
elif [[ "${CONTENT_TYPE,,}" == *"application/x-pkcs12"* || -z "${CONTENT_TYPE}" ]]; then
  log "Detected PFX (or unspecified); converting PFX -> PEM (no passphrase assumed) ..."
  if ! openssl pkcs12 -in "${CERT_BLOB}" -nodes -out "${CERT_PEM}" -passin pass: 2>>"${LOGFILE}"; then
    log "ERROR: Failed to convert PFX to PEM."
    log "Ensure the secret contains a valid certificate with private key included."
    exit 1
  fi
  shred -u "${CERT_BLOB}" 2>/dev/null || rm -f "${CERT_BLOB}"
else
  log "Unknown contentType '${CONTENT_TYPE}'; attempting PEM as fallback ..."
  mv "${CERT_BLOB}" "${CERT_PEM}"
fi
chmod 600 "${CERT_PEM}"

# ---------- Login with SP certificate & connect to Arc ----------
log "Clearing any existing Azure CLI sessions ..."
az account clear 2>/dev/null || true

log "Authenticating as Service Principal (App ID: ${SP_APP_ID}) using certificate ..."
if ! az login --service-principal \
  --username "${SP_APP_ID}" \
  --tenant "${TENANT_ID}" \
  --password "${CERT_PEM}" 1>>"${LOGFILE}" 2>&1; then
  log "ERROR: Service Principal authentication failed."
  log "Verify that the certificate is valid and associated with App ID '${SP_APP_ID}'."
  exit 1
fi

HOST="$(hostname -f 2>/dev/null || hostname)"
log "Connecting host '${HOST}' to Azure Arc in resource group '${RG}' (${AZ_LOCATION}) ..."
log "This may take 2-3 minutes ..."

if ! azcmagent connect \
  --resource-name "${HOST}" \
  --service-principal-id "${SP_APP_ID}" \
  --service-principal-certificate "${CERT_PEM}" \
  --resource-group "${RG}" \
  --tenant-id "${TENANT_ID}" \
  --location "${AZ_LOCATION}" \
  --tags "OS=Linux" \
  --correlation-id "${CORRELATION_ID}" 1>>"${LOGFILE}" 2>&1; then
  log "ERROR: azcmagent connect failed."
  log "Common issues:"
  log "  1. Service Principal lacks 'Azure Connected Machine Onboarding' role on RG '${RG}'"
  log "  2. Network connectivity issues (proxy/firewall blocking *.guestconfiguration.azure.com)"
  log "  3. Resource name '${HOST}' conflicts with existing Arc resource"
  log "Check ${LOGFILE} for detailed error messages."
  exit 1
fi

log "Arc connection successful! Verifying status ..."
azcmagent show | tee -a "${LOGFILE}"

# ---------- Cleanup onboarding credential ----------
log "Securely deleting PEM certificate (onboarding credential no longer needed) ..."
shred -u "${CERT_PEM}" 2>/dev/null || rm -f "${CERT_PEM}"

log "=== Azure Arc agent installed & machine connected successfully ==="
log "Correlation ID: ${CORRELATION_ID}"
log "Note: Arc managed identity credentials are stored under /var/opt/azcmagent/certs with restricted ACLs—do not modify."
exit 0
