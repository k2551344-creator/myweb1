-- 설치 후 SQL Editor의 새 쿼리에서 실행합니다. 데이터를 수정하지 않습니다.
-- 모든 행의 result가 PASS이면 기본 구조와 권한이 준비된 상태입니다.
with expected(schema_name,table_name) as (
 select 'public',unnest(array['profiles','centers','center_admins','center_members','media_assets','center_appearance','products','product_prices','product_access_centers','payment_configs','subscriptions','subscription_access_centers','subscription_items','lockers','locker_assignments','locker_changes','orders','order_items','payments','payment_attempts','attendance'])
 union all select 'gym_private',unnest(array['payment_accounts','billing_methods'])
), inspected as (
 select e.*,c.oid,c.relrowsecurity from expected e
 left join pg_class c on c.oid=to_regclass(format('%I.%I',e.schema_name,e.table_name)) and c.relkind='r'
), checks(number,check_name,ok,detail) as (
 select 1,'운영 테이블 21개',(select count(*)=21 from inspected where schema_name='public' and oid is not null),'회원·센터·상품·구독·결제·출석·락카' union all
 select 2,'비공개 결제 테이블 2개',(select count(*)=2 from inspected where schema_name='gym_private' and oid is not null),'비밀값 대신 서버 비밀 저장소 참조 보관' union all
 select 3,'모든 테이블 RLS 활성화',(select count(*)=23 from inspected where oid is not null and relrowsecurity),'회원·지점별 접근 제한' union all
 select 4,'웹에서 직접 운영 데이터 변경 차단',(select count(*)=23 from inspected where oid is not null and not has_table_privilege('authenticated',oid,'INSERT,UPDATE,DELETE,TRUNCATE')),'저장은 이후 연결할 인증된 서버 API를 사용' union all
 select 5,'비회원 개인정보 접근 차단',(select count(*)=18 from inspected where table_name not in ('centers','center_appearance','products','product_prices','product_access_centers') and oid is not null and not has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')),'공개 상품 정보 이외 접근 금지' union all
 select 6,'회원 비밀 결제 정보 접근 차단',(select count(*)=2 from inspected where schema_name='gym_private' and oid is not null and not has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')),'서버 전용 결제 참조' union all
 select 7,'서버 데이터 접근 권한',(select count(*)=23 from inspected where oid is not null and has_table_privilege('service_role',oid,'SELECT') and has_table_privilege('service_role',oid,'INSERT') and has_table_privilege('service_role',oid,'UPDATE')),'서버는 별도로 로그인과 관리자 권한을 검사해야 함' union all
 select 8,'신규 회원 프로필 자동 생성',exists(select 1 from pg_trigger where tgrelid='auth.users'::regclass and tgname='gym_auth_user_created' and tgenabled='O'),'기존 인증 사용자 프로필도 초기 생성' union all
 select 9,'가격 이력 보호',exists(select 1 from pg_trigger where tgrelid=to_regclass('public.product_prices') and tgname='gym_price_immutable' and tgenabled='O'),'변경 시 기존 행 수정 대신 새 가격 추가' union all
 select 10,'이미지 저장소 설정',exists(select 1 from storage.buckets where id='center-media' and not public and file_size_limit=5242880 and allowed_mime_types @> array['image/jpeg','image/png','image/webp'] and cardinality(allowed_mime_types)=3),'비공개 저장소 · JPG/PNG/WebP · 5MB' union all
 select 11,'이미지 접근 정책',(select count(*)=2 from pg_policies where schemaname='storage' and tablename='objects' and policyname in ('gym_media_read','gym_media_upload')),'센터 관리자 업로드와 공개 상품 이미지 조회' union all
 select 12,'운영 테이블 조회 정책',(select count(distinct tablename)=21 from pg_policies where schemaname='public' and tablename in (select table_name from expected where schema_name='public')),'각 테이블에 조회 범위 설정'
)
select check_name,case when coalesce(ok,false) then 'PASS' else 'FAIL' end as result,detail from checks order by number;
