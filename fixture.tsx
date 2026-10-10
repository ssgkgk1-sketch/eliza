import React from 'react';
import {createRoot} from 'react-dom/client';
import {flushSync} from 'react-dom';
import {usePullGesture} from '../../packages/ui/src/components/shell/use-pull-gesture';
function Demo(){const [open,setOpen]=React.useState(false),[clicks,setClicks]=React.useState(0);const gesture=usePullGesture({preventTouchCompatibilityEvents:true,onTap:()=>flushSync(()=>setOpen(true))});return <main><h1>Touch control lifecycle</h1><p>Tap Open. Only the gesture should run.</p><p>Then tap the message field to focus it.</p><output id="clicks">Follow-up clicks: {clicks}</output><section onClick={()=>{if(open)setClicks(n=>n+1)}}><input aria-label="Message" placeholder="Tap here after opening" style={{visibility:open?'visible':'hidden'}}/>{!open&&<div role="button" id="open" {...gesture}>Open</div>}</section><p id="state">{open?'Opened':'Closed'}</p></main>}
createRoot(document.getElementById('root')!).render(<Demo/>);
