import React, { Suspense, lazy } from 'react';
import ReactDOM from 'react-dom/client';
import { IntlProvider } from 'react-intl';
import { ConfigProvider } from './components/ConfigContext';
import { ErrorBoundary } from './components/ErrorBoundary';
import SuspenseLoader from './suspense-loader';
import { client } from './api/client.gen';
import { setTelemetryEnabled } from './utils/analytics';
import { readConfig } from './api';
import { applyThemeTokens } from './theme/theme-tokens';
import { currentLocale, currentMessageLocale, loadMessages } from './i18n';
import { toast } from 'react-toastify';

// Apply theme tokens to :root before first paint.
applyThemeTokens();

const App = lazy(() => import('./App'));

const TELEMETRY_CONFIG_KEY = 'GOOSE_TELEMETRY_ENABLED';

let warnedFallbackLocale = false;
function handleIntlError(err: { code: string; message?: string }) {
  if (err.code === 'MISSING_TRANSLATION' && currentLocale !== currentMessageLocale) {
    if (!warnedFallbackLocale) {
      warnedFallbackLocale = true;
      console.warn(
        `[i18n] Locale "${currentLocale}" has no translations; falling back to "${currentMessageLocale}".`
      );
    }
    return;
  }
  console.error(err);
}

(async () => {
  // Check if we're in the launcher view (doesn't need goosed connection)
  const isLauncher = window.location.hash === '#/launcher';

  if (!isLauncher) {
    const gooseApiHost = await window.electron.getGoosedHostPort();
    if (gooseApiHost === null) {
      window.alert('failed to start goose backend process');
      return;
    }
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'X-Secret-Key': await window.electron.getSecretKey(),
    };
    // Include client identifier for session isolation when using external server
    try {
      const externalGoosed = await window.electron.getSetting('externalGoosed');
      if (externalGoosed?.enabled && externalGoosed.clientId) {
        headers['X-Client-Id'] = externalGoosed.clientId;
      }
    } catch {
      // settings key not available — skip client-id header
    }
    client.setConfig({
      baseUrl: gooseApiHost,
      headers,
    });

    // Show a toast when remote clients attempt admin operations (403 Forbidden)
    client.interceptors.response.fns.push(async (response, _request) => {
      if (response.status === 403) {
        toast.warning(
          <div>
            <strong className="font-medium">No Permission</strong>
            <div>
              Management features (recipes, extensions, settings, etc.) are only
              available on the server machine. Connect directly to manage.
            </div>
          </div>,
          { autoClose: 8000 }
        );
      }
      return response;
    });

    try {
      const telemetryResponse = await readConfig({
        body: { key: TELEMETRY_CONFIG_KEY, is_secret: false },
      });
      const isTelemetryEnabled = telemetryResponse.data !== false;
      setTelemetryEnabled(isTelemetryEnabled);
    } catch (error) {
      console.warn('[Analytics] Failed to initialize analytics:', error);
    }
  }

  const messages = await loadMessages(currentMessageLocale);

  ReactDOM.createRoot(document.getElementById('root')!).render(
    <React.StrictMode>
      <IntlProvider
        locale={currentLocale}
        defaultLocale="en"
        messages={messages}
        onError={handleIntlError}
      >
        <Suspense fallback={SuspenseLoader()}>
          <ConfigProvider>
            <ErrorBoundary>
              <App />
            </ErrorBoundary>
          </ConfigProvider>
        </Suspense>
      </IntlProvider>
    </React.StrictMode>
  );
})();
