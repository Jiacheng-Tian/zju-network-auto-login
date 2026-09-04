(() => {
  'use strict';

  const initialPath = window.location.pathname;
  const initialProtocolIsHttps = window.location.protocol === 'https:';
  const initialPortIsDefault = window.location.port === '';
  if (
    !initialProtocolIsHttps ||
    !initialPortIsDefault ||
    !initialPath.startsWith('/srun_portal_') ||
    initialPath === '/srun_portal_success' ||
    initialPath.startsWith('/srun_portal_success/')
  ) {
    return;
  }

  const attemptKey = 'zjuNetworkAuthAttempted';
  if (window.sessionStorage.getItem(attemptKey)) {
    return;
  }
  window.sessionStorage.setItem(attemptKey, '1');

  const pollIntervalMilliseconds = 500;
  const timeoutMilliseconds = 30000;
  const startedAt = Date.now();

  const intervalId = window.setInterval(() => {
    if (Date.now() - startedAt >= timeoutMilliseconds) {
      window.clearInterval(intervalId);
      return;
    }

    const currentPath = window.location.pathname;
    const currentProtocolIsHttps = window.location.protocol === 'https:';
    const currentPortIsDefault = window.location.port === '';
    if (
      !currentProtocolIsHttps ||
      !currentPortIsDefault ||
      !currentPath.startsWith('/srun_portal_') ||
      currentPath === '/srun_portal_success' ||
      currentPath.startsWith('/srun_portal_success/')
    ) {
      window.clearInterval(intervalId);
      return;
    }

    const loginButton = document.querySelector('#login-account');
    if (!loginButton) {
      return;
    }

    window.clearInterval(intervalId);
    loginButton.click();
  }, pollIntervalMilliseconds);
})();
