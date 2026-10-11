-- ANY BOXING / Supabase 최초 설치용 스키마 v1
-- 새 Supabase 프로젝트의 SQL Editor에서 이 파일 전체를 실행하세요.
-- 기존 테이블을 삭제하지 않습니다. 같은 이름이 있으면 변경 전에 중단합니다.
-- 성공 결과: SETUP_COMPLETE. 이 SQL만으로 현재 웹 앱이 연결되지는 않습니다.
-- 회원권 구매·결제·출석·관리자 저장 API는 다음 연결 단계에서 구현합니다.
begin;
set local lock_timeout = '10s';
select pg_advisory_xact_lock(734826091);

do $preflight$
declare target text; collisions text[] := array[]::text[];
begin
 if to_regclass('auth.users') is null or to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
  raise exception 'Supabase 프로젝트의 SQL Editor에서 실행해 주세요. auth/storage 테이블이 없습니다.';
 end if;
 foreach target in array array['profiles','centers','center_admins','center_members','media_assets','center_appearance','products','product_prices','product_access_centers','payment_configs','subscriptions','subscription_access_centers','subscription_items','lockers','locker_assignments','locker_changes','orders','order_items','payments','payment_attempts','attendance'] loop
  if to_regclass('public.' || target) is not null then collisions := array_append(collisions, target); end if;
 end loop;
 if cardinality(collisions) > 0 then
  raise exception '설치를 중단했습니다. 같은 이름의 테이블이 이미 있습니다: %. 이미 설치했다면 확인 SQL만 실행하세요. 기존 테이블을 삭제하지 마세요.', array_to_string(collisions, ', ');
 end if;
 if exists(select 1 from pg_namespace where nspname='gym_private') then raise exception 'gym_private 스키마가 이미 있습니다. 재설치하지 말고 기존 설치 상태를 확인해 주세요.'; end if;
 if exists(select 1 from storage.buckets where id='center-media') then raise exception 'center-media 저장소가 이미 있습니다. 기존 데이터를 확인한 뒤 진행해 주세요.'; end if;
 if exists(select 1 from pg_trigger where tgrelid='auth.users'::regclass and tgname='gym_auth_user_created') then raise exception '회원 프로필 생성 설정이 이미 있습니다.'; end if;
 if exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname in ('gym_media_read','gym_media_upload')) then raise exception '이미지 접근 정책이 이미 있습니다.'; end if;
end $preflight$;

