#!/usr/bin/env bash
#===================================================================================
#== DEBIAN/UBUNTU SERVER INIT - V3.0 (Final, Corrected & ShellCheck Ready)        ==
#===================================================================================
# Description: Script de post-installation idempotent pour serveurs Debian/Ubuntu.
#              Conçu pour être testé de manière fiable par un harnais automatisé.
#
# Auteur: sidix & Gemini
# Statut: VERSION FINALE DE PRODUCTION
#===================================================================================

set -euo pipefail
IFS=$'\n\t'
trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

# --- CONSTANTES ---
readonly SCRIPT_VERSION="v3.0"
readonly LOG_FILE="/var/log/server-init-${SCRIPT_VERSION}.log"

# --- CONFIGURATION (modifiable via arguments) ---
MAIN_USER="sidix"
DRY_RUN=false
SNAPPER_CONFIG_NAME="root"
SNAPPER_ENABLED=false
REQUIRED_BTRFS=false
SKIP_FIREWALL=false
SKIP_SNAPPER=false

readonly UFW_RULES=(
  "limit 22/tcp comment 'SSH with rate-limiting'"
  "allow http"
  "allow https"
  "allow 5678/tcp comment 'n8n'"
  "allow 9443/tcp comment 'Portainer'"
)

# --- FONCTIONS UTILITAIRES ---

init_logging() {
  touch "$LOG_FILE"
  chmod 640 "$LOG_FILE"
  chown root:adm "$LOG_FILE"
}

log() {
  local level="$1"
  local context="$2"
  local message="$3"
  local timestamp
  timestamp=$(date --iso-8601=seconds)
  # Écrit sur stdout (pour le harnais de test) et dans le fichier de log local.
  printf "[%s] %-8s %-12s %s\n" "$timestamp" "$level" "$context" "$message" | tee -a "$LOG_FILE"
}

error_handler() {
  local exit_code="$1"
  local line_no="$2"
  local command="$3"
  log "ERROR" "SYSTEM" "Erreur fatale à la ligne $line_no (code: $exit_code) - Commande: '$command'"
  exit "$exit_code"
}

execute_cmd() {
  local context="$1"
  shift
  # Déclare explicitement comme un tableau pour gérer les arguments avec espaces
  local -a cmd_array=("$@")

  if $DRY_RUN; then
    log "DRYRUN" "$context" "Commande simulée : ${cmd_array[*]}"
    return 0
  fi

  log "INFO" "$context" "Exécution : ${cmd_array[*]}"
  if "${cmd_array[@]}"; then
    return 0
  else
    local exit_code=$?
    log "ERROR" "$context" "La commande a échoué avec le code $exit_code : ${cmd_array[*]}"
    return $exit_code
  fi
}

check_and_execute() {
  local context="$1"
  local check_cmd="$2"
  shift 2
  local -a exec_cmd_array=("$@")

  if eval "$check_cmd" &>/dev/null; then
    log "INFO" "$context" "Déjà configuré (vérification : '$check_cmd')"
    return 0
  fi
  # Expansion correcte du tableau pour préserver les arguments
  execute_cmd "$context" "${exec_cmd_array[@]}"
}

# --- VERIFICATIONS SYSTEME ---

check_root() {
  if [[ $EUID -ne 0 ]]; then
    log "ERROR" "PREFLIGHT" "Ce script doit être exécuté avec les privilèges root."
    exit 1
  fi
}

# --- GESTION SNAPPER ---

setup_snapper() {
  if $SKIP_SNAPPER; then
      log "INFO" "SNAPPER" "Installation de Snapper ignorée (option --no-snapper)."
      return
  fi

  if [[ $(findmnt -n -o FSTYPE /) != "btrfs" ]]; then
    log "WARN" "SNAPPER" "Le système de fichiers racine n'est pas BTRFS. Snapper ne sera pas configuré."
    if $REQUIRED_BTRFS; then log "ERROR" "SNAPPER" "BTRFS est requis mais non détecté."; exit 1; fi
    return
  fi
  
  SNAPPER_ENABLED=true
  log "INFO" "SNAPPER" "Configuration de Snapper pour les snapshots système..."
  
  check_and_execute "SNAPPER" "dpkg -s snapper" "apt-get" "install" "-y" "snapper"
  
  if ! snapper list-configs | grep -q "^${SNAPPER_CONFIG_NAME}\$"; then
    execute_cmd "SNAPPER" snapper -c "${SNAPPER_CONFIG_NAME}" create-config /
    execute_cmd "SNAPPER" snapper -c "${SNAPPER_CONFIG_NAME}" set-config "TIMELINE_CREATE=yes"
    execute_cmd "SNAPPER" snapper -c "${SNAPPER_CONFIG_NAME}" set-config "TIMELINE_CLEANUP=yes"
  fi

  check_and_execute "SNAPPER" "systemctl is-enabled snapper-timeline.timer" "systemctl" "enable" "--now" "snapper-timeline.timer"
  check_and_execute "SNAPPER" "systemctl is-enabled snapper-cleanup.timer" "systemctl" "enable" "--now" "snapper-cleanup.timer"

  log "SUCCESS" "SNAPPER" "Snapper est configuré et actif."
}

