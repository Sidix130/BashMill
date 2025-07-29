#!/usr/bin/env bash
#===================================================================================
#== DEBIAN/UBUNTU SERVER INIT - V2.5 (Revue et Optimisée)                         ==
#===================================================================================
# Description: Script de post-installation pour serveurs Debian/Ubuntu.
# Philosophie: Stabilité, idempotence, sécurité et contrôle.
# Auteur: sidix & Gemini
#===================================================================================

set -euo pipefail
IFS=$'\n\t'  # Sécurise les expansions
trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# --- CONSTANTES ---
readonly SCRIPT_VERSION="v2.5"
readonly LOG_FILE="/var/log/server-init-${SCRIPT_VERSION}.log"

# --- CONFIGURATION ---
MAIN_USER="sidix"
DRY_RUN=false
SNAPPER_CONFIG_NAME="root"
SNAPPER_ENABLED=false
REQUIRED_BTRFS=false
SKIP_FIREWALL=false
SKIP_SNAPPER=false

# Ports UFW avec gestion sémantique
UFW_RULES=(
  "22/tcp limit comment 'SSH with rate-limiting'"
  "http/tcp"
  "https/tcp"
  "5678/tcp comment 'n8n'"
  "9443/tcp comment 'Portainer'"
)

# --- FONCTIONS UTILITAIRES ---

init_logging() {
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"  # Sécurité: accès restreint
}

log() {
  local level="$1"
  local context="$2"
  local message="$3"
  local timestamp
  timestamp=$(date --iso-8601=seconds)
  printf "[%s] %-8s %-12s %s\n" "$timestamp" "$level" "$context" "$message" | tee -a "$LOG_FILE" >&2
}

error_handler() {
  local exit_code="$1"
  local line_no="$2"
  local command="$3"
  log "ERROR" "SYSTEM" "Erreur à la ligne $line_no (code: $exit_code) - Commande: '$command'"
  log "ERROR" "SYSTEM" "Arrêt brutal. Log complet: $LOG_FILE"
  exit "$exit_code"
}

execute_cmd() {
  local context="$1"
  shift
  local cmd_array=("$@")

  if $DRY_RUN; then
    log "DRYRUN" "$context" "Commande simulée: ${cmd_array[*]}"
    return 0
  fi

  log "INFO" "$context" "Exécution: ${cmd_array[*]}"
  if "${cmd_array[@]}"; then
    return 0
  else
    local exit_code=$?
    log "ERROR" "$context" "Échec de la commande (code $exit_code): ${cmd_array[*]}"
    return $exit_code
  fi
}

check_and_execute() {
  local context="$1"
  local check_cmd="$2"
  shift 2
  local exec_cmd_array=("$@")

  if eval "$check_cmd" &>/dev/null; then
    log "INFO" "$context" "Déjà configuré (vérification réussie: '$check_cmd')"
    return 0
  fi
  execute_cmd "$context" "${exec_cmd_array[@]}"
}

# --- VERIFICATIONS SYSTEME ---

check_root() {
  if [[ $EUID -ne 0 ]]; then
    log "ERROR" "PREFLIGHT" "Ce script doit être exécuté en tant que root"
    exit 1
  fi
}

validate_groups() {
  local groups=("sudo" "docker")
  for group in "${groups[@]}"; do
    if ! getent group "$group" &>/dev/null; then
      log "WARN" "PREFLIGHT" "Groupe système '$group' non trouvé - création"
      execute_cmd "PREFLIGHT" groupadd "$group"
    fi
  done
}

# --- GESTION SNAPPER ---

setup_snapper() {
  $SKIP_SNAPPER && return
  
  log "INFO" "SNAPPER" "Initialisation de Snapper..."
  local root_fs
  root_fs=$(findmnt -n -o FSTYPE /)
  
  if [[ "$root_fs" != "btrfs" ]]; then
    log "WARN" "SNAPPER" "Système non-BTRFS ($root_fs). Snapper désactivé."
    $REQUIRED_BTRFS && { log "ERROR" "SNAPPER" "BTRFS requis mais non détecté"; exit 1; }
    return
  fi
  
  SNAPPER_ENABLED=true
  check_and_execute "SNAPPER" "dpkg -s snapper" "apt" "install" "-y" "snapper"
  
  if ! snapper list-configs | grep -q "^${SNAPPER_CONFIG_NAME}"; then
    execute_cmd "SNAPPER" snapper -c "${SNAPPER_CONFIG_NAME}" create-config "/"
    execute_cmd "SNAPPER" snapper -c "${SNAPPER_CONFIG_NAME}" set-config "TIMELINE_CREATE=yes"
    execute_cmd "SNAPPER" snapper -c "${SNAPPER_CONFIG_NAME}" set-config "TIMELINE_CLEANUP=yes"
    execute_cmd "SNAPPER" snapper -c "${SNAPPER_CONFIG_NAME}" set-config "TIMELINE_LIMIT_HOURLY=12"
    execute_cmd "SNAPPER" snapper -c "${SNAPPER_CONFIG_NAME}" set-config "TIMELINE_LIMIT_DAILY=7"
    execute_cmd "SNAPPER" snapper -c "${SNAPPER_CONFIG_NAME}" set-config "TIMELINE_LIMIT_WEEKLY=4"
  fi

  check_and_execute "SNAPPER" "systemctl is-enabled snapper-timeline.timer" \
    "systemctl" "enable" "--now" "snapper-timeline.timer"
    
  check_and_execute "SNAPPER" "systemctl is-enabled snapper-cleanup.timer" \
    "systemctl" "enable" "--now" "snapper-cleanup.timer"

  log "SUCCESS" "SNAPPER" "Snapper configuré."
}

