import React from 'react';
import {createRoot} from 'react-dom/client';
import App from '../components/App';
import '../app/globals.css';
createRoot(document.getElementById('root')!).render(<App initialView={location.pathname==='/member'?'member':'admin'}/>);
