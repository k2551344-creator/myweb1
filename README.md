# ANY BOXING / myweb1

GitHub: https://github.com/k2551344-creator/myweb1

웹: https://k2551344-creator.github.io/myweb1/

## 파일 구성

- `index.html`, `assets/`: 기존 GitHub Pages에 배포된 웹 파일
- `center-manager/`: 개발 소스, 테스트, Supabase SQL
- `실행.cmd`: 기존 로컬 데모 실행

소스 변경만으로 공개 페이지가 바뀌지는 않습니다. 웹을 배포할 때는 `center-manager`에서 `npm run build:pages`로 빌드한 뒤 `pages-dist` 안의 파일을 저장소 루트에 반영하고 commit/push합니다. 자세한 초기 연결 과정은 [적용 안내](center-manager/docs/깃허브_적용안내.md)를 참고하세요.

## 앞으로 변경사항 저장하기

이 폴더의 `main`은 `origin/main`을 추적합니다. GitHub 인증은 Git Credential Manager를 사용합니다. 토큰을 소스나 원격 주소에 적지 않습니다.

```powershell
git status
git diff
git add .
git diff --cached --stat
git commit -m "변경 내용 설명"
git push
```

다른 PC나 GitHub에서 변경했다면 로컬 변경을 먼저 커밋한 뒤 `git pull --ff-only`로 가져옵니다. 서로 다른 커밋이 생겨 가져오기가 중단되면 강제 push 대신 이력을 확인합니다.

`.env`, `.env.local`, `node_modules`, 로컬 DB, 캐시, 업로드 ZIP은 추적에서 제외됩니다. 실제 값이 비어 있는 `.env.example`만 소스에 포함합니다. 커밋 전 `git status`와 변경 내용을 확인하세요.

현재 프로젝트에 설정한 커밋 작성자는 기존 저장소의 작성자와 동일합니다. 다른 작성자 정보를 사용하려면 이 폴더에서 `git config user.name`과 `git config user.email`을 설정합니다.
