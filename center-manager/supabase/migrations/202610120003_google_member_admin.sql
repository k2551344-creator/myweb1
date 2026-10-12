-- 05 and 07 must be installed. Additive Google / member administration extension.
begin;
create table if not exists public.gym_roster(
 id uuid primary key default gen_random_uuid(),center_id uuid not null references public.centers,
 profile_id uuid references public.profiles,name text not null, email text not null,phone text not null,
 created_at timestamptz not null default now(),created_by uuid references public.profiles,
 unique(center_id,profile_id),unique(center_id,email)
);
create table if not exists public.gym_manual_passes(
 id uuid primary key default gen_random_uuid(),roster_id uuid not null references public.gym_roster,
 product_id uuid references public.products,label text not null,starts_on date not null,ends_on date not null,
 weekly_limit integer not null check(weekly_limit between 0 and 7),status text not null default 'ACTIVE' check(status in ('ACTIVE','SUSPENDED','ENDED')),
 note text not null default '',created_at timestamptz not null default now(),created_by uuid references public.profiles,
 request_id uuid not null unique,check(ends_on>starts_on)
);
create table if not exists public.gym_manual_attendance(
 id uuid primary key default gen_random_uuid(),roster_id uuid not null references public.gym_roster,
 pass_id uuid not null references public.gym_manual_passes,center_id uuid not null references public.centers,
 occurred_at timestamptz not null default now(),korean_date date generated always as ((occurred_at at time zone 'Asia/Seoul')::date) stored,
 unique(roster_id,korean_date)
);
create table if not exists gym_private.member_audit(
 id uuid primary key default gen_random_uuid(),actor uuid not null,center_id uuid not null,action text not null,target uuid not null,reason text not null,created_at timestamptz not null default now()
);
alter table public.gym_roster enable row level security;
alter table public.gym_manual_passes enable row level security;
alter table public.gym_manual_attendance enable row level security;
alter table gym_private.member_audit enable row level security;
revoke all on public.gym_roster,public.gym_manual_passes,public.gym_manual_attendance,gym_private.member_audit from public,anon,authenticated;
-- All access below is through scoped RPCs. No anonymous list or browser table writes.
alter table public.gym_memberships drop constraint if exists gym_memberships_status_check;
alter table public.gym_memberships add constraint gym_memberships_status_check check(status in ('ACTIVE','CANCEL_AT_PERIOD_END','EXPIRED','PAYMENT_FAILED','SUSPENDED'));
create index if not exists gym_roster_profile on public.gym_roster(profile_id);
create index if not exists gym_roster_suffix on public.gym_roster(right(phone,4));
create or replace function gym_private.register_center_member() returns trigger language plpgsql security definer set search_path='' as $$
declare p public.profiles;e text;
begin
 select * into p from public.profiles where id=new.member_id;select lower(btrim(email)) into e from auth.users where id=new.member_id;
 insert into public.gym_roster(center_id,profile_id,name,email,phone) values(new.center_id,p.id,p.name,coalesce(e,p.id::text||'@unlinked.invalid'),coalesce(p.phone,'')) on conflict(center_id,email) do update set profile_id=excluded.profile_id where public.gym_roster.profile_id is null and exists(select 1 from auth.users where id=new.member_id and email_confirmed_at is not null);
 if not exists(select 1 from public.gym_roster where center_id=new.center_id and profile_id=new.member_id) then raise exception '기존 회원 이메일 연결을 관리자에게 문의해 주세요.';end if;
 return new;
end $$;
revoke all on function gym_private.register_center_member() from public,anon,authenticated;
-- Existing paid/registered members become visible without re-registration.
insert into public.center_members(center_id,member_id) select center_id,member_id from public.gym_memberships union select center_id,member_id from public.subscriptions on conflict do nothing;
insert into public.gym_roster(center_id,profile_id,name,email,phone)
 select cm.center_id,p.id,p.name,coalesce(lower(btrim(u.email)),p.id::text||'@unlinked.invalid'),coalesce(p.phone,'') from public.center_members cm join public.profiles p on p.id=cm.member_id join auth.users u on u.id=p.id
 on conflict do nothing;
