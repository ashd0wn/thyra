@echo off
chcp 65001 >nul
echo.
echo  Thyra — Push initial vers GitHub
echo  ===================================
echo.

:: Vérifie que git est installé
where git >nul 2>&1
if errorlevel 1 (
    echo  ERREUR : Git n'est pas installé.
    echo  Télécharge-le sur https://git-scm.com/download/win
    pause
    exit /b 1
)

:: Config identité (modifie si besoin)
git config --global user.name "ashd0wn"
git config --global user.email "ton@email.com"

:: Mémorise les credentials pour ne pas les retaper
git config --global credential.helper manager

:: Init du repo local
git init
git checkout -b main

:: Ajout de tous les fichiers
git add .
git commit -m "feat: initial release — Thyra bare-metal digital signage"

:: Remote GitHub
git remote add origin https://github.com/ashd0wn/thyra.git

:: Push
git push -u origin main

echo.
echo  Termine ! Vérifie sur https://github.com/ashd0wn/thyra
echo.
pause