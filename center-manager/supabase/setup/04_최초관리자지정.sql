-- 먼저 웹에서 taehwancoen@naver.com으로 가입하고 이메일 인증을 완료하세요.
-- Supabase SQL Editor에서 실행합니다. 기존 센터가 있으면 임의로 권한을 부여하지 않습니다.
begin;
select pg_advisory_xact_lock(734826092);
do $$
declare uid uuid; cid uuid;
begin
 select id into uid from auth.users where lower(email)='taehwancoen@naver.com' and email_confirmed_at is not null;
 if uid is null then raise exception 'taehwancoen@naver.com 가입 및 이메일 인증을 먼저 완료해 주세요.'; end if;
 if exists(select 1 from public.center_admins where user_id=uid and role='owner') then return; end if;
 if exists(select 1 from public.centers) then raise exception '기존 센터가 있습니다. 센터를 확인한 뒤 관리자 권한을 지정해 주세요.'; end if;
 insert into public.centers(name,brand) values('본점','ANY BOXING') returning id into cid;
 insert into public.center_appearance(center_id) values(cid);
 insert into public.center_admins(center_id,user_id,role) values(cid,uid,'owner');
end $$;
commit;
select 'ADMIN_READY' as result;
