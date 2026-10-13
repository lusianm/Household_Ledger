# 차곡

Android 폴더블·가로 태블릿과 Windows에서 사용하는 개인 가계부입니다. Flutter 3.47.7 / Dart 3.13.5, 한국어, 원화, Asia/Seoul을 기준으로 구현했습니다.

## 실행

GitHub Releases에서 Windows는 **`chagok-windows-setup.exe`**, Android는 **`chagok-android.apk`**를 받아 설치합니다. Windows 설치 EXE는 GitHub 서버에서 만들며 사용자 PC에는 Inno Setup을 설치하지 않습니다. 첫 실행에서는 계좌를 등록합니다. 예시 거래는 앱에 들어 있지 않습니다.

개발 환경에서는 Flutter 3.47.7과 해당 플랫폼 개발 도구를 설치합니다.

```powershell
flutter pub get
flutter run -d windows
# 연결한 Android 기기
flutter run -d <device-id>
```

Windows는 Visual Studio의 C++ 데스크톱 개발 구성 요소가 필요합니다. Android는 Android SDK와 JDK 17 이상이 필요합니다. Windows에서 플러그인 심볼릭 링크 오류가 발생하면 Windows 개발자 모드를 활성화하고 `flutter pub get`을 다시 실행하세요.

## 구현된 기능

- 하단 5개 탭, 시안 블루, 라이트·다크 테마, 창 너비에 따른 배치 변경. 좁은 화면은 단일 열, 넓은 내역 화면은 목록과 상세를 함께 표시합니다. 입력 폼은 화면 크기 변경 시 유지되고 새 거래 초안은 이 기기에 저장됩니다.
- 수입·지출·이동, 은행·현금·적금·카드, 초기 잔액과 잔액 조정, 계좌별 내역, 검색, 복사·수정·삭제·부분 환불, 계좌 보관.
- 대분류 → 선택적 소분류, 분류 아래 메모. 분류 추가·이름 변경·삭제. 거래에는 과거 분류 문자열과 선택적 ID를 함께 보관합니다.
- 월간·연간 집계, 대분류·소분류 도넛 그래프, 월별 수입·지출, 월간 전체 예산.
- 함께 결제한 지출의 사람별 정산, 부분 수령, 수령 취소, 남은 금액을 내 지출로 전환. 수입 입력에서 ‘정산금 받기’를 선택할 수도 있습니다.
- 빌린 돈·빌려준 돈, 부분 상환·추가 원금·취소·기한, 선택적인 실제 계좌 입출금 연결.
- 월간·연간 정기 수입·지출·이동, 적금 이동, 말일·윤년 보정, 시작·종료일, 일시중지, 규칙 변경, 회차 건너뛰기. 앱 실행·복귀·동기화 시 도래한 회차를 생성합니다. OS 백그라운드에서 항상 실행되는 결제 서비스는 아닙니다.
- SQLite 저장, JSON 전체 백업·복원, XLSX·UTF-8 CSV 가져오기/내보내기와 반영 전 미리보기.
- 사용자별 Google 로그인 / 내 Drive 폴더 선택·생성, 오프라인 변경 재전송, 동일 기록 충돌 선택 화면. 실제 계정 연결에는 아래 앱 공통 OAuth 설정이 필요합니다.
- Android 기기 인증 / Windows Hello 앱 접근 잠금. 로컬 DB와 내보낸 파일의 암호화 기능은 포함하지 않습니다.
- 공개 GitHub Releases 새 버전 확인, 다운로드 크기·SHA-256 검증, 설치 전 JSON 자동 백업, Windows 설치 프로그램 / Android 시스템 설치 화면 연결.

## 금액 계산

| 기록 | 계좌 잔액 | 수입·지출 집계 |
| --- | --- | --- |
| 수입 / 지출 | 증가 / 감소 | 반영 |
| 계좌 이동 / 적금 납입 | 양쪽 계좌 반영 | 제외 |
| 정산 포함 지출 | 결제액 전액 차감 | 본인 부담만 지출 |
| 정산금 수령 | 증가 | 수입 제외 |
| 빚 원금 / 상환 | 계좌 연결 시만 반영 | 제외 |
| 부분 환불 | 증가 | 환불일의 지출 차감 |
| 초기 잔액 / 잔액 조정 | 반영 | 제외 |

