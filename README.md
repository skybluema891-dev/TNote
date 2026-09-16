# TNote 1.3.3

macOSの統合内容・実機検証・配布条件は[macOS統合記録](docs/macos-integration.md)を参照してください。

TNoteは、上段の複数タイトルと各タイトル内の下段タブを、まとめて1ファイルの`.tnote`として保存するFlutter製エディターです。この`tnote` FlutterプロジェクトをWindows、macOS、iPhone共通の本番アプリ開発元として使います。Windows向けには開発環境不要の正式なリリース版とインストーラーを作成します。

## 1.3.0の変更

- 左上の見出しを、選択中の上段タイトルではなく保存中の`.tnote`ファイル名へ変更。
- 上段タイトルを17ポイント・太字寄りにして見やすさを改善。
- 本文の右クリックメニューへ「コピー」「切り取り」「貼り付け」「すべて選択」を追加。「貼り付け」ボタンと`Ctrl+V`／`Command+V`からもクリップボードの文字を貼り付け可能。
- Gitタグを起点にWindows・macOSを別々のGitHub Actions runnerで検査・ビルドし、両方成功した場合だけGitHub Releaseへ同時公開する仕組みを追加。
- 共通の`release-info.json`、毎回の起動時確認、手動確認、スキップ、Windowsインストーラー更新、macOS配布ページ導線を追加。
- 設定の「TNoteについて」に表示用バージョンとビルド番号を追加。

## 1.2.0の変更

- 上段の「仕事」「要領書」「NC旋盤」などを、各タイトル内の下段タブと一緒に1つの`.tnote`ファイルへ保存する形式へ変更。
- 保存した`.tnote`を開くと、上段タイトルの名前・順番・本文・下段タブがまとめて復元されるように変更。
- 従来形式の`.tnote`も開くことができ、次回保存時に複数タイトル対応形式へ更新。
- ウィンドウの×を押した場合は文書選択画面へ戻さず、そのままアプリを終了。未保存時の確認はファイル全体に対して一度だけ表示。
- ファイルメニューの保存項目を「上書き保存」と「ファイルに保存」の2項目へ整理。

## 1.1.1の変更

- フォント選択欄と設定の「標準フォント」を削除し、Windows、macOS、iPhoneそれぞれのシステム標準フォントへ統一。既存文書に残っている個別フォント指定も読み込み時に除去。
- 保存直後に本文から同一内容の通知が届いても、文書を未保存状態へ戻さないよう修正。
- 保存済みで変更がない`.tnote`は、ウィンドウの×を押したときに確認を表示せず終了。
- 起動時の「前回の未保存データを復元しますか？」を廃止。古い一時下書きは確認なしで破棄。
- 保存と上書き保存を`.tnote`ファイル全体の処理として明記し、タブごとの保存確認を行わない仕様へ統一。
- 設定画面と上部の「取扱説明」ボタンへ、保存、タブ、書式、終了、OneDriveの簡単な説明を追加。表示バージョンは`pubspec.yaml`のアプリバージョンと連動。

## 1.1.0の変更（第4・第5段階）

- フォント欄を追加し、WindowsまたはmacOSに入っているフォントを検索して選べる一覧を追加。
- 文字サイズはExcelで一般的な一覧から選べるほか、1～400の任意の数値を直接入力可能。
- 文字色と背景色を、Excel風のテーマ色60色、標準色10色、任意の色コードから選べるパレットへ変更。ボタンも文字色の下線と塗りつぶし色が分かる表示へ変更。
- 下段タブの×を削除。削除はタブを右クリックまたは長押しし、「削除」を選んだ場合だけ実行。
- macOSのFinderとiPhoneのファイルアプリで`.tnote`を認識する文書形式、開く処理、ユーザー選択ファイルへの読み書き権限を追加。
- iPhoneでファイルアプリまたはOneDriveから開く、新規保存・別名保存、TXT/Markdown書き出し、共有シートを追加。
- WindowsとMacBookがOneDrive上の同じ`.tnote`ファイルを開いた場合、後から開く側へ「読み取り専用で開きますか？」と日本語で確認。「はい」で読み取り専用、「いいえ」でそのファイルを閉じる仕様を追加。
- 読み取り専用側では本文・タブの変更と上書き保存を無効化。先に開いた側が閉じると共有ロックを解除し、異常終了したロックは2分後に古いものとして扱う。

