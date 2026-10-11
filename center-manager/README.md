> 로그인 계획 변경: 05번 실행 후 [07번 SQL과 이메일·전화번호 출석 설정](docs/이메일가입_전화번호출석_적용안내.md)을 적용합니다. 소셜 로그인은 사용하지 않습니다.

# ANY BOXING · 센터 관리

## 회원·지점 결제 확장 (2026-10-12)

이메일 로그인·회원 기본정보, 지점 사업자/토스 설정, 상세/약관/해지 문구, 주·월 결제주기, 락카 합산 구매와 해지를 추가했습니다. [추가 설정 안내](docs/회원결제_설정안내.md)의 05번 SQL과 결제 서버 설정을 적용해야 동작합니다. 실제 결제/로그인 검증은 아직 남아 있습니다.

## GitHub Pages + Supabase 연결 버전

`web/`에는 실제 Supabase Auth와 센터·상품·이미지·배경 저장을 연결한 웹이 있습니다. `npm run build:pages`로 생성한 `pages-dist`를 기존 myweb1 저장소에 올립니다. 추가 SQL 03번과 최초 관리자 지정 04번은 사용자가 Supabase에서 실행합니다. [적용 안내](docs/깃허브_적용안내.md)를 따라 주세요. 실제 프로젝트/깃허브에 반영되기 전이며, 구독·결제·출석 연결은 아직 남아 있습니다.

## 기존 로컬 데모

비공개 기능 테스트용 관리자 웹과 회원 모바일 웹입니다. 실제 운영용 인증·결제는 연결되지 않았습니다.

## 이 PC에서 실행

상위 폴더의 **실행.cmd**를 더블클릭한 뒤 [관리자 화면](http://127.0.0.1:5173/) 또는 [회원 화면](http://127.0.0.1:5173/member)을 엽니다. 프로그램이 이미 실행 중이라면 주소만 열면 됩니다.

- [사진·배경 설정 사용 안내](docs/사용안내.md)
- [아키텍처와 구현 상태](docs/아키텍처.md)
- [검증 결과와 제한](docs/검증기록.md)

## 저장

로컬 테스트 데이터와 업로드는 `.sites-runtime/local-data`에 저장됩니다. 이 폴더를 지우면 테스트 데이터가 사라집니다. 사진 삭제 버튼은 이미지 연결만 해제합니다.

배포용 구조는 Cloudflare D1/R2를 사용하며, 실제 운영 전환용 Supabase 관계형 설계는 `supabase/migrations`에 있습니다. 현재 실행 중인 앱은 Supabase에 연결되지 않았습니다.

## 개발

Node 22.13 이상 및 npm이 필요합니다. 의존성은 package-lock.json을 기준으로 설치합니다.

- `npm run dev:local`: Windows에서도 동작하는 로컬 테스트 서버
- `npm test`: 핵심 업무 규칙 테스트
- `npm run build`: 배포용 Worker 및 웹 클라이언트 빌드

결제 모듈은 `services/payment`, 테스트 저장소는 `services/demo`, 공통 업무 규칙은 `lib/actions.ts`로 분리되어 있습니다. 관리자 화면은 `components/Admin.tsx`, 상품·꾸미기 화면은 `components/Catalog.tsx`, 회원 화면은 `components/Member.tsx`입니다.

실제 회원 개인정보나 실제 Secret Key를 테스트 화면에 입력하지 마세요. Supabase Auth·DB·Storage 어댑터, Toss 서버 결제·재결제·웹훅, 실제 QR 출석은 후속 구현과 연결이 필요합니다.

## Supabase 테이블 설치

실행용 SQL과 단계별 안내는 [Supabase 설치 안내](supabase/setup/00_실행안내.md)에 있습니다. 01번 생성 SQL, 02번 확인 SQL 순서로 실행합니다. 로컬 PostgreSQL 검증 40개를 통과했으며 실제 Supabase 프로젝트에는 아직 적용하지 않았습니다.
