import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {PGlite} from '../.sites-runtime/sql-check/node_modules/@electric-sql/pglite/dist/index.js';
process.on('uncaughtException',e=>{console.error(e.message,e.where??'');process.exit(1)});
const db=new PGlite();await db.waitReady;let passed=0;const pass=s=>{passed++;console.log('PASS '+s)};
const source=readFileSync('tests/supabase-schema.mjs','utf8');await db.exec(source.split('const bootstrap=`')[1].split('`;')[0]);
for(const file of ['202609290001_initial.sql','202609290002_catalog.sql','202610120001_member_commerce.sql','202610120002_email_kiosk.sql','202610120002_email_kiosk.sql'])await db.exec(readFileSync('supabase/migrations/'+file,'utf8'));pass('additive migration and repeat');
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
const base={centerId:cid,name:'2주 회원권',description:'intro',category:'회원권',details:'상세',terms:'약관 v1',cancellationNotice:'해지 v1',intervalUnit:'week',intervalCount:2,price:50000,recurring:false,weeklyLimit:3,capacity:10,stock:0,active:true,selling:true,sort:1,accessCenters:[cid]};
const pid=await payload('gym_save_product_v2',base),lid=await payload('gym_save_locker',{centerId:cid,number:'A01',location:'입구',price:5000,status:'AVAILABLE'});
await role('authenticated',member);await reject(()=>payload('gym_save_product_v2',{...base,id:pid}),/권한/,'member product edit denied');await reject(()=>payload('gym_save_locker',{centerId:cid,number:'bad',price:0,status:'AVAILABLE'}),/권한/,'member locker edit denied');
await reject(()=>call('gym_save_toss',{actor:owner,payload:JSON.stringify({centerId:cid}),ciphertext:'xxxxxxxxxxxxxxxxxxxx'}),/permission denied/,'browser secret write denied');
await role('service_role');await call('gym_save_toss',{actor:owner,payload:JSON.stringify({centerId:cid,mode:'test',enabled:true,paymentClientKey:'test_ck_fixture',billingClientKey:'test_ck_fixture',merchantLabel:'A'}),ciphertext:'encrypted-fixture-12345678'});pass('branch credential configured by server');
await reject(()=>call('gym_save_toss',{actor:member,payload:JSON.stringify({centerId:cid}),ciphertext:'xxxxxxxxxxxxxxxxxxxx'}),/소유자/,'server checks actual branch owner');
await role('authenticated',member);await reject(()=>payload('gym_prepare_checkout',{productId:pid,revision:2,agreed:true}),/전화번호/,'profile required');await payload('gym_update_profile',{name:'회원 A',phone:'010-1234-5678'});
await reject(()=>payload('gym_update_profile',{name:'',phone:'123'}),/이름/,'invalid profile rejected');await reject(()=>payload('gym_prepare_checkout',{productId:pid,revision:2,agreed:false}),/동의/,'terms consent required');await reject(()=>payload('gym_prepare_checkout',{productId:pid,revision:1,agreed:true}),/변경/,'stale terms revision rejected');
const order=await payload('gym_prepare_checkout',{productId:pid,revision:2,agreed:true,lockerId:lid,amount:1});assert.equal(order.amount,55000);pass('server computes membership and locker price');
await role('authenticated',other);await payload('gym_update_profile',{name:'회원 B',phone:'01099998888'});await reject(()=>payload('gym_prepare_checkout',{productId:pid,revision:2,agreed:true,lockerId:lid}),/락카/,'locker double-booking blocked');assert.equal((await db.query('select * from public.gym_checkout_orders')).rows.length,0);pass('checkout records isolated');
await reject(()=>call('gym_claim_payment',{oid:order.orderId,actor:member}),/permission denied/,'browser cannot access merchant secrets');await role('service_role');await reject(()=>call('gym_claim_payment',{oid:order.orderId,actor:other}),/권한/,'callback bound to customer');await call('gym_claim_payment',{oid:order.orderId,actor:member});await reject(()=>call('gym_finish_payment',{oid:order.orderId,payment_key_value:'pay1',paid_amount:1}),/일치/,'wrong payment amount rejected');
const mid=await call('gym_finish_payment',{oid:order.orderId,payment_key_value:'pay1',paid_amount:55000});assert.equal(await call('gym_finish_payment',{oid:order.orderId,payment_key_value:'pay1',paid_amount:55000}),mid);pass('payment completion idempotent');
await role('postgres');let m=(await db.query('select * from public.gym_memberships where id=$1',[mid])).rows[0];assert.equal((new Date(m.period_end)-new Date(m.period_start))/86400000,14);assert.equal(m.locker_amount,5000);pass('one-time two-week period and locker snapshot');
await role('authenticated',member);await reject(()=>call('gym_kiosk_admin',{cid,action:'create'}),/권한/,'member cannot register terminal');
await role('authenticated',owner);await reject(()=>call('gym_kiosk_admin',{cid:c2,action:'create'}),/권한/,'cross-center terminal denied');
const device=await call('gym_kiosk_admin',{cid,action:'create'});assert.ok(device.token.length>60);pass('terminal gets separate strong credential');
await role('anon');await reject(()=>call('gym_kiosk_lookup',{token:'bad',suffix:'5678'}),/기기/,'unregistered device blocked');
await reject(()=>db.query('select * from gym_private.kiosk_devices'),/permission denied/,'device secrets private');
await reject(()=>db.query('select * from public.gym_attendance'),/permission denied/,'attendance private');
let lookup=await call('gym_kiosk_lookup',{token:device.token,suffix:'5678'});assert.equal(lookup.items.length,1);assert.equal(lookup.items[0].name,'회원 A');assert.deepEqual(Object.keys(lookup.items[0]).sort(),['candidate','name']);pass('lookup returns name and opaque candidate only');
const first=lookup.items[0].candidate;await call('gym_kiosk_lookup',{token:device.token,suffix:'8888'});await reject(()=>call('gym_kiosk_checkin',{token:device.token,candidate:first}),/확인 시간/,'new lookup invalidates old selection');
lookup=await call('gym_kiosk_lookup',{token:device.token,suffix:'5678'});await call('gym_kiosk_checkin',{token:device.token,candidate:lookup.items[0].candidate});const again=await call('gym_kiosk_checkin',{token:device.token,candidate:lookup.items[0].candidate});assert.match(again.message,/이미/);pass('tap and countdown cannot double-checkin');
await role('postgres');assert.equal((await db.query('select * from public.gym_attendance')).rows.length,1);await db.exec('delete from public.gym_attendance');await db.query("update public.gym_memberships set period_end=now()-interval '1 minute' where id=$1",[mid]);
await role('anon');await reject(()=>call('gym_kiosk_checkin',{token:device.token,candidate:lookup.items[0].candidate}),/회원권/,'expired membership rejected');
await role('postgres');await db.query("update public.gym_memberships set period_end=now()+interval '1 day',status='PAYMENT_FAILED' where id=$1",[mid]);
await role('anon');await reject(()=>call('gym_kiosk_checkin',{token:device.token,candidate:lookup.items[0].candidate}),/회원권/,'payment failed rejected');
await role('postgres');await db.query("update public.gym_memberships set status='CANCEL_AT_PERIOD_END',weekly_limit=1 where id=$1",[mid]);
// Insert a same-week historical attendance when today is not Monday; direct timestamps are fixtures only.
const day=Number((await db.query("select extract(isodow from now() at time zone 'Asia/Seoul') as day")).rows[0].day);
if(day>1){await db.query("insert into public.gym_attendance(member_id,center_id,membership_id,occurred_at) values($1,$2,$3,now()-interval '1 day')",[member,cid,mid]);await role('anon');await reject(()=>call('gym_kiosk_checkin',{token:device.token,candidate:lookup.items[0].candidate}),/횟수/,'weekly limit enforced');await role('postgres');await db.exec('delete from public.gym_attendance')}
await db.query("update gym_private.kiosk_candidates set expires_at=now()-interval '1 minute' where id=$1",[lookup.items[0].candidate]);await role('anon');await reject(()=>call('gym_kiosk_checkin',{token:device.token,candidate:lookup.items[0].candidate}),/확인 시간/,'expired selection rejected');
await role('postgres');await db.query("insert into auth.users(id,email,raw_user_meta_data) values(gen_random_uuid(),'signup@test.invalid',$1)",[JSON.stringify({name:'신규 회원',phone:'010-9999-1234',role:'owner'})]);const profile=(await db.query("select p.* from public.profiles p join auth.users u on u.id=p.id where u.email='signup@test.invalid'")).rows[0];assert.equal(profile.phone,'01099991234');assert.equal(profile.name,'신규 회원');assert.equal((await db.query('select * from public.center_admins where user_id=$1',[profile.id])).rows.length,0);pass('signup profile captures phone without role escalation');

