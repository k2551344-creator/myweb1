// Execute the actual migration in PostgreSQL (PGlite). Supabase-owned auth and
// storage schemas are minimal fixtures, not the hosted Auth/Storage services.
import {readFileSync,mkdirSync,writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {PGlite} from '../.sites-runtime/sql-check/node_modules/@electric-sql/pglite/dist/index.js';
const migration=readFileSync('supabase/migrations/202609290001_initial.sql','utf8').replace(/^\uFEFF/,'');
const publicTables=['profiles','centers','center_admins','center_members','media_assets','center_appearance','products','product_prices','product_access_centers','payment_configs','subscriptions','subscription_access_centers','subscription_items','lockers','locker_assignments','locker_changes','orders','order_items','payments','payment_attempts','attendance'];
const bootstrap=`
 create role anon nologin;
 create role authenticated nologin;
 create role service_role nologin bypassrls;
 create schema auth; create schema storage;
 create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}',phone text,created_at timestamptz default now());
 create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
 grant usage on schema auth to anon,authenticated,service_role;
 grant execute on function auth.uid() to anon,authenticated,service_role;
 create table storage.buckets(id text primary key,name text not null,public boolean not null default false,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets,name text not null,unique(bucket_id,name));
 alter table storage.objects enable row level security;
 grant usage on schema storage to anon,authenticated,service_role;
 grant select,insert,update,delete on storage.objects to anon,authenticated,service_role;
 create function storage.foldername(name text) returns text[] language sql immutable as $$ select (string_to_array(name,'/'))[1:array_length(string_to_array(name,'/'),1)-1] $$;
 -- Exercise revocation of inherited Supabase-like broad defaults.
 alter default privileges grant all on tables to anon,authenticated,service_role;
 alter default privileges grant execute on functions to anon,authenticated,service_role;
`;
let db;let passes=[];
const u1='10000000-0000-4000-8000-000000000001',u2='10000000-0000-4000-8000-000000000002',u3='10000000-0000-4000-8000-000000000003',admin='10000000-0000-4000-8000-000000000004',staff='10000000-0000-4000-8000-000000000005';
const c1='20000000-0000-4000-8000-000000000001',c2='20000000-0000-4000-8000-000000000002';
const p1='30000000-0000-4000-8000-000000000001',p2='30000000-0000-4000-8000-000000000002';
const price1='40000000-0000-4000-8000-000000000001',price2='40000000-0000-4000-8000-000000000002';
const cfg1='50000000-0000-4000-8000-000000000001',cfg2='50000000-0000-4000-8000-000000000002';
const s1='60000000-0000-4000-8000-000000000001',s2='60000000-0000-4000-8000-000000000002';
const l1='70000000-0000-4000-8000-000000000001',l2='70000000-0000-4000-8000-000000000002';
const media='80000000-0000-4000-8000-000000000001',path=c1+'/'+media+'.png';
const run=sql=>db.exec(sql);
const scalar=async sql=>Object.values((await db.query(sql)).rows[0])[0];
const pass=label=>{passes.push(label);console.log('PASS '+label)};
async function reject(sql,pattern,label){let error;try{await run(sql)}catch(e){error=e}assert(error,'Expected rejection: '+label);if(pattern)assert.match(error.message,pattern);pass(label)}
async function role(name,user=''){await run(`reset role; select set_config('request.jwt.claim.sub','${user}',false); set role ${name}`)}
try{
 db=new PGlite();await db.waitReady;await run(bootstrap);
 await run(`insert into auth.users(id,email,raw_user_meta_data) values('${u1}','member1@test.invalid','{"name":"Existing Member"}')`);
 await run(migration);pass('complete installer executes and commits');
 assert.equal(await scalar("select count(*)::int from pg_tables where schemaname='public'"),21);pass('21 public tables');
 assert.equal(await scalar("select count(*)::int from pg_tables where schemaname='gym_private'"),2);pass('2 private billing tables');
 assert.equal(await scalar("select count(*)::int from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','gym_private') and c.relkind='r' and c.relrowsecurity"),23);pass('RLS enabled on every application table');
 assert.equal(await scalar(`select name from public.profiles where id='${u1}'`),'Existing Member');pass('existing Auth account gets profile');
 await run(`insert into auth.users(id,email,raw_user_meta_data) values('${u2}','member2@test.invalid','{"name":"Second Member"}'),('${u3}','unrelated@test.invalid','{"name":"Attacker","role":"owner"}'),('${admin}','admin@test.invalid','{"name":"Admin"}'),('${staff}','staff@test.invalid','{"name":"Staff"}')`);
 assert.equal(await scalar('select count(*)::int from public.profiles'),5);assert.equal(await scalar('select count(*)::int from public.center_admins'),0);pass('signup trigger creates profile without metadata privilege escalation');
 await run(`
 insert into public.centers(id,name,brand,active) values('${c1}','Center A','BOX',true),('${c2}','Center B','BOX',false);
 insert into public.center_admins(center_id,user_id,role) values('${c1}','${admin}','owner'),('${c1}','${staff}','staff');
 insert into public.center_members(center_id,member_id) values('${c1}','${u1}'),('${c2}','${u2}');
 insert into public.center_appearance(center_id) values('${c1}'),('${c2}');
 insert into public.products(id,center_id,name) values('${p1}','${c1}','Monthly A'),('${p2}','${c2}','Monthly B');
 insert into public.product_prices(id,product_id,amount,created_by) values('${price1}','${p1}',99000,'${admin}'),('${price2}','${p2}',129000,'${admin}');
 insert into public.payment_configs(id,center_id,provider) values('${cfg1}','${c1}','mock'),('${cfg2}','${c2}','mock');
 insert into public.subscriptions(id,member_id,center_id,product_id,price_id,payment_config_id,status,current_period_start,current_period_end,weekly_limit,unit_amount)
 values('${s1}','${u1}','${c1}','${p1}','${price1}','${cfg1}','ACTIVE','2026-09-01','2026-10-01',3,99000),('${s2}','${u2}','${c2}','${p2}','${price2}','${cfg2}','ACTIVE','2026-09-01','2026-10-01',2,129000);
 insert into public.lockers(id,center_id,number) values('${l1}','${c1}','A-01'),('${l2}','${c2}','B-01');
 insert into public.payments(center_id,member_id,config_id,subscription_id,amount,provider,status,request_id)
 values('${c1}','${u1}','${cfg1}','${s1}',99000,'mock','PAID',gen_random_uuid()),('${c2}','${u2}','${cfg2}','${s2}',129000,'mock','PAID',gen_random_uuid());
 insert into public.media_assets(id,center_id,object_path,mime_type,byte_size,created_by) values('${media}','${c1}','${path}','image/png',100,'${admin}');
 insert into storage.objects(bucket_id,name) values('center-media','${path}');
 `);pass('representative linked center/member/product/subscription/payment data inserts');
 await role('anon');
 assert.equal(await scalar('select count(*)::int from public.centers'),1);assert.equal(await scalar('select count(*)::int from public.products'),1);assert.equal(await scalar('select count(*)::int from public.product_prices'),1);pass('anonymous catalog hides inactive center');
 await reject('select * from public.profiles',/permission denied/,'anonymous cannot read profiles');
 await reject('select * from public.payments',/permission denied/,'anonymous cannot read payments');
 assert.equal(await scalar('select count(*)::int from storage.objects'),0);pass('unpublished image not readable anonymously');
 await role('authenticated',u1);
 assert.equal(await scalar('select count(*)::int from public.profiles'),1);assert.equal(await scalar('select count(*)::int from public.subscriptions'),1);assert.equal(await scalar('select count(*)::int from public.payments'),1);pass('member sees own personal records only');
 await reject(`update public.subscriptions set unit_amount=0 where id='${s1}'`,/permission denied/,'member cannot rewrite purchased price');
 await reject(`insert into public.center_admins values('${c1}','${u1}','owner',now())`,/permission denied/,'member cannot self-promote');
 await reject('select * from gym_private.payment_accounts',/permission denied/,'member cannot access billing secrets');
 for(const table of publicTables){assert.equal(await scalar(`select has_table_privilege('authenticated','public.${table}','INSERT,UPDATE,DELETE,TRUNCATE')`),false)}pass('all browser business writes explicitly closed');
 await role('authenticated',admin);
 assert.equal(await scalar('select count(*)::int from public.subscriptions'),1);assert.equal(await scalar('select count(*)::int from public.payments'),1);
 assert.equal(await scalar(`select count(*)::int from public.profiles where id='${u2}'`),0);pass('center administrator cannot read another center member records');
 await run(`insert into storage.objects(bucket_id,name) values('center-media','${c1}/90000000-0000-4000-8000-000000000001.png')`);pass('manager uploads into own center');
 await reject(`insert into storage.objects(bucket_id,name) values('center-media','${c2}/90000000-0000-4000-8000-000000000002.png')`,/row-level security/,'cross-center image upload denied');
 await role('authenticated',staff);
 await reject(`insert into storage.objects(bucket_id,name) values('center-media','${c1}/90000000-0000-4000-8000-000000000003.png')`,/row-level security/,'read-only staff cannot upload');
 await role('service_role');
 await run(`insert into gym_private.payment_accounts(config_id,secret_reference) values('${cfg1}','vault-ref-only')`);
 assert.equal(await scalar('select count(*)::int from gym_private.payment_accounts'),1);pass('trusted server has explicit private billing access');
 await run(`update public.products set image_id='${media}' where id='${p1}'`);
 await role('anon');assert.equal(await scalar('select count(*)::int from storage.objects'),1);pass('published catalog image readable without exposing orphan uploads');
 await role('service_role');await run(`update public.products set selling=false where id='${p1}'`);
 await role('anon');assert.equal(await scalar('select count(*)::int from public.products'),0);assert.equal(await scalar('select count(*)::int from storage.objects'),0);pass('retired product and image disappear from public catalog');
 await role('authenticated',u1);assert.equal(await scalar(`select count(*)::int from public.products where id='${p1}'`),1);pass('buyer retains retired product title in membership history');
 await role('authenticated',u3);assert.equal(await scalar('select count(*)::int from public.subscriptions'),0);assert.equal(await scalar('select count(*)::int from public.products'),0);pass('unrelated member sees no private purchases');
 await role('service_role');
 await reject(`insert into public.payments(center_id,member_id,config_id,subscription_id,amount,provider,status,request_id) values('${c1}','${u2}','${cfg1}','${s1}',99000,'mock','PAID',gen_random_uuid())`,/foreign key/,'payment cannot name a different member than its subscription');
 await reject(`insert into public.payments(center_id,member_id,config_id,subscription_id,amount,provider,status,request_id) values('${c1}','${u1}','${cfg2}','${s1}',99000,'mock','PAID',gen_random_uuid())`,/foreign key/,'payment cannot use another center configuration');
 await reject(`insert into public.subscriptions(member_id,center_id,product_id,price_id,payment_config_id,status,current_period_start,current_period_end,weekly_limit,unit_amount) values('${u3}','${c1}','${p1}','${price2}','${cfg1}','ACTIVE','2026-09-01','2026-10-01',3,1)`,/foreign key/,'subscription price belongs to its product');
 await reject(`insert into public.locker_assignments(center_id,locker_id,subscription_id,starts_at,ends_at,monthly_amount) values('${c1}','${l2}','${s1}','2026-09-01','2026-10-01',10000)`,/foreign key/,'locker assignment cannot cross centers');
 await run(`insert into public.locker_assignments(center_id,locker_id,subscription_id,starts_at,ends_at,monthly_amount) values('${c1}','${l1}','${s1}','2026-09-01','2026-10-01',10000)`);
 await reject(`insert into public.locker_assignments(center_id,locker_id,subscription_id,starts_at,ends_at,monthly_amount) values('${c1}','${l1}','${s1}','2026-09-01','2026-10-01',10000)`,/unique/,'locker cannot have duplicate current assignments');
 await reject(`update public.product_prices set amount=1 where id='${price1}'`,/가격 이력/,'price history cannot be edited');
 await reject(`delete from public.product_prices where id='${price1}'`,/가격 이력/,'price history cannot be deleted');
 await reject(`update public.products set stock=-1 where id='${p1}'`,/check constraint/,'negative inventory rejected');
 await run(`insert into public.attendance(member_id,center_id,subscription_id,product_id,occurred_at,success,reason) values('${u1}','${c1}','${s1}','${p1}','2026-09-29T15:05:00Z',true,'입장 완료')`);
 assert.equal(await scalar("select korean_date::text from public.attendance limit 1"),'2026-09-30');pass('attendance derives Korean date from timestamp');
 await reject(`insert into public.attendance(member_id,center_id,subscription_id,product_id,occurred_at,success,reason) values('${u1}','${c1}','${s1}','${p1}','2026-09-29T16:05:00Z',true,'duplicate')`,/unique/,'duplicate successful daily attendance rejected');
 await run(`insert into public.attendance(member_id,center_id,occurred_at,success,reason) values('${u1}','${c1}','2026-09-29T16:05:00Z',false,'거부')`);pass('denied attendance retained beside success');
 await reject(`insert into public.attendance(member_id,center_id,subscription_id,product_id,success,reason) values('${u2}','${c1}','${s1}','${p1}',true,'spoof')`,/foreign key/,'attendance subscription must belong to member');
 await role('postgres');
 const rowsBefore=await scalar('select count(*)::int from public.payments');let repeatError;try{await run(migration)}catch(e){repeatError=e;await run('rollback')}
 assert(repeatError);assert.match(repeatError.message,/이미 있습니다/);assert.equal(await scalar('select count(*)::int from public.payments'),rowsBefore);pass('rerun stops without changing existing data');
 if(readFileSync('supabase/setup/02_설치확인.sql','utf8')){const checks=await db.query(readFileSync('supabase/setup/02_설치확인.sql','utf8').replace(/^\uFEFF/,''));assert(checks.rows.length>=8);assert(checks.rows.every(r=>r.result==='PASS'),JSON.stringify(checks.rows));pass('user-facing verification SQL reports all PASS')}
 await db.close();db=new PGlite();await db.waitReady;await run(bootstrap);await run('create table public.products(note text); insert into public.products values (\'preserve me\')');
 let collision;try{await run(migration)}catch(e){collision=e;await run('rollback')};assert(collision);assert.equal(await scalar('select note from public.products'),'preserve me');assert.equal(await scalar("select count(*)::int from pg_namespace where nspname='gym_private'"),0);pass('pre-existing table preserved and installation remains atomic');
 mkdirSync('supabase/setup',{recursive:true});writeFileSync('supabase/setup/검증결과.json',JSON.stringify({testedAt:new Date().toISOString(),engine:'PGlite PostgreSQL 0.5.8',supabaseSystemSchemas:'auth/storage minimal fixtures; hosted services not tested',passed:passes.length,checks:passes},null,2));console.log(`\n${passes.length} checks passed.`);
}catch(e){console.error(e.message);console.error(e.stack);process.exitCode=1}finally{if(db)await db.close()}
