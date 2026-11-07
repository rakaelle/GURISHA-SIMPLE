(() => {
  let deferredInstallPrompt = null;

  // Le navigateur prépare sa propre fenêtre d'installation.
  window.addEventListener('beforeinstallprompt', (event) => {
    event.preventDefault();
    deferredInstallPrompt = event;
    const button = document.getElementById('gurishaInstallHelp');
    if (button) {
      button.textContent = 'Installer GURISHA';
      button.disabled = false;
    }
  });

  window.addEventListener('appinstalled', () => {
    deferredInstallPrompt = null;
    const banner = document.getElementById('gurishaInstallNotice');
    if (banner) banner.hidden = true;
  });

  function checkInstallStatus() {
    const role = window.GURISHA_ROLE;
    const installed = window.matchMedia('(display-mode: standalone)').matches ||
      window.navigator.standalone === true;
    const banner = document.getElementById('gurishaInstallNotice');
    if (!banner || !role) return;
    if (['cashier', 'manager', 'gestionnaire'].includes(role) && !installed) {
      banner.hidden = false;
    }
  }

  document.addEventListener('DOMContentLoaded', () => {
    const help = document.getElementById('gurishaInstallHelp');
    const later = document.getElementById('gurishaInstallLater');
    const iphone = document.getElementById('gurishaInstallIphone');

    if (help) {
      help.addEventListener('click', async () => {
        // Lance directement la boîte de dialogue native Android/Chrome.
        if (deferredInstallPrompt) {
          deferredInstallPrompt.prompt();
          const choice = await deferredInstallPrompt.userChoice;
          deferredInstallPrompt = null;
          if (choice && choice.outcome === 'accepted') {
            const banner = document.getElementById('gurishaInstallNotice');
            if (banner) banner.hidden = true;
          }
          return;
        }

        // Aucun navigateur ne permet de forcer l'installation sans son autorisation.
        alert('La fenêtre d’installation directe n’est pas disponible dans ce navigateur. Ouvrez GURISHA dans Chrome sur Android. Sur iPhone, l’ajout à l’écran d’accueil doit être confirmé depuis Safari.');
      });
    }

    if (iphone) {
      iphone.addEventListener('click', () => {
        alert('Sur iPhone, Apple exige une confirmation : ouvrez GURISHA dans Safari, appuyez sur Partager, puis « Sur l’écran d’accueil » et « Ajouter ».');
      });
    }

    if (later) {
      later.addEventListener('click', () => {
        const banner = document.getElementById('gurishaInstallNotice');
        if (banner) banner.hidden = true;
      });
    }

    const wait = window.setInterval(() => {
      if (window.GURISHA_ROLE) {
        window.clearInterval(wait);
        checkInstallStatus();
      }
    }, 250);
  });
})();