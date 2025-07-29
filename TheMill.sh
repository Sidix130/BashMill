#!/usr/bin/env bash
#===================================================================================
#== BANC DE TEST AUTOMATISÉ LXD -                                                 ==
#===================================================================================
# Description: Framework de test générique pour scripts d'infrastructure via LXD.
#              Conçu pour la robustesse, la flexibilité et un débogage avancé.
#
# Auteur: sidix & Gemini
# Statut: VERSION FINALE DE PRODUCTION
#===================================================================================

set -euo pipefail
IFS=$'\n\t'

# --- CONFIGURATION ET CONSTANTES ---
readonly SCRIPT_VERSION="v4.3"
readonly HOME_DIR="${HOME}"
readonly CONTAINER_NAME="debian-test-rig"
readonly IMAGE="images:debian/12"
readonly USER_NAME="admin"

SCRIPT_PATH_HOST="${HOME_DIR}/dev/script/debian-server-init.sh"
MAX_TEST_ATTEMPTS=2
TEST_DELAY=10
GLOBAL_TIMEOUT=900
INTERACTIVE=false

readonly REQUIRED_PATTERNS=(
  "Installation terminée avec succès"
  "Docker et son écosystème sont prêts"
)

readonly RED='\033[0;31m'; readonly GREEN='\033[0;32m'; readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'; readonly NC='\033[0m'

LOG_DIR=""; LOG_FILE=""

# --- FONCTIONS ---

init_logging() {
    local log_dir="${HOME_DIR}/lxd-test-logs"
    [[ -d "${HOME_DIR}/dev/script/test_LXD/log" ]] && log_dir="${HOME_DIR}/dev/script/test_LXD/log"
    mkdir -p "${log_dir}"
    LOG_DIR="${log_dir}"
    LOG_FILE="${LOG_DIR}/test-$(basename "${SCRIPT_PATH_HOST}")-$(date +%Y%m%d-%H%M%S).log"
    touch "${LOG_FILE}" && chmod 600 "${LOG_FILE}"
    echo "Début des logs - $(date)" > "${LOG_FILE}"
}

log_error()   { printf "${RED}[ERREUR]${NC} %s\n" "$1" | tee -a "${LOG_FILE}" >&2; }
log_warn()    { printf "${YELLOW}[ATTENTION]${NC} %s\n" "$1" | tee -a "${LOG_FILE}"; }
log_info()    { printf "${YELLOW}[INFO]${NC} %s\n" "$1" | tee -a "${LOG_FILE}"; }
log_success(){ printf "${GREEN}[SUCCÈS]${NC} %s\n" "$1" | tee -a "${LOG_FILE}"; }
log_step()   { printf "\n${CYAN}--- %s ---${NC}\n" "$1" | tee -a "${LOG_FILE}"; }

cleanup() {
    local mode=${1:-on_success}
    if ! lxc info "${CONTAINER_NAME}" &>/dev/null; then return; fi
    
    if [[ "$mode" == "on_failure" ]]; then
        log_warn "Conservation du conteneur pour débogage: ${CONTAINER_NAME}"
        local diff_file="${LOG_DIR}/diff_${CONTAINER_NAME}_$(date +%H%M%S).txt"
        log_info "Génération du rapport de modifications: ${diff_file}"
        lxc diff "$CONTAINER_NAME" initial > "$diff_file" 2>>"${LOG_FILE}" || true
        log_info "Commandes d'inspection:"
        log_info "  Accès shell: lxc exec ${CONTAINER_NAME} -- bash"
        log_info "  Voir logs: cat ${LOG_FILE}"
    else
        log_info "Nettoyage du conteneur: ${CONTAINER_NAME}"
        if ! lxc delete "${CONTAINER_NAME}" --force &>>"${LOG_FILE}"; then
            sleep 2
            lxc delete "${CONTAINER_NAME}" --force &>>"${LOG_FILE}" || 
                log_error "Échec critique de suppression - conteneur conservé: ${CONTAINER_NAME}"
        fi
    fi
}

trap_cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        cleanup on_failure
    elif [[ "$INTERACTIVE" == true ]]; then
        log_info "Mode interactif - conteneur conservé: ${CONTAINER_NAME}"
        log_info "Accès shell: lxc exec ${CONTAINER_NAME} -- bash"
    else
        cleanup on_success
    fi
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --script-path)  SCRIPT_PATH_HOST="$2"; shift 2;;
            --max-attempts) MAX_TEST_ATTEMPTS="$2"; 
                            [[ "$MAX_TEST_ATTEMPTS" =~ ^[0-9]+$ ]] || { log_error "--max-attempts nécessite un entier"; exit 1; }
                            shift 2;;
            --delay)        TEST_DELAY="$2"; 
                            [[ "$TEST_DELAY" =~ ^[0-9]+$ ]] || { log_error "--delay nécessite un entier (secondes)"; exit 1; }
                            shift 2;;
            --timeout)      GLOBAL_TIMEOUT="$2"; 
                            [[ "$GLOBAL_TIMEOUT" =~ ^[0-9]+$ ]] || { log_error "--timeout nécessite un entier (secondes)"; exit 1; }
                            shift 2;;
            --interactive)  INTERACTIVE=true; shift;;
            --help)         show_help; exit 0;;
            *)              log_error "Option invalide: $1"; show_help; exit 1;;
        esac
    done
}

