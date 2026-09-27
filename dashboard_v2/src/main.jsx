import React from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from './App'
import './index.css'
import { ThemeProvider } from './lib/theme.jsx'
import { dashboardBasename } from './lib/dashboardLocation.js'

createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <ThemeProvider>
      <BrowserRouter basename={dashboardBasename(window.location.pathname)}>
        <App />
      </BrowserRouter>
    </ThemeProvider>
  </React.StrictMode>
)