drop trigger if exists gym_roster_join on public.center_members;
create trigger gym_roster_join after insert on public.center_members for each row execute function gym_private.register_center_member();
create or replace function public.gym_sync_member(cid uuid default null) returns void language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();e text;r record;
begin
 if uid is null then raise exception '로그인이 필요합니다.';end if;
 select lower(btrim(email)) into e from auth.users where id=uid and email_confirmed_at is not null;
 if e is null then raise exception '인증된 이메일이 필요합니다.';end if;
 perform 1 from public.profiles where id=uid for update;
 for r in select * from public.gym_roster where email=e and profile_id is null for update loop
  update public.gym_roster set profile_id=uid where id=r.id;
  update public.profiles set phone=case when coalesce(phone,'')='' then r.phone else phone end where id=uid;
  insert into public.center_members(center_id,member_id) values(r.center_id,uid) on conflict do nothing;
 end loop;
 if cid is not null then
  if not exists(select 1 from public.centers where id=cid and active) then raise exception '운영 중인 지점을 선택해 주세요.';end if;
  insert into public.center_members(center_id,member_id) values(cid,uid) on conflict do nothing;
 end if;
end $$;
create or replace function public.gym_admin_add_member(payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare cid uuid:=(payload->>'centerId')::uuid;uid uuid;rid uuid;e text:=lower(btrim(payload->>'email'));n text:=btrim(payload->>'name');p text:=regexp_replace(payload->>'phone','[^0-9]','','g');
begin
 if not gym_private.can_manage_center(cid) then raise exception '회원 관리 권한이 없습니다.';end if;
 if coalesce(length(n),0) not between 1 and 150 or coalesce(e,'') !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or length(e)>254 or coalesce(p,'') !~ '^[0-9]{9,15}$' then raise exception '이름·이메일·전화번호를 확인해 주세요.';end if;
 -- Serializes duplicate submissions and claims within this branch.
 perform 1 from public.centers where id=cid for update;
 select id into uid from auth.users where lower(btrim(email))=e and email_confirmed_at is not null;
 insert into public.gym_roster(center_id,profile_id,name,email,phone,created_by) values(cid,uid,n,e,p,auth.uid()) on conflict(center_id,email) do nothing returning id into rid;
 if rid is null then raise exception '이 이메일은 이미 해당 지점에 등록되어 있습니다.';end if;
 if uid is not null then insert into public.center_members(center_id,member_id) values(cid,uid) on conflict do nothing;end if;
 insert into gym_private.member_audit(actor,center_id,action,target,reason) values(auth.uid(),cid,'ADD_MEMBER',rid,'직접 등록');
 return rid;
end $$;
create or replace function public.gym_admin_grant_pass(payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.gym_roster;p public.products;pid uuid;start_day date:=(payload->>'start')::date;end_day date:=(payload->>'end')::date+1;req uuid:=(payload->>'requestId')::uuid;lim integer:=(payload->>'weeklyLimit')::integer;
begin
 select * into r from public.gym_roster where id=(payload->>'rosterId')::uuid for update;
 if r.id is null or not gym_private.can_manage_center(r.center_id) then raise exception '회원권 부여 권한이 없습니다.';end if;
 select * into p from public.products where id=(payload->>'productId')::uuid and center_id=r.center_id;
 if p.id is null then raise exception '같은 지점의 상품을 선택해 주세요.';end if;
 if start_day is null or end_day is null or end_day<=start_day or end_day>start_day+3660 or lim is null or lim not between 0 and 7 or req is null or length(coalesce(payload->>'note',''))>1000 then raise exception '이용기간·횟수·메모를 확인해 주세요.';end if;
 select id into pid from public.gym_manual_passes where request_id=req and roster_id=r.id;
 if pid is not null then return pid;end if;
 insert into public.gym_manual_passes(roster_id,product_id,label,starts_on,ends_on,weekly_limit,note,created_by,request_id) values(r.id,p.id,p.name,start_day,end_day,lim,coalesce(payload->>'note',''),auth.uid(),req) returning id into pid;
 insert into gym_private.member_audit(actor,center_id,action,target,reason) values(auth.uid(),r.center_id,'GRANT_PASS',pid,coalesce(payload->>'note',''));
 return pid;
end $$;
-- Unified display format for purchased, legacy and desk-issued memberships.
create or replace function gym_private.member_passes(rid uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(x) order by period_start desc),'[]'::jsonb) from (
 select m.id,'online'::text as kind,m.product_name,m.status,m.period_start,m.period_end,m.unit_amount+m.locker_amount as amount,m.recurring,m.weekly_limit,m.cancellation_snapshot,m.center_id from public.gym_memberships m join public.gym_roster r on r.profile_id=m.member_id and r.center_id=m.center_id where r.id=rid
 union all select s.id,'legacy',p.name,s.status,s.current_period_start::timestamp at time zone 'Asia/Seoul',s.current_period_end::timestamp at time zone 'Asia/Seoul',s.unit_amount,true,s.weekly_limit,''::text,s.center_id from public.subscriptions s join public.products p on p.id=s.product_id join public.gym_roster r on r.profile_id=s.member_id and r.center_id=s.center_id where r.id=rid
 union all select m.id,'manual',m.label,case when m.status='ACTIVE' and m.ends_on<=(now() at time zone 'Asia/Seoul')::date then 'EXPIRED' else m.status end,m.starts_on::timestamp at time zone 'Asia/Seoul',m.ends_on::timestamp at time zone 'Asia/Seoul',0,false,m.weekly_limit,''::text,r.center_id from public.gym_manual_passes m join public.gym_roster r on r.id=m.roster_id where r.id=rid
 ) x;
$$;
revoke all on function gym_private.member_passes(uuid) from public,anon,authenticated;
create or replace function public.gym_admin_members(cid uuid default null,query text default '',page integer default 0,page_size integer default 50) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not exists(select 1 from public.center_admins where user_id=auth.uid() and role in ('owner','manager')) or (cid is not null and not gym_private.can_manage_center(cid)) then raise exception '회원 조회 권한이 없습니다.';end if;
 if page<0 or page_size not between 1 and 200 or length(query)>150 then raise exception '조회 범위를 확인해 주세요.';end if;
 with filtered as (
 select r.id,r.center_id,c.name as center_name,r.profile_id,coalesce(p.name,r.name) as name,coalesce(u.email,r.email) as email,coalesce(nullif(p.phone,''),r.phone) as phone,r.created_at
 from public.gym_roster r join public.centers c on c.id=r.center_id left join public.profiles p on p.id=r.profile_id left join auth.users u on u.id=r.profile_id
 where gym_private.can_manage_center(r.center_id) and (cid is null or r.center_id=cid) and strpos(lower(concat_ws(' ',coalesce(p.name,r.name),coalesce(u.email,r.email),coalesce(p.phone,r.phone))),lower(btrim(query)))>0
 ), sliced as (select * from filtered order by created_at desc,id limit page_size offset page*page_size)
 select jsonb_build_object('total',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('passes',gym_private.member_passes(s.id)) order by s.created_at desc,s.id) from sliced s),'[]'::jsonb)) into result;
 return result;