create_snapshot() {
  $SKIP_SNAPPER && return
  local description="$1"
  local type="$2"

  if ! $SNAPPER_ENABLED || $DRY_RUN; then
    log "DRYRUN" "SNAPSHOT" "Snapshot ($type) simulé: $description"
    return
  fi

  log "INFO" "SNAPSHOT" "Création snapshot ($type): $description"
  if ! snapshot_number=$(snapper -c "${SNAPPER_CONFIG_NAME}" create --type "$type" \
    --print-number --description "$description" 2>>"${LOG_FILE}"); then
    log "ERROR" "SNAPSHOT" "Échec création"
    return 1
  fi
  log "SUCCESS" "SNAPSHOT" "Snapshot #$snapshot_number créé."
}

# --- ÉTAPES D'INSTALLATION ---

preflight_checks() {
  log "INFO" "PREFLIGHT" "Vérifications préalables..."
  check_root
  validate_groups

  if ! id -u "$MAIN_USER" &>/dev/null; then
    log "WARN" "PREFLIGHT" "Utilisateur '$MAIN_USER' non trouvé - création"
    execute_cmd "PREFLIGHT" useradd -m -s /bin/bash -G sudo "$MAIN_USER"
    log "INFO" "PREFLIGHT" "NOTE: Définir le mot de passe avec 'passwd $MAIN_USER'"
  fi

  execute_cmd "PREFLIGHT" apt-get -qq update
  log "SUCCESS" "PREFLIGHT" "Vérifications terminées."
}

install_system_foundation() {
  log "INFO" "FOUNDATION" "Installation des paquets système de base..."
  local packages=(curl git ufw fail2ban btrfs-progs htop vim wget ca-certificates gnupg software-properties-common)
  for pkg in "${packages[@]}"; do
    check_and_execute "FOUNDATION" "dpkg -s $pkg" "apt-get" "install" "-y" "$pkg"
  done
  setup_snapper
  create_snapshot "Fondation Système Installée" "post"
  log "SUCCESS" "FOUNDATION" "Paquets de base installés."
}

configure_security() {
  $SKIP_FIREWALL && { log "INFO" "SECURITY" "Configuration pare-feu désactivée"; return; }
  
  log "INFO" "SECURITY" "Configuration de la sécurité..."
  create_snapshot "Pré-configuration sécurité" "pre"

  execute_cmd "SECURITY" ufw --force reset
  execute_cmd "SECURITY" ufw default deny incoming
  execute_cmd "SECURITY" ufw default allow outgoing

  for rule in "${UFW_RULES[@]}"; do
    local ufw_cmd=("ufw" "$rule")
    local check_pattern="${rule%% *}"  # Premier mot de la règle
    
    if ! ufw status | grep -q "$check_pattern"; then
      execute_cmd "SECURITY" "${ufw_cmd[@]}"
    else
      log "INFO" "SECURITY" "Règle existante: ${rule}"
    fi
  done

  check_and_execute "SECURITY" "ufw status | grep -q 'Status: active'" "ufw" "--force" "enable"
  check_and_execute "SECURITY" "systemctl is-enabled fail2ban" "systemctl" "enable" "--now" "fail2ban"

  create_snapshot "Post-configuration sécurité" "post"
  log "SUCCESS" "SECURITY" "Sécurité configurée."
}