## 1.0.3の変更

- 上段の文書タイトルを右クリックまたは長押しすると、「名前を変更」「複製」「削除」を選べるように変更。
- 「削除」は開いている一覧から文書を閉じる操作とし、保存済みの`.tnote`ファイルは削除しない安全な仕様に変更。
- 上段の文書タイトルと下段のメモタブを、タイトル部分からドラッグして並べ替えられるように変更。
- 文字サイズを、Excelで一般的な8、9、10、11、12、14、16、18、20、22、24、26、28、36、48、72へ拡張。
- 文字色と背景色を、基本色・濃色・淡色を含む24色の共通パレットへ拡張。太字・斜体・下線は選択した文字へ適用。
- 文書につけた名前を`.tnote`内へ保存し、別のPCで開いても保持するように変更。

## 1.0.2の修正

- 本文の文字色を明示し、入力済みの文字が見えない不具合を修正。
- 未保存文書を終了時に閉じる際の一覧変更による例外を修正。
- 保存・起動・操作失敗時の案内を日本語に統一。
- 日本語の連続入力、文字色、複数文書の終了を含む24件のテストと静的解析に合格。
- Windowsリリース版の実画面で日本語の変換・確定と保存を確認。

## 1.0.1で行った変更（入力表示の問題は1.0.2で修正）

- 本文へ文字を入力できない問題を修正。
- 本文をクリック・タップすると、必ず編集欄へ入力位置が移るよう改善。
- 日本語入力を実際に送る自動テストを追加。
- アプリの対応言語を日本語だけに限定。
- 書式ツール、色選択、書き出し項目などの表示を日本語へ統一。

## 配置とデータの分離

| 種類 | 場所・方針 |
|---|---|
| ソース | 開発者が保存したTNoteのFlutterプロジェクトフォルダ |
| 一時ビルド | ソース配下の`build\windows\x64\runner\Release` |
| インストール済みアプリ | 標準では`%LOCALAPPDATA%\Programs\TNote`。インストール時に変更可能 |
| ユーザーデータ | 初回保存・「ファイルに保存」でユーザーが選んだ任意のフォルダ |
| 設定・履歴・復旧・バックアップ | 各OSのユーザー別アプリデータ領域 |

アプリ本体と`.tnote`データは独立しています。OneDrive、ドキュメント、外付けドライブなどを保存先に選べます。アプリの更新・再インストール・アンインストールでは、これらの`.tnote`を削除しません。

## Windows 11の別PCへ導入する

別PCにFlutter SDK、Dart、Visual Studio、Visual Studio Code、Gitは不要です。必要なのは`TNoteSetup.exe`と、利用する`.tnote`だけです。

1. USBメモリ、OneDrive、LAN共有などで`TNoteSetup.exe`を別PCへコピーします。インストーラーだけをコピーすればよく、開発プロジェクトは不要です。
2. コピーした`TNoteSetup.exe`をダブルクリックします。
3. 「次へ」→インストール先の確認→必要なら「デスクトップにショートカットを作成する」を選択→「インストール」→「完了」と進みます。WindowsスタートメニューにもTNoteが登録されます。
4. 発行元のコード署名をまだ付けていない初期版のため、Windowsの警告が表示される場合があります。配布元とREADME記載のSHA-256が一致することを確認し、「詳細情報」→「実行」を選びます。不明な入手元のファイルは実行しないでください。
5. OneDriveを使う場合は、WindowsのOneDriveアプリを開き、Microsoftアカウントでサインインします。エクスプローラーにOneDriveフォルダが表示され、対象ファイルの同期が完了してから開きます。
6. TNoteの「開く」からOneDrive上の`.tnote`を選ぶか、エクスプローラーで`.tnote`をダブルクリックします。インストーラーが`.tnote`をTNoteへ関連付けます。
7. 編集後は保存し、TNoteを閉じてからOneDriveの同期完了を確認します。別PCでも同期完了後に同じファイルを開きます。
8. アンインストールは「設定」→「アプリ」→「インストールされているアプリ」→「TNote」→「アンインストール」です。OneDriveや任意フォルダの`.tnote`、ユーザー別の設定・履歴・バックアップは削除しません。

関連付けが反映されない場合は、Windowsの「設定」→「アプリ」→「既定のアプリ」で`.tnote`を検索し、TNoteを選びます。