show_help() {
    cat <<EOF
Utilisation: $0 [OPTIONS]
Framework de test pour scripts d'infrastructure via LXD

Options:
  --script-path CHEMIN  Chemin du script à tester (défaut: ${SCRIPT_PATH_HOST})
  --max-attempts N      Tentatives max (défaut: ${MAX_TEST_ATTEMPTS})
  --delay T             Délai entre tentatives en secondes (défaut: ${TEST_DELAY})
  --timeout S           Timeout global par exécution (défaut: ${GLOBAL_TIMEOUT})
  --interactive         Conserve le conteneur après exécution
  --help                Affiche cette aide
EOF
}

check_requirements() {
    log_step "Vérification des prérequis"
    local missing=0
    
    if ! id -nG "$USER" | grep -qw lxd; then
        log_error "L'utilisateur '$USER' n'est pas dans le groupe lxd"
        log_info "Solution: sudo usermod -aG lxd \$USER && newgrp lxd"
        missing=1
    fi
    
    for cmd in lxc dirname basename timeout; do 
        if ! command -v "$cmd" &>/dev/null; then 
            log_error "Commande manquante: $cmd"
            missing=1 
        fi
    done
    
    [[ ! -f "$SCRIPT_PATH_HOST" ]] && {
        log_error "Script introuvable: $SCRIPT_PATH_HOST"
        missing=1
    }
    
    lxc remote list | grep -q 'https://images.linuxcontainers.org' || {
        log_warn "Le remote 'images' n'est pas configuré. Ajout automatique..."
        lxc remote add images https://images.linuxcontainers.org --protocol=simplestreams --public &>>"${LOG_FILE}" || 
            log_error "Échec de configuration du remote images"
    }
    
    [[ $missing -eq 0 ]] && log_success "Prérequis validés" || exit 1
}

setup_container() {
    local script_basename=$(basename "${SCRIPT_PATH_HOST}")
    local script_dir_host=$(dirname "${SCRIPT_PATH_HOST}")
    local script_path_guest="/opt/scripts/${script_basename}"
    
    log_step "Initialisation du conteneur"
    cleanup on_success
    sleep 1

    if lxc info "${CONTAINER_NAME}" &>/dev/null; then
        log_warn "Un conteneur existant a été détecté. Suppression forcée..."
        lxc delete "${CONTAINER_NAME}" --force &>>"${LOG_FILE}" || {
            log_error "Échec de suppression du conteneur existant"
            exit 1
        }
        sleep 2
    fi

    log_info "Création du conteneur: ${CONTAINER_NAME}"
    lxc launch "${IMAGE}" "${CONTAINER_NAME}" &>>"${LOG_FILE}"
    
    log_info "Vérification de la connectivité réseau"
    local network_ok=false
    for i in {1..5}; do
        if lxc exec "${CONTAINER_NAME}" -- apt-get -qq update &>/dev/null; then
            network_ok=true
            break
        fi
        log_info "Attente réseau ($i/5)..."
        sleep 3
    done
    $network_ok && log_success "Connectivité réseau validée" || {
        log_error "Échec de connexion aux dépôts APT"
        exit 1
    }

    log_info "Montage du script: ${script_dir_host} → /opt/scripts"
    lxc config device remove "${CONTAINER_NAME}" scripts 2>/dev/null || true
    lxc config device add "${CONTAINER_NAME}" scripts disk source="${script_dir_host}" path="/opt/scripts"
    
    log_info "Vérification de l'accès au script"
    lxc exec "${CONTAINER_NAME}" -- test -f "${script_path_guest}" || { 
        log_error "Échec du montage: ${script_path_guest} non trouvé"
        exit 1
    }
    
    log_info "Création du snapshot initial"
    lxc snapshot "${CONTAINER_NAME}" initial &>>"${LOG_FILE}" || {
        log_error "Échec de la création du snapshot"
        exit 1
    }
    
    log_success "Environnement de test prêt"
}

