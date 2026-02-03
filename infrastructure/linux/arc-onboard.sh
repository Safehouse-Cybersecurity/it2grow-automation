#!/usr/bin/env bash
# Azure Arc onboarding with SP certificate from Azure Key Vault
# Works on Rocky Linux 10+
# Authentication: SP secret -> downloads certificate from KV -> connects to Arc

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  arc-onboard.sh \
    --sp-app-id <GUID> \
    --sp-secret <secret> \
    --tenant-id <GUID> \
    --resource-group <name> \
    --location <azure-region> \
    --keyvault <kv-name> \
    --kv-cert-name <kv-certificate-name> \
    [--log /var/log/arc-onboard.log]

Requirements:
- Service Principal must have:
  - **Key Vault Secrets User** role on Key Vault (to download certificate)
  - **Azure Connected Machine Onboarding** role on Resource Group
- Certificate in Key Vault must include private key (PFX or PEM format)
- Machine must not already be Arc-connected

Authentication Flow:
1. SP authenticates with client secret
2. Downloads certificate from Key Vault
3. Uses certificate to connect to Azure Arc
4. Certificate is securely deleted after connection
USAGE
}

# ---------- Parse arguments ----------
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
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

for v in SP_APP_ID SP_SECRET TENANT_ID RG AZ_LOCATION KV_NAME KV_CERT_NAME; do
  if [[ -z "${!v:-}" ]]; then 
    echo "ERROR: Missing required parameter: --${v//_/-}"
    usage
    exit 1
  fi
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
    log "ERROR: Machine is already Arc-connected."
    log "Run 'sudo azcmagent disconnect' first if re-onboarding is needed."
    exit 1
  fi
fi

# ---------- Install required tools ----------
need() { 
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Installing $1..."
    dnf -y install "$1" >>"${LOGFILE}" 2>&1
  fi
}

need curl
need unzip
need openssl

# ---------- Install Azure CLI ----------
if ! command -v az >/dev/null 2>&1; then
  log "Installing Azure CLI..."
  rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null || true
  
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

# ---------- Install Azure Arc agent ----------
if ! command -v azcmagent >/dev/null 2>&1; then
  log "Installing Azure Connected Machine agent..."
  
  # Detect OS version
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_VERSION_ID="${VERSION_ID%%.*}"
    log "Detected: ${NAME} ${VERSION_ID}"
  else
    OS_VERSION_ID="9"
    log "WARNING: Could not detect OS version, defaulting to RHEL 9"
  fi
  
  # Import Microsoft GPG key
  rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null || true
  
  # Configure Microsoft repository
  log "Configuring Microsoft repository for RHEL ${OS_VERSION_ID}..."
  if rpm -Uvh "https://packages.microsoft.com/config/rhel/${OS_VERSION_ID}/packages-microsoft-prod.rpm" >>"${LOGFILE}" 2>&1; then
    log "Repository configured successfully"
    
    if dnf install -y azcmagent >>"${LOGFILE}" 2>&1; then
      log "azcmagent installed via dnf"
    else
      log "WARNING: dnf install failed, trying direct RPM download..."
    fi
  else
    log "WARNING: Repository configuration failed, trying direct RPM download..."
  fi
  
  # Fallback: Direct RPM download
  if ! command -v azcmagent >/dev/null 2>&1; then
    log "Downloading Arc agent RPM..."
    
    # Clean up broken repos
    rm -f /etc/yum.repos.d/azure-connected-machine-agent.repo 2>/dev/null || true
    rm -f /etc/yum.repos.d/prod.repo 2>/dev/null || true
    dnf clean all >>"${LOGFILE}" 2>&1 || true
    
    if curl -fsSL --max-time 180 -o /tmp/azcmagent.rpm https://aka.ms/azcmagent-rhel 2>>"${LOGFILE}"; then
      log "Download successful ($(du -h /tmp/azcmagent.rpm | awk '{print $1}'))"
      
      # Install with rpm to bypass repository issues
      rpm -Uvh /tmp/azcmagent.rpm >>"${LOGFILE}" 2>&1 || \
        dnf -y install --disablerepo='*' /tmp/azcmagent.rpm >>"${LOGFILE}" 2>&1
      
      rm -f /tmp/azcmagent.rpm
    else
      log "ERROR: Failed to download Arc agent RPM"
      log "Check network connectivity and DNS resolution"
      exit 1
    fi
  fi
  
  # Verify installation
  if ! command -v azcmagent >/dev/null 2>&1; then
    log "ERROR: azcmagent installation failed. Check ${LOGFILE} for details."
    exit 1
  fi
  
  log "azcmagent installed successfully: $(azcmagent version)"
fi

# ---------- Authenticate with SP secret ----------
log "Authenticating as Service Principal (App ID: ${SP_APP_ID})..."
az account clear 2>/dev/null || true