end $$;
create or replace function public.gym_my_passes() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다.';end if;
 return (select coalesce(jsonb_agg(x.item||jsonb_build_object('center_name',c.name)),'[]'::jsonb) from public.gym_roster r join public.centers c on c.id=r.center_id cross join lateral jsonb_array_elements(gym_private.member_passes(r.id)) x(item) where r.profile_id=auth.uid());
end $$;
create or replace function public.gym_admin_pass_action(kind text,pid uuid,action text,reason text) returns void language plpgsql security definer set search_path='' as $$
declare cid uuid;state text;rec boolean;ends timestamptz;
begin
 if coalesce(btrim(reason),'')='' or length(reason)>1000 then raise exception '처리 사유를 입력해 주세요.';end if;
 if kind='online' then select center_id,status,recurring,period_end into cid,state,rec,ends from public.gym_memberships where id=pid for update;
 elsif kind='manual' then select r.center_id,m.status,false,m.ends_on::timestamp at time zone 'Asia/Seoul' into cid,state,rec,ends from public.gym_manual_passes m join public.gym_roster r on r.id=m.roster_id where m.id=pid for update of m;
 elsif kind='legacy' then select center_id,status,true,current_period_end::timestamp at time zone 'Asia/Seoul' into cid,state,rec,ends from public.subscriptions where id=pid for update;
 else raise exception '회원권 종류를 확인해 주세요.';end if;
 if cid is null or not gym_private.can_manage_center(cid) then raise exception '회원권 관리 권한이 없습니다.';end if;
 if action not in ('cancel','suspend','resume') or action is null then raise exception '처리를 선택해 주세요.';end if;
 if state in ('EXPIRED','ENDED','PENDING') or (ends<=now() and not (rec and action in ('cancel','suspend'))) then raise exception '이용 중인 회원권만 변경할 수 있습니다.';end if;
 if action='cancel' and (not rec or state='SUSPENDED') then raise exception '정상 이용 중인 정기결제만 해지할 수 있습니다.';end if;
 if action='resume' and state<>'SUSPENDED' then raise exception '정지된 회원권만 재개할 수 있습니다.';end if;
 if kind='online' then
  if exists(select 1 from public.gym_checkout_orders where membership_id=pid and status='PROCESSING') then raise exception '결제 처리 중입니다. 완료 후 다시 변경해 주세요.';end if;
  update public.gym_checkout_orders set status='CANCELED' where membership_id=pid and status='PENDING';
  update public.gym_memberships set status=case when action='suspend' then 'SUSPENDED' when ends<=now() then 'EXPIRED' else 'CANCEL_AT_PERIOD_END' end,canceled_at=coalesce(canceled_at,now()) where id=pid;
 elsif kind='manual' then update public.gym_manual_passes set status=case when action='suspend' then 'SUSPENDED' else 'ACTIVE' end where id=pid;
 else update public.subscriptions set status=case when action='suspend' then 'SUSPENDED' when ends<=now() then 'EXPIRED' else 'CANCEL_AT_PERIOD_END' end,next_payment_at=null,canceled_at=coalesce(canceled_at,now()) where id=pid;end if;
 insert into gym_private.member_audit(actor,center_id,action,target,reason) values(auth.uid(),cid,upper(action),pid,btrim(reason));
