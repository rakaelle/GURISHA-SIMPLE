(() => {
  let deferredInstallPrompt = null;
  window.addEventListener('beforeinstallprompt', (event) => {
    event.preventDefault();
    deferredInstallPrompt = event;
    const button = document.getElementById('gurishaInstallHelp');
    if (button) button.textContent = 'Installer GURISHA';
  });
  window.addEventListener('appinstalled', () => {
    deferredInstallPrompt = null;
    const banner = document.getElementById('gurishaInstallNotice');
    if (banner) banner.hidden = true;
  });
  function checkInstallStatus() {
    const role = window.GURISHA_ROLE;
    const installed = window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
    const banner = document.getElementById('gurishaInstallNotice');
    if (!banner || !role) return;
    if (['cashier', 'manager', 'gestionnaire'].includes(role) && !installed) banner.hidden = false;
  }
  document.addEventListener('DOMContentLoaded', () => {
    const help = document.getElementById('gurishaInstallHelp');
    const later = document.getElementById('gurishaInstallLater');
    const iphone = document.getElementById('gurishaInstallIphone');
    if (help) help.addEventListener('click', async () => {
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
      alert('L’installation directe n’est pas proposée par ce navigateur pour le moment. Sur Android, ouvrez le menu ⋮ puis choisissez « Installer l’application » ou « Ajouter à l’écran d’accueil ». Sur iPhone, utilisez Partager puis « Sur l’écran d’accueil ».');
    });
    if (iphone) iphone.addEventListener('click', () => {
      alert('Pour installer GURISHA sur iPhone :\n1. Ouvrez cette page dans Safari.\n2. Appuyez sur le bouton Partager (carré avec une flèche vers le haut).\n3. Faites défiler et choisissez « Sur l’écran d’accueil ».\n4. Appuyez sur « Ajouter ».');
    });
    if (later) later.addEventListener('click', () => {
      const banner = document.getElementById('gurishaInstallNotice');
      if (banner) banner.hidden = true;
    });
    const wait = window.setInterval(() => {
      if (window.GURISHA_ROLE) {
        window.clearInterval(wait);
        checkInstallStatus();
      }
    }, 250);
  });
})();