## Windows配布形式

`flutter build windows --release`が生成するReleaseフォルダ全体をインストーラーへ収録します。`TNote.exe`だけでなく、Flutterエンジン、プラグインDLL、`data`フォルダを含むため、exeだけをコピーする方式ではありません。Microsoft Visual C++ x64 Runtimeもインストーラーに収録し、別PCで確認・導入します。

初期版にはInno Setupを採用しました。通常の「次へ→インストール→完了」画面、ユーザー別のWindowsアプリ領域への配置、スタートメニュー、任意のデスクトップショートカット、設定画面からのアンインストール、拡張子関連付け、同じAppIdによる上書き更新を1つの`TNoteSetup.exe`で扱えるためです。TNote本体の導入は管理者権限を要求しません。Visual C++ Runtimeが未導入のPCだけは、Microsoftのランタイム導入時にWindowsの管理者確認が表示される場合があります。

インストーラー定義は`installer\TNote.iss`、生成スクリプトは`tools\build-installer.ps1`です。安定したAppIdを維持するため、新しい`TNoteSetup.exe`を実行すると既存版を更新できます。更新時も`.tnote`、最近使ったファイル、設定、バックアップを保持します。

## 第2・第3段階で追加した機能

- Flutter QuillのDelta JSONによるリッチテキスト。太字、斜体、下線、文字色、背景色、配置、見出し、番号・箇条書き、Undo/Redo。
- 既存のplain-v1文書を読み込み、新規保存時にdelta-v1へ移行。
- タブの複製、ドラッグ並べ替え、現在タブ・全タブ検索。
- 最近使ったファイル、お気に入り、テーマ、自動保存間隔、標準文字サイズ、バックアップ世代数の設定。
- 既存ファイルを上書きする直前の世代バックアップと、バックアップから未保存文書として復元する画面。
- 現在タブ・全タブのTXT/Markdown書き出し。
- 「新しいウィンドウで開く」。各ウィンドウを独立プロセスにし、1ウィンドウで1文書を扱える構成。
- OSレベルの排他ロックによる別プロセス二重編集の抑止。
- 外部変更の定期検出。「再読み込み」または「ファイルに保存」を選択可能。
- 起動引数の`.tnote`を直接開く処理と、Windowsインストーラーのファイル関連付け。
- 終了時の保存待ちを一度にまとめ、未保存・エラー文書だけ確認する処理へ変更。固定待ちは最短120ms。

初回保存と「ファイルに保存」はWindows標準の保存ダイアログを使い、保存先を固定しません。既存の別ファイルを誤って上書きする保存は拒否します。

## OneDrive運用と同じファイルの同時起動

OneDrive同期フォルダは通常のローカルパスとして開閉します。ファイルがオンライン専用の場合は、開く前にダウンロードが完了するまで待ってください。

TNoteは、開いている`.tnote`の隣に一時的な共有ロック情報を作り、OneDriveを通じて同じ保存先ファイルを識別します。Windows側で先に開いている同じファイルをMacBook側から開いた場合、またはその逆の場合は「読み取り専用で開きますか？」と表示します。「はい」なら閲覧だけができ、編集と上書き保存はできません。「いいえ」なら対象ファイルを開かず、そのまま閉じます。内容が同じでも保存先が異なる別ファイルには、この制限はかかりません。

通常は先に開いた端末で保存してTNoteを閉じ、OneDriveの同期完了後にもう一方の端末で開いてください。OneDriveの同期には時間差があるため、同じファイルをほぼ同時に開いた場合はロック情報の到着前に両方が開く可能性があります。その場合も外部変更検出が上書きを停止します。

推奨確認手順は「既存`.tnote`を開く→編集→保存→終了→OneDrive同期完了→再起動→同じ`.tnote`を開く」です。

リリース操作の要点は[リリース手順](docs/release-guide.md)にもまとめています。

## バージョンと更新

バージョンの正本は`pubspec.yaml`の`version: 1.3.3+11`です。表示用バージョンは`1.3.3`、`+`以降はビルド番号です。Windowsの実行ファイルとインストーラー、macOSアプリとDMG、更新情報はビルド時にこの値を使用します。変更する場所は`pubspec.yaml`の1か所です。

