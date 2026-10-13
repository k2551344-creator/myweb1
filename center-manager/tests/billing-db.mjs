import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {PGlite} from '../.sites-runtime/sql-check/node_modules/@electric-sql/pglite/dist/index.js';
process.on('uncaughtException',e=>{console.error(e.message,e.where??'');process.exit(1)});
const db=new PGlite();await db.waitReady;let passed=0;const pass=s=>{passed++;console.log('PASS '+s)};
const source=readFileSync('tests/supabase-schema.mjs','utf8');await db.exec(source.split('const bootstrap=`')[1].split('`;')[0]);
await db.exec('alter table auth.users add column email_confirmed_at timestamptz default now()');
for(const file of ['202609290001_initial.sql','202609290002_catalog.sql','202610120001_member_commerce.sql','202610120002_email_kiosk.sql','202610120003_google_member_admin.sql','202610130001_billing_safety.sql','202610130001_billing_safety.sql'])await db.exec(readFileSync('supabase/migrations/'+file,'utf8'));pass('additive migration and repeat');
const owner='10000000-0000-4000-8000-000000000001',member='10000000-0000-4000-8000-000000000002',other='10000000-0000-4000-8000-000000000003';
await db.exec(`insert into auth.users(id,email) values('${owner}','owner@test.invalid'),('${member}','member@test.invalid'),('${other}','other@test.invalid')`);
const cid=(await db.query("insert into public.centers(name,brand) values('A','BOX') returning id")).rows[0].id;
const c2=(await db.query("insert into public.centers(name,brand) values('B','BOX') returning id")).rows[0].id;
await db.query("insert into public.center_admins(center_id,user_id,role) values($1,$2,'owner')",[cid,owner]);
async function role(name,user=''){await db.exec(`reset role;select set_config('request.jwt.claim.sub','${user}',false);set role ${name}`)}
async function call(name,args){return (await db.query(`select public.${name}(${Object.keys(args).map((k,i)=>`${k}=>$${i+1}`).join(',')}) as result`,Object.values(args))).rows[0].result;}
const payload=(name,p)=>call(name,{payload:JSON.stringify(p)});
async function reject(fn,pattern,label){await assert.rejects(fn,pattern);pass(label)}
await role('authenticated',owner);await payload('gym_save_center_v2',{id:cid,name:'A',brand:'BOX',businessName:'사업자 A',representative:'대표'});pass('branch business details saved');
await reject(()=>payload('gym_save_center_v2',{id:c2,name:'B',brand:'BOX'}),/권한/,'cross-branch edit denied');
const base={centerId:cid,name:'2주 회원권',description:'intro',category:'회원권',details:'상세',terms:'약관 v1',cancellationNotice:'해지 v1',intervalUnit:'week',intervalCount:2,price:50000,recurring:true,weeklyLimit:3,capacity:10,stock:0,active:true,selling:true,sort:1,accessCenters:[cid]};
const pid=await payload('gym_save_product_v2',base),lid=await payload('gym_save_locker',{centerId:cid,number:'A01',location:'입구',price:5000,status:'AVAILABLE'});
await role('authenticated',member);await reject(()=>payload('gym_save_product_v2',{...base,id:pid}),/권한/,'member product edit denied');await reject(()=>payload('gym_save_locker',{centerId:cid,number:'bad',price:0,status:'AVAILABLE'}),/권한/,'member locker edit denied');
await reject(()=>call('gym_save_toss',{actor:owner,payload:JSON.stringify({centerId:cid}),ciphertext:'xxxxxxxxxxxxxxxxxxxx'}),/permission denied/,'browser secret write denied');
await role('service_role');await call('gym_save_toss',{actor:owner,payload:JSON.stringify({centerId:cid,mode:'test',enabled:true,paymentClientKey:'test_ck_fixture',billingClientKey:'test_ck_fixture',merchantLabel:'A'}),ciphertext:'encrypted-fixture-12345678'});pass('branch credential configured by server');
await reject(()=>call('gym_save_toss',{actor:member,payload:JSON.stringify({centerId:cid}),ciphertext:'xxxxxxxxxxxxxxxxxxxx'}),/소유자/,'server checks actual branch owner');
await role('authenticated',member);await reject(()=>payload('gym_prepare_checkout',{productId:pid,revision:2,agreed:true}),/전화번호/,'profile required');await payload('gym_update_profile',{name:'회원 A',phone:'010-1234-5678'});
await reject(()=>payload('gym_update_profile',{name:'',phone:'123'}),/이름/,'invalid profile rejected');await reject(()=>payload('gym_prepare_checkout',{productId:pid,revision:2,agreed:false}),/동의/,'terms consent required');await reject(()=>payload('gym_prepare_checkout',{productId:pid,revision:1,agreed:true}),/변경/,'stale terms revision rejected');

