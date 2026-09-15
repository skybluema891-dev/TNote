# macOS統合・実機確認（2026-09-16）

## 共通ソース

GitHub `skybluema891-dev/TNote` の `main`（6b3cf44cc48eaf29f39345daf4d0e244ef2a3849、1.3.2+10）を基点に、`codex/macos-integration` へ既存Mac修正を移植した。Windowsの貼り付け、右クリックメニュー、見出し、更新確認を含む最新版のコードを保持している。OS別にlibを複製せず、このGitリポジトリを両OSの開発元として使う。

元のMac作業フォルダは保存してあり、統合前ソースのtar.gzも別に確保済み。今後の開発はGit管理されているrepositoryフォルダで行い、旧TNote/tnoteへ変更を重ねない。

## 変更

- `DirectoryAccessService`をDartとSwiftに追加。Macだけでユーザー選択フォルダのsecurity-scoped bookmarkを保存・復元する。SQLiteの補助ファイルとロックファイルも選択フォルダ内で使用可能にする。
- 許可済みの親フォルダに含まれる場合も、実際に開いた・保存したサブフォルダを保存先履歴に記憶する。
- 起動時にフォルダ権限を復元してから履歴を読み込む。一時的なアクセス不可でMacの履歴を削除しない。
- App Sandboxとユーザー選択read/writeを維持し、bookmarks.app-scopeとnetwork.clientを追加。全ディスクアクセスやSandbox解除は使用しない。
- Finderのopen URLsイベントを受け取り、Dartの起動完了まで文書を保留する。`.tnote`のUTI・関連付け宣言は既存設定を使用する。
- Command-Qを既存の保存確認へ渡す。通常終了時にロックが残らないようDart終了処理と連携する。
- 同一ファイルの別パス表現を認識する。ロック取得以外のアクセスエラーを「別アプリで開いている」と誤表示しない。
- フォルダ選択の日本語エラーを表示する。Macの更新URLを開く際の例外を捕捉する。
- 配布スクリプトのアプリ再署名時にRelease.entitlementsを明示して権限を維持する。

## 確認結果

- Flutter 3.47.4 / Dart 3.13.3、Xcode 27.0、Apple Silicon。
- `flutter clean`、`flutter pub get`成功。既存のpubspecとlockを維持。
- `flutter test`：39件成功（既存の編集、保存、更新確認テストとMac保存テスト）。
- `dart analyze`：No issues found。
- `flutter analyze`：日本語を含む絶対パスでFlutter SDK側のLSP送信メッセージ長に起因するFormatExceptionが再現。SDKを改変せず、dart analyzeで解析した。GitHub側の通常の英数字パスでは公開済みActionsの解析は成功している。
- `flutter build macos --release`成功。x86_64 / arm64のUniversalアプリ。起動・日本語入力・Windows作成文書の読込と保存を実機で確認。
- 1.3.2の手動更新確認では新しい版なし。確認用に`--build-name=1.3.1 --build-number=9`でビルドすると、起動時・手動の両方で公開1.3.2を検出。「今すぐ更新」から実際のMac用ZIPを取得。確認用の版番号は最終ビルドへ残さない。
- Windowsで作成した形式v1文書のコピーをMacで開き、日本語を追記して形式v2へ保存。元の文書は変更していない。
- 日本語・空白入りの指定フォルダへ`.tnote`とUTF-8テキストを書き出し、ファイル内容を直接照合。
- 再起動後のFinder関連付け、文書読込、書き出し先の正確な復元も実機確認済み。
- 署名整合性検査は成功。ただしローカルはad-hoc署名。

## GitHub Actions・配布

既存の`.github/workflows/release.yml`とWindowsインストーラー処理は変更していない。タグまたは手動起動でWindows/macOSを別runnerで検証し、両方成功後に同じReleaseへ公開する構造。公開1.3.2の両OSビルドは成功済み。今回の統合差分のWindows実機ビルドはこのMacでは未実施。

公開`release-info.json`はversion 1.3.2 / build 10で、Mac用`TNote-macOS-1.3.2.zip`とWindows用インストーラーを正しく指している。DMGは現在の配布仕様に含まれない。既存タグや公開Releaseは書き換えていない。統合後の配布は通常の手順で新バージョンへ更新し、新タグを作る。

## 残る条件

- `security find-identity -v -p codesigning`で有効な証明書は0件。Developer ID署名・notarization・staplingの実行確認には、ユーザーのApple Developerアカウントと証明書が必要。ライセンス同意・ログインは代行しない。
- Xcode → Settings → Accounts → ＋ → Apple Accountで本人がログインし、チームを選択してManage CertificatesからDeveloper ID Applicationを準備する。配布時は既存スクリプトのMACOS_SIGNING_IDENTITYとApple公証用の環境変数、またはGitHub Secretsを設定する。証明書パスワードやアプリ用パスワードをリポジトリへ保存しない。
- 依存パッケージfile_selector_macos / quill_native_bridge_macos由来の非推奨API等のSwift警告がある。今回の機能には影響せず、Windowsへの影響を避けるため依存関係の一括更新はしていない。
- 既存共通更新サービスは通信失敗と「新しい版なし」を同じ結果として返す。オンラインでの実機確認は成功しているが、手動確認で両者を区別する改善は別途検討できる。

## Android・Sparkle

Androidは既存のモバイル用ファイル選択経路を維持している。Mac権限処理はDartの専用サービス経由だけで呼び、Mac以外では何もしない。Androidの保存先はStorage Access FrameworkのURIと永続権限を前提に扱い、Macのbookmarkやパスを流用しない。Android SDKはこのMacでは未設定。

Sparkle 2は後からMacネイティブ側へ導入可能だが、現在は未導入。現在のRelease JSONはSparkle appcastの代わりにはならない。導入時にはappcast/署名、Installer XPC、必要なMachサービス権限、ネストしたヘルパーの署名を追加し、配布スクリプトを拡張する。未使用のSparkle権限は今は追加しない。

参照：
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client
- https://sparkle-project.org/documentation/sandboxing/