create_snapshot() {
  if ! $SNAPPER_ENABLED || $DRY_RUN; then
    log "DRYRUN" "SNAPSHOT" "Snapshot simulé : $1"
    return
  fi

  local description="$1"
  local type="${2:-}" # 'pre' ou 'post'
  
  log "INFO" "SNAPSHOT" "Création d'un snapshot : $description"
  execute_cmd "SNAPSHOT" snapper -c "$SNAPPER_CONFIG_NAME" create ${type:+--type "$type"} --description "$description"
}

# --- ÉTAPES D'INSTALLATION ---

preflight_checks() {
  log "INFO" "PREFLIGHT" "Lancement des vérifications préalables..."
  check_root

  if ! id -u "$MAIN_USER" &>/dev/null; then
    log "WARN" "PREFLIGHT" "L'utilisateur '$MAIN_USER' n'existe pas. Création..."
    getent group sudo &>/dev/null || groupadd sudo
    execute_cmd "PREFLIGHT" useradd -m -s /bin/bash -G sudo "$MAIN_USER"
    log "INFO" "PREFLIGHT" "Utilisateur '$MAIN_USER' créé. Pensez à définir son mot de passe avec 'passwd $MAIN_USER'."
  fi

  log "INFO" "PREFLIGHT" "Mise à jour des listes de paquets..."
  execute_cmd "PREFLIGHT" apt-get -qq update
  log "SUCCESS" "PREFLIGHT" "Vérifications terminées."
}

install_system_foundation() {
  log "INFO" "FOUNDATION" "Installation des paquets système de base..."
  local -a packages=("curl" "wget" "git" "ufw" "fail2ban" "btrfs-progs" "htop" "vim" "ca-certificates" "gnupg" "software-properties-common")
  
  for pkg in "${packages[@]}"; do
    check_and_execute "FOUNDATION" "dpkg -s $pkg" "apt-get" "install" "-y" "$pkg"
  done
  
  log "SUCCESS" "FOUNDATION" "Paquets de base installés et vérifiés."
}

configure_security() {
  if $SKIP_FIREWALL; then
      log "INFO" "SECURITY" "Configuration du pare-feu ignorée (option --skip-firewall)."
      return
  fi
  
  log "INFO" "SECURITY" "Configuration de la sécurité (UFW & Fail2ban)..."
  create_snapshot "Pré-configuration sécurité" "pre"
  
  execute_cmd "SECURITY" ufw --force reset
  execute_cmd "SECURITY" ufw default deny incoming
  execute_cmd "SECURITY" ufw default allow outgoing

  for rule in "${UFW_RULES[@]}"; do
    # CORRECTION SC2086 : La méthode la plus sûre et la plus propre.
    # On utilise 'read -ra' pour découper la chaîne en un tableau d'arguments.
    # C'est la seule façon de gérer correctement les arguments contenant des espaces.
    local -a rule_args
    IFS=' ' read -ra rule_args <<< "$rule"
    
    # La vérification se fait sur les deux premiers éléments (ex: "limit 22/tcp")
    local check_pattern="${rule_args[0]} ${rule_args[1]}"
    
    if ! ufw status verbose | grep -qF "$check_pattern"; then
        # On passe le tableau d'arguments, ce qui préserve les guillemets et les espaces.
        execute_cmd "SECURITY" ufw "${rule_args[@]}"
    else
        log "INFO" "SECURITY" "Règle UFW déjà existante pour '${check_pattern}'"
    fi
  done

  check_and_execute "SECURITY" "ufw status | grep -q 'Status: active'" ufw --force enable
  check_and_execute "SECURITY" "systemctl is-enabled fail2ban" systemctl enable --now fail2ban

  create_snapshot "Post-configuration sécurité" "post"
  log "SUCCESS" "SECURITY" "Sécurité de base configurée."
}