validate_output() {
    local output="$1" ok=1
    log_info "Analyse des résultats"
    for pat in "${REQUIRED_PATTERNS[@]}"; do
        if grep -qF "$pat" <<<"$output"; then 
            log_info "  [✓] '$pat' détecté"
        else 
            log_warn "  [✗] '$pat' manquant"
            ok=0
        fi
    done
    return $ok
}

run_test_cycle() {
    local attempt=1 success=false
    local script_basename=$(basename "${SCRIPT_PATH_HOST}")
    local script_path_guest="/opt/scripts/${script_basename}"
    
    while (( attempt <= MAX_TEST_ATTEMPTS )); do
        log_step "TENTATIVE #${attempt}/${MAX_TEST_ATTEMPTS}"
        if (( attempt > 1 )); then
            log_info "Restauration du snapshot initial"
            lxc restore "${CONTAINER_NAME}" initial &>>"${LOG_FILE}" 
            sleep 2
        fi
        
        local tmp_file=$(mktemp)
        local exit_code
        
        set +e
        log_info "Exécution du script avec timeout: ${GLOBAL_TIMEOUT}s"
        timeout "${GLOBAL_TIMEOUT}" lxc exec "${CONTAINER_NAME}" -- \
            bash "${script_path_guest}" --user "$USER_NAME" >"$tmp_file" 2>&1
        exit_code=$?
        set -e
        
        local output=$(<"$tmp_file")
        rm -f "$tmp_file"
        echo "$output" >>"${LOG_FILE}"

        case $exit_code in
            0)  if validate_output "$output"; then
                    success=true
                    break
                else
                    log_error "Sortie validée mais motifs manquants"
                fi
                ;;
            124) log_error "TIMEOUT: Le script a dépassé ${GLOBAL_TIMEOUT}s"
                 log_info "Augmentez --timeout si nécessaire";;
            *)  log_error "ERREUR: Code de sortie $exit_code";;
        esac
        
        log_info "Extrait des logs:"
        printf "%.80s\n" "=================================================================================="
        tail -n 20 <<<"$output" | sed 's/^/  | /'
        printf "%.80s\n" "=================================================================================="
        log_info "Log complet disponible: ${LOG_FILE}"
        
        ((attempt++))
        if (( attempt <= MAX_TEST_ATTEMPTS )); then
            log_info "Nouvelle tentative dans ${TEST_DELAY}s..."
            sleep "$TEST_DELAY"
        fi
    done
    
    $success && return 0 || return 1
}

# --- POINT D'ENTRÉE ---
main() {
    parse_arguments "$@"
    init_logging
    trap 'trap_cleanup' EXIT
    
    log_step "BANC DE TEST LXD ${SCRIPT_VERSION}"
    log_info "Script testé: ${SCRIPT_PATH_HOST}"
    log_info "Journal d'exécution: ${LOG_FILE}"
    
    check_requirements
    setup_container
    
    if run_test_cycle; then
        log_success "TEST RÉUSSI"
    else
        log_error "TEST ÉCHOUÉ"
        exit 1
    fi
}

main "$@"