create schema gym_private;
revoke all on schema gym_private from public, anon, authenticated;
-- Helpers are callable but this schema must NOT be exposed in the Data API.
grant usage on schema gym_private to anon, authenticated, service_role;

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 name text not null check(length(btrim(name)) between 1 and 150),
 phone text check(phone is null or length(phone)<=30), created_at timestamptz not null default now()
);
create table public.centers (
 id uuid primary key default gen_random_uuid(), name text not null check(length(btrim(name)) between 1 and 150),
 brand text not null check(length(btrim(brand)) between 1 and 150), address text not null default '',
 phone text not null default '', active boolean not null default true, created_at timestamptz not null default now()
);
create table public.center_admins (
 center_id uuid references public.centers on delete cascade, user_id uuid references public.profiles on delete cascade,
 role text not null check(role in ('owner','manager','staff')), created_at timestamptz not null default now(),
 primary key(center_id,user_id)
);
create table public.center_members (
 center_id uuid references public.centers on delete cascade, member_id uuid references public.profiles on delete cascade,
 joined_at timestamptz not null default now(), primary key(center_id,member_id)
);
create table public.media_assets (
 id uuid primary key default gen_random_uuid(), center_id uuid not null references public.centers,
 object_path text not null unique,
 mime_type text not null check(mime_type in ('image/jpeg','image/png','image/webp')),
 byte_size bigint not null check(byte_size between 1 and 5242880), created_by uuid not null references public.profiles,
 created_at timestamptz not null default now(), unique(id,center_id),
 check(object_path ~ ('^' || center_id::text || '/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'))
);
create table public.center_appearance (
 center_id uuid primary key references public.centers on delete cascade,
 background_color text not null default '#102e2b' check(background_color ~ '^#[0-9a-fA-F]{6}$'),
 background_image_id uuid, headline text not null default '오늘도, 나를 넘어서.' check(length(headline)<=80),
 image_overlay integer not null default 40 check(image_overlay between 0 and 80),
 foreign key(background_image_id,center_id) references public.media_assets(id,center_id)
);
create table public.products (
 id uuid primary key default gen_random_uuid(), center_id uuid not null references public.centers,
 name text not null check(length(btrim(name)) between 1 and 150), description text not null default '' check(length(description)<=1500),
 category text not null default '월 회원권' check(length(btrim(category)) between 1 and 150),
 recurring boolean not null default true, weekly_limit integer not null default 0 check(weekly_limit between 0 and 7),
 capacity integer not null default 0 check(capacity>=0), stock integer not null default 0 check(stock>=0),
 active boolean not null default true, selling boolean not null default true, sort_order integer not null default 0 check(sort_order>=0),
 image_id uuid, created_at timestamptz not null default now(), unique(id,center_id),
 foreign key(image_id,center_id) references public.media_assets(id,center_id)
);
create table public.product_prices (
 id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products,
 amount bigint not null check(amount>=0), currency text not null default 'KRW' check(currency='KRW'),
 interval_months integer check(interval_months>0), effective_at timestamptz not null default now(),
 created_by uuid not null references public.profiles, unique(id,product_id)
);
create table public.product_access_centers (
 product_id uuid references public.products on delete cascade, center_id uuid references public.centers,
 primary key(product_id,center_id)
);
create table public.payment_configs (
 id uuid primary key default gen_random_uuid(), center_id uuid not null references public.centers,
 provider text not null check(provider in ('mock','toss')), mode text not null default 'test' check(mode in ('test','live')),
 merchant_label text not null default '', enabled boolean not null default false,
 is_current boolean not null default true, created_at timestamptz not null default now(), unique(id,center_id)
);
-- Preserve previous configurations for historical payments when a PG account changes.
create unique index payment_config_current_center on public.payment_configs(center_id) where is_current;
create table gym_private.payment_accounts (
 config_id uuid primary key references public.payment_configs on delete cascade,
 secret_reference text not null, merchant_id text, created_at timestamptz not null default now()
);
create table gym_private.billing_methods (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.profiles,
 config_id uuid not null references public.payment_configs,
 billing_key_secret_reference text not null, customer_key text not null,
 status text not null default 'active' check(status in ('active','revoked')),
 created_at timestamptz not null default now(), unique(id,config_id,member_id)
);
create table public.subscriptions (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.profiles,
 center_id uuid not null references public.centers, product_id uuid not null, price_id uuid not null,
 payment_config_id uuid not null, billing_method_id uuid,
 status text not null check(status in ('PENDING','ACTIVE','CANCEL_AT_PERIOD_END','EXPIRED','PAYMENT_FAILED','SUSPENDED')),
 current_period_start date not null, current_period_end date not null, next_payment_at timestamptz,
 weekly_limit integer not null check(weekly_limit between 0 and 7), unit_amount bigint not null check(unit_amount>=0),
 created_at timestamptz not null default now(), canceled_at timestamptz,
 check(current_period_end>current_period_start), unique(id,center_id), unique(id,center_id,member_id), unique(id,member_id,product_id),
 foreign key(product_id,center_id) references public.products(id,center_id),
 foreign key(price_id,product_id) references public.product_prices(id,product_id),
 foreign key(payment_config_id,center_id) references public.payment_configs(id,center_id),
 foreign key(billing_method_id,payment_config_id,member_id) references gym_private.billing_methods(id,config_id,member_id)
);
-- Ended subscriptions must be marked EXPIRED by the server before a new purchase.
create unique index subscription_one_open_per_member on public.subscriptions(member_id) where status <> 'EXPIRED';
create table public.subscription_access_centers (
 subscription_id uuid references public.subscriptions on delete cascade, center_id uuid references public.centers,
 primary key(subscription_id,center_id)
);
create table public.subscription_items (
 id uuid primary key default gen_random_uuid(), center_id uuid not null references public.centers,
 subscription_id uuid not null, product_id uuid, label text not null,
 unit_amount bigint not null check(unit_amount>=0), quantity integer not null default 1 check(quantity>0),
 foreign key(subscription_id,center_id) references public.subscriptions(id,center_id),
 foreign key(product_id,center_id) references public.products(id,center_id)
);
create table public.lockers (
 id uuid primary key default gen_random_uuid(), center_id uuid not null references public.centers,
 number text not null check(length(btrim(number)) between 1 and 50), location text not null default '',
 monthly_price bigint not null default 0 check(monthly_price>=0),
 status text not null default 'AVAILABLE' check(status in ('AVAILABLE','OCCUPIED','MAINTENANCE','DISABLED')),
 unique(center_id,number), unique(id,center_id)
);
create table public.locker_assignments (
 id uuid primary key default gen_random_uuid(), center_id uuid not null references public.centers,
 locker_id uuid not null, subscription_id uuid not null, starts_at timestamptz not null,
 ends_at timestamptz not null, released_at timestamptz, monthly_amount bigint not null check(monthly_amount>=0),
 check(ends_at>starts_at), check(released_at is null or released_at>=starts_at),
 foreign key(locker_id,center_id) references public.lockers(id,center_id),
 foreign key(subscription_id,center_id) references public.subscriptions(id,center_id)
);
create unique index locker_current_assignment on public.locker_assignments(locker_id) where released_at is null;
create unique index subscription_current_locker on public.locker_assignments(subscription_id) where released_at is null;
create table public.locker_changes (
 id uuid primary key default gen_random_uuid(), center_id uuid not null references public.centers,
 subscription_id uuid not null, from_locker_id uuid, to_locker_id uuid not null,
 changed_by uuid not null references public.profiles, created_at timestamptz not null default now(),
 check(from_locker_id is distinct from to_locker_id),
 foreign key(subscription_id,center_id) references public.subscriptions(id,center_id),
 foreign key(from_locker_id,center_id) references public.lockers(id,center_id),
 foreign key(to_locker_id,center_id) references public.lockers(id,center_id)
);
create table public.orders (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.profiles,
 center_id uuid not null references public.centers, total_amount bigint not null check(total_amount>=0),
 status text not null check(status in ('PENDING','PAID','FAILED','CANCELED','REFUNDED')),
 request_id uuid not null unique, created_at timestamptz not null default now(), unique(id,center_id), unique(id,center_id,member_id)
);
create table public.order_items (
 id uuid primary key default gen_random_uuid(), center_id uuid not null references public.centers,
 order_id uuid not null, product_id uuid not null, name_snapshot text not null,
 quantity integer not null check(quantity>0), unit_amount bigint not null check(unit_amount>=0),
 foreign key(order_id,center_id) references public.orders(id,center_id),
 foreign key(product_id,center_id) references public.products(id,center_id)
);
create table public.payments (
 id uuid primary key default gen_random_uuid(), center_id uuid not null references public.centers,
 member_id uuid not null references public.profiles, config_id uuid not null,
 subscription_id uuid, order_id uuid, amount bigint not null check(amount>=0),
 provider text not null check(provider in ('mock','toss')), provider_payment_key text,
 status text not null check(status in ('PENDING','PAID','FAILED','CANCELED','REFUNDED')),
 request_id uuid not null unique, paid_at timestamptz, created_at timestamptz not null default now(),
 foreign key(config_id,center_id) references public.payment_configs(id,center_id),
 foreign key(subscription_id,center_id,member_id) references public.subscriptions(id,center_id,member_id),
 foreign key(order_id,center_id,member_id) references public.orders(id,center_id,member_id),
 check(num_nonnulls(subscription_id,order_id)=1)
);
create unique index payment_provider_key on public.payments(config_id,provider_payment_key) where provider_payment_key is not null;
create table public.payment_attempts (
 id uuid primary key default gen_random_uuid(), payment_id uuid not null references public.payments,
 idempotency_key text not null unique, status text not null check(status in ('PENDING','SUCCEEDED','FAILED','UNKNOWN')),
 failure_code text, created_at timestamptz not null default now()
);
create table public.attendance (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.profiles,
 center_id uuid not null references public.centers, subscription_id uuid, product_id uuid,
 occurred_at timestamptz not null default now(),
 korean_date date generated always as ((occurred_at at time zone 'Asia/Seoul')::date) stored,
 success boolean not null, reason text not null,
 foreign key(subscription_id,member_id,product_id) references public.subscriptions(id,member_id,product_id),
 check((subscription_id is null) = (product_id is null)), check(not success or subscription_id is not null)
);
create unique index attendance_once_daily on public.attendance(member_id,korean_date) where success;
create index attendance_center_date on public.attendance(center_id,korean_date desc);
create index attendance_member_date on public.attendance(member_id,korean_date desc);
create index subscriptions_center_status on public.subscriptions(center_id,status);
create index products_center_sort on public.products(center_id,sort_order);
create index prices_product_effective on public.product_prices(product_id,effective_at desc);
create index payments_center_date on public.payments(center_id,created_at desc);
create index payments_member_date on public.payments(member_id,created_at desc);
create index center_admins_user on public.center_admins(user_id);
create index center_members_member on public.center_members(member_id);
create index orders_member_date on public.orders(member_id,created_at desc);