전체 보유 금액은 현금·은행·적금 계좌의 현재 잔액입니다. 신용카드, 받을 정산금, 빚 장부의 원금을 가감하지 않습니다. 사용 가능 금액은 유동 계좌 중 적금·카드를 제외한 잔액입니다. 카드 구매는 카드 계좌 지출, 카드 대금 납부는 은행 → 카드 이동으로 기록합니다.

## Google Drive 연결 설정

**앱 이용자는 자기 Google 계정으로 로그인하고 동기화 폴더를 직접 선택합니다.** 개발자의 Drive에 자동으로 모으는 구조가 아닙니다. Google 비밀번호·개인 로그인 토큰·선택 폴더 ID·가계부 데이터는 GitHub에 등록하지 않습니다.

아래 OAuth 클라이언트 설정은 ‘차곡이라는 앱의 로그인 기능’을 Google에 등록하는 개발자용 공통 설정입니다. 이 값을 빌드에 포함해도 특정 사용자의 Drive 접근 권한이 생기지 않습니다. 각 사용자가 로그인하고 동의해야 그 계정의 접근 토큰을 받습니다. 사용자는 Google Cloud 프로젝트를 따로 만들 필요가 없습니다.

1. Google Cloud 프로젝트에서 Drive API를 활성화하고 OAuth 동의 화면에 `https://www.googleapis.com/auth/drive` 범위를 설정합니다. 테스트 상태라면 사용할 Google 계정을 테스트 사용자로 등록합니다.
2. Android OAuth 클라이언트: 패키지 `io.chagok.chagok`, 사용할 서명 키의 SHA-1을 등록합니다. 같은 프로젝트에 **웹 애플리케이션 클라이언트**도 만들고 그 ID를 `GOOGLE_ANDROID_SERVER_CLIENT_ID`에 넣습니다. 웹 클라이언트 비밀키는 Android 앱에 넣지 않습니다.
3. Windows OAuth 클라이언트는 **데스크톱 앱** 유형으로 만듭니다. ID와 발급된 설치 앱 클라이언트 설정의 secret을 아래 파일에 넣습니다. 설치 앱의 client secret은 배포 시 비밀로 숨길 수 있는 서버 비밀키가 아닙니다. 인증은 PKCE S256 + state + 127.0.0.1 임시 포트를 사용합니다.
4. `config.example.json`을 `config.local.json`으로 복사해 채웁니다. 이 파일, 토큰, 서명 키는 Git에 포함하지 않습니다.

```powershell
flutter run -d windows --dart-define-from-file=config.local.json
flutter build apk --release --dart-define-from-file=config.local.json
./scripts/package-windows.ps1 -Config config.local.json -PrepareOnly
```

일반 기존 폴더를 앱에서 탐색하고 선택하기 위해 `drive` 권한을 요청합니다. Google의 권한 자체는 전체 Drive 파일 접근 범위이며, 폴더 하나로 제한된 OAuth 권한이라고 표시하지 않습니다. 앱은 폴더 목록·권한을 확인하고, 가계부 파일 조회와 업로드는 선택한 폴더 ID 및 차곡 파일 표시로 제한합니다. 일반 문서를 수정·삭제하거나 다른 폴더로 자동 전환하지 않습니다. 공개 서비스로 배포할 때는 이 제한된 범위(restricted scope)에 대한 Google 검증 요건을 확인해야 합니다. 향후 Google Picker를 연동하면 `drive.file` 권한으로 접근 범위를 줄이는 별도 전환을 검토할 수 있습니다.

앱의 **더보기 → 설정 → Google 로그인 · 폴더 선택**에서 로그인한 뒤 내 Drive의 기존 폴더를 열어 선택하거나 새 폴더를 만듭니다. 공유 드라이브와 다른 사람이 소유한 폴더는 선택 대상에서 제외합니다. 첫 연결에서 계정·폴더·가계부 전환 여부를 확인한 후 동기화를 시작합니다. 다른 기기에서도 같은 계정과 같은 폴더를 선택하고, 그 안의 기존 가계부를 엽니다. 해당 기기의 장부는 자동 백업 후 교체하며 서로 다른 가계부를 임의로 합치지 않습니다.

계정·폴더 변경은 **연결 해제 / 변경** 후 다시 연결합니다. 연결 해제는 기기와 Drive의 기존 기록을 삭제하지 않습니다. 새 위치에 연결하면 이전 위치의 업로드 완료 표시를 초기화해 전체 이력을 다시 보냅니다. 예상한 계정과 실제 로그인 계정이 다르거나 폴더가 삭제·접근 불가 상태이면 동기화를 중단합니다.

