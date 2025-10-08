#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Script: maintenance/git.sh
# Objet : Automatiser un flux Git standard (add -> commit -> pull --rebase -> push)
# Usage : voir la fonction usage() ci-dessous.
# Note  : Ce script n'altère pas l'historique autrement qu'un flux normal Git.
#         Il s'arrête à la moindre erreur (set -euo pipefail) pour éviter des états incohérents.
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

log() {
  # Petite fonction de log avec horodatage
  local level="$1"; shift
  printf "[%s] %-7s %s\n" "$(date --iso-8601=seconds)" "$level" "$*"
}

usage() {
  # Affiche l'aide et les options disponibles
  cat <<EOF
Usage: maintenance/git.sh [options]

Automates common Git sync flow: pull --rebase, add, commit, push.

Options:
  -m, --message MSG   Commit message (default: chore(sync): auto at <timestamp>)
  --no-pull           Skip fetch + pull --rebase
  --no-add            Skip git add -A
  --no-push           Skip git push
  --no-rebase         Use merge instead of rebase when pulling
  -h, --help          Show this help

Examples:
  maintenance/git.sh -m "feat: reorganize structure"
  maintenance/git.sh --no-pull --no-push -m "chore: local snapshot"
EOF
}

commit_msg=""       # Message de commit fourni par l'utilisateur
do_pull=true         # Effectuer fetch + pull (par défaut oui)
do_add=true          # Effectuer git add -A (par défaut oui)
do_push=true         # Effectuer git push (par défaut oui)
use_rebase=true      # Utiliser rebase lors du pull (par défaut oui)

while [[ $# -gt 0 ]]; do
  # Parsing des options de la ligne de commande
  case "$1" in
    -m|--message)
      commit_msg="${2-}"
      [[ -n "$commit_msg" ]] || { log ERROR "--message requires a non-empty value"; exit 1; }
      shift 2;;
    --no-pull) do_pull=false; shift ;;
    --no-add)  do_add=false;  shift ;;
    --no-push) do_push=false; shift ;;
    --no-rebase) use_rebase=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log ERROR "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# Vérifie que l'on est dans un dépôt Git
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log ERROR "Not inside a Git repository."
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"  # Racine du dépôt
cd "$repo_root"                               # On s'y place pour éviter les surprises

current_branch="$(git rev-parse --abbrev-ref HEAD)"  # Branche courante
remote_name="origin"                                  # Remote par défaut

log INFO "Repository: $repo_root (branch: $current_branch)"

if $do_add; then
  # Étape 1 : indexation des changements locaux
  log INFO "Adding all changes (git add -A)..."
  git add -A
fi

# Détermine s'il y a quelque chose à committer (staged et/ou unstaged)
has_staged_changes=true
if git diff --cached --quiet; then has_staged_changes=false; fi

has_unstaged_changes=true
if git diff --quiet; then has_unstaged_changes=false; fi

if $has_staged_changes || $has_unstaged_changes; then
  # Étape 2 : commit des changements si présents
  if [[ -z "$commit_msg" ]]; then
    commit_msg="chore(sync): auto at $(date --iso-8601=seconds)"
  fi
  log INFO "Committing changes: $commit_msg"
  git commit -m "$commit_msg" || log INFO "Nothing to commit after all (possibly empty changes)"
else
  log INFO "No changes detected to commit."
fi

# Étape 3 : Pull (rebase/merge) après le commit local pour éviter l'erreur
#           "modifications non indexées". Le rebase garde un historique propre.
if $do_pull; then
  log INFO "Fetching from $remote_name..."
  git fetch "$remote_name"
  if $use_rebase; then
    log INFO "Pulling with rebase from $remote_name/$current_branch..."
    if ! git pull --rebase "$remote_name" "$current_branch"; then
      log ERROR "Rebase failed. Vous êtes probablement au milieu d'un rebase."
      log ERROR "Diagnostic: exécutez 'git status' pour voir les fichiers en conflit."
      log ERROR "Résolution: corrigez les conflits, puis 'git add <fichiers>' et 'git rebase --continue'."
      log ERROR "Abandon: si nécessaire, 'git rebase --abort' pour revenir à l'état précédent."
      exit 1
    fi
  else
    log INFO "Pulling with merge from $remote_name/$current_branch..."
    if ! git pull "$remote_name" "$current_branch"; then
      log ERROR "Merge failed. Des conflits doivent être résolus."
      log ERROR "Diagnostic: exécutez 'git status' pour voir les fichiers en conflit."
      log ERROR "Résolution: corrigez les conflits, 'git add <fichiers>', puis 'git commit' pour finaliser le merge."
      log ERROR "Abandon: si nécessaire, 'git merge --abort' pour revenir à l'état précédent."
      exit 1
    fi
  fi
fi

if $do_push; then
  # Étape 4 : push vers le remote. Si aucun upstream n'est défini, on le crée.
  if ! git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
    log INFO "Setting upstream to $remote_name/$current_branch"
    git push -u "$remote_name" "$current_branch"
  else
    log INFO "Pushing to $remote_name/$current_branch..."
    git push "$remote_name" "$current_branch"
  fi
fi

log INFO "Done."

