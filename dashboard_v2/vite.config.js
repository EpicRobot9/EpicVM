import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

export default defineConfig({
  plugins: [react()],
  root: realpathSync(fileURLToPath(new URL('.', import.meta.url))),
  base: '/EpicVM/Dashboard/',
  build: {
    outDir: 'dist',
    emptyOutDir: true
  }
})
