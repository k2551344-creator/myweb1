-- 03번 웹 연결 SQL 다음 실행. 기존 회원/거래 데이터 보존.
begin;
alter table public.centers add column if not exists business_name text not null default '', add column if not exists representative text not null default '', add column if not exists business_address text not null default '', add column if not exists business_phone text not null default '';
alter table public.products add column if not exists details text not null default '', add column if not exists terms text not null default '', add column if not exists cancellation_notice text not null default '', add column if not exists interval_unit text not null default 'month' check(interval_unit in ('week','month')), add column if not exists interval_count integer not null default 1 check(interval_count between 1 and 36), add column if not exists revision integer not null default 1;
alter table public.lockers add column if not exists cycle_price bigint not null default 0 check(cycle_price>=0);
alter table public.payment_configs add column if not exists payment_client_key text not null default '', add column if not exists billing_client_key text not null default '', add column if not exists secret_configured boolean not null default false;
create table if not exists public.gym_memberships (
 id uuid primary key default gen_random_uuid(),member_id uuid not null references public.profiles,center_id uuid not null references public.centers,product_id uuid not null references public.products,config_id uuid not null references public.payment_configs,
 product_name text not null,unit_amount bigint not null check(unit_amount>0),locker_id uuid references public.lockers,locker_amount bigint not null default 0 check(locker_amount>=0),
 recurring boolean not null,interval_unit text not null check(interval_unit in ('week','month')),interval_count integer not null check(interval_count between 1 and 36),
 status text not null check(status in ('ACTIVE','CANCEL_AT_PERIOD_END','EXPIRED','PAYMENT_FAILED')),period_start timestamptz not null,period_end timestamptz not null,anchor_at timestamptz not null,cycle_number integer not null default 1,
 terms_snapshot text not null,cancellation_snapshot text not null,weekly_limit integer not null,access_centers uuid[] not null,created_at timestamptz not null default now(),canceled_at timestamptz
);
create unique index if not exists gym_member_open on public.gym_memberships(member_id) where status<>'EXPIRED';
create table if not exists public.gym_checkout_orders (
 id uuid primary key default gen_random_uuid(),member_id uuid not null references public.profiles,center_id uuid not null references public.centers,product_id uuid not null references public.products,config_id uuid not null references public.payment_configs,
 membership_id uuid references public.gym_memberships,product_name text not null,unit_amount bigint not null check(unit_amount>0),locker_id uuid references public.lockers,locker_amount bigint not null default 0 check(locker_amount>=0),
 recurring boolean not null,interval_unit text not null check(interval_unit in ('week','month')),interval_count integer not null check(interval_count between 1 and 36),
 terms_snapshot text not null,cancellation_snapshot text not null,consented_at timestamptz not null,weekly_limit integer not null,access_centers uuid[] not null,
 status text not null default 'PENDING' check(status in ('PENDING','PROCESSING','PAID','FAILED','CANCELED')),expires_at timestamptz not null default now()+interval '15 minutes',created_at timestamptz not null default now(),
 payment_key text unique,paid_at timestamptz,renewal_cycle integer,unique(membership_id,renewal_cycle)
);
create table if not exists gym_private.gym_billing_tokens(membership_id uuid primary key references public.gym_memberships,encrypted_token text not null);
create table if not exists gym_private.gym_checkout_tokens(order_id uuid primary key references public.gym_checkout_orders,encrypted_token text not null);
alter table gym_private.gym_checkout_tokens enable row level security;
revoke all on gym_private.gym_checkout_tokens from public,anon,authenticated;
grant all on gym_private.gym_checkout_tokens to service_role;
alter table public.gym_memberships enable row level security;
alter table public.gym_checkout_orders enable row level security;
alter table gym_private.gym_billing_tokens enable row level security;
revoke all on public.gym_memberships,public.gym_checkout_orders,gym_private.gym_billing_tokens from public,anon,authenticated;
grant select on public.gym_memberships,public.gym_checkout_orders to authenticated;
grant all on public.gym_memberships,public.gym_checkout_orders,gym_private.gym_billing_tokens to service_role;
drop policy if exists gym_membership_read on public.gym_memberships;
create policy gym_membership_read on public.gym_memberships for select to authenticated using(member_id=auth.uid() or gym_private.is_center_admin(center_id));
drop policy if exists gym_checkout_read on public.gym_checkout_orders;
create policy gym_checkout_read on public.gym_checkout_orders for select to authenticated using(member_id=auth.uid() or gym_private.is_center_admin(center_id));
create or replace function public.gym_save_center_v2(payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare cid uuid;
begin
 cid:=public.gym_save_center(payload);
 update public.centers set business_name=left(coalesce(payload->>'businessName',business_name),150),representative=left(coalesce(payload->>'representative',representative),150),business_address=left(coalesce(payload->>'businessAddress',business_address),500),business_phone=left(coalesce(payload->>'businessPhone',business_phone),30) where id=cid;
 return cid;
end $$;
create or replace function public.gym_save_product_v2(payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare pid uuid;
begin
 if length(coalesce(payload->>'details',''))>15000 or length(coalesce(payload->>'terms',''))>20000 or length(coalesce(payload->>'cancellationNotice',''))>10000 then raise exception '설명 또는 약관이 너무 깁니다.'; end if;
 pid:=public.gym_save_product(payload);
 update public.products set details=coalesce(payload->>'details',''),terms=coalesce(payload->>'terms',''),cancellation_notice=coalesce(payload->>'cancellationNotice',''),interval_unit=coalesce(payload->>'intervalUnit','month'),interval_count=coalesce((payload->>'intervalCount')::integer,1),revision=revision+1 where id=pid;
 return pid;
end $$;
create or replace function public.gym_update_profile(payload jsonb) returns void language plpgsql security definer set search_path='' as $$
declare phone_value text:=regexp_replace(coalesce(payload->>'phone',''),'[^0-9]','','g');
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
 if length(btrim(coalesce(payload->>'name',''))) not between 1 and 150 or length(phone_value) not between 9 and 15 then raise exception '이름과 전화번호를 확인해 주세요.'; end if;
 update public.profiles set name=btrim(payload->>'name'),phone=phone_value where id=auth.uid();
end $$;
create or replace function public.gym_save_locker(payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare cid uuid:=(payload->>'centerId')::uuid; lid uuid:=nullif(payload->>'id','')::uuid;
begin
 if auth.uid() is null or not gym_private.can_manage_center(cid) then raise exception '락카 관리 권한이 없습니다.'; end if;
 perform 1 from public.centers where id=cid for update;
 if payload->>'status' not in ('AVAILABLE','MAINTENANCE','DISABLED') then raise exception '락카 상태를 확인해 주세요.'; end if;
 if lid is not null then
  if not exists(select 1 from public.lockers where id=lid and center_id=cid) then raise exception '다른 지점의 락카입니다.'; end if;
  if exists(select 1 from public.gym_memberships where locker_id=lid and (period_end>now() or (recurring and status in ('ACTIVE','PAYMENT_FAILED')))) or exists(select 1 from public.gym_checkout_orders where locker_id=lid and (status='PROCESSING' or (status='PENDING' and expires_at>now()))) or exists(select 1 from public.locker_assignments where locker_id=lid and released_at is null) then raise exception '사용 또는 결제 중인 락카는 수정할 수 없습니다.'; end if;
 else
  insert into public.lockers(center_id,number) values(cid,payload->>'number') returning id into lid;
 end if;
 update public.lockers set number=payload->>'number',location=left(coalesce(payload->>'location',''),150),cycle_price=(payload->>'price')::bigint,status=payload->>'status' where id=lid;
 return lid;
end $$;
create or replace function public.gym_save_toss(actor uuid,payload jsonb,ciphertext text) returns uuid language plpgsql security definer set search_path='' as $$
declare cid uuid:=(payload->>'centerId')::uuid; cfg uuid;
begin
 if not exists(select 1 from public.center_admins where center_id=cid and user_id=actor and role='owner') then raise exception '지점 소유자만 결제 계정을 설정할 수 있습니다.'; end if;
 perform 1 from public.centers where id=cid for update;
 if length(ciphertext)<20 then raise exception '암호화된 비밀 키가 필요합니다.'; end if;
 update public.payment_configs set is_current=false where center_id=cid and is_current;
 insert into public.payment_configs(center_id,provider,mode,merchant_label,enabled,payment_client_key,billing_client_key,secret_configured)
 values(cid,'toss',payload->>'mode',left(coalesce(payload->>'merchantLabel',''),150),coalesce((payload->>'enabled')::boolean,false),payload->>'paymentClientKey',coalesce(payload->>'billingClientKey',''),true) returning id into cfg;
 insert into gym_private.payment_accounts(config_id,secret_reference) values(cfg,ciphertext);
 return cfg;
end $$;
-- Period arithmetic uses the original anchor to avoid month-end drift.
create or replace function gym_private.gym_period(anchor_at timestamptz,unit text,count_value integer,cycle integer) returns timestamptz language sql immutable set search_path='' as $$
 select ((anchor_at at time zone 'Asia/Seoul') + case when unit='week' then make_interval(days=>7*count_value*cycle) else make_interval(months=>count_value*cycle) end) at time zone 'Asia/Seoul';
$$;
create or replace function public.gym_prepare_checkout(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.products; cfg public.payment_configs; price bigint; locker public.lockers; lid uuid:=nullif(payload->>'lockerId','')::uuid; oid uuid; actor uuid:=auth.uid();
begin
 if actor is null then raise exception '로그인이 필요합니다.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 if not exists(select 1 from public.profiles where id=actor and length(btrim(name))>0 and phone ~ '^[0-9]{9,15}$') then raise exception '이름과 전화번호를 먼저 저장해 주세요.'; end if;
 select * into p from public.products where id=(payload->>'productId')::uuid;
 if p.id is null then raise exception '상품을 찾을 수 없습니다.'; end if;
 perform 1 from public.centers where id=p.center_id and active for update;
 if not found or not p.active or not p.selling then raise exception '판매 중인 상품이 아닙니다.'; end if;
 -- Re-read after center lock to serialize against price/terms changes.
 select * into p from public.products where id=p.id;
 if not p.active or not p.selling or (payload->>'revision')::integer is distinct from p.revision then raise exception '상품 내용이 변경되었습니다. 다시 확인해 주세요.'; end if;
 if coalesce((payload->>'agreed')::boolean,false)=false or btrim(p.terms)='' then raise exception '결제 약관을 확인하고 동의해 주세요.'; end if;
 update public.gym_memberships set status='EXPIRED' where member_id=actor and period_end<=now() and (not recurring or status='CANCEL_AT_PERIOD_END');
 if exists(select 1 from public.gym_memberships where member_id=actor and status<>'EXPIRED') or exists(select 1 from public.subscriptions where member_id=actor and status<>'EXPIRED' and current_period_end>current_date) then raise exception '이미 이용 중인 회원권이 있습니다.'; end if;
 if exists(select 1 from public.gym_checkout_orders where member_id=actor and status='PROCESSING') then raise exception '이전 결제가 처리 중입니다. 완료 후 다시 시도해 주세요.'; end if;
 update public.gym_checkout_orders set status='CANCELED' where member_id=actor and status='PENDING';
 if p.capacity>0 and (select count(*) from public.gym_memberships where product_id=p.id and status<>'EXPIRED' and (period_end>now() or (recurring and status in ('ACTIVE','PAYMENT_FAILED'))))+(select count(*) from public.gym_checkout_orders where product_id=p.id and (status='PROCESSING' or (status='PENDING' and expires_at>now())))>=p.capacity then raise exception '상품 정원이 마감되었습니다.'; end if;
 select * into cfg from public.payment_configs where center_id=p.center_id and is_current and enabled and provider='toss' and secret_configured;
 if cfg.id is null or (p.recurring and cfg.billing_client_key='') or (not p.recurring and cfg.payment_client_key='') then raise exception '센터의 결제 연결이 아직 준비되지 않았습니다.'; end if;
 select amount into price from public.product_prices where product_id=p.id and effective_at<=now() order by effective_at desc,id desc limit 1;
 if price is null or price<=0 then raise exception '결제 금액을 확인해 주세요.'; end if;
 if lid is not null then
  select * into locker from public.lockers where id=lid and center_id=p.center_id and status='AVAILABLE' for update;
  if locker.id is null or exists(select 1 from public.gym_memberships where locker_id=lid and (period_end>now() or (recurring and status in ('ACTIVE','PAYMENT_FAILED')))) or exists(select 1 from public.gym_checkout_orders where locker_id=lid and (status='PROCESSING' or (status='PENDING' and expires_at>now()))) or exists(select 1 from public.locker_assignments where locker_id=lid and released_at is null) then raise exception '선택한 락카는 사용할 수 없습니다.'; end if;
 end if;
 insert into public.gym_checkout_orders(member_id,center_id,product_id,config_id,product_name,unit_amount,locker_id,locker_amount,recurring,interval_unit,interval_count,terms_snapshot,cancellation_snapshot,consented_at,weekly_limit,access_centers)
 values(actor,p.center_id,p.id,cfg.id,p.name,price,lid,coalesce(locker.cycle_price,0),p.recurring,p.interval_unit,p.interval_count,p.terms,p.cancellation_notice,now(),p.weekly_limit,array(select center_id from public.product_access_centers where product_id=p.id)) returning id into oid;
 return jsonb_build_object('orderId',oid,'amount',price+coalesce(locker.cycle_price,0),'orderName',p.name||case when lid is null then '' else ' + 락카' end,'clientKey',case when p.recurring then cfg.billing_client_key else cfg.payment_client_key end,'recurring',p.recurring,'customerKey',actor);
end $$;
create or replace function public.gym_claim_payment(oid uuid,actor uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.gym_checkout_orders; secret_value text; token_value text;
begin
 select * into o from public.gym_checkout_orders where id=oid for update;
 if o.id is null or o.member_id is distinct from actor then raise exception '결제 권한이 없습니다.'; end if;
 if o.status='PAID' then return jsonb_build_object('paid',true); end if;
 if o.status not in ('PENDING','PROCESSING') or (o.status='PENDING' and o.expires_at<=now()) then raise exception '만료되거나 취소된 결제입니다.'; end if;
 update public.gym_checkout_orders set status='PROCESSING' where id=oid;
 select secret_reference into secret_value from gym_private.payment_accounts where config_id=o.config_id;
 select encrypted_token into token_value from gym_private.gym_billing_tokens where membership_id=o.membership_id;
 if token_value is null then select encrypted_token into token_value from gym_private.gym_checkout_tokens where order_id=oid; end if;
 return to_jsonb(o)||jsonb_build_object('secret',secret_value,'token',token_value,'paid',false);
end $$;
create or replace function public.gym_finish_payment(oid uuid,payment_key_value text,paid_amount bigint,billing_cipher text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare o public.gym_checkout_orders; mid uuid; m public.gym_memberships;
begin
 select * into o from public.gym_checkout_orders where id=oid for update;
 if o.id is null then raise exception '주문이 없습니다.'; end if;
 if o.status='PAID' then return o.membership_id; end if;
 if o.status<>'PROCESSING' or paid_amount<>o.unit_amount+o.locker_amount or coalesce(payment_key_value,'')='' then raise exception '결제 승인 정보가 일치하지 않습니다.'; end if;
 if o.membership_id is null then
  if o.recurring and coalesce(billing_cipher,'')='' then raise exception '자동결제 인증 정보가 없습니다.'; end if;
  insert into public.gym_memberships(member_id,center_id,product_id,config_id,product_name,unit_amount,locker_id,locker_amount,recurring,interval_unit,interval_count,status,period_start,period_end,anchor_at,terms_snapshot,cancellation_snapshot,weekly_limit,access_centers)
  values(o.member_id,o.center_id,o.product_id,o.config_id,o.product_name,o.unit_amount,o.locker_id,o.locker_amount,o.recurring,o.interval_unit,o.interval_count,'ACTIVE',now(),gym_private.gym_period(now(),o.interval_unit,o.interval_count,1),now(),o.terms_snapshot,o.cancellation_snapshot,o.weekly_limit,o.access_centers) returning id into mid;
  if o.recurring then insert into gym_private.gym_billing_tokens values(mid,billing_cipher); end if;
 else
  mid:=o.membership_id;select * into m from public.gym_memberships where id=mid for update;
  if o.renewal_cycle<>m.cycle_number+1 then raise exception '결제 회차가 일치하지 않습니다.'; end if;
  update public.gym_memberships set period_start=period_end,period_end=gym_private.gym_period(anchor_at,interval_unit,interval_count,o.renewal_cycle),cycle_number=o.renewal_cycle,status='ACTIVE' where id=mid;
 end if;
 insert into public.center_members(center_id,member_id) values(o.center_id,o.member_id) on conflict do nothing;
 update public.gym_checkout_orders set status='PAID',membership_id=mid,payment_key=payment_key_value,paid_at=now() where id=oid;
 return mid;
end $$;
create or replace function public.gym_cancel_membership(mid uuid) returns void language plpgsql security definer set search_path='' as $$
declare m public.gym_memberships;
begin
 select * into m from public.gym_memberships where id=mid and member_id=auth.uid() for update;
 if m.id is null then raise exception '본인 회원권만 해지할 수 있습니다.'; end if;
 if not m.recurring or m.status not in ('ACTIVE','PAYMENT_FAILED','CANCEL_AT_PERIOD_END') then raise exception '해지할 정기결제가 없습니다.'; end if;
 if exists(select 1 from public.gym_checkout_orders where membership_id=mid and status='PROCESSING') then raise exception '결제 처리 중입니다. 완료 후 다시 해지해 주세요.'; end if;
 update public.gym_checkout_orders set status='CANCELED' where membership_id=mid and status='PENDING';
 update public.gym_memberships set status=case when period_end<=now() then 'EXPIRED' else 'CANCEL_AT_PERIOD_END' end,canceled_at=coalesce(canceled_at,now()) where id=mid;
end $$;
create or replace function public.gym_due_orders() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.gym_memberships; result jsonb;
begin
 update public.gym_memberships set status='EXPIRED' where period_end<=now() and (not recurring or status='CANCEL_AT_PERIOD_END');
 for m in select * from public.gym_memberships where recurring and status='ACTIVE' and period_end<=now() order by period_end limit 50 for update skip locked loop
  insert into public.gym_checkout_orders(member_id,center_id,product_id,config_id,membership_id,product_name,unit_amount,locker_id,locker_amount,recurring,interval_unit,interval_count,terms_snapshot,cancellation_snapshot,consented_at,weekly_limit,access_centers,renewal_cycle,expires_at)
  values(m.member_id,m.center_id,m.product_id,m.config_id,m.id,m.product_name,m.unit_amount,m.locker_id,m.locker_amount,true,m.interval_unit,m.interval_count,m.terms_snapshot,m.cancellation_snapshot,m.created_at,m.weekly_limit,m.access_centers,m.cycle_number+1,now()+interval '1 day') on conflict(membership_id,renewal_cycle) do nothing;
 end loop;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'member_id',member_id)),'[]') into result from (select id,member_id from public.gym_checkout_orders where renewal_cycle is not null and status in ('PENDING','PROCESSING') order by created_at limit 50) due;
 return result;
end $$;
create or replace function public.gym_store_checkout_token(oid uuid,ciphertext text) returns void language plpgsql security definer set search_path='' as $$
begin
 insert into gym_private.gym_checkout_tokens values(oid,ciphertext) on conflict(order_id) do nothing;
end $$;
-- Only an explicit provider rejection may release a reservation. Timeouts remain PROCESSING.
create or replace function public.gym_fail_payment(oid uuid) returns void language plpgsql security definer set search_path='' as $$
declare o public.gym_checkout_orders;
begin
 select * into o from public.gym_checkout_orders where id=oid for update;
 if o.status='PAID' then return; end if;
 update public.gym_checkout_orders set status='FAILED' where id=oid;
 if o.membership_id is not null then update public.gym_memberships set status='PAYMENT_FAILED' where id=o.membership_id; end if;
end $$;
create or replace function public.gym_list_lockers(cid uuid) returns table(id uuid,number text,location text,cycle_price bigint,status text) language sql stable security definer set search_path='' as $$
 select l.id,l.number,l.location,l.cycle_price,case when exists(select 1 from public.gym_memberships m where m.locker_id=l.id and (m.period_end>now() or (m.recurring and m.status in ('ACTIVE','PAYMENT_FAILED')))) or exists(select 1 from public.gym_checkout_orders o where o.locker_id=l.id and (o.status='PROCESSING' or (o.status='PENDING' and o.expires_at>now()))) or exists(select 1 from public.locker_assignments a where a.locker_id=l.id and a.released_at is null) then 'OCCUPIED' else l.status end
 from public.lockers l join public.centers c on c.id=l.center_id where l.center_id=cid and auth.uid() is not null and (c.active or gym_private.is_center_admin(cid)) order by l.number;
$$;
-- Explicit ACLs on all new APIs, regardless of Supabase default privileges.
do $$ declare signature text; begin
 foreach signature in array array['gym_list_lockers(uuid)','gym_save_center_v2(jsonb)','gym_save_product_v2(jsonb)','gym_update_profile(jsonb)','gym_save_locker(jsonb)','gym_prepare_checkout(jsonb)','gym_cancel_membership(uuid)'] loop
  execute 'revoke all on function public.'||signature||' from public,anon,authenticated';execute 'grant execute on function public.'||signature||' to authenticated';
 end loop;
 foreach signature in array array['gym_store_checkout_token(uuid,text)','gym_save_toss(uuid,jsonb,text)','gym_claim_payment(uuid,uuid)','gym_finish_payment(uuid,text,bigint,text)','gym_due_orders()','gym_fail_payment(uuid)'] loop
  execute 'revoke all on function public.'||signature||' from public,anon,authenticated';execute 'grant execute on function public.'||signature||' to service_role';
 end loop;
end $$;
revoke all on function gym_private.gym_period(timestamptz,text,integer,integer) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
select 'MEMBER_COMMERCE_READY' as result;
