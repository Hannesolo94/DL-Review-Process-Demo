import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Builds into ../copy (served by GitHub Pages at /DL-Review-Process-Demo/copy/).
// assetsDir is 'js' because the Pages _config.yml excludes any folder called 'assets'.
export default defineConfig({
  plugins: [react()],
  base: './',
  build: { outDir: '../copy', emptyOutDir: true, assetsDir: 'js', chunkSizeWarningLimit: 4000 },
});
