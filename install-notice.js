(() => {
  function checkInstallStatus() {
    const role = window.GURISHA_ROLE;
    const installed = window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
    const banner = document.getElementById('gurishaInstallNotice');
    if (!banner || !role) return;
    if (['cashier', 'manager', 'gestionnaire'].includes(role) && !installed) {
      banner.hidden = false;
    }
  }
  document.addEventListener('DOMContentLoaded', () => {
    const help = document.getElementById('gurishaInstallHelp');
    const later = document.getElementById('gurishaInstallLater');
    if (help) help.addEventListener('click', () => {
      alert('Sur Android : ouvrez le menu ⋮ de votre navigateur, puis choisissez « Installer l’application » ou « Ajouter à l’écran d’accueil ». Sur iPhone : utilisez Partager, puis « Sur l’écran d’accueil ».');
    });
    if (later) later.addEventListener('click', () => {
      document.getElementById('gurishaInstallNotice').hidden = true;
    });
    const wait = window.setInterval(() => {
      if (window.GURISHA_ROLE) {
        window.clearInterval(wait);
        checkInstallStatus();
      }
    }, 250);
  });
})();
