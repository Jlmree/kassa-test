import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';

const proef = process.env.VITE_PROEF === '1';

// Relatieve paden, zodat de app ook onder https://<naam>.github.io/<repo>/ werkt.
export default defineConfig({
  base: './',
  plugins: [react()],
  // Alleen de proefversie krijgt de database in de browser mee.
  resolve: { alias: { '@proef': fileURLToPath(new URL(proef ? './src/demo/client.ts' : './src/demo/uit.ts', import.meta.url)) } },
  // PGlite (database van de proefversie) laadt zijn eigen wasm-bestanden.
  optimizeDeps: { exclude: ['@electric-sql/pglite'] },
});
