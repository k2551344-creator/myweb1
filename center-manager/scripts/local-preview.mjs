// Windows fallback when the native Workers emulator is unavailable.
// Binds loopback only. Production uses the separate Cloudflare/D1/R2 routes.
import {createServer} from 'vite';
import react from '@vitejs/plugin-react';
import {DatabaseSync} from 'node:sqlite';
import {mkdirSync,readFileSync,writeFileSync,existsSync} from 'node:fs';
import path from 'node:path';
const root=process.cwd(),dataDir=path.join(root,'.sites-runtime','local-data');
mkdirSync(path.join(dataDir,'images'),{recursive:true});
const db=new DatabaseSync(path.join(dataDir,'demo.sqlite'));
db.exec('CREATE TABLE IF NOT EXISTS demo_state(owner TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 0, data TEXT NOT NULL)');
const vite=await createServer({configFile:false,root:path.join(root,'preview'),publicDir:path.join(root,'public'),plugins:[react()],server:{host:'127.0.0.1',port:5173,strictPort:true,fs:{allow:[root]}}});
vite.middlewares.use(async(req,res,next)=>{
 if(!req.url?.startsWith('/api/'))return next();
 const origin='http://127.0.0.1:5173';
 const send=(data,status=200)=>{res.statusCode=status;res.setHeader('Content-Type','application/json');res.setHeader('Cache-Control','no-store');res.end(JSON.stringify(data))};
 try{
 if(req.headers.host!=='127.0.0.1:5173')throw Error('Invalid host');
 if(req.method!=='GET'&&req.headers.origin!==origin)throw Error('허용하지 않는 요청입니다.');
 const {seed}=await vite.ssrLoadModule(path.join(root,'lib/seed.ts'));
 const {applyAction}=await vite.ssrLoadModule(path.join(root,'lib/actions.ts'));
 const {normalize}=await vite.ssrLoadModule(path.join(root,'lib/model.ts'));
 async function body(limit){const chunks=[];let size=0;for await(const chunk of req){size+=chunk.length;if(size>limit)throw Error('입력 크기가 너무 큽니다.');chunks.push(chunk)}return Buffer.concat(chunks)}
 if(req.url==='/api/state'){
 let row=db.prepare('SELECT data,revision FROM demo_state WHERE owner=?').get('local-demo');
 if(!row){db.prepare('INSERT INTO demo_state(owner,data) VALUES(?,?)').run('local-demo',JSON.stringify(seed()));row=db.prepare('SELECT data,revision FROM demo_state WHERE owner=?').get('local-demo')}
 if(req.method==='GET')return send({state:normalize(JSON.parse(row.data)),revision:row.revision});
 if(req.method!=='POST')return send({error:'Method not allowed'},405);
 const {action,input}=JSON.parse((await body(20000)).toString());
 // Re-read after awaiting body; mutation/save are synchronous and atomic in this process.
 const current=db.prepare('SELECT data FROM demo_state WHERE owner=?').get('local-demo');
 const state=JSON.parse(current.data),result=applyAction(state,action,input);
 db.prepare('UPDATE demo_state SET data=?,revision=revision+1 WHERE owner=?').run(JSON.stringify(state),'local-demo');return send({state,result});
 }
 if(req.url==='/api/images'&&req.method==='POST'){
 const raw=await body(6*1024*1024),form=await new Request(origin,{method:'POST',headers:{'Content-Type':req.headers['content-type']},body:raw}).formData(),file=form.get('image');
 if(!(file instanceof File)||file.size>5*1024*1024||file.size<12)throw Error('5MB 이하의 사진을 선택해 주세요.');
 const data=Buffer.from(await file.arrayBuffer());let ext='';
 if(data[0]===255&&data[1]===216&&data[2]===255)ext='jpg';
 else if(data.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))ext='png';
 else if(data.toString('ascii',0,4)==='RIFF'&&data.toString('ascii',8,12)==='WEBP')ext='webp';
 else throw Error('JPG, PNG, WebP 이미지만 사용할 수 있습니다.');
 const key=crypto.randomUUID()+'.'+ext;writeFileSync(path.join(dataDir,'images',key),data);return send({url:'/api/images/'+key});
 }
 const match=req.url.match(/^\/api\/images\/([a-f0-9-]{36}\.(png|jpg|webp))$/);
 if(match&&req.method==='GET'){const file=path.join(dataDir,'images',match[1]);if(!existsSync(file))return send({error:'Not found'},404);res.setHeader('Content-Type','image/'+(match[2]==='jpg'?'jpeg':match[2]));res.setHeader('X-Content-Type-Options','nosniff');res.end(readFileSync(file));return}
 send({error:'Not found'},404);
 }catch(e){console.error(e.message);send({error:e.message.startsWith('[')?'입력 내용을 확인해 주세요.':e.message},400)}
});
vite.middlewares.stack.unshift(vite.middlewares.stack.pop());
await vite.listen();vite.printUrls();