Windows版とMac版は共通の公開情報を使って更新を確認します。Windows版はSHA-256検証済みの`TNote-Setup-バージョン.exe`を起動して同じインストール先を更新し、Mac版は`TNote-バージョン.dmg`をブラウザーで開きます。

## ポータブル版

Releaseフォルダは、`TNote.exe`、DLL、`data`を含むフォルダ全体を保持すればポータブル構成にできます。配布物には`TNote-Portable-1.3.0.zip`も用意します。別PCではフォルダ全体を展開し、必要なら同梱のWindows実行環境を先に導入します。正式な配布・関連付け・更新には`TNoteSetup.exe`を使ってください。

## 開発とビルド

開発PCでPowerShellを開きます。

```powershell
Set-Location 'TNoteプロジェクトを保存したフォルダ'
flutter pub get
flutter analyze
flutter test
flutter build windows --release
.\tools\build-installer.ps1
```

`tools\build-installer.ps1`は`pubspec.yaml`からバージョンを読み、Visual Studioに含まれるx64 Visual C++ Runtimeを収集して、Inno Setupで`artifacts\installer\TNoteSetup.exe`を作成しSHA-256を表示します。GitHub Actionsが公開時に`TNote-Setup-バージョン.exe`へ変更します。

## データ形式と保護

各`.tnote`は独立したSQLiteデータベースです。全ファイルの本文を共通DBへ集約しません。

- `PRAGMA application_id = 0x544e4f54`、`user_version = 1`。
- `document_meta`に文書ID、選択タブ、本文形式、更新時刻を保存。
- `tabs`にタブ名、順序、Delta JSON、検索・書き出し用プレーンテキストを保存。
- SQLはバインド変数を使い、Unicode、日本語ファイル名、改行を保持。
- 保存はバックグラウンドIsolateの1トランザクションで実施。
- 新規ファイルは同じ保存先フォルダで一時DBを完成させてから置換。
- 保存前のSHA-256比較、プロセス間ロック、外部変更検知、復旧下書き、世代バックアップを併用。

## macOSで使う（第4段階）

macOS版はFinderで`.tnote`をダブルクリックして開く文書形式、ユーザーが選んだファイルへの読み書き権限、Command+SなどのMac用ショートカット、複数ウィンドウ起動を設定しています。ビルドにはmacOSとXcodeが必要です。

```bash
flutter pub get
flutter analyze
flutter test
flutter build macos --release
```

配布前にApple Developerの署名と公証を行い、Finderから開く、OneDrive上で編集・保存する、複数ウィンドウ、Windows版との相互読込をMac実機で確認してください。

## iPhoneで使う（第5段階）

iPhone版はファイルアプリの「このiPhone内」と、ファイルアプリに表示されたOneDriveから`.tnote`を選択できます。新規保存と別名保存も保存先を選び、TXT/Markdownの書き出しとiOS共有シートに対応します。OneDriveアプリをインストールしてサインインし、ファイルアプリの「ブラウズ」→右上メニュー→「編集」でOneDriveを有効にしてください。

Xcodeで実機またはシミュレーターを選び、次を実行します。

```bash
flutter pub get
flutter analyze
flutter test
flutter build ios --release
```

WindowsではApple向けバイナリを作成できないため、今回のWindows環境では共通コードの解析・テストとWindows版の回帰確認までを行います。macOS・iPhoneの署名、Finder／ファイルアプリ、OneDrive File Provider、共有シートはmacOSのXcode環境と実機で最終確認してください。

検証結果は`docs\stage4-stage5-validation.md`を参照してください。

## GitHubでWindows・macOSを自動公開する

このプロジェクトは`.github/workflows/release.yml`を使用します。`v1.3.0`のようなタグをpushすると、Windows runnerとmacOS runnerが別々に起動します。初回確認や再実行では、GitHubの「Actions」から手動実行することもできます。両方で依存関係取得、静的解析、全テスト、Releaseビルドを行います。Windows側はInno SetupインストーラーとポータブルZIP、macOS側は`TNote.app`と`Applications`ショートカットを含むDMGを作成します。

正式なGitHub Releaseを作る処理はWindowsとmacOSの両ジョブを待ちます。片方が失敗した場合はReleaseを公開しないため、同じバージョンで片方のOSだけが公開される状態を防ぎます。成功時のReleaseには次を添付します。

