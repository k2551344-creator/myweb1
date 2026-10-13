-- Apply after setup 08. Additive; existing contracts and orders are retained.
begin;
alter table public.gym_checkout_orders
 add column if not exists attempt_count integer not null default 0,
 add column if not exists first_attempt_at timestamptz,
 add column if not exists next_attempt_at timestamptz,
 add column if not exists lease_until timestamptz,
 add column if not exists lease_id uuid,
 add column if not exists review_required boolean not null default false,
 add column if not exists last_error_code text;
create index if not exists gym_checkout_retry on public.gym_checkout_orders(next_attempt_at) where status='PROCESSING';

create or replace function public.gym_billing_config_base(cid uuid,actor uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not exists(select 1 from public.center_admins where center_id=cid and user_id=actor and role='owner') then raise exception '지점 소유자만 결제 계정을 설정할 수 있습니다.';end if;
 select jsonb_build_object('mode',c.mode,'paymentClientKey',c.payment_client_key,'secret',a.secret_reference) into result from public.payment_configs c join gym_private.payment_accounts a on a.config_id=c.id where c.center_id=cid and c.is_current;
 if result->>'mode'='live' then raise exception '운영 계정은 테스트 키로 덮어쓸 수 없습니다. 별도 테스트 지점을 사용하세요.';end if;
 return coalesce(result,'{}'::jsonb);
end $$;

create or replace function public.gym_billing_claim(oid uuid,actor uuid,review boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.gym_checkout_orders;m public.gym_memberships;cfg public.payment_configs;ticket uuid;secret_value text;token_value text;
begin
 select * into o from public.gym_checkout_orders where id=oid;
 if o.membership_id is not null then select * into m from public.gym_memberships where id=o.membership_id for update;end if;
 select * into o from public.gym_checkout_orders where id=oid for update;
 if o.id is null or o.member_id is distinct from actor then raise exception '결제 권한이 없습니다.';end if;
 if o.status='PAID' then return jsonb_build_object('paid',true);end if;
 select * into cfg from public.payment_configs where id=o.config_id;
 if cfg.mode is distinct from 'test' then raise exception '테스트 결제만 허용합니다.';end if;
 if o.status not in ('PENDING','PROCESSING') or (o.status='PENDING' and o.expires_at<=now()) then raise exception '만료되거나 취소된 결제입니다.';end if;
 if o.membership_id is not null and (m.status is distinct from 'ACTIVE' or not m.recurring) then raise exception '중지되거나 해지된 구독입니다.';end if;
 if o.consented_at is null or btrim(o.terms_snapshot)='' then raise exception '결제 동의가 없습니다.';end if;
 if o.lease_until>now() then return jsonb_build_object('busy',true);end if;
 if not review and (o.review_required or o.attempt_count>=4 or o.first_attempt_at<now()-interval '14 days') then
  update public.gym_checkout_orders set review_required=true,last_error_code=coalesce(last_error_code,'REVIEW_REQUIRED') where id=oid;
  return jsonb_build_object('review',true);
 end if;
 if not review and o.next_attempt_at>now() then return jsonb_build_object('retryAt',o.next_attempt_at);end if;
 ticket:=gen_random_uuid();
 update public.gym_checkout_orders set status='PROCESSING',lease_id=ticket,lease_until=now()+interval '3 minutes',first_attempt_at=coalesce(first_attempt_at,now()),attempt_count=attempt_count+case when review then 0 else 1 end,next_attempt_at=null where id=oid;
 select secret_reference into secret_value from gym_private.payment_accounts where config_id=o.config_id;
 select encrypted_token into token_value from gym_private.gym_billing_tokens where membership_id=o.membership_id;
 if token_value is null then select encrypted_token into token_value from gym_private.gym_checkout_tokens where order_id=oid;end if;
 return to_jsonb(o)||jsonb_build_object('mode',cfg.mode,'clientKey',case when o.recurring then cfg.billing_client_key else cfg.payment_client_key end,'lease',ticket,'secret',secret_value,'token',token_value,'paid',false);
end $$;

create or replace function public.gym_billing_store_token(oid uuid,ticket uuid,ciphertext text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.gym_checkout_orders where id=oid and status='PROCESSING' and lease_id=ticket for update;
 if not found then raise exception '결제 처리 잠금이 변경되었습니다.';end if;
 if length(ciphertext)<20 then raise exception '암호화된 빌링키가 필요합니다.';end if;
 perform public.gym_store_checkout_token(oid,ciphertext);
end $$;

create or replace function public.gym_billing_finish(oid uuid,ticket uuid,payment_key_value text,paid_amount bigint,billing_cipher text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare o public.gym_checkout_orders;mid uuid;
begin
 select * into o from public.gym_checkout_orders where id=oid;
 if o.membership_id is not null then perform 1 from public.gym_memberships where id=o.membership_id for update;end if;
 select * into o from public.gym_checkout_orders where id=oid for update;
 if o.status='PAID' then return o.membership_id;end if;
 if o.lease_id is distinct from ticket or ticket is null then raise exception '결제 처리 잠금이 변경되었습니다.';end if;
 mid:=public.gym_finish_payment(oid,payment_key_value,paid_amount,billing_cipher);
 update public.gym_checkout_orders set lease_id=null,lease_until=null,next_attempt_at=null,review_required=false,last_error_code=null where id=oid;
 return mid;
end $$;

create or replace function public.gym_billing_defer(oid uuid,ticket uuid,code text,definitive boolean default false,manual boolean default false) returns void language plpgsql security definer set search_path='' as $$
declare o public.gym_checkout_orders;
begin
 select * into o from public.gym_checkout_orders where id=oid;
 if o.membership_id is not null then perform 1 from public.gym_memberships where id=o.membership_id for update;end if;
 select * into o from public.gym_checkout_orders where id=oid for update;
 if o.status='PAID' or o.lease_id is distinct from ticket or ticket is null then return;end if;
 if definitive then perform public.gym_fail_payment(oid);end if;
 update public.gym_checkout_orders set lease_id=null,lease_until=null,last_error_code=left(regexp_replace(coalesce(code,'UNKNOWN'),'[^A-Z0-9_]','','g'),80),
 review_required=not definitive and (manual or attempt_count>=4 or first_attempt_at<now()-interval '14 days'),
 next_attempt_at=case when definitive or manual or attempt_count>=4 or first_attempt_at<now()-interval '14 days' then null else now()+case attempt_count when 1 then interval '5 minutes' when 2 then interval '30 minutes' else interval '2 hours' end end where id=oid;
end $$;

create or replace function public.gym_billing_due() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.gym_memberships;result jsonb;
begin
 for m in select s.* from public.gym_memberships s join public.payment_configs c on c.id=s.config_id where s.recurring and s.status='ACTIVE' and s.period_end<=now() and c.mode='test' and not exists(select 1 from public.gym_checkout_orders o where o.membership_id=s.id and o.renewal_cycle=s.cycle_number+1) order by s.period_end limit 50 for update of s skip locked loop
  insert into public.gym_checkout_orders(member_id,center_id,product_id,config_id,membership_id,product_name,unit_amount,locker_id,locker_amount,recurring,interval_unit,interval_count,terms_snapshot,cancellation_snapshot,consented_at,weekly_limit,access_centers,renewal_cycle,expires_at)
  values(m.member_id,m.center_id,m.product_id,m.config_id,m.id,m.product_name,m.unit_amount,m.locker_id,m.locker_amount,true,m.interval_unit,m.interval_count,m.terms_snapshot,m.cancellation_snapshot,m.created_at,m.weekly_limit,m.access_centers,m.cycle_number+1,now()+interval '1 day') on conflict(membership_id,renewal_cycle) do nothing;
  -- A long outage must not trigger multiple historical periods of catch-up charges.
  if m.period_end<now()-interval '1 day' then
   update public.gym_checkout_orders set status='FAILED',last_error_code='RENEWAL_OVERDUE' where membership_id=m.id and renewal_cycle=m.cycle_number+1 and status='PENDING';
   update public.gym_memberships set status='PAYMENT_FAILED' where id=m.id;
  end if;
 end loop;
 -- PENDING means no worker ever initiated a provider request; expiration can safely stop it.
 for m in select s.* from public.gym_memberships s join public.payment_configs c on c.id=s.config_id where c.mode='test' and exists(select 1 from public.gym_checkout_orders o where o.membership_id=s.id and o.status='PENDING' and o.expires_at<=now()) for update of s skip locked loop
  update public.gym_checkout_orders set status='FAILED',last_error_code='ORDER_EXPIRED' where membership_id=m.id and status='PENDING' and expires_at<=now();
  update public.gym_memberships set status='PAYMENT_FAILED' where id=m.id and status='ACTIVE';
 end loop;
 update public.gym_checkout_orders set review_required=true,last_error_code=coalesce(last_error_code,'RETRY_LIMIT') where config_id in (select id from public.payment_configs where mode='test') and status='PROCESSING' and (lease_until is null or lease_until<=now()) and (attempt_count>=4 or first_attempt_at<now()-interval '14 days');
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'member_id',member_id)),'[]'::jsonb) into result from (
  select o.id,o.member_id from public.gym_checkout_orders o join public.payment_configs c on c.id=o.config_id
  where c.mode='test' and not o.review_required and o.attempt_count<4 and (o.next_attempt_at is null or o.next_attempt_at<=now()) and (o.lease_until is null or o.lease_until<=now())
   and ((o.status='PENDING' and o.renewal_cycle is not null and o.expires_at>now()) or o.status='PROCESSING')
   and (o.first_attempt_at is null or o.first_attempt_at>=now()-interval '14 days')
  order by coalesce(o.next_attempt_at,o.created_at) limit 20
 ) pending;
 return result;
end $$;

-- Returns only records in a managed center; keys and encrypted tokens are excluded.
create or replace function public.gym_admin_billing(cid uuid,page_number integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if auth.uid() is null or not gym_private.can_manage_center(cid) then raise exception '결제 조회 권한이 없습니다.';end if;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into rows from (
 select o.id,o.product_name,p.name as member_name,o.status,c.mode,o.unit_amount+o.locker_amount as amount,o.recurring,o.created_at,o.paid_at,o.attempt_count,o.next_attempt_at,o.last_error_code,o.review_required,
 case when m.recurring and m.status='ACTIVE' then m.period_end else null end as next_payment_at,m.status as membership_status,o.renewal_cycle
 from public.gym_checkout_orders o join public.profiles p on p.id=o.member_id join public.payment_configs c on c.id=o.config_id left join public.gym_memberships m on m.id=o.membership_id
 where o.center_id=cid order by o.created_at desc,o.id limit 50 offset greatest(0,least(page_number,10000))*50
 ) x;
 return rows;
end $$;

create or replace function public.gym_billing_review_actor(oid uuid,actor uuid) returns uuid language plpgsql stable security definer set search_path='' as $$
declare o public.gym_checkout_orders;
begin
 select * into o from public.gym_checkout_orders where id=oid;
 if not exists(select 1 from public.center_admins where center_id=o.center_id and user_id=actor and role in ('owner','manager')) then raise exception '결제 확인 권한이 없습니다.';end if;
 return o.member_id;
end $$;

do $$ declare sig text;begin
 foreach sig in array array['gym_billing_config_base(uuid,uuid)','gym_billing_claim(uuid,uuid,boolean)','gym_billing_store_token(uuid,uuid,text)','gym_billing_finish(uuid,uuid,text,bigint,text)','gym_billing_defer(uuid,uuid,text,boolean,boolean)','gym_billing_due()','gym_billing_review_actor(uuid,uuid)'] loop
 execute 'revoke all on function public.'||sig||' from public,anon,authenticated';execute 'grant execute on function public.'||sig||' to service_role';
 end loop;
end $$;
revoke all on function public.gym_admin_billing(uuid,integer) from public,anon,authenticated;
grant execute on function public.gym_admin_billing(uuid,integer) to authenticated;
notify pgrst,'reload schema';
commit;
select 'TEST_BILLING_READY' as result;
