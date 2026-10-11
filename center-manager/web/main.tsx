import React,{lazy,Suspense} from 'react';
import {createRoot} from 'react-dom/client';
const WebApp=lazy(()=>import('./WebApp'));
const Kiosk=lazy(()=>import('./Kiosk'));
import '../app/globals.css';
import './web.css';
createRoot(document.getElementById('root')!).render(<Suspense fallback={<p>불러오는 중…</p>}>{new URLSearchParams(location.search).has('kiosk')?<Kiosk/>:<WebApp/>}</Suspense>);