install_docker() {
  log "INFO" "DOCKER" "Installation de Docker..."
  if command -v docker &>/dev/null; then
    log "INFO" "DOCKER" "Docker déjà installé - vérification groupe"
    check_and_execute "DOCKER" "getent group docker | grep -q \"\b${MAIN_USER}\b\"" "usermod" "-aG" "docker" "$MAIN_USER"
    return
  fi
  
  create_snapshot "Pré-installation Docker" "pre"

  local gpg_keyring="/etc/apt/keyrings/docker.gpg"
  execute_cmd "DOCKER" install -m 0755 -d "/etc/apt/keyrings"
  check_and_execute "DOCKER" "test -f $gpg_keyring" \
    "bash" "-c" "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o $gpg_keyring"
  execute_cmd "DOCKER" chmod a+r "$gpg_keyring"

  local docker_list="/etc/apt/sources.list.d/docker.list"
  local arch repo_line
  arch=$(dpkg --print-architecture)
  repo_line="deb [arch=$arch signed-by=$gpg_keyring] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
  check_and_execute "DOCKER" "grep -Fq 'download.docker.com' '$docker_list' 2>/dev/null" \
    "bash" "-c" "echo '$repo_line' > '$docker_list'"

  execute_cmd "DOCKER" apt-get -qq update
  local docker_packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  for pkg in "${docker_packages[@]}"; do
    check_and_execute "DOCKER" "dpkg -s $pkg" "apt-get" "install" "-y" "$pkg"
  done

  execute_cmd "DOCKER" usermod -aG docker "$MAIN_USER"
  check_and_execute "DOCKER" "systemctl is-enabled docker.service" "systemctl" "enable" "--now" "docker.service"
  check_and_execute "DOCKER" "systemctl is-enabled containerd.service" "systemctl" "enable" "--now" "containerd.service"

  create_snapshot "Post-installation Docker" "post"
  log "SUCCESS" "DOCKER" "Docker installé."
}

finalize_system() {
  log "INFO" "FINALIZE" "Finalisation du système..."
  create_snapshot "Pré-finalisation" "pre"
  execute_cmd "FINALIZE" apt-get -qq upgrade -y
  execute_cmd "FINALIZE" apt-get -qq autoremove -y
  execute_cmd "FINALIZE" apt-get -qq autoclean
  create_snapshot "Système Prêt" "post"
  log "SUCCESS" "FINALIZE" "Système finalisé."
}

print_summary() {
  log "INFO" "SUMMARY" "=== RÉSUMÉ DE L'INSTALLATION (${SCRIPT_VERSION}) ==="
  log "INFO" "SUMMARY" "✓ Fondation système installée et sécurisée."
  log "INFO" "SUMMARY" "✓ Docker et son écosystème sont prêts."
  $SNAPPER_ENABLED && log "INFO" "SUMMARY" "✓ Snapper actif pour les snapshots"
  log "INFO" "SUMMARY" "-------------------------------------------"
  log "INFO" "SUMMARY" "ACTIONS POST-INSTALLATION:"
  log "INFO" "SUMMARY" "1. Déconnexion/Reconnexion requise pour les permissions Docker"
  log "INFO" "SUMMARY" "2. Redémarrage recommandé: sudo reboot"
  log "INFO" "SUMMARY" "-------------------------------------------"
  log "INFO" "SUMMARY" "Log complet: ${LOG_FILE}"
}

# --- GESTION DES ARGUMENTS ---

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        log "INFO" "SYSTEM" "Mode dry-run activé"
        shift
        ;;
      --user)
        if [[ -z "${2:-}" ]]; then
          log "ERROR" "ARGUMENT" "--user nécessite un nom d'utilisateur"
          exit 1
        fi
        MAIN_USER="$2"
        log "INFO" "SYSTEM" "Utilisateur principal: $MAIN_USER"
        shift 2
        ;;
      --no-snapper)
        SKIP_SNAPPER=true
        log "INFO" "SYSTEM" "Snapper désactivé"
        shift
        ;;
      --skip-firewall)
        SKIP_FIREWALL=true
        log "INFO" "SYSTEM" "Configuration pare-feu désactivée"
        shift
        ;;
      --help)
        echo "Usage: $0 [OPTIONS]"
        echo "  --dry-run         Mode simulation"
        echo "  --user USER       Définir l'utilisateur principal"
        echo "  --no-snapper      Désactiver Snapper"
        echo "  --skip-firewall   Ignorer la configuration UFW"
        echo "  --help            Afficher cette aide"
        exit 0
        ;;
      *)
        log "ERROR" "ARGUMENT" "Option invalide: $1 (utilisez --help)"
        exit 1
        ;;
    esac
  done
}

# --- POINT D'ENTRÉE ---
main() {
  init_logging
  parse_arguments "$@"
  log "INFO" "SYSTEM" "Démarrage Server Init ${SCRIPT_VERSION}..."
  
  preflight_checks
  install_system_foundation
  configure_security
  install_docker
  finalize_system
  print_summary

  log "SUCCESS" "SYSTEM" "Installation terminée avec succès!"
}

main "$@"