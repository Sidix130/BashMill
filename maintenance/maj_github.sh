#!/usr/bin/env bash

# Placez-vous dans le bon dossier (au cas où)
cd ~/dev/script/BashMill

# Vérifiez ce qui a changé
git status

# Ajoutez tous les changements
git add .

# Créez le commit de sauvegarde
git commit -m "feat(testing): Finalize scripts before first successful run"

# Poussez vers GitHub
git push

echo "✅ Votre projet BashMill a été sauvegardé avec succès sur GitHub."