-- Explicit object permissions; never rely on project default privileges.
do $permissions$ declare t text; begin
 foreach t in array array['profiles','centers','center_admins','center_members','media_assets','center_appearance','products','product_prices','product_access_centers','payment_configs','subscriptions','subscription_access_centers','subscription_items','lockers','locker_assignments','locker_changes','orders','order_items','payments','payment_attempts','attendance'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('grant all on public.%I to service_role',t);
 end loop;
end $permissions$;
grant usage on schema public to anon, authenticated, service_role;
grant select on public.centers,public.center_appearance,public.products,public.product_prices,public.product_access_centers to anon;
alter table gym_private.payment_accounts enable row level security;
alter table gym_private.billing_methods enable row level security;
revoke all on gym_private.payment_accounts,gym_private.billing_methods from public,anon,authenticated;
grant all on gym_private.payment_accounts,gym_private.billing_methods to service_role;

-- No role is ever taken from user-editable signup metadata.
create function gym_private.is_center_admin(target uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.center_admins a where a.center_id=target and a.user_id=(select auth.uid()));
$$;
create function gym_private.can_manage_center(target uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.center_admins a where a.center_id=target and a.user_id=(select auth.uid()) and a.role in ('owner','manager'));
$$;
create function gym_private.can_read_subscription(target uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.subscriptions s where s.id=target and (s.member_id=(select auth.uid()) or gym_private.is_center_admin(s.center_id)));
$$;
create function gym_private.can_read_media(object_name text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.center_admins a where a.user_id=(select auth.uid()) and a.center_id::text=split_part(object_name,'/',1)) or exists(
  select 1 from public.media_assets m join public.centers c on c.id=m.center_id
  where m.object_path=object_name and (
   gym_private.is_center_admin(c.id)
   or (c.active and (
    exists(select 1 from public.center_appearance a where a.center_id=c.id and a.background_image_id=m.id)
    or exists(select 1 from public.products p where p.image_id=m.id and p.center_id=c.id and p.active and p.selling)
   ))
  )
 );
$$;
revoke all on function gym_private.is_center_admin(uuid),gym_private.can_manage_center(uuid),gym_private.can_read_subscription(uuid),gym_private.can_read_media(text) from public,anon,authenticated;
grant execute on function gym_private.is_center_admin(uuid),gym_private.can_manage_center(uuid),gym_private.can_read_subscription(uuid) to authenticated,service_role;
grant execute on function gym_private.can_read_media(text) to anon,authenticated,service_role;

-- Anonymous visitors may browse only the active catalog. Personal records
-- require Supabase Auth; browser writes remain closed until server APIs exist.
create policy center_catalog on public.centers for select to anon,authenticated using(active);
create policy center_admin_read on public.centers for select to authenticated using(gym_private.is_center_admin(id));
create policy admins_self on public.center_admins for select to authenticated using(user_id=(select auth.uid()));
create policy membership_read on public.center_members for select to authenticated using(member_id=(select auth.uid()) or gym_private.is_center_admin(center_id));
create policy profile_self_or_admin on public.profiles for select to authenticated using(
 id=(select auth.uid()) or exists(select 1 from public.center_members cm where cm.member_id=profiles.id and gym_private.is_center_admin(cm.center_id)));
create policy media_admin_read on public.media_assets for select to authenticated using(gym_private.is_center_admin(center_id));
create policy appearance_catalog on public.center_appearance for select to anon,authenticated using(exists(select 1 from public.centers c where c.id=center_appearance.center_id and c.active));
create policy appearance_admin_read on public.center_appearance for select to authenticated using(gym_private.is_center_admin(center_id));
create policy product_catalog on public.products for select to anon,authenticated using(active and selling and exists(select 1 from public.centers c where c.id=products.center_id and c.active));
create policy product_admin_read on public.products for select to authenticated using(gym_private.is_center_admin(center_id));
create policy subscription_read on public.subscriptions for select to authenticated using(member_id=(select auth.uid()) or gym_private.is_center_admin(center_id));
create policy order_read on public.orders for select to authenticated using(member_id=(select auth.uid()) or gym_private.is_center_admin(center_id));
create policy order_item_read on public.order_items for select to authenticated using(exists(select 1 from public.orders o where o.id=order_items.order_id));
-- Preserve access to the name of a retired product in one's purchase history.
create policy purchased_product_read on public.products for select to authenticated using(
 exists(select 1 from public.subscriptions s where s.product_id=products.id and s.member_id=(select auth.uid()))
 or exists(select 1 from public.order_items i join public.orders o on o.id=i.order_id where i.product_id=products.id and o.member_id=(select auth.uid())));
create policy price_read on public.product_prices for select to anon,authenticated using(exists(select 1 from public.products p where p.id=product_prices.product_id));
create policy product_access_read on public.product_access_centers for select to anon,authenticated using(exists(select 1 from public.products p where p.id=product_access_centers.product_id));
create policy config_admin on public.payment_configs for select to authenticated using(gym_private.is_center_admin(center_id));
create policy subscription_item_read on public.subscription_items for select to authenticated using(gym_private.can_read_subscription(subscription_id));
create policy subscription_access_read on public.subscription_access_centers for select to authenticated using(gym_private.can_read_subscription(subscription_id));
create policy locker_read on public.lockers for select to authenticated using(gym_private.is_center_admin(center_id) or exists(select 1 from public.centers c where c.id=lockers.center_id and c.active));
create policy assignment_read on public.locker_assignments for select to authenticated using(gym_private.can_read_subscription(subscription_id));
create policy locker_history_read on public.locker_changes for select to authenticated using(gym_private.can_read_subscription(subscription_id));
create policy payment_read on public.payments for select to authenticated using(member_id=(select auth.uid()) or gym_private.is_center_admin(center_id));
create policy attempt_read on public.payment_attempts for select to authenticated using(exists(select 1 from public.payments p where p.id=payment_attempts.payment_id));
create policy attendance_read on public.attendance for select to authenticated using(member_id=(select auth.uid()) or gym_private.is_center_admin(center_id));

create function gym_private.create_profile() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,name,phone) values(new.id,left(coalesce(nullif(btrim(new.raw_user_meta_data->>'name'),''),'회원'),150),left(new.phone,30));
 return new;
