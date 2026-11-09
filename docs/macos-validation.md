# macOS 검증 기록

검증일: 2026-11-09

## 확인한 범위

- 로컬 Apple Silicon 맥에서 arm64·x86_64 유니버설 dylib와 진단 프로그램을 빌드했습니다. 컴파일 옵션 `-Wall -Wextra -Werror`를 통과했습니다.
- 실제 macOS Security API 반환 목록에서 자체 서명된 G4만 제외하고, 빠진 DigiCert Assured ID Root CA를 보충했습니다. 나머지 인증서의 SHA-256 목록과 각 도메인의 반환 상태는 그대로 유지됐습니다. 잘못된 도메인의 오류 상태도 유지됐습니다.
- arm64 네이티브 실행과 Rosetta x86_64 실행에서 같은 변환 결과를 확인했습니다.
- `/usr/bin/ruby tests/macos_test.rb`: 9개 테스트, 61개 단언, 실패·오류·건너뛰기 0개였습니다.
- 임시 보틀에서 설치 반복 실행, 인증서 DER 직렬화, 자체 서명 G4 재유입 후 실행, 제거 시 다른 설정 보존, 손상된 백업 거부, 비어 있는 중단 상태 복구를 확인했습니다.
- 공개 교차서명 인증서가 포함된 핀 루트로 검증되는 것을 OpenSSL로 확인했습니다.
- 기존 Linux 실행 스크립트는 변경하지 않았으며 Bash 구문 검사를 통과했습니다. Linux에서 새로 게임을 실행한 것은 아닙니다.

## 아직 확인하지 못한 범위

검증 머신에는 Wine·CrossOver·Whisky·오버워치가 설치되어 있지 않았습니다. 실제 Wine의 `crypt32` 인증서 연결, 배틀넷 로그인, 게임 실행 및 매치 진입은 검증하지 못했습니다. CrossOver나 Whisky의 서명 정책이 DYLD 주입을 허용하는지도 설치된 실제 런타임에서 확인해야 합니다.

네이티브 테스트는 실제 macOS API를 사용하는 진단 프로세스에 관한 증거입니다. Wine과 게임 호환성을 증명하지 않습니다. `doctor`는 이 차이를 유지하기 위해 종료 코드 2와 `NOT VERIFIED`를 반환합니다. SIP 비활성화, 사용자 앱 재서명, 시스템 키체인 변경은 수행하지 않았습니다.

## 구현 근거

- [원본 원인 분석](ANALYSIS.md)
- [Wine crypt32 macOS 호스트 인증서 열거](https://github.com/wine-mirror/wine/blob/master/dlls/crypt32/unixlib.c)
- [Wine 루트 저장소 동기화](https://github.com/wine-mirror/wine/blob/master/dlls/crypt32/rootstore.c)
- [Apple DYLD 환경변수 권한](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables)
- [Apple 라이브러리 검증 권한](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
