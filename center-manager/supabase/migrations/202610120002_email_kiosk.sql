-- Apply after 05. No dependency on payment scheduler 06.
begin;
create or replace function gym_private.create_profile() returns trigger language plpgsql security definer set search_path='' as $$
declare p text:=regexp_replace(coalesce(new.raw_user_meta_data->>'phone',new.phone,''),'[^0-9]','','g');
begin
 insert into public.profiles(id,name,phone) values(new.id,left(coalesce(nullif(btrim(new.raw_user_meta_data->>'name'),''),'회원'),150),case when p ~ '^[0-9]{9,15}$' then p else null end);
 return new;
end $$;
revoke all on function gym_private.create_profile() from public,anon,authenticated;
create table if not exists gym_private.kiosk_devices(
 id uuid primary key default gen_random_uuid(),center_id uuid not null references public.centers,
 label text not null, token_hash bytea not null unique,active boolean not null default true,
 created_at timestamptz not null default now(), window_start timestamptz not null default now(),requests integer not null default 0
);
create table if not exists gym_private.kiosk_candidates(
 id uuid primary key default gen_random_uuid(),device_id uuid not null references gym_private.kiosk_devices on delete cascade,
 member_id uuid not null references public.profiles, expires_at timestamptz not null default now()+interval '90 seconds'
);
create table if not exists public.gym_attendance(
 id uuid primary key default gen_random_uuid(),member_id uuid not null references public.profiles,
 center_id uuid not null references public.centers,membership_id uuid references public.gym_memberships,
 legacy_subscription_id uuid references public.subscriptions,occurred_at timestamptz not null default now(),
 korean_date date generated always as ((occurred_at at time zone 'Asia/Seoul')::date) stored,
 check(num_nonnulls(membership_id,legacy_subscription_id)=1),unique(member_id,korean_date)
);
alter table gym_private.kiosk_devices enable row level security;
alter table gym_private.kiosk_candidates enable row level security;
alter table public.gym_attendance enable row level security;
revoke all on gym_private.kiosk_devices,gym_private.kiosk_candidates,public.gym_attendance from public,anon,authenticated;
grant select on public.gym_attendance to authenticated;
drop policy if exists gym_attendance_read on public.gym_attendance;
create policy gym_attendance_read on public.gym_attendance for select to authenticated using(member_id=auth.uid() or gym_private.is_center_admin(center_id));
create index if not exists gym_attendance_center_day on public.gym_attendance(center_id,korean_date desc);
create index if not exists gym_profile_phone_suffix on public.profiles(right(regexp_replace(phone,'[^0-9]','','g'),4));
create or replace function public.gym_kiosk_admin(cid uuid,action text,device uuid default null,label text default '입구 태블릿') returns jsonb language plpgsql security definer set search_path='' as $$
declare secret text;did uuid;result jsonb;
begin
 if not gym_private.can_manage_center(cid) then raise exception '관리자 권한이 필요합니다.';end if;
 if action='create' then
  if (select count(*) from gym_private.kiosk_devices where center_id=cid and active)>=10 then raise exception '기기는 지점당 10대까지 등록할 수 있습니다.';end if;
  secret:=gen_random_uuid()::text||gen_random_uuid()::text;
  insert into gym_private.kiosk_devices(center_id,label,token_hash) values(cid,left(coalesce(nullif(btrim(label),''),'출석 기기'),60),sha256(convert_to(secret,'UTF8'))) returning id into did;
  return jsonb_build_object('id',did,'token',secret);
 elsif action='revoke' then update gym_private.kiosk_devices set active=false where id=device and center_id=cid;
 elsif action<>'list' then raise exception '잘못된 요청입니다.';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'label',k.label,'active',active,'created_at',created_at) order by created_at desc),'[]'::jsonb) into result from gym_private.kiosk_devices k where center_id=cid;
 return result;
end $$;
-- Terminal credential is independent of member/admin login. Never return full phone/email.
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
 for p in select pr.id,pr.name from public.profiles pr where right(regexp_replace(pr.phone,'[^0-9]','','g'),4)=suffix and (
 exists(select 1 from public.gym_memberships m where m.member_id=pr.id and (m.center_id=d.center_id or d.center_id=any(m.access_centers))) or
 exists(select 1 from public.subscriptions s where s.member_id=pr.id and (s.center_id=d.center_id or exists(select 1 from public.subscription_access_centers a where a.subscription_id=s.id and a.center_id=d.center_id)))
 ) order by pr.name,pr.id limit 15 loop
  insert into gym_private.kiosk_candidates(device_id,member_id) values(d.id,p.id) returning id into candidate;
  items:=items||jsonb_build_array(jsonb_build_object('candidate',candidate,'name',p.name));
 end loop;
 return jsonb_build_object('center',(select name from public.centers where id=d.center_id),'items',items);
