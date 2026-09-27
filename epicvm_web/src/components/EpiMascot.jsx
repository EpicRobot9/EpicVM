import React from 'react'

export default function EpiMascot({ small = false }) {
  return <svg className={`epi-mascot ${small ? 'epi-mascot-small' : ''}`} viewBox="0 0 112 112" role="img" aria-label="Epi smiling" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <linearGradient id="epi-face" x1=".1" y1="0" x2=".9" y2="1" objectBoundingBox="true"><stop stopColor="#b5f4ff"/><stop offset=".48" stopColor="#87dfff"/><stop offset="1" stopColor="#a795ff"/></linearGradient>
      <linearGradient id="epi-body" x1="0" y1="0" x2="1" y2="1" objectBoundingBox="true"><stop stopColor="#aaedff"/><stop offset="1" stopColor="#7775e7"/></linearGradient>
    </defs>
    <ellipse cx="56" cy="99" rx="34" ry="7" fill="#060e20" opacity=".28"/>
    <path d="M30 98c2-15 13-22 26-22s24 7 26 22" fill="url(#epi-body)" stroke="#c8f4ff" strokeWidth="2"/>
    <path d="M20 57c-2-22 11-39 36-39s38 17 36 39c-2 22-18 35-36 35S22 79 20 57Z" fill="url(#epi-face)" stroke="#d5f8ff" strokeWidth="2"/>
    <path d="M20 54c-3-17 8-34 24-36-3 8 4 13 16 12 8 0 16-4 21-9 9 6 14 18 11 33-4-11-8-14-16-17-18 12-38 9-49 3-4 4-6 9-7 14Z" fill="#27366f"/>
    <path d="M52 19c-1-7 2-12 8-15-1 7 2 11 8 13" fill="none" stroke="#5263b4" strokeWidth="5" strokeLinecap="round"/>
    <ellipse cx="39" cy="59" rx="3" ry="4.5" fill="#19274a"/><ellipse cx="73" cy="59" rx="3" ry="4.5" fill="#19274a"/>
    <path d="M46 69c5 7 15 7 20 0" fill="none" stroke="#233055" strokeWidth="3" strokeLinecap="round"/>
    <ellipse cx="31" cy="68" rx="7" ry="3" fill="#ff8fba" opacity=".68"/><ellipse cx="81" cy="68" rx="7" ry="3" fill="#ff8fba" opacity=".68"/>
    <path d="m89 17 2.5 5.5L97 25l-5.5 2.5L89 33l-2.5-5.5L81 25l5.5-2.5Z" fill="#ffe9a5"/>
    <circle cx="15" cy="39" r="2.5" fill="#a5eaff"/>
  </svg>
}
