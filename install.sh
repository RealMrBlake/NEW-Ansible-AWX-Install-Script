#!/usr/bin/env bash
#
# AWX Installation Script für Ubuntu 24.04
# Version: 1.7
# AWX Version: 24.6.1
# AWX Operator Version: 2.19.1
#

set -euo pipefail

# Farben für Ausgaben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info(){  echo -e "${GREEN}[INFO]${NC}  $1"; }
warn(){  echo -e "${YELLOW}[WARN]${NC}  $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Konfiguration
MINIKUBE_CPUS=4
MINIKUBE_MEMORY=8192        # in MB
MINIKUBE_DISK_SIZE=40g      # in GB
AWX_NAMESPACE='awx'
AWX_INSTANCE_NAME='awx'
AWX_OPERATOR_VERSION='2.19.1'
USER_NAME="$USER"
KUBECONFIG_PATH="/home/$USER/.kube/config"
MK_SERVICE="minikube.service"
PF_SERVICE="awx-portforward.service"

# Skript darf nicht als root laufen
(( EUID != 0 )) || error "Nicht als root ausführen."

# 1) Systemanforderungen prüfen
check_system() {
  info "Prüfe Systemanforderungen..."
  (( $(nproc) >= MINIKUBE_CPUS )) || error "Mindestens ${MINIKUBE_CPUS} CPU‑Kernerforderlich."
  local mem_kb; mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  (( mem_kb >= MINIKUBE_MEMORY*1024 )) || error "Mindestens ${MINIKUBE_MEMORY} MB RAM erforderlich."
  local avail_kb; avail_kb=$(df / --output=avail | tail -1)
  local req_kb=$(( ${MINIKUBE_DISK_SIZE%g} * 1024 * 1024 ))
  (( avail_kb >= req_kb )) || error "Mindestens ${MINIKUBE_DISK_SIZE} freier Speicher erforderlich."
}

# 2) System updaten
update_system() {
  info "Systempakete aktualisieren..."
  sudo apt update && sudo apt upgrade -y
  sudo apt install -y curl wget apt-transport-https ca-certificates gnupg \
                      lsb-release software-properties-common
}

# 3) Docker installieren
install_docker() {
  info "Installiere Docker..."
  command -v docker &>/dev/null && { info "Docker bereits installiert."; return; }
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER_NAME"
  sudo systemctl enable --now docker
  warn "Bitte neu einloggen oder 'newgrp docker' ausführen, dann Skript erneut fortsetzen."
  exit 0
}

# 4) kubectl installieren
install_kubectl() {
  info "Installiere kubectl..."
  command -v kubectl &>/dev/null && { info "kubectl bereits vorhanden."; return; }
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
  echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl kubectl.sha256
}

# 5) Minikube installieren
install_minikube() {
  info "Installiere Minikube..."
  command -v minikube &>/dev/null && { info "Minikube bereits installiert."; return; }
  curl -Lo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  sudo install minikube /usr/local/bin/minikube
  rm minikube
}

# 6) Minikube starten
start_minikube() {
  info "Starte Minikube..."
  minikube status &>/dev/null && { info "Minikube läuft bereits."; return; }
  minikube start \
    --driver=docker \
    --cpus=$MINIKUBE_CPUS \
    --memory=${MINIKUBE_MEMORY}MB \
    --disk-size=$MINIKUBE_DISK_SIZE \
    --addons=ingress,dashboard,metrics-server
  kubectl wait node --for=condition=Ready --all --timeout=300s
}

# 7) AWX Operator installieren
install_awx_operator() {
  info "Installiere AWX Operator $AWX_OPERATOR_VERSION..."
  kubectl create namespace "$AWX_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  local tmp; tmp=$(mktemp -d)
  pushd "$tmp" >/dev/null
    cat > kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - github.com/ansible/awx-operator/config/default?ref=$AWX_OPERATOR_VERSION
namespace: $AWX_NAMESPACE
images:
  - name: quay.io/ansible/awx-operator
    newTag: $AWX_OPERATOR_VERSION
EOF
    kubectl apply -k .
  popd >/dev/null && rm -rf "$tmp"
  kubectl rollout status deployment/awx-operator-controller-manager \
    -n "$AWX_NAMESPACE" --timeout=300s
}

# 8) AWX CustomResource deployen
deploy_awx() {
  info "Deploy AWX CustomResource..."
  if kubectl get awx "$AWX_INSTANCE_NAME" -n "$AWX_NAMESPACE" &>/dev/null; then
    info "AWX-Instanz existiert bereits; überspringe."
  else
    cat <<EOF | kubectl apply -f -
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: $AWX_INSTANCE_NAME
  namespace: $AWX_NAMESPACE
spec:
  service_type: nodeport
  ingress_type: none
  hostname: awx.local
  web_replicas: 1
  task_replicas: 1
  web_resource_requirements:
    requests: {cpu: 500m, memory: 1Gi}
    limits:   {cpu: 1000m, memory: 2Gi}
  task_resource_requirements:
    requests: {cpu: 500m, memory: 1Gi}
    limits:   {cpu: 1000m, memory: 2Gi}
  postgres_storage_requirements:
    requests: {storage: 8Gi}
  postgres_storage_class: standard
  projects_persistence: true
  projects_storage_size: 4Gi
  projects_storage_class: standard
EOF
  fi
}

# 9) Auf AWX‑Pods warten
wait_for_awx() {
  info "Warte auf AWX‑Pods..."
  local timeout=900 interval=10 elapsed=0
  while (( elapsed < timeout )); do
    local pods
    pods=$(kubectl get pods -n "$AWX_NAMESPACE" \
           -l app.kubernetes.io/managed-by=awx-operator --no-headers 2>/dev/null || true)
    if [[ -n "$pods" ]]; then
      info "Gefundene Pods:"
      echo "$pods"
      info "Warte auf READY..."
      if kubectl wait --for=condition=Ready pod \
           -l app.kubernetes.io/managed-by=awx-operator \
           -n "$AWX_NAMESPACE" --timeout=$((timeout-elapsed))s; then
        info "Alle AWX-Pods sind bereit!"
        return 0
      else
        error "Einige AWX-Pods konnten nicht bereitgestellt werden."; \
        kubectl get pod -n "$AWX_NAMESPACE"; return 1
      fi
    fi
    sleep $interval
    elapsed=$((elapsed+interval))
    info "Noch keine Pods – warte..."
  done
  error "Timeout: Keine AWX-Pods gefunden innerhalb $timeout Sekunden."; \
  kubectl get pod -n "$AWX_NAMESPACE"; return 1
}

# 10) Auf Service warten
wait_for_service() {
  info "Warte auf awx-Service..."
  for i in {1..30}; do
    kubectl get svc ${AWX_INSTANCE_NAME}-service -n "$AWX_NAMESPACE" &>/dev/null \
      && return 0
    sleep 2
  done
  error "awx-Service nicht gefunden nach Wartezeit."
}

# 11) Zugangsdaten anzeigen
get_awx_access_info() {
  wait_for_service
  local pw port ip
  pw=$(kubectl get secret ${AWX_INSTANCE_NAME}-admin-password \
       -n "$AWX_NAMESPACE" -o jsonpath="{.data.password}" | base64 --decode)
  port=$(kubectl get svc ${AWX_INSTANCE_NAME}-service \
         -n "$AWX_NAMESPACE" -o jsonpath="{.spec.ports[?(@.port==80)].nodePort}")
  ip=$(minikube ip)
  info "AWX erreichbar: http://$ip:$port"
  info "User: admin"
  info "Pass: $pw"
}

# 12) Systemd‑Service für Minikube
create_minikube_service() {
  info "Erstelle systemd‑Service für Minikube..."
  sudo tee /etc/systemd/system/$MK_SERVICE >/dev/null <<EOF
[Unit]
Description=Minikube-Cluster für AWX
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$USER_NAME
Environment=KUBECONFIG=$KUBECONFIG_PATH
ExecStart=/usr/local/bin/minikube start \\
  --driver=docker \\
  --cpus=$MINIKUBE_CPUS \\
  --memory=${MINIKUBE_MEMORY}MB \\
  --disk-size=$MINIKUBE_DISK_SIZE \\
  --addons=ingress,dashboard,metrics-server
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable  $MK_SERVICE
  sudo systemctl start   $MK_SERVICE
}

# 13) Systemd‑Service für Port‑Forwarding
create_portforward_service() {
  info "Erstelle systemd‑Service für Port‑Forwarding..."
  sudo tee /etc/systemd/system/$PF_SERVICE >/dev/null <<EOF
[Unit]
Description=Port-Forward AWX auf 0.0.0.0:8080
After=$MK_SERVICE network-online.target
Wants=$MK_SERVICE

[Service]
Type=simple
User=$USER_NAME
Environment=KUBECONFIG=$KUBECONFIG_PATH

# Warte auf Service (max 60 Sekunden)
ExecStartPre=/bin/bash -c 'for i in {1..30}; do kubectl get svc awx-service -n $AWX_NAMESPACE &>/dev/null && exit 0; sleep 2; done; exit 1'

ExecStart=/usr/local/bin/kubectl port-forward \\
  --address 0.0.0.0 svc/${AWX_INSTANCE_NAME}-service 8080:80 -n $AWX_NAMESPACE
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable  $PF_SERVICE
  sudo systemctl start   $PF_SERVICE
}

# Hauptprogramm
check_system
update_system
install_docker
install_kubectl
install_minikube
start_minikube
install_awx_operator
deploy_awx
wait_for_awx
get_awx_access_info
create_minikube_service
create_portforward_service

info "Installation abgeschlossen. AWX im LAN unter http://<Server-IP>:8080 erreichbar."