const order=await payload('gym_prepare_checkout',{productId:pid,revision:2,agreed:true,lockerId:lid,amount:1});assert.equal(order.amount,55000);pass('server snapshot ignores browser amount');
await reject(()=>call('gym_billing_claim',{oid:order.orderId,actor:member}),/permission denied/,'browser cannot claim payments');
await role('service_role');
await reject(()=>call('gym_billing_claim',{oid:order.orderId,actor:other}),/권한/,'member binding checked');
let claim=await call('gym_billing_claim',{oid:order.orderId,actor:member});assert.equal(claim.mode,'test');assert.ok(claim.lease);
assert.equal((await call('gym_billing_claim',{oid:order.orderId,actor:member})).busy,true);pass('second concurrent claimant is blocked');
await reject(()=>call('gym_billing_finish',{oid:order.orderId,ticket:other,payment_key_value:'pay-fixture',paid_amount:55000,billing_cipher:'encrypted-billing-fixture'}),/잠금/,'stale worker cannot fulfill');
await call('gym_billing_defer',{oid:order.orderId,ticket:claim.lease,code:'PROVIDER_UNAVAILABLE'});
assert.ok((await call('gym_billing_claim',{oid:order.orderId,actor:member})).retryAt);pass('retry delay cannot be bypassed by callback');
await role('postgres');await db.query("update public.gym_checkout_orders set next_attempt_at=now()-interval '1 second' where id=$1",[order.orderId]);
await role('service_role');claim=await call('gym_billing_claim',{oid:order.orderId,actor:member});
await call('gym_billing_store_token',{oid:order.orderId,ticket:claim.lease,ciphertext:'encrypted-billing-fixture'});
const mid=await call('gym_billing_finish',{oid:order.orderId,ticket:claim.lease,payment_key_value:'pay-fixture',paid_amount:55000,billing_cipher:'encrypted-billing-fixture'});
assert.equal((await call('gym_billing_claim',{oid:order.orderId,actor:member})).paid,true);pass('approved order fulfilled once');
await role('authenticated',member);await reject(()=>call('gym_admin_billing',{cid}),/권한/,'ordinary member cannot read admin payment directory');
await role('authenticated',owner);const history=await call('gym_admin_billing',{cid});assert.equal(history.length,1);assert.equal(history[0].mode,'test');assert.ok(history[0].next_payment_at);assert.equal(history[0].payment_key,undefined);assert.equal(history[0].secret,undefined);pass('admin sees test result and next date without keys');
await reject(()=>call('gym_admin_billing',{cid:c2}),/권한/,'other center payments isolated');
await role('postgres');await db.query("update public.gym_memberships set period_end=now()-interval '1 minute' where id=$1",[mid]);
await role('service_role');let due=await call('gym_billing_due',{});assert.equal(due.length,1);assert.equal((await call('gym_billing_due',{}))[0].id,due[0].id);pass('scheduler creates a unique order per cycle');
let rid=due[0].id;claim=await call('gym_billing_claim',{oid:rid,actor:member});
await call('gym_billing_defer',{oid:rid,ticket:claim.lease,code:'PROVIDER_UNAVAILABLE'});
for(let i=0;i<3;i++){
 await role('postgres');await db.query("update public.gym_checkout_orders set next_attempt_at=now()-interval '1 second' where id=$1",[rid]);
 await role('service_role');claim=await call('gym_billing_claim',{oid:rid,actor:member});assert.ok(claim.lease);
 await call('gym_billing_defer',{oid:rid,ticket:claim.lease,code:'PROVIDER_UNAVAILABLE'});
}
assert.equal((await call('gym_billing_claim',{oid:rid,actor:member})).review,true);assert.equal((await call('gym_billing_due',{})).length,0);pass('four ambiguous attempts stop automatically without new order');
claim=await call('gym_billing_claim',{oid:rid,actor:member,review:true});
await call('gym_billing_defer',{oid:rid,ticket:claim.lease,code:'REJECT_CARD_PAYMENT',definitive:true});
await role('postgres');assert.equal((await db.query('select status from public.gym_memberships where id=$1',[mid])).rows[0].status,'PAYMENT_FAILED');pass('definitive rejection never renews entitlement');
await role('authenticated',member);await call('gym_cancel_membership',{mid});
await role('service_role');assert.equal((await call('gym_billing_due',{})).length,0);pass('canceled subscription is not scheduled');
await role('postgres');
for(const [unit,count,days] of [['week',1,7],['week',2,14]]){const r=await db.query("select extract(epoch from (gym_private.gym_period('2026-01-01T00:00:00+09',$1,$2,1)-'2026-01-01T00:00:00+09'::timestamptz))/86400 as span",[unit,count]);assert.equal(Number(r.rows[0].span),days);}
assert.equal(new Date((await db.query("select gym_private.gym_period('2026-01-31T00:00:00+09','month',1,2) as t")).rows[0].t).toISOString(),'2026-03-30T15:00:00.000Z');pass('one week, two weeks and anchored month periods');

await db.query("update public.gym_memberships set status='ACTIVE',cycle_number=2,period_end=now()-interval '2 days' where id=$1",[mid]);
await role('service_role');assert.equal((await call('gym_billing_due',{})).length,0);
await role('postgres');assert.equal((await db.query('select status from public.gym_memberships where id=$1',[mid])).rows[0].status,'PAYMENT_FAILED');pass('long outage does not cause catch-up charges');
await db.query("update public.gym_memberships set status='ACTIVE',cycle_number=3,period_end=now()-interval '1 minute' where id=$1",[mid]);
await role('service_role');due=await call('gym_billing_due',{});assert.equal(due.length,1);
await role('authenticated',member);await call('gym_cancel_membership',{mid});
await role('service_role');await reject(()=>call('gym_billing_claim',{oid:due[0].id,actor:member}),/취소|해지/,'cancellation after enqueue prevents provider claim');
await role('postgres');await db.query("update public.payment_configs set mode='live' where center_id=$1",[cid]);
await db.query("update public.gym_memberships set status='ACTIVE',cycle_number=4,period_end=now()-interval '1 minute' where id=$1",[mid]);
await role('service_role');assert.equal((await call('gym_billing_due',{})).length,0);await reject(()=>call('gym_billing_config_base',{cid,actor:owner}),/운영 계정/,'live configuration cannot be overwritten by test setup');pass('scheduler excludes live contracts');
console.log(`${passed} billing database checks passed`);await db.close();
