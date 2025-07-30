#!/usr/bin/env bash
#===================================================================================
#== BANC DE TEST AUTOMATISÉ LXD - V4.7 (BTRFS Native Edition)                     ==
#===================================================================================
# Description: Framework de test générique pour scripts d'infrastructure via LXD.
#              Conçu pour la robustesse, la flexibilité et un débogage avancé.
#
# Auteur: sidix & Gemini
# Statut: VERSION FINALE DE PRODUCTION
#===================================================================================

# Met le script en mode strict.
set -euo pipefail
IFS=$'\n\t'

# --- CONFIGURATION ET CONSTANTES ---
readonly SCRIPT_VERSION="v4.7"
readonly HOME_DIR="${HOME}"
readonly CONTAINER_NAME="debian-test-rig"
readonly IMAGE="images:debian/12"
readonly USER_NAME="admin"

# Variables modifiables via arguments.
SCRIPT_PATH_HOST="${HOME_DIR}/dev/script/BashMill/TheGrain.sh"
MAX_TEST_ATTEMPTS=2
TEST_DELAY=10
GLOBAL_TIMEOUT=900
INTERACTIVE=false

readonly REQUIRED_PATTERNS=(
  "Installation terminée avec succès"
  "Docker et son écosystème sont prêts"
)

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

LOG_DIR=""
LOG_FILE=""

# --- FONCTIONS ---

init_logging() {
  local log_dir="${HOME_DIR}/lxd-test-logs"
  if [[ -d "${HOME_DIR}/dev/script/BashMill/log" ]]; then
    log_dir="${HOME_DIR}/dev/script/BashMill/log"
  fi
  mkdir -p "${log_dir}"
  LOG_DIR="${log_dir}"
  LOG_FILE="${LOG_DIR}/test-$(basename "${SCRIPT_PATH_HOST}")-$(date +%Y%m%d-%H%M%S).log"
  touch "${LOG_FILE}" && chmod 600 "${LOG_FILE}"
  echo "Début des logs - $(date)" >"${LOG_FILE}"
}

log_error() { printf "${RED}[ERREUR]${NC} %s\n" "$1" | tee -a "${LOG_FILE}" >&2; }
log_warn() { printf "${YELLOW}[ATTENTION]${NC} %s\n" "$1" | tee -a "${LOG_FILE}"; }
log_info() { printf "${YELLOW}[INFO]${NC} %s\n" "$1" | tee -a "${LOG_FILE}"; }
log_success() { printf "${GREEN}[SUCCÈS]${NC} %s\n" "$1" | tee -a "${LOG_FILE}"; }
log_step() { printf "\n${CYAN}--- %s ---${NC}\n" "$1" | tee -a "${LOG_FILE}"; }

cleanup() {
  local mode=${1:-on_success}
  if ! lxc info "${CONTAINER_NAME}" &>/dev/null; then return; fi

  if [[ "$mode" == "on_failure" ]]; then
    log_warn "Le test a échoué. Le conteneur '${CONTAINER_NAME}' est conservé pour le débogage."
    local diff_file
    diff_file="${LOG_DIR}/diff_${CONTAINER_NAME}_$(date +%H%M%S).txt"
    log_info "Génération du rapport de modifications : ${diff_file}"
    lxc diff "$CONTAINER_NAME" initial >"$diff_file" 2>>"${LOG_FILE}" || true
    log_info "Commandes d'inspection utiles :"
    log_info "  Accès shell : lxc exec ${CONTAINER_NAME} -- bash"
  else
    log_info "Nettoyage du conteneur '${CONTAINER_NAME}'..."
    if ! lxc delete "${CONTAINER_NAME}" --force &>>"${LOG_FILE}"; then
      sleep 2
      lxc delete "${CONTAINER_NAME}" --force &>>"${LOG_FILE}" ||
        log_error "Échec critique de la suppression. Le conteneur '${CONTAINER_NAME}' est peut-être toujours présent."
    else
      log_success "Conteneur supprimé."
    fi
  fi
}