end $$;
create or replace function gym_private.kiosk_week_visits(uid uuid,on_date date) returns integer language sql stable security definer set search_path='' as $$
 select count(*)::integer from (select korean_date from public.gym_attendance where member_id=uid and korean_date>=date_trunc('week',on_date::timestamp)::date and korean_date<=on_date union select korean_date from public.attendance where member_id=uid and success and korean_date>=date_trunc('week',on_date::timestamp)::date and korean_date<=on_date) v;
$$;
revoke all on function gym_private.kiosk_week_visits(uuid,date) from public,anon,authenticated;
create or replace function public.gym_kiosk_checkin(token text,candidate uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare d gym_private.kiosk_devices;uid uuid;m public.gym_memberships;s public.subscriptions;lim integer;today date:=(now() at time zone 'Asia/Seoul')::date;visits integer;
begin
 select k.* into d from gym_private.kiosk_devices k join public.centers c on c.id=k.center_id and c.active where k.token_hash=sha256(convert_to(token,'UTF8')) and k.active for update of k;
 if d.id is null then raise exception '출석 기기 등록이 필요합니다.';end if;
 select member_id into uid from gym_private.kiosk_candidates where id=candidate and device_id=d.id and expires_at>now();
 if uid is null then raise exception '확인 시간이 지났습니다. 전화번호를 다시 입력해 주세요.';end if;
 -- Serialize all terminals for this member; unique date also prevents duplicate inserts.
 perform 1 from public.profiles where id=uid for update;
 if exists(select 1 from public.gym_attendance where member_id=uid and korean_date=today) or exists(select 1 from public.attendance where member_id=uid and korean_date=today and success) then return jsonb_build_object('message','오늘 출석이 이미 완료되었습니다.');end if;
 select * into m from public.gym_memberships where member_id=uid and status in ('ACTIVE','CANCEL_AT_PERIOD_END') and period_start<=now() and period_end>now() and (center_id=d.center_id or d.center_id=any(access_centers)) order by period_end desc limit 1 for update;
 if m.id is null then
  select x.* into s from public.subscriptions x where member_id=uid and status in ('ACTIVE','CANCEL_AT_PERIOD_END') and current_period_start<=today and current_period_end>today and (center_id=d.center_id or exists(select 1 from public.subscription_access_centers a where a.subscription_id=x.id and a.center_id=d.center_id)) order by current_period_end desc limit 1 for update;
  if s.id is null then raise exception '이 지점에서 이용 가능한 회원권이 없습니다. 데스크에 문의해 주세요.';end if;
  lim:=s.weekly_limit;
 else lim:=m.weekly_limit;end if;
 visits:=gym_private.kiosk_week_visits(uid,today);
 if lim>0 and visits>=lim then raise exception '이번 주 이용 횟수를 모두 사용했습니다. 데스크에 문의해 주세요.';end if;
 insert into public.gym_attendance(member_id,center_id,membership_id,legacy_subscription_id) values(uid,d.center_id,m.id,s.id);
 return jsonb_build_object('message','출석이 완료되었습니다. 즐겁게 운동하세요!');
end $$;
create or replace function public.gym_attendance_recent(cid uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not gym_private.is_center_admin(cid) then raise exception '관리자 권한이 필요합니다.';end if;
 return (select coalesce(jsonb_agg(row_to_json(r)),'[]'::jsonb) from (select a.id,p.name,a.occurred_at from public.gym_attendance a join public.profiles p on p.id=a.member_id where a.center_id=cid order by a.occurred_at desc limit 100) r);
end $$;
revoke all on function public.gym_kiosk_admin(uuid,text,uuid,text),public.gym_kiosk_lookup(text,text),public.gym_kiosk_checkin(text,uuid),public.gym_attendance_recent(uuid) from public,anon,authenticated;
grant execute on function public.gym_kiosk_admin(uuid,text,uuid,text),public.gym_attendance_recent(uuid) to authenticated;
grant execute on function public.gym_kiosk_lookup(text,text),public.gym_kiosk_checkin(text,uuid) to anon,authenticated;
commit;