- `TNote-Setup-1.3.3.exe`
- `TNote-Windows-Portable-1.3.3.zip`
- `TNote-1.3.3.dmg`
- `release-info.json`

### 初回だけ行うGitHub設定

1. GitHubへサインインし、右上の「New repository」から`TNote`というリポジトリを作ります。一般配布では更新情報をアプリが直接取得できるようPublicを選びます。
2. このフォルダで`git init -b main`を実行します。
3. `git add .`、`git commit -m "TNote 初回登録"`を実行します。
4. GitHubの画面に表示されたURLを使い、`git remote add origin https://github.com/ユーザー名/TNote.git`を実行します。
5. `git push -u origin main`を実行します。
6. GitHubの「Actions」を開き、「Windows・macOS 自動リリース」が表示されることを確認します。

このプロジェクトの更新確認先は`https://github.com/skybluema891-dev/TNote/releases/latest/download/release-info.json`です。別の所有者名やリポジトリ名を使う場合は、ビルド時に`--dart-define=TNOTE_RELEASE_INFO_URL=URL`を指定するか、`lib/services/update_service.dart`の既定URLを変更します。

### 通常のリリース手順

1. 新しい機能を実装します。
2. Windowsで`flutter analyze`と`flutter test`を実行します。
3. 必要に応じてMacでも実画面を確認します。
4. `CHANGELOG.md`へ新バージョンの変更内容を追加します。
5. `pubspec.yaml`の表示用バージョンとビルド番号を上げます。
6. 変更をGitHubの`main`へpushします。
7. `git tag v1.3.0`、`git push origin v1.3.0`のようにタグを作成してpushします。
8. GitHubの「Actions」でWindowsとmacOSの処理を確認します。
9. 両方成功するとGitHub Releasesへ同じバージョンの成果物が自動公開されます。
10. Windows版とMac版は共通の`release-info.json`を読み、次回の更新確認で通知します。

Windowsでは`powershell -ExecutionPolicy Bypass -File .\scripts\release.ps1 1.3.1`、Macでは`./scripts/release.sh 1.3.1`でもバージョン更新・検査・コミット・タグ作成をまとめて実行できます。スクリプトはpush前に「はい／いいえ」で確認し、「はい」を選んだ場合だけGitHubへ送信します。

### macOS署名と公証のSecrets

Appleの情報はソースやworkflowへ直接書かず、GitHubリポジトリの「Settings」→「Secrets and variables」→「Actions」へ登録します。

| Secret名 | 内容 |
|---|---|
| `MACOS_CERTIFICATE` | Developer ID Application証明書を含むP12をBase64化した値 |
| `MACOS_CERTIFICATE_PASSWORD` | P12のパスワード |
| `MACOS_KEYCHAIN_PASSWORD` | Actions内の一時キーチェーン用パスワード |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: ...`形式の署名ID |
| `APPLE_ID` | 公証に使うApple ID |
| `APPLE_APP_PASSWORD` | Apple IDのアプリ用パスワード |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

これらが未登録でも、macOS runnerは未署名の`TNote.app`をZIP化して成果物を作ります。すべて設定すると`codesign`、`notarytool`、`stapler`を順に実行します。Secretsの値はログへ直接出力しません。

## アプリの更新確認

Windows版とMac版は起動するたびに共通の`release-info.json`を確認します。新しい版がある場合は「今すぐ更新」「後で」「このバージョンをスキップ」を表示します。「後で」を選ぶと次回起動時に再び表示し、「このバージョンをスキップ」を選ぶと次の版が公開されるまで表示しません。設定の「アップデートを確認」からも随時確認できます。ネット未接続やGitHub側の一時障害では確認を静かに終了し、編集機能は通常どおり起動します。

Windowsの「今すぐ更新」は、作業中のファイルを先に保存し、インストーラーを一時フォルダへダウンロードします。`release-info.json`に記録されたSHA-256と一致した場合だけインストーラーを起動してTNoteを終了します。失敗時は既存アプリを変更しません。macOSでは同じReleaseのDMGをブラウザーで開きます。

`.tnote`はSQLiteの`PRAGMA user_version`にスキーマ番号を持ち、文書メタデータにも`schema_version`と`format_version`を保存します。既存ファイルを移行する前にはバックアップを作り、設定、最近使ったファイル、お気に入り、OneDrive上のデータはアプリ本体とは別の場所に保持します。




