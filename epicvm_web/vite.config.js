import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

// Public EpicVM beta front door. Mounted under /EpicVM/ (the BrowserRouter
// basename is baked at build time, so this app uses its own build).
export default defineConfig({
  plugins: [react()],
  root: realpathSync(fileURLToPath(new URL('.', import.meta.url))),
  base: '/EpicVM/',
  build: {
    outDir: 'dist',
    emptyOutDir: true
  }
})
