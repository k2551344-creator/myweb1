import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import ts from 'typescript';
import {webcrypto} from 'node:crypto';
let handler;let actor='member-a',owner='owner-a',claims=0,finishes=0,charges=0,failures=0;
const env={APP_SITE_URL:'https://example.test/myweb1/',SUPABASE_URL:'https://supabase.test',SUPABASE_SERVICE_ROLE_KEY:'fixture',PAYMENT_ENCRYPTION_KEY:Buffer.alloc(32,7).toString('base64'),CRON_SECRET:'fixture-cron',BILLING_SCHEDULER_READY:'true'};
const iv=new Uint8Array(12).fill(3),key=await webcrypto.subtle.importKey('raw',Buffer.from(env.PAYMENT_ENCRYPTION_KEY,'base64'),'AES-GCM',false,['encrypt']);
const cipher=Buffer.from(iv).toString('base64')+'.'+Buffer.from(await webcrypto.subtle.encrypt({name:'AES-GCM',iv},key,new TextEncoder().encode(JSON.stringify({payment:'test_sk_fixture',billing:'test_sk_billing'})))).toString('base64');
let paid=false,existing=false,status='DONE',amount=55000,recurring=false,definitiveFailure=false,networkFailure=false,token=null,configured=null;
const client={auth:{getUser:async token=>({data:{user:token==='valid'?{id:actor}:null},error:token==='valid'?null:{message:'invalid'}})},rpc:async(name,args)=>{
 if(name==='gym_claim_payment'){claims++;if(args.actor!==actor)return {error:{message:'unauthorized'}};return {data:paid?{paid:true}:{id:'order-123',member_id:actor,product_name:'회원권',unit_amount:50000,locker_amount:5000,locker_id:'locker',secret:cipher,recurring,token}};}
 if(name==='gym_finish_payment'){finishes++;paid=true;assert.equal(args.paid_amount,55000);return {data:'membership'};}
 if(name==='gym_fail_payment'){failures++;return {data:null};}
 if(name==='gym_store_checkout_token'){token=args.ciphertext;assert.ok(!token.includes('billing-key-fixture'));return {data:null};}
 if(name==='gym_due_orders')return {data:[]};
 if(name==='gym_save_toss'){if(args.actor!==owner)return {error:{message:'owner only'}};configured=args;return {data:'config'};}
 throw Error('unexpected rpc '+name);
}};
const fetcher=async(url,opts)=>{
 if(networkFailure)throw Error('network unavailable');
 if(url.includes('/payments/orders/'))return existing?Response.json({status,orderId:'order-123',totalAmount:amount,paymentKey:'pay-fixture'}):Response.json({code:'NOT_FOUND_PAYMENT'},{status:404});
 if(url.includes('/billing/authorizations/issue'))return Response.json({billingKey:'billing-key-fixture'});
 charges++;assert.ok(opts.headers['Idempotency-Key']);const body=JSON.parse(opts.body);assert.equal(body.amount,55000);assert.equal(body.orderId,'order-123');if(definitiveFailure)return Response.json({code:'REJECT_CARD_PAYMENT'},{status:400});
 return Response.json({status,orderId:'order-123',totalAmount:amount,paymentKey:'pay-fixture'});
};
let code=readFileSync('supabase/functions/gym-payments/index.ts','utf8').replace(/import \{createClient\} from [^;]+;/,'const createClient=globalThis.mockClient;');
code=ts.transpileModule(code,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText.replace(/export \{\};?/g,'');
vm.runInNewContext(code,{mockClient:()=>client,Deno:{env:{get:k=>env[k]},serve:h=>{handler=h}},Request,Response,URL,fetch:fetcher,crypto:webcrypto,TextEncoder,TextDecoder,Uint8Array,atob,btoa,AbortSignal});
let tests=0;function pass(s){tests++;console.log('PASS '+s)}
const request=(body,token='valid',origin='https://example.test',extra={})=>handler(new Request('https://function.test',{method:'POST',headers:{origin,authorization:'Bearer '+token,'Content-Type':'application/json',...extra},body:JSON.stringify(body)}));
const confirmation={action:'confirm',orderId:'order-123',amount:55000,paymentKey:'key'};
assert.equal((await request(confirmation,'bad')).status,401);assert.equal(claims,0);pass('invalid JWT rejected before database access');
assert.equal((await request(confirmation,'valid','https://evil.test')).status,403);pass('unexpected browser origin denied');
assert.equal((await request({...confirmation,amount:1})).status,400);assert.equal(charges,0);pass('tampered amount cannot reach provider charge');
assert.equal((await request(confirmation)).status,200);assert.equal(charges,1);assert.equal(finishes,1);pass('successful confirmation checked and fulfilled');
await request(confirmation);assert.equal(charges,1);pass('completed callback does not charge twice');
paid=false;existing=true;await request(confirmation);assert.equal(charges,1);pass('provider charge recovered after local failure');
paid=false;status='CANCELED';assert.equal((await request(confirmation)).status,400);assert.equal(paid,false);pass('non-DONE provider response cannot grant membership');
status='DONE';existing=false;networkFailure=true;assert.equal((await request(confirmation)).status,400);assert.equal(failures,0);pass('network ambiguity does not release reservation');
networkFailure=false;definitiveFailure=true;await request(confirmation);assert.equal(failures,1);pass('definitive rejection marked failed');
definitiveFailure=false;recurring=true;await request({...confirmation,authKey:'auth',customerKey:actor});assert.ok(token);assert.equal(paid,true);pass('billing key encrypted before first recurring charge');
assert.equal((await request({action:'renew'})).status,401);assert.equal((await request({action:'renew'},'','https://example.test',{'x-cron-secret':'fixture-cron'})).status,200);pass('renewal worker requires separate secret');
actor=owner;const config={action:'configure',payload:{mode:'test',paymentClientKey:'test_ck_fixture',paymentSecretKey:'test_sk_fixture',billingClientKey:'',billingSecretKey:''}};
assert.equal((await request(config)).status,200);assert.ok(configured.ciphertext);assert.equal(configured.payload.paymentSecretKey,undefined);assert.ok(!configured.ciphertext.includes('test_sk_fixture'));pass('configuration stores only encrypted secrets');
console.log(`${tests} payment server checks passed (provider mocked)`);
