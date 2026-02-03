#!/usr/bin/env bash
# Azure Arc onboarding with Service Principal secret
# Works on Rocky Linux 10+
# No Azure CLI or Key Vault required

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
    [--log /var/log/arc-onboard.log]

Requirements:
- Service Principal must have **Azure Connected Machine Onboarding** role on Resource Group
- Machine must not already be Arc-connected

Example:
  ./arc-onboard.sh \
    --sp-app-id c839dc63-611d-4f59-9b15-6df14d9fd147 \
    --sp-secret "your-secret-here" \
    --tenant-id 7579e671-8741-4a70-9047-9962a3c06c68 \
    --resource-group rg-arc-prod-weu-001 \
    --location westeurope
USAGE
}

# ---------- Parse arguments ----------
SP_APP_ID=""; SP_SECRET=""; TENANT_ID=""; SUBSCRIPTION_ID=""; RG=""; AZ_LOCATION=""
LOGFILE="/var/log/arc-onboard.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sp-app-id)       SP_APP_ID="$2"; shift 2 ;;
    --sp-secret)       SP_SECRET="$2"; shift 2 ;;
    --tenant-id)       TENANT_ID="$2"; shift 2 ;;
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --resource-group)  RG="$2"; shift 2 ;;
    --location)        AZ_LOCATION="$2"; shift 2 ;;
    --log)             LOGFILE="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

for v in SP_APP_ID SP_SECRET TENANT_ID SUBSCRIPTION_ID RG AZ_LOCATION; do
  if [[ -z "${!v:-}" ]]; then 
    echo "ERROR: Missing required parameter: --${v//_/-}"
    usage
    exit 1
  fi
done

# ---------- Setup ----------
mkdir -p "$(dirname "${LOGFILE}")"
touch "${LOGFILE}"; chmod 600 "${LOGFILE}"
log(){ echo "[$(date -Is)] $*" | tee -a "${LOGFILE}"; }

CORRELATION_ID="$(uuidgen 2>/dev/null || date +%s)"
log "=== Azure Arc Onboarding Session: ${CORRELATION_ID} ==="

# ---------- Pre-flight checks ----------
if command -v azcmagent >/dev/null 2>&1; then
  if azcmagent show >/dev/null 2>&1; then
    log "ERROR: Machine is already Arc-connected."
    log "Run 'sudo azcmagent disconnect --force-local-only' first if re-onboarding is needed."
    exit 1
  fi
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
  
  # Check if Microsoft repository is already configured
  if ! rpm -q packages-microsoft-prod >/dev/null 2>&1; then
    log "Configuring Microsoft repository for RHEL ${OS_VERSION_ID}..."
    rpm -Uvh "https://packages.microsoft.com/config/rhel/${OS_VERSION_ID}/packages-microsoft-prod.rpm" >>"${LOGFILE}" 2>&1
  else
    log "Microsoft repository already configured"
  fi
  
  # Install azcmagent
  log "Installing azcmagent package..."
  dnf install -y azcmagent >>"${LOGFILE}" 2>&1
  
  # Verify installation
  if ! command -v azcmagent >/dev/null 2>&1; then
    log "ERROR: azcmagent installation failed. Check ${LOGFILE} for details."
    exit 1
  fi
  
  log "azcmagent installed successfully: $(azcmagent version)"
fi

# ---------- Connect to Azure Arc ----------
HOST="$(hostname -f 2>/dev/null || hostname)"
log "Connecting '${HOST}' to Azure Arc (${AZ_LOCATION})..."
log "This may take 2-3 minutes..."

if ! azcmagent connect \
  --resource-name "${HOST}" \
  --service-principal-id "${SP_APP_ID}" \
  --service-principal-secret "${SP_SECRET}" \
  --subscription-id "${SUBSCRIPTION_ID}" \
  --resource-group "${RG}" \
  --tenant-id "${TENANT_ID}" \
  --location "${AZ_LOCATION}" \
  --tags "OS=Linux" \
  --correlation-id "${CORRELATION_ID}" 1>>"${LOGFILE}" 2>&1; then
  log "ERROR: azcmagent connect failed"
  log "Common issues:"
  log "  - SP lacks 'Azure Connected Machine Onboarding' role on RG '${RG}'"
  log "  - Client secret is invalid or expired"
  log "  - Network issues (firewall blocking *.guestconfiguration.azure.com)"
  log "  - Resource name '${HOST}' conflicts with existing Arc resource"
  log "Check ${LOGFILE} for detailed error messages"
  exit 1
fi

log "Connection successful! Verifying status..."
azcmagent show | tee -a "${LOGFILE}"

log "=== Azure Arc onboarding completed successfully ==="
log "Correlation ID: ${CORRELATION_ID}"
log "Arc managed identity is now available at: http://localhost:40342/metadata/identity"
exit 0
