#!/usr/bin/env bash
# Azure Arc: install agent + connect using SP certificate from Azure Key Vault (RBAC)
# Works on Rocky Linux 10+ (no packages-microsoft-prod required)
# Updated: SP authenticates with client secret to download certificate from Key Vault

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  arc-install-and-connect.sh \
    --sp-app-id <GUID> \
    --sp-secret <secret> \
    --tenant-id <GUID> \
    --resource-group <name> \
    --location <azure-region> \
    --keyvault <kv-name> \
    --kv-cert-name <kv-certificate-name> \
    [--log /var/log/arc-onboard.log]

Requirements:
- The Service Principal must have:
  - **Key Vault Secrets User** role on the Key Vault (to download the certificate)
  - **Azure Connected Machine Onboarding** role on the Resource Group (to connect to Arc)
- Machine must not already be Arc-connected (check with: azcmagent show)

Authentication Flow:
1. SP authenticates with client secret → downloads certificate from Key Vault
2. SP uses certificate → connects machine to Azure Arc
3. Certificate is securely deleted after successful connection

Notes:
- Certificate in Key Vault must be in PFX or PEM format with private key included.
- PFX certificates are assumed to have no password (standard for KV-exported certs).
- Client secret is only used for bootstrap authentication, not stored.
USAGE
}

# ---------- Parse args ----------
SP_APP_ID=""; SP_SECRET=""; TENANT_ID=""; RG=""; AZ_LOCATION=""; KV_NAME=""; KV_CERT_NAME=""
LOGFILE="/var/log/arc-onboard.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sp-app-id)      SP_APP_ID="$2"; shift 2 ;;
    --sp-secret)      SP_SECRET="$2"; shift 2 ;;
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

for v in SP_APP_ID SP_SECRET TENANT_ID RG AZ_LOCATION KV_NAME KV_CERT_NAME; do
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

# Install Azure Arc Connected Machine agent
if ! command -v azcmagent >/dev/null 2>&1; then
  log "Installing Azure Connected Machine agent..."
  
  # Detect OS version for proper repository
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_VERSION_ID="${VERSION_ID%%.*}"  # Get major version only
    log "Detected: ${NAME} ${VERSION_ID} (Major: ${OS_VERSION_ID})"
  else
    OS_VERSION_ID="9"  # Default fallback
    log "WARNING: Could not detect OS version, defaulting to RHEL 9 repos"
  fi
  
  # Try dnf installation with packages-microsoft-prod.rpm
  log "Method 1: Installing via Microsoft package repository..."
  
  # Import Microsoft GPG key
  rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null || true
  
  log "Configuring Microsoft repository for RHEL ${OS_VERSION_ID}..."
  if rpm -Uvh "https://packages.microsoft.com/config/rhel/${OS_VERSION_ID}/packages-microsoft-prod.rpm" >>"${LOGFILE}" 2>&1; then
    log "Microsoft repository configured successfully"
    
    log "Installing azcmagent package via dnf..."
    if dnf install -y azcmagent >>"${LOGFILE}" 2>&1; then
      log "azcmagent installed successfully via dnf"
    else
      log "WARNING: dnf install failed, will try direct RPM download"
    fi
  else
    log "WARNING: Could not configure Microsoft repository, will try direct RPM download"
  fi
  
  # Fallback: Direct RPM download if dnf method failed
  if ! command -v azcmagent >/dev/null 2>&1; then
    log "Method 2: Downloading Arc agent RPM directly..."
    
    # Clean up any broken repo files that might have been created
    log "Cleaning up any broken repository configurations..."
    rm -f /etc/yum.repos.d/azure-connected-machine-agent.repo 2>/dev/null || true
    rm -f /etc/yum.repos.d/prod.repo 2>/dev/null || true
    dnf clean all >>"${LOGFILE}" 2>&1 || true
    
    if curl -fsSL --max-time 180 --connect-timeout 30 \
         -o /tmp/azcmagent.rpm \
         https://aka.ms/azcmagent-rhel 2>>"${LOGFILE}"; then
      
      log "Download successful. File size: $(du -h /tmp/azcmagent.rpm | awk '{print $1}')"
      log "Installing RPM directly (bypassing repositories)..."
      
      # Use rpm directly to avoid repo issues
      rpm -Uvh /tmp/azcmagent.rpm >>"${LOGFILE}" 2>&1 || \
        dnf -y install --disablerepo='*' /tmp/azcmagent.rpm >>"${LOGFILE}" 2>&1
      rm -f /tmp/azcmagent.rpm
    else
      log "ERROR: Failed to download Arc agent RPM from https://aka.ms/azcmagent-rhel"
      log "Troubleshooting:"
      log "  - Check network connectivity: curl -I https://packages.microsoft.com"
      log "  - Check DNS resolution: nslookup aka.ms"
      log "  - Check firewall: sudo firewall-cmd --list-all"
      exit 1
    fi
  fi
  
  # Final verification
  if ! command -v azcmagent >/dev/null 2>&1; then
    log "ERROR: azcmagent installation failed. Check ${LOGFILE} for details."
    exit 1
  fi
  
  log "azcmagent installed successfully: $(azcmagent version)"
fi

# ---------- Authenticate with SP client secret ----------
log "Authenticating with Service Principal using client secret..."
log "App ID: ${SP_APP_ID}"

# Clear any existing sessions
az account clear 2>/dev/null || true

if ! az login --service-principal \
  --username "${SP_APP_ID}" \
  --tenant "${TENANT_ID}" \
  --password "${SP_SECRET}" 1>>"${LOGFILE}" 2>&1; then
  log "ERROR: Service Principal authentication failed."
  log "Verify that:"
  log "  1. App ID '${SP_APP_ID}' is correct"
  log "  2. Client secret is valid and not expired"
  log "  3. SP exists in tenant '${TENANT_ID}'"
  exit 1
fi

CURRENT_SUB=$(az account show --query id -o tsv)
log "Authenticated successfully. Using subscription: ${CURRENT_SUB}"

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
  log "  1. Service Principal has 'Key Vault Secrets User' role on vault '${KV_NAME}'"
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

# ---------- Re-authenticate with certificate for Arc connection ----------
log "Re-authenticating with Service Principal using downloaded certificate..."
az account clear 2>/dev/null || true

if ! az login --service-principal \
  --username "${SP_APP_ID}" \
  --tenant "${TENANT_ID}" \
  --password "${CERT_PEM}" 1>>"${LOGFILE}" 2>&1; then
  log "ERROR: Certificate-based authentication failed."
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

# ---------- Cleanup onboarding credentials ----------
log "Securely deleting certificate (onboarding credential no longer needed) ..."
shred -u "${CERT_PEM}" 2>/dev/null || rm -f "${CERT_PEM}"

log "=== Azure Arc agent installed & machine connected successfully ==="
log "Correlation ID: ${CORRELATION_ID}"
log "Note: Arc managed identity credentials are stored under /var/opt/azcmagent/certs with restricted ACLs—do not modify."
exit 0