await db.query("insert into public.gym_attendance(member_id,center_id,membership_id,occurred_at) values($1,$2,$3,'2026-10-11 23:59:59+09'),($1,$2,$3,'2026-10-12 00:00:00+09')",[member,cid,mid]);
assert.equal((await db.query("select gym_private.kiosk_week_visits($1,'2026-10-13') as n",[member])).rows[0].n,1);pass('weekly count resets Monday in Korean timezone');await db.exec('delete from public.gym_attendance');
await db.query("insert into public.gym_memberships select (jsonb_populate_record(null::public.gym_memberships,to_jsonb(m)||jsonb_build_object('id',gen_random_uuid(),'member_id',$1::uuid))).* from public.gym_memberships m where id=$2",[other,mid]);
await db.query("update public.profiles set phone='01099995678' where id=$1",[other]);
await role('anon');const duplicates=await call('gym_kiosk_lookup',{token:device.token,suffix:'5678'});assert.equal(duplicates.items.length,2);assert.notEqual(duplicates.items[0].candidate,duplicates.items[1].candidate);pass('shared phone suffix returns distinct choices');
await role('authenticated',owner);const secondDevice=await call('gym_kiosk_admin',{cid,action:'create'});await role('anon');await reject(()=>call('gym_kiosk_checkin',{token:secondDevice.token,candidate:duplicates.items[0].candidate}),/확인 시간/,'selection cannot move between devices');
await call('gym_kiosk_checkin',{token:device.token,candidate:duplicates.items[0].candidate});pass('canceled renewal retains paid attendance access');
await role('authenticated',profile.id);assert.equal((await db.query('select * from public.gym_attendance')).rows.length,0);pass('attendance RLS hides other members');await role('postgres');
await db.query('update gym_private.kiosk_devices set requests=20,window_start=now() where id=$1',[device.id]);await role('anon');assert.ok((await call('gym_kiosk_lookup',{token:device.token,suffix:'5678'})).error);pass('terminal lookup rate limited');
await role('authenticated',owner);await call('gym_kiosk_admin',{cid,action:'revoke',device:device.id});await role('anon');await reject(()=>call('gym_kiosk_lookup',{token:device.token,suffix:'5678'}),/기기/,'revocation blocks terminal immediately');
console.log(`${passed} kiosk and integration checks passed`);await db.close();