end $$;
revoke all on function gym_private.create_profile() from public,anon,authenticated;
create trigger gym_auth_user_created after insert on auth.users for each row execute function gym_private.create_profile();
-- Accounts made in Authentication before installation also get a profile.
insert into public.profiles(id,name,phone,created_at)
select id,left(coalesce(nullif(btrim(raw_user_meta_data->>'name'),''),'회원'),150),left(phone,30),coalesce(created_at,now()) from auth.users;

create function gym_private.reject_price_mutation() returns trigger language plpgsql set search_path='' as $$
begin raise exception '가격 이력은 수정·삭제하지 않습니다. 새 가격 행을 추가해 주세요.'; end $$;
revoke all on function gym_private.reject_price_mutation() from public,anon,authenticated;
create trigger gym_price_immutable before update or delete on public.product_prices for each row execute function gym_private.reject_price_mutation();

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('center-media','center-media',false,5242880,array['image/jpeg','image/png','image/webp']);
create policy gym_media_upload on storage.objects for insert to authenticated with check(
 bucket_id='center-media' and name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'
 and exists(select 1 from public.centers c where c.id::text=(storage.foldername(storage.objects.name))[1] and gym_private.can_manage_center(c.id)));
-- No blind overwrite/delete: replacements use new objects. Dereferenced assets
-- cannot be read by catalog users; server-side cleanup comes with app integration.
create policy gym_media_read on storage.objects for select to anon,authenticated using(
 bucket_id='center-media' and gym_private.can_read_media(name));

comment on schema gym_private is 'ANY BOXING: internal helpers and billing references. Do not expose this schema in the Data API.';
comment on table public.profiles is '회원 기본정보; 관리자 권한은 center_admins에서 별도 관리';
comment on table public.product_prices is '추가만 가능한 가격 이력. 기존 구독은 구매 당시 금액을 유지';
comment on table public.attendance is '한국 날짜 자동 산출. 성공은 하루 1회; 실패도 사유와 함께 기록';
comment on table gym_private.payment_accounts is '실제 Secret Key가 아닌 서버 비밀 저장소의 참조만 저장';
commit;
select 'SETUP_COMPLETE' as result, 21 as public_tables, 2 as private_tables, 'center-media' as image_bucket;


