import { defineConfig } from 'vite';
import { resolve } from 'node:path';

// On GitHub Pages the site lives under /lofer/ (summerrainzozo.github.io/lofer/),
// so built files need that prefix. The dev server keeps serving from "/".
// Three pages: the landing page, the privacy policy at /privacy/, and the email-preferences page at
// /unsubscribe/ (where personal links in emails lead). Each is a folder with its own index.html,
// so the address works when typed in or refreshed, with no server rules.
export default defineConfig(({ command }) => ({
  base: '/',
  build: {
    rollupOptions: {
      input: {
        main: resolve(import.meta.dirname, 'index.html'),
        privacy: resolve(import.meta.dirname, 'privacy/index.html'),
        unsubscribe: resolve(import.meta.dirname, 'unsubscribe/index.html'),
      },
    },
  },
}));
