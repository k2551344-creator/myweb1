import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const base='http://127.0.0.1:5173';
const json=async(path,init={})=>{const r=await fetch(base+path,init),d=await r.json();if(!r.ok)throw Error(d.error);return d};
const send=(action,input)=>json('/api/state',{method:'POST',headers:{'Content-Type':'application/json',Origin:base},body:JSON.stringify({action,input})});
const initial=(await json('/api/state')).state;
const c=initial.centers[0],p=initial.products[0],other=initial.centers[1];
const image=readFileSync('.sites-runtime/upload-test.png');
const form=new FormData();form.append('image',new Blob([image],{type:'image/png'}),'test.png');
const uploaded=await json('/api/images',{method:'POST',headers:{Origin:base},body:form});
assert.match(uploaded.url,/^\/api\/images\/[\w-]+\.png$/);
assert.deepEqual(Buffer.from(await (await fetch(base+uploaded.url)).arrayBuffer()),image);
try{
 await send('center.save',{...c,bgColor:'#173852',bgImage:uploaded.url});
 await send('product.save',{...p,image:uploaded.url});
 const saved=(await json('/api/state')).state;
 assert.equal(saved.centers[0].bgImage,uploaded.url);assert.equal(saved.centers[0].bgColor,'#173852');assert.equal(saved.products[0].image,uploaded.url);assert.deepEqual(saved.centers[1],other);
 console.log('PASS uploaded image bytes, product association, background settings, reload persistence, center isolation');
}finally{await send('center.save',c);await send('product.save',p)}
const bad=new FormData();bad.append('image',new Blob(['<svg>not a raster image</svg>'],{type:'image/png'}),'bad.png');
assert.equal((await fetch(base+'/api/images',{method:'POST',headers:{Origin:base},body:bad})).status,400);
assert.equal((await fetch(base+'/api/state',{method:'POST',headers:{Origin:'https://untrusted.example','Content-Type':'application/json'},body:'{}'})).status,400);
console.log('PASS disguised non-image rejection and cross-origin write rejection');