trap_cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    cleanup on_failure
  elif [[ "$INTERACTIVE" == true ]]; then
    log_info "Mode interactif : le conteneur '${CONTAINER_NAME}' est conservé."
  else
    cleanup on_success
  fi
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
    --script-path)
      SCRIPT_PATH_HOST="$2"
      shift 2
      ;;
    --max-attempts)
      MAX_TEST_ATTEMPTS="$2"
      [[ "$MAX_TEST_ATTEMPTS" =~ ^[0-9]+$ ]] || {
        log_error "--max-attempts nécessite un entier"
        exit 1
      }
      shift 2
      ;;
    --delay)
      TEST_DELAY="$2"
      [[ "$TEST_DELAY" =~ ^[0-9]+$ ]] || {
        log_error "--delay nécessite un entier (secondes)"
        exit 1
      }
      shift 2
      ;;
    --timeout)
      GLOBAL_TIMEOUT="$2"
      [[ "$GLOBAL_TIMEOUT" =~ ^[0-9]+$ ]] || {
        log_error "--timeout nécessite un entier (secondes)"
        exit 1
      }
      shift 2
      ;;
    --interactive)
      INTERACTIVE=true
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      log_error "Option invalide: $1"
      show_help
      exit 1
      ;;
    esac
  done
}

show_help() {
  cat <<EOF
Utilisation: $0 [OPTIONS]
Framework de test pour scripts d'infrastructure via LXD.

Options:
  --script-path CHEMIN  Chemin du script à tester (défaut: ${SCRIPT_PATH_HOST})
  --max-attempts N      Tentatives max (défaut: ${MAX_TEST_ATTEMPTS})
  --delay T             Délai entre tentatives en secondes (défaut: ${TEST_DELAY})
  --timeout S           Timeout global par exécution en secondes (défaut: ${GLOBAL_TIMEOUT})
  --interactive         Conserve le conteneur après une exécution réussie.
  --help                Affiche cette aide.
EOF
}

check_requirements() {
  log_step "Vérification des prérequis"
  local missing=0

  if ! id -nG "$USER" | grep -qw lxd; then
    log_error "L'utilisateur '$USER' n'est pas dans le groupe lxd."
    missing=1
  fi

  for cmd in lxc dirname basename timeout realpath; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Commande requise manquante : $cmd"
      missing=1
    fi
  done

  if [[ ! -f "$SCRIPT_PATH_HOST" ]]; then
    log_error "Script à tester introuvable : $SCRIPT_PATH_HOST"
    missing=1
  fi

  if [[ $missing -eq 0 ]]; then
    log_success "Prérequis validés."
  else
    exit 1
  fi
}

setup_container() {
  local script_basename
  script_basename=$(basename "${SCRIPT_PATH_HOST}")
  local script_dir_host
  script_dir_host=$(realpath "$(dirname "${SCRIPT_PATH_HOST}")")
  local script_path_guest="/opt/scripts/${script_basename}"

  log_step "Initialisation de l'environnement de test"
  cleanup on_success
  sleep 1

  log_info "Création du conteneur '${CONTAINER_NAME}' avec un volume BTRFS natif..."

  # CORRECTION FINALE : On ne lance plus directement.
  # 1. On crée un volume de stockage BTRFS pour le conteneur.
  # Le '|| true' est une sécurité si le volume existait déjà d'un run précédent mal nettoyé.
  lxc storage volume create default "${CONTAINER_NAME}" &>>"${LOG_FILE}" || true

  # 2. On lance le conteneur EN UTILISANT ce volume.
  # Ceci force le système de fichiers à l'intérieur du conteneur à être BTRFS.
  lxc launch "${IMAGE}" "${CONTAINER_NAME}" --storage default &>>"${LOG_FILE}"

  log_info "Validation de la connectivité réseau..."
  local network_ok=false
  for i in {1..5}; do
    set +e
    if lxc exec "${CONTAINER_NAME}" -- apt-get -qq update &>/dev/null; then
      network_ok=true
      set -e
      break
    fi
    set -e
    log_info "Attente réseau (tentative $i/5)..."
    sleep 3
  done

  if $network_ok; then
    log_success "Connectivité réseau validée."
  else
    log_error "Échec de la connexion aux dépôts APT."
    exit 1
  fi

  log_info "Montage du dossier des scripts : ${script_dir_host} -> /opt/scripts"
  lxc config device add "${CONTAINER_NAME}" scripts disk source="${script_dir_host}" path="/opt/scripts"

  lxc exec "${CONTAINER_NAME}" -- test -f "${script_path_guest}" || {
    log_error "Échec du montage du script."
    exit 1
  }

  log_info "Création du snapshot initial 'initial'..."
  lxc snapshot "${CONTAINER_NAME}" initial &>>"${LOG_FILE}" || {
    log_error "Échec critique de la création du snapshot."
    exit 1
  }

  log_success "Environnement de test prêt."
}