Android 인증은 Google Sign-In, Windows 갱신 토큰은 OS 보안 저장소에 보관합니다. 계정·선택 폴더 정보는 해당 기기의 `local_settings`에 저장하며 토큰·기기 인증 설정과 함께 JSON 백업이나 Drive 장부에 포함하지 않습니다. JSON 파일 복원은 별도의 새 가계부로 복원하고 Drive 연결을 해제합니다.

이전 앱 전용 숨김 폴더 연결은 자동으로 재개하지 않습니다. 먼저 이전 버전에서 최신 기록을 동기화하거나 JSON 백업을 확보한 뒤 새 버전에서 로그인·폴더를 다시 선택하면 현재 기기의 기록을 새 위치에 업로드합니다. 예전 숨김 폴더에만 남아 있는 기록을 새 버전에서 자동으로 가져오지는 않습니다.

공식 문서: [Drive 권한 범위](https://developers.google.com/workspace/drive/api/guides/api-specific-auth), [설치 앱 OAuth](https://developers.google.com/identity/protocols/oauth2/native-app), [Android 배포](https://docs.flutter.dev/deployment/android).

## 저장 구조와 동기화

`lib/data/ledger_store.dart`의 `schema`가 실제 SQLite 테이블 정의입니다. DB는 `path_provider`의 application support 디렉터리에 저장합니다.

| 데이터 | 테이블 |
| --- | --- |
| 계좌·분류 | `accounts`, `categories` |
| 거래·계좌 증감·분류 배분 | `transactions`, `postings`, `transaction_allocations` |
| 정산 | `people`, `settlements`, `settlement_shares`, `settlement_receipts` |
| 빚 | `debts`, `debt_events` |
| 정기 내역 | `recurring_rules`, `recurring_rule_revisions`, `recurring_occurrences` |
| 예산 | `budgets` |
| 원본 변경 이력·동기화 | `change_events`, `sync_deliveries`, `aggregates` |
| 기기별 설정·초안·로그인 계정 식별자·선택 Drive 폴더 | `local_settings` |

불필요한 코드 생성 계층을 줄이기 위해 SQLite 직접 접근을 사용합니다. 금액 계산은 `LedgerService`에 모으고 화면에서 별도의 금액 장부를 만들지 않습니다.

동기화 원본은 **거래와 연결된 정산 수령·환불을 한 묶음으로 만든 불변 버전**입니다. 빚은 원금·상환을 한 묶음, 계좌는 초기 잔액을 한 묶음으로 변경합니다. 각 버전에는 `schema`, `ledger`, `kind`, `entity`, `parents`, `data`, `device`, `created_at`, 내용 해시 `id`가 있습니다. 설정과 거래 모두 JSON이며, 관계형 테이블은 검증된 원본으로부터 SQLite 트랜잭션 안에서 재구성합니다.

기기 시간으로 최신 버전을 선택하지 않습니다. 부모 버전 관계로 변경 순서를 판별하고, 동시 수정은 공통 이전 버전을 유지하며 사용자가 선택하게 합니다. 연결 계좌가 미수신 상태인 금전 기록은 부분 반영하지 않습니다. 삭제는 삭제 표시를 남겨 다른 기기에서 되살아나지 않게 합니다. 정기 회차는 가계부·규칙·예정일의 고유 키로 중복을 막습니다. 백업 복원 후에도 기존 규칙·날짜를 확인합니다.

Drive에는 장부 안내 파일과 변경별 JSON 파일을 업로드합니다. 업로드 확인 전에 전송 완료로 표시하지 않으며, 응답 유실로 같은 파일이 두 번 올라가도 내용 ID로 중복 적용하지 않습니다. 이미 아는 변경은 다시 다운로드하지 않습니다. 현재 버전은 안전한 이력 보존을 우선해 이력 압축/정리는 하지 않습니다. 데이터가 장기간 누적되면 초기 동기화 파일 수와 로컬 재구성 비용을 측정해 개선해야 합니다.

## 엑셀 가져오기

`내역` 시트가 편집·가져오기 대상입니다. 열은 다음과 같습니다.

```text
거래ID | 기준버전 | 날짜 | 유형 | 금액 | 계좌 | 도착계좌 | 대분류 | 소분류 | 메모
```

필수 열은 날짜·유형·금액·계좌이며 수입/지출에는 대분류, 이동에는 도착계좌가 필요합니다. 날짜는 YYYY-MM-DD, 유형은 수입/지출/이동, 금액은 정수입니다. 계좌는 앱에 먼저 등록하고 이름을 일치시키세요. 미등록 분류는 문자열로 보존하며 자유 입력 UI로 바꾸지 않습니다.

새 거래는 거래ID·기준버전을 비워도 됩니다. 기존 내역을 수정할 때는 내보낸 거래ID·기준버전을 보존해야 합니다. 앱에서 그 사이 변경되었다면 덮어쓰기를 거부합니다. 중복 의심 행은 기본 제외하며 미리보기에서 선택할 수 있습니다. 가져오는 셀의 수식은 실행하지 않고 오류로 표시합니다. CSV 내보내기는 수식처럼 해석될 수 있는 문자열 앞에 `'`를 붙이므로 원문 왕복에는 XLSX를 권장합니다.

정산·환불이 연결된 복합 거래와 빚은 일반 거래로 다시 가져오지 않습니다. XLSX의 `전체 기록`, `정산`, `빚`, `정기내역` 시트는 조회용입니다. 모든 관계·설정·삭제 이력 복원은 JSON 전체 백업을 사용하세요. 가져오기/복원 파일은 20MB까지 지원합니다.

## 테스트와 패키징

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
./scripts/package-windows.ps1 -PrepareOnly
```

`-PrepareOnly`는 로컬에서 Windows 실행 번들을 빌드·확인하는 옵션입니다. 설치 EXE는 `.github/workflows/verify.yml`의 Windows 작업이 GitHub `windows-2022` 실행 환경에 준비된 Inno Setup 6으로 생성합니다. 실행 파일·Flutter DLL·플러그인·데이터·Visual C++ 런타임을 설치 파일 안에 포함합니다. Windows ZIP 배포는 생성하지 않습니다. 설치 프로그램 소스는 `packaging/windows.iss`이며 사용자별 디렉터리에 설치합니다. Windows 코드 서명은 아직 구성하지 않았습니다.

Android 테스트용은 `flutter build apk --debug`입니다. 배포용은 본인의 릴리스 키를 만들고 `android/key.properties.example`을 참고해 `android/key.properties`를 채운 후 `flutter build apk --release`를 사용합니다. 키가 없으면 릴리스 빌드를 명시적으로 중단하며 디버그 키를 배포 키로 사용하지 않습니다. 같은 앱을 업데이트하려면 같은 서명 키를 계속 사용해야 합니다.

## GitHub 배포 절차

1. 코드를 GitHub 저장소에 올립니다. 일반 브랜치 push / PR에서는 검사·테스트 후 Windows 설치 EXE와 Android 테스트 APK를 Actions 아티팩트로 만듭니다. Actions의 아티팩트 다운로드가 ZIP으로 제공되는 것은 GitHub의 전달 방식이며, 내부 EXE가 실제 설치 파일입니다. 테스트 빌드에는 OAuth 값이 없어 Drive 로그인은 사용할 수 없습니다.
2. 저장소의 **Settings → Secrets and variables → Actions**에 아래 Repository secrets를 등록합니다. Android 서명 키는 별도로 안전하게 백업하고 이후 버전에서도 같은 키를 사용합니다.

| Secret | 값 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | 본인 릴리스 keystore 파일의 Base64 문자열 |
| `ANDROID_STORE_PASSWORD` | keystore 비밀번호 |
| `ANDROID_KEY_PASSWORD` | 서명 키 비밀번호 |
| `ANDROID_KEY_ALIAS` | 서명 키 alias |
| `GOOGLE_ANDROID_SERVER_CLIENT_ID` | 앱 공통 Google 웹 클라이언트 ID. 개인 Drive 계정 정보가 아님 |
| `GOOGLE_DESKTOP_CLIENT_ID` | 앱 공통 Google 데스크톱 클라이언트 ID |
| `GOOGLE_DESKTOP_CLIENT_SECRET` | 같은 데스크톱 클라이언트의 설정값. 사용자 비밀번호·로그인 토큰이 아님 |

3. `pubspec.yaml`의 `version`과 정확히 같은 태그를 push합니다. 현재 첫 버전은 `0.1.0+1`이므로 아래와 같습니다. 다음 배포는 예를 들어 `0.1.1+2` / `v0.1.1+2`입니다. `+` 뒤 빌드 번호는 매번 증가시킵니다.

```powershell
git tag v0.1.0+1
git push origin v0.1.0+1
```

4. 검증·Windows 설치 EXE·서명된 Android APK가 모두 성공하면 **Release 초안**에 두 설치 파일과 SHA-256 파일을 첨부합니다. GitHub Releases에서 설명과 파일을 확인한 뒤 **Publish release**로 공개합니다. 이미 공개한 같은 태그의 파일은 CI에서 덮어쓰지 않습니다.
5. 이후 사용자는 Releases의 설치 파일 링크에서 직접 다운로드합니다. 앱에는 빌드한 저장소 이름을 `UPDATE_REPOSITORY=소유자/저장소`로 자동 주입합니다. 자동 업데이트 확인은 **공개 저장소**를 전제로 하며 비공개 저장소 접근용 토큰을 앱에 넣지 않습니다. 로컬 릴리스 빌드에서는 `config.local.json`에 이 값을 지정할 수 있습니다.

실제 저장소 push와 GitHub Actions 실행·Release 게시는 아직 수행하지 않았습니다. 설치 EXE 생성 자체는 GitHub에서 확인해야 합니다.

## 앱 업데이트와 데이터 보존

릴리스 앱은 시작·복귀 시 하루 한 번 최신 공개 정식 Release를 확인합니다. 설정에서 자동 확인을 끄거나 수동 확인할 수 있고, 새 버전 안내는 ‘나중에’로 숨길 수 있습니다. 초안·시험판·낮은 버전은 제안하지 않으며, 디버그 APK는 자동 업데이트를 사용하지 않습니다.

사용자가 업데이트를 선택하면 파일 크기와 GitHub 배포 메타데이터의 SHA-256을 확인하고, application support 디렉터리의 `backups/before-update-*.json`에 장부를 백업합니다. 검증·백업 실패 시 설치를 진행하지 않습니다. Windows에서는 설치 프로그램을 열고 앱을 종료하며, 설치 완료 후 다시 실행할 수 있습니다. Android에서는 차곡에 대한 ‘이 출처 허용’ 설정과 시스템 설치 승인이 필요할 수 있습니다. 허용 후 앱으로 돌아와 설치를 다시 누르면 검증된 파일을 재사용합니다.

설치 파일과 SQLite 저장 폴더를 분리하고 Windows 설치 식별자를 고정하여 같은 위치에 새 버전을 설치합니다. 앱 삭제 후 재설치가 업데이트 절차는 아닙니다. Android는 같은 패키지와 서명 키를 유지해야 합니다. 기존 디버그 APK에서 정식 서명 APK로 전환할 때는 먼저 JSON 전체 백업을 내보내세요. 서로 서명이 다르면 덮어 설치할 수 없고 기존 앱 삭제 시 데이터가 지워집니다.

자동 백업에는 가계부 기록이 포함되며 OAuth 토큰·잠금 등 기기별 설정은 포함하지 않습니다. SHA-256은 다운로드 무결성 확인이며 Windows 실행 파일 코드 서명을 대체하지 않습니다. 실제 설치 → 다음 버전 업데이트 → 기존 장부 보존은 GitHub에서 생성한 두 버전으로 추가 확인해야 합니다.

## 검증 범위와 후속 확인

로컬 계산·저장·엑셀 왕복·동기화 엔진의 재전송/충돌과 344/690/1280 논리 픽셀 화면을 자동 테스트합니다. 화면 스크린샷의 예시 금액은 테스트 데이터입니다.

실제 Google 계정의 OAuth/Drive 왕복, Fold 8 실물의 접힘·펼침 및 기기 인증은 클라이언트 설정과 기기 연결 후 확인해야 합니다. 프로젝트 내부에 Android SDK/JDK를 준비하여 ARM64 테스트 APK 빌드는 통과했습니다. 실물 기기에 설치·실행한 결과는 아직 확인하지 않았고 CI도 아직 실행되지 않았습니다.

초기 기획 중 사용자 지정 엑셀 열 매핑, 카테고리 수동 정렬, 기존 입금과 정산 연결, 계좌별 리포트 필터·그래프에서 원거래까지 이동, 분류별 예산은 후속 항목입니다. 현재 버전은 고정 열 가져오기·정산 전용 입금·월간 전체 예산을 제공합니다. 앱 데이터 암호화와 동기화 이력 압축은 별도 설계가 필요합니다.