end $$;
create or replace function public.gym_claim_payment(oid uuid,actor uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.gym_checkout_orders; secret_value text; token_value text; m public.gym_memberships;
begin
 select * into o from public.gym_checkout_orders where id=oid;
 if o.membership_id is not null then select * into m from public.gym_memberships where id=o.membership_id for update;end if;
 select * into o from public.gym_checkout_orders where id=oid for update;
 if o.id is null or o.member_id is distinct from actor then raise exception '결제 권한이 없습니다.'; end if;
 if o.status='PAID' then return jsonb_build_object('paid',true); end if;
 if o.membership_id is not null and (m.status is distinct from 'ACTIVE' or not m.recurring) then raise exception '중지되거나 해지된 구독입니다.';end if;
 if o.status not in ('PENDING','PROCESSING') or (o.status='PENDING' and o.expires_at<=now()) then raise exception '만료되거나 취소된 결제입니다.'; end if;
 update public.gym_checkout_orders set status='PROCESSING' where id=oid;
 select secret_reference into secret_value from gym_private.payment_accounts where config_id=o.config_id;
 select encrypted_token into token_value from gym_private.gym_billing_tokens where membership_id=o.membership_id;
 if token_value is null then select encrypted_token into token_value from gym_private.gym_checkout_tokens where order_id=oid; end if;
 return to_jsonb(o)||jsonb_build_object('secret',secret_value,'token',token_value,'paid',false);
end $$;

alter table gym_private.kiosk_candidates alter column member_id drop not null;
alter table gym_private.kiosk_candidates add column if not exists roster_id uuid references public.gym_roster;
create or replace function public.gym_kiosk_lookup(token text,suffix text) returns jsonb language plpgsql security definer set search_path='' as $$
declare d gym_private.kiosk_devices; p record; candidate uuid;items jsonb:='[]';
begin
 if length(token)>100 or suffix !~ '^[0-9]{4}$' then raise exception '전화번호 뒤 4자리를 입력해 주세요.';end if;
 select k.* into d from gym_private.kiosk_devices k join public.centers c on c.id=k.center_id and c.active where k.token_hash=sha256(convert_to(token,'UTF8')) and k.active for update of k;
 if d.id is null then raise exception '출석 기기 등록이 필요합니다.';end if;
 if d.window_start<now()-interval '1 minute' then d.window_start:=now();d.requests:=0;end if;
 if d.requests>=20 then return jsonb_build_object('error','조회가 많습니다. 잠시 후 다시 입력해 주세요.','items','[]'::jsonb);end if;
 update gym_private.kiosk_devices set requests=d.requests+1,window_start=d.window_start where id=d.id;
 delete from gym_private.kiosk_candidates where device_id=d.id or expires_at<now();
 for p in select * from (select pr.id,null::uuid as rid,pr.name from public.profiles pr where right(regexp_replace(pr.phone,'[^0-9]','','g'),4)=suffix and (
 exists(select 1 from public.gym_memberships m where m.member_id=pr.id and (m.center_id=d.center_id or d.center_id=any(m.access_centers))) or
 exists(select 1 from public.gym_roster r join public.gym_manual_passes mp on mp.roster_id=r.id where r.profile_id=pr.id and r.center_id=d.center_id) or
 exists(select 1 from public.subscriptions s where s.member_id=pr.id and (s.center_id=d.center_id or exists(select 1 from public.subscription_access_centers a where a.subscription_id=s.id and a.center_id=d.center_id)))
 ) union all select null::uuid,r.id,r.name from public.gym_roster r where r.profile_id is null and r.center_id=d.center_id and right(r.phone,4)=suffix and exists(select 1 from public.gym_manual_passes mp where mp.roster_id=r.id)) matches order by name,id,rid limit 15 loop
  insert into gym_private.kiosk_candidates(device_id,member_id,roster_id) values(d.id,p.id,p.rid) returning id into candidate;
  items:=items||jsonb_build_array(jsonb_build_object('candidate',candidate,'name',p.name));
 end loop;
 return jsonb_build_object('center',(select name from public.centers where id=d.center_id),'items',items);
end $$;
create or replace function public.gym_kiosk_checkin(token text,candidate uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d gym_private.kiosk_devices;uid uuid;rid uuid;linked uuid;m public.gym_memberships;s public.subscriptions;mp public.gym_manual_passes;lim integer;today date:=(now() at time zone 'Asia/Seoul')::date;visits integer;
begin
 select k.* into d from gym_private.kiosk_devices k join public.centers c on c.id=k.center_id and c.active where k.token_hash=sha256(convert_to(token,'UTF8')) and k.active for update of k;
 if d.id is null then raise exception '출석 기기 등록이 필요합니다.';end if;
 select member_id,roster_id into uid,rid from gym_private.kiosk_candidates where id=candidate and device_id=d.id and expires_at>now();
 if uid is null and rid is null then raise exception '확인 시간이 지났습니다. 전화번호를 다시 입력해 주세요.';end if;
 if rid is not null then select profile_id into uid from public.gym_roster where id=rid;end if;
 perform 1 from public.profiles where id=uid for update;
 if rid is not null then
  select profile_id into linked from public.gym_roster where id=rid for update;
  if linked is distinct from uid then raise exception '회원 정보가 연결되었습니다. 전화번호를 다시 입력해 주세요.';end if;
 end if;
 if exists(select 1 from public.gym_attendance where member_id=uid and korean_date=today) or exists(select 1 from public.attendance where member_id=uid and korean_date=today and success) or exists(select 1 from public.gym_manual_attendance a join public.gym_roster r on r.id=a.roster_id where (r.profile_id=uid or r.id=rid) and a.korean_date=today) then return jsonb_build_object('message','오늘 출석이 이미 완료되었습니다.');end if;
 select count(*) into visits from (
 select korean_date from public.gym_attendance where member_id=uid
 union select korean_date from public.attendance where member_id=uid and success
 union select a.korean_date from public.gym_manual_attendance a join public.gym_roster r on r.id=a.roster_id where r.profile_id=uid or r.id=rid
 ) v where korean_date>=date_trunc('week',today::timestamp)::date and korean_date<=today;
 -- Desk-issued pass takes priority; no credit-card charge is created by a grant.
 select x.* into mp from public.gym_manual_passes x join public.gym_roster r on r.id=x.roster_id where (r.profile_id=uid or r.id=rid) and r.center_id=d.center_id and x.status='ACTIVE' and x.starts_on<=today and x.ends_on>today and (x.weekly_limit=0 or x.weekly_limit>visits) order by x.ends_on,x.id limit 1 for update of x;
 if mp.id is not null then lim:=mp.weekly_limit;
 else
  select * into m from public.gym_memberships where member_id=uid and status in ('ACTIVE','CANCEL_AT_PERIOD_END') and period_start<=now() and period_end>now() and (weekly_limit=0 or weekly_limit>visits) and (center_id=d.center_id or d.center_id=any(access_centers)) order by period_end desc limit 1 for update;
  if m.id is null then
   select x.* into s from public.subscriptions x where member_id=uid and status in ('ACTIVE','CANCEL_AT_PERIOD_END') and current_period_start<=today and current_period_end>today and (weekly_limit=0 or weekly_limit>visits) and (center_id=d.center_id or exists(select 1 from public.subscription_access_centers a where a.subscription_id=x.id and a.center_id=d.center_id)) order by current_period_end desc limit 1 for update;
   if s.id is null then raise exception '이용 가능한 회원권이 없거나 이번 주 이용 횟수를 모두 사용했습니다. 데스크에 문의해 주세요.';end if;lim:=s.weekly_limit;
  else lim:=m.weekly_limit;end if;
 end if;
 if lim>0 and visits>=lim then raise exception '이번 주 이용 횟수를 모두 사용했습니다. 데스크에 문의해 주세요.';end if;
 if mp.id is not null then insert into public.gym_manual_attendance(roster_id,pass_id,center_id) values(mp.roster_id,mp.id,d.center_id);
 else insert into public.gym_attendance(member_id,center_id,membership_id,legacy_subscription_id) values(uid,d.center_id,m.id,s.id);end if;
 return jsonb_build_object('message','출석이 완료되었습니다. 즐겁게 운동하세요!');
end $$;
create or replace function public.gym_admin_attendance(cid uuid default null,from_day date default current_date-30,to_day date default current_date,query text default '',page integer default 0,page_size integer default 50) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not exists(select 1 from public.center_admins where user_id=auth.uid() and role in ('owner','manager')) or (cid is not null and not gym_private.can_manage_center(cid)) then raise exception '출석 조회 권한이 없습니다.';end if;
 if from_day is null or to_day is null or to_day<from_day or page<0 or page_size not between 1 and 200 or length(query)>150 then raise exception '조회 범위를 확인해 주세요.';end if;
 with all_rows as (
 select a.id,a.center_id,p.name,a.occurred_at,a.korean_date,true as success,'출석 완료'::text as reason from public.gym_attendance a join public.profiles p on p.id=a.member_id
 union all select a.id,a.center_id,coalesce(p.name,r.name),a.occurred_at,a.korean_date,true,'출석 완료' from public.gym_manual_attendance a join public.gym_roster r on r.id=a.roster_id left join public.profiles p on p.id=r.profile_id
 union all select a.id,a.center_id,p.name,a.occurred_at,a.korean_date,a.success,a.reason from public.attendance a join public.profiles p on p.id=a.member_id
 ), filtered as (
 select a.*,c.name as center_name from all_rows a join public.centers c on c.id=a.center_id where gym_private.can_manage_center(a.center_id) and (cid is null or a.center_id=cid) and a.korean_date between from_day and to_day and strpos(lower(a.name),lower(btrim(query)))>0
 ), sliced as (select * from filtered order by occurred_at desc,id limit page_size offset page*page_size)
 select jsonb_build_object('total',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(s) order by s.occurred_at desc,s.id) from sliced s),'[]'::jsonb)) into result;
 return result;