validate_output() {
  local output="$1" ok=1
  log_info "Analyse des résultats de la sortie..."
  for pat in "${REQUIRED_PATTERNS[@]}"; do
    if grep -qF "$pat" <<<"$output"; then
      log_info "  [✓] Motif de succès trouvé : '$pat'"
    else
      log_warn "  [✗] Motif de succès manquant : '$pat'"
      ok=0
    fi
  done
  return $ok
}

run_test_cycle() {
  local attempt=1 success=false
  local script_basename
  script_basename=$(basename "${SCRIPT_PATH_HOST}")
  local script_path_guest="/opt/scripts/${script_basename}"

  while ((attempt <= MAX_TEST_ATTEMPTS)); do
    log_step "Lancement du Test - TENTATIVE #${attempt}/${MAX_TEST_ATTEMPTS}"
    if ((attempt > 1)); then
      log_info "Restauration du conteneur à son état initial..."
      lxc restore "${CONTAINER_NAME}" initial &>>"${LOG_FILE}"
      sleep 2
    fi

    local tmp_file
    tmp_file=$(mktemp)
    local exit_code

    set +e
    log_info "Exécution du script distant avec un timeout de ${GLOBAL_TIMEOUT} secondes..."
    timeout "$GLOBAL_TIMEOUT" lxc exec "${CONTAINER_NAME}" -- \
      bash "${script_path_guest}" --user "$USER_NAME" >"$tmp_file" 2>&1
    exit_code=$?
    set -e

    local output
    output=$(<"$tmp_file")
    rm -f "$tmp_file"
    echo "$output" >>"${LOG_FILE}"

    case $exit_code in
    0)
      if validate_output "$output"; then
        success=true
        break
      else
        log_error "Échec de la validation : Le script s'est terminé sans erreur mais les motifs de succès sont absents."
      fi
      ;;
    124)
      log_error "Échec de l'exécution : TIMEOUT. Le script a dépassé la durée maximale de ${GLOBAL_TIMEOUT}s."
      ;;
    *) log_error "Échec de l'exécution : Le script a retourné un code d'erreur critique : $exit_code." ;;
    esac

    log_info "Extrait des 20 dernières lignes de la sortie pour le diagnostic :"
    printf "%.80s\n" "==================================== LOG TAIL ===================================="
    tail -n 20 <<<"$output" | sed 's/^/  | /'
    printf "%.80s\n" "================================== END LOG TAIL =================================="

    ((attempt++))
    if ((attempt <= MAX_TEST_ATTEMPTS)); then
      log_info "Nouvelle tentative dans ${TEST_DELAY} secondes..."
      sleep "$TEST_DELAY"
    fi
  done

  if $success; then
    return 0
  else
    return 1
  fi
}

# --- POINT D'ENTRÉE ---
main() {
  parse_arguments "$@"
  init_logging
  trap 'trap_cleanup' EXIT

  log_step "BANC DE TEST LXD ${SCRIPT_VERSION}"
  log_info "Script à tester : ${SCRIPT_PATH_HOST}"
  log_info "Journal d'exécution : ${LOG_FILE}"

  check_requirements
  setup_container

  if run_test_cycle; then
    log_success "=== TEST GLOBAL RÉUSSI ==="
  else
    log_error "=== TEST GLOBAL ÉCHOUÉ ==="
    exit 1
  fi
}

main "$@"