install_docker() {
  log "INFO" "DOCKER" "Installation de Docker et de ses outils..."
  create_snapshot "Pré-installation Docker" "pre"

  getent group docker &>/dev/null || execute_cmd "DOCKER" groupadd docker

  local docker_keyring="/etc/apt/keyrings/docker.gpg"
  if [[ ! -f "$docker_keyring" ]]; then
    execute_cmd "DOCKER" install -m 0755 -d "/etc/apt/keyrings"
    execute_cmd "DOCKER" bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o $docker_keyring"
    execute_cmd "DOCKER" chmod a+r "$docker_keyring"
    execute_cmd "DOCKER" bash -c "echo \"deb [arch=$(dpkg --print-architecture) signed-by=$docker_keyring] https://download.docker.com/linux/debian $(lsb_release -cs) stable\" > /etc/apt/sources.list.d/docker.list"
    execute_cmd "DOCKER" apt-get -qq update
  fi

  local -a docker_packages=("docker-ce" "docker-ce-cli" "containerd.io" "docker-compose-plugin")
  for pkg in "${docker_packages[@]}"; do
    check_and_execute "DOCKER" "dpkg -s $pkg" "apt-get" "install" "-y" "$pkg"
  done

  check_and_execute "DOCKER" "getent group docker | grep -q \"\b${MAIN_USER}\b\"" "usermod" "-aG" "docker" "$MAIN_USER"
  
  create_snapshot "Post-installation Docker" "post"
  log "SUCCESS" "DOCKER" "Docker et son écosystème sont prêts"
}

finalize_system() {
  log "INFO" "FINALIZE" "Finalisation du système..."
  
  execute_cmd "FINALIZE" apt-get -y autoremove --purge
  execute_cmd "FINALIZE" apt-get -y autoclean
  execute_cmd "FINALIZE" apt-get -y upgrade

  log "SUCCESS" "FINALIZE" "Système finalisé."
}

print_summary() {
  log "INFO" "SUMMARY" "=== RÉSUMÉ DE L'INSTALLATION (${SCRIPT_VERSION}) ==="
  log "INFO" "SUMMARY" "✓ Fondation système installée."
  $SKIP_FIREWALL || log "INFO" "SUMMARY" "✓ Sécurité de base (UFW, Fail2ban) configurée."
  log "INFO" "SUMMARY" "✓ Docker et son écosystème sont prêts."
  $SNAPPER_ENABLED && log "INFO" "SUMMARY" "✓ Snapper est actif pour les snapshots."
  log "INFO" "SUMMARY" "----------------------------------------------------"
  log "INFO" "SUMMARY" "ACTIONS POST-INSTALLATION IMPORTANTES :"
  log "INFO" "SUMMARY" "1. Une DÉCONNEXION/RECONNEXION est requise pour que l'utilisateur '${MAIN_USER}' puisse utiliser Docker sans sudo."
  log "INFO" "SUMMARY" "2. Un redémarrage est fortement recommandé : sudo reboot"
  log "INFO" "SUMMARY" "3. SÉCURITÉ SSH (Action Manuelle Recommandée) :"
  log "INFO" "SUMMARY" "   Si vous utilisez des clés SSH, désactivez l'authentification par mot de passe avec :"
  log "INFO" "SUMMARY" "   'sudo sed -i 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && sudo systemctl restart ssh'"
  log "INFO" "SUMMARY" "----------------------------------------------------"
  log "INFO" "SUMMARY" "Log complet de cette opération : ${LOG_FILE}"
}

# --- GESTION DES ARGUMENTS ---
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift;;
      --user)
        MAIN_USER="${2-}"; 
        [[ -n "$MAIN_USER" ]] || { log "ERROR" "ARGUMENT" "--user nécessite un nom d'utilisateur"; exit 1; }
        shift 2;;
      --no-snapper) SKIP_SNAPPER=true; shift;;
      --skip-firewall) SKIP_FIREWALL=true; shift;;
      --help)
        cat <<EOF
Utilisation: $0 [OPTIONS]
Script d'initialisation de serveur Debian/Ubuntu.

Options:
  --dry-run         Simulation sans effectuer de changements.
  --user USER       Définit l'utilisateur principal (défaut: sidix).
  --no-snapper      Ignore l'installation et la configuration de Snapper.
  --skip-firewall   Ignore la configuration du pare-feu UFW.
  --help            Affiche cette aide.
EOF
        exit 0;;
      *) log "ERROR" "ARGUMENT" "Option invalide: $1"; exit 1;;
    esac
  done
}

# --- POINT D'ENTRÉE ---
main() {
  init_logging
  
  parse_arguments "$@"
  
  log "INFO" "SYSTEM" "Démarrage de Server Init ${SCRIPT_VERSION}..."
  
  preflight_checks
  install_system_foundation
  setup_snapper
  configure_security
  install_docker
  finalize_system
  print_summary

  log "SUCCESS" "SYSTEM" "Installation terminée avec succès!"
}

main "$@"