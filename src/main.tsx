import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import { THEMA_OPSLAG } from './data';
import './styles.css';

// Het thema van de vorige keer meteen, zodat de kassa niet eerst even licht oplicht.
try {
  const t = localStorage.getItem(THEMA_OPSLAG);
  if (t === 'kroeg' || t === 'groot') document.documentElement.dataset.thema = t;
} catch { /* geen opslag */ }

createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);

if ('serviceWorker' in navigator && import.meta.env.PROD) {
  addEventListener('load', () => void navigator.serviceWorker.register('./sw.js'));
}
