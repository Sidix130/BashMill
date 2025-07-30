# --- SECTION 1 : NETTOYAGE COMPLET ---
log_info() { printf "\033[1;33m[INFO]\033[0m %s\n" "$1"; }
log_success() { printf "\033[0;32m[SUCCÈS]\033[0m %s\n" "$1"; }

log_info "Début du nettoyage complet de l'environnement de test LXD..."

# Étape 1 : Suppression de tous les conteneurs existants (arrêtés ou non)
if lxc list debian-test-rig -c n --format csv | grep -q 'debian-test-rig'; then
  log_info "Suppression du conteneur de test 'debian-test-rig'..."
  lxc delete debian-test-rig --force
  sleep 2 # Laisse le temps au système de traiter la suppression
else
  log_info "Aucun conteneur de test 'debian-test-rig' trouvé. C'est bon."
fi

# --- SECTION 2 : RECONFIGURATION DU STOCKAGE ---
log_info "Reconfiguration du pool de stockage pour BTRFS..."

# Étape 2 : Détacher le disque du profil (devrait marcher maintenant que le conteneur est supprimé)
lxc profile device remove default root || true

# Étape 3 : Supprimer l'ancien pool de stockage
sudo lxc storage delete default || true

# Étape 4 : Créer le nouveau pool de stockage BTRFS
sudo lxc storage create default btrfs

# Étape 5 : Attacher le nouveau pool au profil par défaut
lxc profile device add default root disk path=/ pool=default

# --- SECTION 3 : VÉRIFICATION FINALE ---
log_info "Vérification de la nouvelle configuration de stockage..."
lxc storage list

log_success "Environnement LXD reconfiguré avec succès pour BTRFS."
