import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Relatieve paden, zodat de app ook onder https://<naam>.github.io/<repo>/ werkt.
export default defineConfig({ base: './', plugins: [react()] });
