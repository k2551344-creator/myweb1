@echo off
chcp 65001 >nul
cd /d "%~dp0center-manager"
echo ANY BOXING 테스트 프로그램을 실행합니다.
echo 브라우저에서 http://127.0.0.1:5173/ 주소를 열어 주세요.
echo 이 창을 닫으면 프로그램이 종료됩니다.
"C:\Users\USER\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe" scripts/local-preview.mjs
pause
