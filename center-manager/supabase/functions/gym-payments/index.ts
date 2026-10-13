// Test-only payment server. Never enable live keys in this deployment.
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
function testMode(){if(Deno.env.get('TOSS_ENVIRONMENT')!=='test')throw Error('TOSS_ENVIRONMENT=test 설정이 필요합니다. 실결제는 지원하지 않습니다.');}
function testMember(actor:string){if(!required('TOSS_TEST_USER_IDS').split(',').map(x=>x.trim()).includes(actor))throw Error('등록된 테스트 회원만 결제할 수 있습니다.');}
function testKey(value:unknown,type:'ck'|'sk'){if(typeof value!=='string'||!value.startsWith('test_'+type+'_'))throw Error('테스트 API 개별 연동 키만 사용할 수 있습니다.');return value;}
class ProviderFailure extends Error {constructor(public definitive:boolean,message:string){super(message);}}
class ReviewRequired extends Error {}
async function toss(secret:string,path:string,body?:unknown,idempotency?:string){
 testMode();testKey(secret,'sk');
 const response=await fetch('https://api.tosspayments.com/v1/'+path,{method:body?'POST':'GET',headers:{Authorization:'Basic '+btoa(secret+':'),'Content-Type':'application/json',...(idempotency?{'Idempotency-Key':idempotency}:{})},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(20000)});
 const result=await response.json();
 if(!response.ok){const code=/^[A-Z0-9_]{1,80}$/.test(result.code)?result.code:'PAYMENT_ERROR';throw new ProviderFailure(response.status>=400&&response.status<500&&![408,409,429].includes(response.status)&&!/ALREADY|DUPLICATE/.test(code),code);}
 return result;
}
async function settle(orderId:string,actor:string,input:Record<string,any>,review=false){
 testMode();
 testMember(actor);
 if(!review&&Deno.env.get('BILLING_SCHEDULER_READY')!=='true')throw Error('자동결제 스케줄러 설정을 먼저 완료해 주세요.');
 const order=await rpc('gym_billing_claim',{oid:orderId,actor,review});
 if(order.paid)return {paid:true,mode:'test'};
 if(order.busy)throw Error('다른 요청이 처리 중입니다. 잠시 후 확인해 주세요.');
 if(order.review)throw Error('자동 재시도를 중단했습니다. 관리자에게 승인 내역 확인을 요청해 주세요.');
 if(order.retryAt)throw Error('결과 확인을 예약했습니다. 다음 확인 시각: '+order.retryAt);
 let stage='config',encryptedToken=order.token;
 try{
  if(order.mode!=='test')throw new ReviewRequired('MODE_MISMATCH');
  testKey(order.clientKey,'ck');
  const secrets=JSON.parse(await decrypt(order.secret));const secret=testKey(order.recurring?secrets.billing:secrets.payment,'sk');
  const amount=Number(order.unit_amount)+Number(order.locker_amount);
  if(!Number.isSafeInteger(amount)||amount<=0)throw new ReviewRequired('INVALID_SERVER_AMOUNT');
  let paid;stage='lookup';
  try{paid=await toss(secret,'payments/orders/'+encodeURIComponent(orderId));}
  catch(e){if(!(e instanceof ProviderFailure)||e.message!=='NOT_FOUND_PAYMENT')throw e;}
  if(!paid){
   if(review)throw new ReviewRequired('PAYMENT_NOT_FOUND_REVIEW');
   if(order.recurring){
    if(!encryptedToken){
     // The initial browser callback is the only source of authKey; it is never logged or persisted.
     if(!input.authKey||input.customerKey!==actor)throw new ReviewRequired('BILLING_AUTH_REQUIRED');
     stage='issue';
     const auth=await toss(secret,'billing/authorizations/issue',{authKey:input.authKey,customerKey:actor},orderId+'-auth');
     if(typeof auth.billingKey!=='string'||!auth.billingKey||auth.customerKey!==actor)throw new ReviewRequired('BILLING_RESPONSE_MISMATCH');
     encryptedToken=await encrypt(auth.billingKey);
     await rpc('gym_billing_store_token',{oid:orderId,ticket:order.lease,ciphertext:encryptedToken});
    }
    stage='charge';
    paid=await toss(secret,'billing/'+encodeURIComponent(await decrypt(encryptedToken)),{customerKey:actor,amount,orderId,orderName:order.product_name+(order.locker_id?' + 락카':'')},orderId);
   }else{
    if(!input.paymentKey||Number(input.amount)!==amount)throw new ReviewRequired('PAYMENT_CALLBACK_REQUIRED');
    stage='charge';
    paid=await toss(secret,'payments/confirm',{paymentKey:input.paymentKey,orderId,amount},orderId);
   }
  }
  if(paid.status!=='DONE'||paid.orderId!==orderId||Number(paid.totalAmount)!==amount||paid.currency!=='KRW'||typeof paid.paymentKey!=='string'||!paid.paymentKey)throw new ReviewRequired('PAYMENT_RESPONSE_MISMATCH');
  stage='fulfill';
  await rpc('gym_billing_finish',{oid:orderId,ticket:order.lease,payment_key_value:paid.paymentKey,paid_amount:amount,billing_cipher:encryptedToken??null});
  return {paid:true,mode:'test'};
 }catch(e){
  const definitive=e instanceof ProviderFailure&&e.definitive&&['charge','issue'].includes(stage);
  const manual=review||e instanceof ReviewRequired||stage==='config';
  const code=e instanceof ProviderFailure||e instanceof ReviewRequired?e.message:stage==='fulfill'?'FULFILLMENT_PENDING':stage==='config'?'SERVER_CONFIG_ERROR':'PROVIDER_UNAVAILABLE';
  // Never free a reservation on a timeout: the provider may already have charged it.
  await rpc('gym_billing_defer',{oid:orderId,ticket:order.lease,code,definitive,manual});
  throw Error(definitive?`테스트 결제가 거절되었습니다 (${code}). 회원권은 활성화되지 않았습니다.`:manual?`승인 내역 확인이 필요합니다 (${code}). 추가 청구는 중단했습니다.`:`테스트 결제 결과를 다시 확인할 예정입니다 (${code}). 중복 주문을 만들지 마세요.`);
 }
}
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response(null,{headers});
 if(req.method!=='POST')return reply({error:'Method not allowed'},405);
 try{
  if(req.headers.get('origin')&&req.headers.get('origin')!==origin)return reply({error:'허용하지 않는 요청입니다.'},403);
  testMode();const input=await req.json();
  if(input.action==='renew'){
   const cron=required('CRON_SECRET');
   if(cron.length<32||req.headers.get('x-cron-secret')!==cron)return reply({error:'Unauthorized'},401);
   if(Deno.env.get('BILLING_SCHEDULER_READY')!=='true')throw Error('자동결제 스케줄러가 비활성화되어 있습니다.');
   const orders=await rpc('gym_billing_due');const results=[];const started=Date.now();
   for(const o of orders){if(Date.now()-started>45000)break;try{await settle(o.id,o.member_id,{});results.push({id:o.id,ok:true});}catch{results.push({id:o.id,ok:false});}}
   return reply({results,mode:'test'});
  }
  const token=req.headers.get('authorization')?.replace(/^Bearer /i,'');
  if(!token)return reply({error:'로그인이 필요합니다.'},401);
  const {data:{user},error}=await admin.auth.getUser(token);if(error||!user)return reply({error:'로그인이 필요합니다.'},401);
  if(input.action==='prepare'){
   testMember(user.id);
   if(Deno.env.get('BILLING_SCHEDULER_READY')!=='true')throw Error('자동결제 스케줄러 설정을 먼저 완료해 주세요.');
   const userClient=createClient(required('SUPABASE_URL'),required('SUPABASE_ANON_KEY'),{global:{headers:{Authorization:'Bearer '+token}},auth:{persistSession:false,autoRefreshToken:false}});
   const {data,error}=await userClient.rpc('gym_prepare_checkout',{payload:input.payload});if(error)throw Error(error.message);
   testKey(data.clientKey,'ck');return reply(data);
  }
  if(input.action==='configure_env'){
   const clientKey=testKey(required('TOSS_CLIENT_KEY'),'ck'),secretKey=testKey(required('TOSS_SECRET_KEY'),'sk');
   const current=await rpc('gym_billing_config_base',{cid:input.centerId,actor:user.id});
   const paymentSecret=current.secret?JSON.parse(await decrypt(current.secret)).payment||'':'';
   if(paymentSecret){testKey(paymentSecret,'sk');testKey(current.paymentClientKey,'ck');}
   // Keep a versioned encrypted snapshot: rotating environment keys cannot silently rebind existing subscriptions.
   const cipher=await encrypt(JSON.stringify({billing:secretKey,payment:paymentSecret}));
   await rpc('gym_save_toss',{actor:user.id,payload:{centerId:input.centerId,mode:'test',merchantLabel:'토스 빌링 테스트',enabled:input.enabled===true,paymentClientKey:current.paymentClientKey||'',billingClientKey:clientKey},ciphertext:cipher});
   return reply({saved:true,mode:'test'});
  }
  // Existing one-time payment settings are retained, but live configuration is rejected.
  if(input.action==='configure'){
   const p=input.payload;if(p.mode!=='test')throw Error('현재 서버는 테스트 결제 전용입니다.');
   testKey(p.paymentClientKey,'ck');testKey(p.paymentSecretKey,'sk');
   if(p.billingClientKey||p.billingSecretKey){testKey(p.billingClientKey,'ck');testKey(p.billingSecretKey,'sk');}
   const cipher=await encrypt(JSON.stringify({payment:p.paymentSecretKey,billing:p.billingSecretKey||''}));
   const {paymentSecretKey,billingSecretKey,...safe}=p;
   await rpc('gym_save_toss',{actor:user.id,payload:safe,ciphertext:cipher});return reply({saved:true});
  }
  if(input.action==='confirm')return reply(await settle(input.orderId,user.id,input));
  if(input.action==='reconcile'){
   const actor=await rpc('gym_billing_review_actor',{oid:input.orderId,actor:user.id});
   return reply(await settle(input.orderId,actor,{},true)); // Provider lookup only; never create another charge.
  }
  return reply({error:'지원하지 않는 요청입니다.'},400);
 }catch(e){return reply({error:e instanceof Error?e.message:'처리하지 못했습니다.'},400);}
});
