// Supabase Edge Function. Secrets never enter the public web bundle.
import {createClient} from 'npm:@supabase/supabase-js@2.117.2';
const required=(name:string)=>{const value=Deno.env.get(name);if(!value)throw Error(`Missing server configuration: ${name}`);return value;};
const site=required('APP_SITE_URL');const origin=new URL(site).origin;
const admin=createClient(required('SUPABASE_URL'),required('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
const headers={'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info, x-cron-secret','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...headers,'Content-Type':'application/json','Cache-Control':'no-store'}});
async function rpc(name:string,args:Record<string,unknown>={}){const {data,error}=await admin.rpc(name,args);if(error)throw Error(error.message);return data;}
const bytes=(value:string)=>Uint8Array.from(atob(value),c=>c.charCodeAt(0));
const base64=(value:Uint8Array)=>btoa(String.fromCharCode(...value));
async function key(){return crypto.subtle.importKey('raw',bytes(required('PAYMENT_ENCRYPTION_KEY')),'AES-GCM',false,['encrypt','decrypt']);}
async function encrypt(value:string){const iv=crypto.getRandomValues(new Uint8Array(12));const result=await crypto.subtle.encrypt({name:'AES-GCM',iv},await key(),new TextEncoder().encode(value));return base64(iv)+'.'+base64(new Uint8Array(result));}
async function decrypt(value:string){const [iv,data]=value.split('.');return new TextDecoder().decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes(iv)},await key(),bytes(data)));}
class ProviderFailure extends Error {constructor(public definitive:boolean,message:string){super(message);}}
async function toss(secret:string,path:string,body?:unknown,idempotency?:string){
 const response=await fetch('https://api.tosspayments.com/v1/'+path,{method:body?'POST':'GET',headers:{Authorization:'Basic '+btoa(secret+':'),'Content-Type':'application/json',...(idempotency?{'Idempotency-Key':idempotency}:{})},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(20000)});
 const result=await response.json();
 if(!response.ok)throw new ProviderFailure(response.status>=400&&response.status<500&&![408,409,429].includes(response.status),String(result.code??'PAYMENT_ERROR'));
 return result;
}
async function settle(orderId:string,actor:string,input:Record<string,any>){
 const order=await rpc('gym_claim_payment',{oid:orderId,actor});if(order.paid)return {paid:true};
 const secrets=JSON.parse(await decrypt(order.secret));const secret=order.recurring?secrets.billing:secrets.payment;
 if(!secret)throw Error('지점 결제 키가 설정되지 않았습니다.');
 const amount=Number(order.unit_amount)+Number(order.locker_amount);let encryptedToken=order.token;let paid;
 // Recover a completed charge before attempting any retry, including after a crash.
 try {paid=await toss(secret,'payments/orders/'+encodeURIComponent(orderId));}
 catch(e){if(!(e instanceof ProviderFailure)||e.message!=='NOT_FOUND_PAYMENT')throw e;}
 if(!paid){
  if(order.recurring){
   if(Deno.env.get('BILLING_SCHEDULER_READY')!=='true')throw Error('자동결제 스케줄러 설정이 필요합니다.');
   if(!encryptedToken){
    if(!input.authKey||input.customerKey!==actor)throw Error('카드 등록 정보가 일치하지 않습니다.');
    const auth=await toss(secret,'billing/authorizations/issue',{authKey:input.authKey,customerKey:actor},orderId+'-auth');
    encryptedToken=await encrypt(auth.billingKey);
    await rpc('gym_store_checkout_token',{oid:orderId,ciphertext:encryptedToken});
    // Read the first persisted key if the callback was delivered concurrently.
    encryptedToken=(await rpc('gym_claim_payment',{oid:orderId,actor})).token;
   }
   try{paid=await toss(secret,'billing/'+encodeURIComponent(await decrypt(encryptedToken)),{customerKey:actor,amount,orderId,orderName:order.product_name+(order.locker_id?' + 락카':'')},orderId);}catch(e){if(e instanceof ProviderFailure&&e.definitive&&!/ALREADY|DUPLICATE/.test(e.message))await rpc('gym_fail_payment',{oid:orderId});throw e;}
  }else{
   if(!input.paymentKey||Number(input.amount)!==amount)throw Error('결제 금액이 일치하지 않습니다.');
   try{paid=await toss(secret,'payments/confirm',{paymentKey:input.paymentKey,orderId,amount},orderId);}catch(e){if(e instanceof ProviderFailure&&e.definitive&&!/ALREADY|DUPLICATE/.test(e.message))await rpc('gym_fail_payment',{oid:orderId});throw e;}
  }
 }
 if(paid.status!=='DONE'||paid.orderId!==orderId||Number(paid.totalAmount)!==amount)throw Error('결제 승인 내역이 일치하지 않습니다. 센터에 문의해 주세요.');
 await rpc('gym_finish_payment',{oid:orderId,payment_key_value:paid.paymentKey,paid_amount:amount,billing_cipher:encryptedToken??null});
 return {paid:true};
}
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response(null,{headers});
 if(req.method!=='POST')return reply({error:'Method not allowed'},405);
 try{
  if(req.headers.get('origin')&&req.headers.get('origin')!==origin)return reply({error:'허용하지 않는 요청입니다.'},403);
  const input=await req.json();
  if(input.action==='renew'){
   if(!Deno.env.get('CRON_SECRET')||req.headers.get('x-cron-secret')!==Deno.env.get('CRON_SECRET'))return reply({error:'Unauthorized'},401);
   if(Deno.env.get('BILLING_SCHEDULER_READY')!=='true')throw Error('자동결제 스케줄러가 비활성화되어 있습니다.');
   const orders=await rpc('gym_due_orders');const results=[];const started=Date.now();
   for(const o of orders){if(Date.now()-started>80000)break;try{await settle(o.id,o.member_id,{});results.push({id:o.id,ok:true});}catch{results.push({id:o.id,ok:false});}}
   return reply({results});
  }
  const token=req.headers.get('authorization')?.replace(/^Bearer /i,'');
  if(!token)return reply({error:'로그인이 필요합니다.'},401);
  const {data:{user},error}=await admin.auth.getUser(token);if(error||!user)return reply({error:'로그인이 필요합니다.'},401);
  if(input.action==='configure'){
   const p=input.payload,mode=p.mode;
   if(!['test','live'].includes(mode))throw Error('테스트/실결제 모드를 확인해 주세요.');
   if(!String(p.paymentClientKey).startsWith(mode+'_ck_')||!String(p.paymentSecretKey).startsWith(mode+'_sk_'))throw Error('일회성 결제 Client/Secret Key를 확인해 주세요.');
   if((p.billingClientKey||p.billingSecretKey)&&(!String(p.billingClientKey).startsWith(mode+'_ck_')||!String(p.billingSecretKey).startsWith(mode+'_sk_')))throw Error('자동결제 Client/Secret Key를 확인해 주세요.');
   const cipher=await encrypt(JSON.stringify({payment:p.paymentSecretKey,billing:p.billingSecretKey||''}));
   const {paymentSecretKey,billingSecretKey,...safe}=p;
   await rpc('gym_save_toss',{actor:user.id,payload:safe,ciphertext:cipher});return reply({saved:true});
  }
  if(input.action==='confirm')return reply(await settle(input.orderId,user.id,input));
  return reply({error:'지원하지 않는 요청입니다.'},400);
 }catch(e){return reply({error:e instanceof Error?e.message:'처리하지 못했습니다.'},400);}
});