end $$;
-- Google supplies display name in name or full_name. No metadata can grant roles.
create or replace function gym_private.create_profile() returns trigger language plpgsql security definer set search_path='' as $$
declare p text:=regexp_replace(coalesce(new.raw_user_meta_data->>'phone',new.phone,''),'[^0-9]','','g');
begin
 insert into public.profiles(id,name,phone) values(new.id,left(coalesce(nullif(btrim(new.raw_user_meta_data->>'name'),''),nullif(btrim(new.raw_user_meta_data->>'full_name'),''),'회원'),150),case when p ~ '^[0-9]{9,15}$' then p else null end);
 return new;
end $$;
create or replace function public.gym_admin_export_members(cid uuid default null,query text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.center_admins where user_id=auth.uid() and role in ('owner','manager')) or (cid is not null and not gym_private.can_manage_center(cid)) then raise exception '회원 다운로드 권한이 없습니다.';end if;
 if length(query)>150 then raise exception '검색어를 확인해 주세요.';end if;
 return (select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('passes',gym_private.member_passes(x.id)) order by x.created_at desc,x.id),'[]'::jsonb) from (
 select r.id,r.center_id,c.name as center_name,r.profile_id,coalesce(p.name,r.name) as name,coalesce(u.email,r.email) as email,coalesce(nullif(p.phone,''),r.phone) as phone,r.created_at
 from public.gym_roster r join public.centers c on c.id=r.center_id left join public.profiles p on p.id=r.profile_id left join auth.users u on u.id=r.profile_id
 where gym_private.can_manage_center(r.center_id) and (cid is null or r.center_id=cid) and strpos(lower(concat_ws(' ',coalesce(p.name,r.name),coalesce(u.email,r.email),coalesce(p.phone,r.phone))),lower(btrim(query)))>0
 ) x);
end $$;
do $permissions$ declare f text;begin
 foreach f in array array['gym_admin_export_members(uuid,text)','gym_sync_member(uuid)','gym_admin_add_member(jsonb)','gym_admin_grant_pass(jsonb)','gym_admin_members(uuid,text,integer,integer)','gym_my_passes()','gym_admin_pass_action(text,uuid,text,text)','gym_admin_attendance(uuid,date,date,text,integer,integer)'] loop
 execute 'revoke all on function public.'||f||' from public,anon,authenticated';execute 'grant execute on function public.'||f||' to authenticated';end loop;
end $permissions$;
revoke all on function public.gym_claim_payment(uuid,uuid) from public,anon,authenticated;
grant execute on function public.gym_claim_payment(uuid,uuid) to service_role;
commit;
select 'GOOGLE_MEMBER_ADMIN_READY' as result;