if ! az login --service-principal \
  --username "${SP_APP_ID}" \
  --tenant "${TENANT_ID}" \
  --password "${SP_SECRET}" 1>>"${LOGFILE}" 2>&1; then
  log "ERROR: Service Principal authentication failed"
  log "Verify:"
  log "  - App ID is correct: ${SP_APP_ID}"
  log "  - Client secret is valid and not expired"
  log "  - SP exists in tenant: ${TENANT_ID}"
  exit 1
fi

CURRENT_SUB=$(az account show --query id -o tsv)
log "Authenticated successfully. Subscription: ${CURRENT_SUB}"

# ---------- Download certificate from Key Vault ----------
log "Downloading certificate '${KV_CERT_NAME}' from Key Vault '${KV_NAME}'..."

CONTENT_TYPE="$(az keyvault secret show \
  --vault-name "${KV_NAME}" \
  --name "${KV_CERT_NAME}" \
  --query contentType -o tsv 2>>"${LOGFILE}" || true)"

log "Certificate content type: ${CONTENT_TYPE:-<empty>}"

if ! az keyvault secret download \
  --vault-name "${KV_NAME}" \
  --name "${KV_CERT_NAME}" \
  --file "${CERT_BLOB}" 1>>"${LOGFILE}" 2>&1; then
  log "ERROR: Failed to download certificate from Key Vault"
  log "Verify:"
  log "  - SP has 'Key Vault Secrets User' role on vault '${KV_NAME}'"
  log "  - Certificate '${KV_CERT_NAME}' exists in the vault"
  log "  - Key Vault firewall allows access from this machine"
  exit 1
fi

chmod 600 "${CERT_BLOB}"

# Convert to PEM if needed
if [[ "${CONTENT_TYPE,,}" == *"application/x-pem-file"* ]]; then
  log "Certificate is already in PEM format"
  mv "${CERT_BLOB}" "${CERT_PEM}"
elif [[ "${CONTENT_TYPE,,}" == *"application/x-pkcs12"* || -z "${CONTENT_TYPE}" ]]; then
  log "Converting PFX to PEM..."
  if ! openssl pkcs12 -in "${CERT_BLOB}" -nodes -out "${CERT_PEM}" -passin pass: 2>>"${LOGFILE}"; then
    log "ERROR: Failed to convert PFX to PEM"
    log "Ensure certificate contains private key"
    exit 1
  fi
  shred -u "${CERT_BLOB}" 2>/dev/null || rm -f "${CERT_BLOB}"
else
  log "Unknown content type, attempting PEM conversion..."
  mv "${CERT_BLOB}" "${CERT_PEM}"
fi

chmod 600 "${CERT_PEM}"

# ---------- Connect to Azure Arc ----------
log "Re-authenticating with certificate for Arc connection..."
az account clear 2>/dev/null || true

if ! az login --service-principal \
  --username "${SP_APP_ID}" \
  --tenant "${TENANT_ID}" \
  --password "${CERT_PEM}" 1>>"${LOGFILE}" 2>&1; then
  log "ERROR: Certificate-based authentication failed"
  log "Verify certificate is valid and associated with App ID '${SP_APP_ID}'"
  exit 1
fi

HOST="$(hostname -f 2>/dev/null || hostname)"
log "Connecting '${HOST}' to Azure Arc (${AZ_LOCATION})..."
log "This may take 2-3 minutes..."

if ! azcmagent connect \
  --resource-name "${HOST}" \
  --service-principal-id "${SP_APP_ID}" \
  --service-principal-certificate "${CERT_PEM}" \
  --resource-group "${RG}" \
  --tenant-id "${TENANT_ID}" \
  --location "${AZ_LOCATION}" \
  --tags "OS=Linux" \
  --correlation-id "${CORRELATION_ID}" 1>>"${LOGFILE}" 2>&1; then
  log "ERROR: azcmagent connect failed"
  log "Common issues:"
  log "  - SP lacks 'Azure Connected Machine Onboarding' role on RG '${RG}'"
  log "  - Network issues (firewall blocking *.guestconfiguration.azure.com)"
  log "  - Resource name '${HOST}' conflicts with existing Arc resource"
  log "Check ${LOGFILE} for detailed error messages"
  exit 1
fi

log "Connection successful! Verifying status..."
azcmagent show | tee -a "${LOGFILE}"

# ---------- Cleanup ----------
log "Securely deleting certificate..."
shred -u "${CERT_PEM}" 2>/dev/null || rm -f "${CERT_PEM}"

log "=== Azure Arc onboarding completed successfully ==="
log "Correlation ID: ${CORRELATION_ID}"
log "Arc managed identity is now available at: http://localhost:40342/metadata/identity"
exit 0
