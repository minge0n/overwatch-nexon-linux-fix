# macOS 실험용 포트

이 문서는 [minge0n 포크](https://github.com/minge0n/overwatch-nexon-linux-fix)의 macOS용 실험 기능을 설명합니다. 기존 Linux 스크립트와 사용 방법이 다릅니다.

**아직 실제 게임 실행은 검증되지 않았습니다.** macOS 네이티브 테스트 프로그램으로 인증서 필터를 확인할 수 있지만, Wine과 게임이 설치된 환경에서 Battle.net이나 오버워치 실행을 확인한 것은 아닙니다. CrossOver와 Whisky의 실행 파일 위치 및 실행 방식도 환경별로 검증되지 않았습니다.

## 작동 방식과 범위

이 포트는 선택한 Wine 프리픽스에 필요한 인증서 설정을 적용하고, 실행할 때 네이티브 라이브러리를 해당 프로세스에 주입합니다. 라이브러리는 `SecTrustSettingsCopyCertificates`만 가로채 자체 서명된 DigiCert Trusted Root G4를 반환 목록에서 제외하며, 다른 루트 인증서는 유지합니다. macOS 목록에서 게임에 필요한 DigiCert Assured ID Root CA가 빠져 있으면 해당 프로세스의 System 도메인 반환 목록에 공개 인증서 사본을 보충합니다. Wine이 프리픽스의 루트 인증서를 호스트와 동기화하면서 삭제하지 않게 하기 위한 처리이며, 시스템 키체인에는 추가하지 않습니다. 변경은 이 API 호출에 한정되며, 모든 신뢰 평가 경로에 적용된다고 보장하지 않습니다.

시스템 Keychain을 수정하거나 게임 DLL을 패치하지 않고 서명 검증을 우회하지도 않습니다. 대신 프리픽스의 인증서 관련 레지스트리 항목은 수정합니다. 원래 항목과 작업 상태는 프리픽스의 `.overwatch-nexon-macos-fix`에 보관하며, 제거할 때 전체 레지스트리 파일을 덮어쓰지 않고 해당 인증서 항목만 복원합니다. 중요한 프리픽스는 사용 전에 별도로 백업하세요.

## 준비

- macOS와 `/usr/bin/ruby`로 실행할 수 있는 시스템 Ruby
- `clang`이 포함된 Xcode Command Line Tools
- 사용할 Wine 프리픽스와 그 프리픽스를 실행하는 네이티브 Wine 런타임

다음 명령으로 도구의 사용 가능 여부를 확인하세요. 필요한 도구가 없다면 직접 설치한 뒤 다시 확인하세요. 이 포트가 도구를 자동으로 설치하지는 않습니다.

```bash
/usr/bin/ruby --version
xcrun --find clang
```

저장소를 아직 받지 않았다면 다음과 같이 받으세요.

```bash
git clone https://github.com/minge0n/overwatch-nexon-linux-fix.git
cd overwatch-nexon-linux-fix
```

아래 명령은 모두 저장소 루트에서 실행합니다. 프리픽스를 명시적으로 지정하면 다른 설치를 잘못 선택할 가능성을 줄일 수 있습니다. `/absolute/prefix`를 `system.reg`가 있는 실제 프리픽스 디렉터리의 절대 경로로 바꾸세요.

```bash
export OW_PREFIX="/absolute/prefix"
```

`OW_PREFIX`를 생략하면 지원되는 CrossOver, Whisky, `~/.wine` 위치에서 프리픽스를 자동 탐색합니다. 자동 탐색이 실패하거나 원하는 프리픽스가 확실하지 않으면 직접 지정하세요. 프리픽스 경로와 Wine 실행 파일 경로는 서로 다릅니다.

## 설치와 실행

프리픽스를 백업하고 모든 Battle.net, 게임 및 Wine 프로세스를 종료한 다음 설치하세요. 다른 보틀의 Wine도 실행 중이면 안전을 위해 설치·실행·제거를 거부합니다.

```bash
OW_PREFIX="$OW_PREFIX" /usr/bin/ruby macos/overwatch-nexon-macos-fix.rb install
OW_PREFIX="$OW_PREFIX" /usr/bin/ruby macos/overwatch-nexon-macos-fix.rb status
OW_PREFIX="$OW_PREFIX" /usr/bin/ruby macos/overwatch-nexon-macos-fix.rb doctor
```

출력에서 선택한 프리픽스와 진단 결과를 확인하세요. `status`가 성공하더라도 게임 실행이 확인된 것은 아닙니다. `doctor`는 네이티브 필터 검사 뒤에도 실제 Wine 인증서 연결과 게임 실행을 `NOT VERIFIED`로 표시하며 종료 코드 2를 반환합니다. 이 코드를 설치 실패나 게임 실행 성공으로 해석하지 마세요.

실행할 때마다 `run`을 사용해야 합니다. `OW_WINE`에는 사용 중인 환경에서 **직접 확인한 네이티브 Wine Mach-O 실행 파일의 절대 경로**를 지정하세요. 셸 스크립트, `/usr/bin/open`, `/usr/bin/env` 또는 Windows `.exe`를 이 자리에 넣지 마세요. CrossOver와 Whisky에서 사용할 경로는 설치 및 버전마다 다를 수 있으므로 아래 값은 예시가 아닌 자리 표시자입니다.

```bash
export OW_WINE="/absolute/path/to/native/wine"
OW_PREFIX="$OW_PREFIX" /usr/bin/ruby macos/overwatch-nexon-macos-fix.rb run \
  "$OW_WINE" 'C:\Program Files (x86)\Battle.net\Battle.net Launcher.exe'
```

Windows 실행 파일 경로와 나머지 인수는 실제 Wine 환경에 맞게 바꾸세요. 기존 Battle.net 프로세스가 실행 중이면 요청이 래퍼 밖의 프로세스로 전달될 수 있으므로, 테스트 전에 관련 프로세스를 모두 종료하세요.

## 네이티브 빌드 및 확인

다음 명령은 별도 출력 디렉터리에 arm64와 x86_64를 포함하는 `libow-nexon-trust.dylib`와 `trust-probe`를 빌드합니다.

```bash
BUILD_DIR="$(mktemp -d)"
bash macos/build.sh "$BUILD_DIR"
lipo -info "$BUILD_DIR/libow-nexon-trust.dylib"
lipo -info "$BUILD_DIR/trust-probe"
```

각 `lipo` 출력에 두 아키텍처가 있는지 확인하세요. 다음 두 실행의 결과를 비교하면 현재 Mac에서 라이브러리 주입 전후의 인증서 목록을 살펴볼 수 있습니다.

```bash
"$BUILD_DIR/trust-probe"
DYLD_INSERT_LIBRARIES="$BUILD_DIR/libow-nexon-trust.dylib" "$BUILD_DIR/trust-probe"
```

주입 후 자체 서명된 G4가 제외되고, 필요한 핀 루트만 보충되며 다른 루트가 유지되는지 출력과 프로그램의 종료 상태를 확인하세요. G4가 원래 목록에 없다면 이 비교만으로 필터가 작동한다고 결론 내릴 수 없습니다. 네이티브 probe의 결과는 해당 API와 테스트 프로세스에 관한 확인일 뿐, Wine이나 실제 게임에서 동일하게 작동한다는 증거는 아닙니다.

## 제한과 문제 해결

- `DYLD_INSERT_LIBRARIES`가 실행 경로 중 스크립트나 런처에 의해 제거되거나 자식 프로세스에 전달되지 않을 수 있습니다. 실제 네이티브 Wine 실행 파일로 시작했는지 확인하세요.
- macOS의 hardened runtime과 라이브러리 검증은 주입을 막을 수 있습니다. 주입이 막힌 경우 이 방법이 해당 런타임에서 동작하지 않을 수 있습니다. SIP를 끄거나 사용자 앱을 자동으로 다시 서명하지 마세요.
- 이 라이브러리는 대상 프로세스의 인증서 신뢰 결과를 바꿉니다. 게임 및 관련 프로세스의 연결에 예상치 못한 영향을 줄 수 있으므로 신뢰하는 실행 경로에만 사용하세요.
- 문제가 있으면 `doctor`의 출력과 선택한 프리픽스, 실제 실행 파일 경로를 확인하세요. 네이티브 probe 성공만으로 게임 문제의 원인이나 해결을 확정할 수는 없습니다.

## 제거

해당 프리픽스의 Battle.net, 게임 및 Wine 프로세스를 종료한 뒤 설치할 때와 같은 프리픽스를 지정하세요.

```bash
OW_PREFIX="$OW_PREFIX" /usr/bin/ruby macos/overwatch-nexon-macos-fix.rb uninstall
```

제거는 저장된 인증서 관련 항목을 복원하며, 프리픽스의 다른 레지스트리 변경 사항을 통째로 이전 상태로 되돌리지는 않습니다. 제거 결과를 확인하고 더 이상 실행 래퍼를 사용하지 마세요.

## 테스트와 실제 Wine 진단

저장소 루트에서 `/usr/bin/ruby tests/macos_test.rb`를 실행하세요. 이 테스트는 macOS의 실제 공개 인증서 목록을 읽고 임시 프리픽스만 수정합니다. 실제 게임이나 사용자 보틀을 실행하지 않습니다. 현재 Mac의 목록에 자체 서명된 G4가 있어야 제거 동작을 검증할 수 있습니다. [검증 기록](macos-validation.md)을 참고하세요.

실제 Wine 실행 뒤에는 프리픽스의 `.overwatch-nexon-macos-fix/last-run.log`에서 `loaded`와 `filtered` 기록을 확인할 수 있습니다. `loaded`만 있으면 라이브러리가 로드되었다는 뜻일 뿐입니다. `filtered`가 있어도 게임의 전체 인증서 연결이나 매치 진입이 성공했다는 뜻은 아닙니다. `WINEDEBUG=+crypt,+chain,+wintrust`를 실행 명령 앞에 지정하여 Wine 로그를 별도로 확인하세요. 계정 정보가 포함될 수 있는 전체 로그를 그대로 공개하지 마세요.
