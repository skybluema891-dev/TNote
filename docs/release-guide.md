# TNote リリース手順

Windows版とmacOS版は、同じ`main`と`pubspec.yaml`のバージョンを使用します。OS別のソースやバージョンファイルは作りません。

## 自動生成されるファイル

`v1.3.3`のタグ、または`release/v1.3.3`ブランチをpushすると、GitHub Actionsが次を同じReleaseへ公開します。

- `TNote-Setup-1.3.3.exe`：Windowsインストーラー
- `TNote-Windows-Portable-1.3.3.zip`：Windowsポータブル版
- `TNote-1.3.3.dmg`：macOSインストール用DMG
- `release-info.json`　Windowsの更新情報と両OSの配布物のサイズ・SHA-256
- `appcast.xml`　同じビルド番号のMac用署名付き更新情報

Windowsは `release-info.json`、MacはSparkleの `appcast.xml` から、このReleaseの配布物を取得します。WindowsインストーラーのAppIdとインストール先は既存版を維持するため、上書き更新でもユーザーの`.tnote`、設定、履歴、バックアップを削除しません。

## 新しいバージョンを公開する

1. 作業内容を保存し、`main`へ反映します。
2. `CHANGELOG.md`の先頭へ新しいバージョンと変更内容を追加します。
3. `pubspec.yaml`の`version:`を1回だけ変更します。例：`1.3.3+11`から`1.3.4+12`。
4. `flutter pub get`、`dart analyze`、`flutter analyze`、`flutter test`を実行します。
5. 対象OSでReleaseビルドと主要操作を確認します。
6. 変更をcommitして`main`へpushします。
7. 同じ表示バージョンのタグを作ります。

   ```bash
   git tag v1.3.4
   git push origin main
   git push origin v1.3.4
   ```

8. GitHubのActionsで「Windows・macOS 自動リリース」が成功したことを確認します。
9. GitHub ReleasesでEXE、Windows ZIP、DMG、`release-info.json`、`appcast.xml` が揃っていることを確認します。

Macでは`./scripts/release.sh 1.3.4`、Windowsでは`powershell -ExecutionPolicy Bypass -File .\scripts\release.ps1 1.3.4`でも、バージョン更新、検査、commit、タグ作成をまとめて実行できます。

## macOS更新に使う署名鍵

Sparkle 2.10.1の公式配布物にある `bin/generate_keys --account TNote-Release` で、署名鍵を管理者のMacのログインキーチェーンに一度だけ作成します。公開鍵は `bin/generate_keys --account TNote-Release -p` で確認できます。公開鍵をアプリの `SUPublicEDKey` に固定し、保護した控えを使用者の手元に保存してください。既存公開鍵を変更して配布する場合はSparkleの鍵移行手順が必要です。

GitHubのリポジトリ管理者として正規のCLIにログインし、生成した鍵をActionsのシークレット `SPARKLE_PRIVATE_KEY` に登録します。以下のコマンドをMacのターミナルで実行すると、鍵の値を画面やシェルの履歴に表示せず登録できます。

```bash
(
  set -eu
  umask 077
  key_dir="$(mktemp -d)"
  trap 'rm -f "$key_dir/private"; rmdir "$key_dir"' EXIT
  bin/generate_keys --account TNote-Release -x "$key_dir/private"
  gh secret set SPARKLE_PRIVATE_KEY --repo skybluema891-dev/TNote < "$key_dir/private"
)
```

正式版のCIは配布用DMGを作成してから署名済みの更新情報を生成し、署名・配布URL・バージョン・サイズを検証します。鍵不足や検証失敗の場合、正式Releaseの作成は始まりません。候補ブランチは実機で初回導入できるDMGを作成します。

## macOS署名

Developer ID未設定でも、開発者本人のMacとGitHub Actionsで未公証DMGを生成できます。一般配布でGatekeeperの警告をなくす場合は、次のGitHub Secretsを設定します。

- `MACOS_CERTIFICATE`：Developer ID Application証明書（p12）のBase64
- `MACOS_CERTIFICATE_PASSWORD`：p12のパスワード
- `MACOS_KEYCHAIN_PASSWORD`：Actions内の一時キーチェーン用パスワード
- `MACOS_SIGNING_IDENTITY`：`Developer ID Application: ... (TEAMID)`
- `APPLE_ID`：Apple DeveloperのApple Account
- `APPLE_APP_PASSWORD`：Appleのアプリ用パスワード
- `APPLE_TEAM_ID`：Developer Team ID

Secretsはソース、ログ、設定ファイルへ書きません。3つの公証情報が揃った場合だけ`notarytool`を実行し、成功後にDMGへstapleします。

## ローカルDMG確認

```bash
flutter build macos --release
DMG_NAME=TNote-1.3.4.dmg bash scripts/sign_and_notarize_macos.sh
open artifacts/macos/TNote-1.3.4.dmg
```

DMG内の`TNote.app`を`Applications`ショートカットへドラッグします。署名情報が未設定なら、生成物は開発確認用のad-hoc署名で、公証はされません。

## Windows 1 に保管した鍵で候補版を正式公開する

GitHub Secrets に署名鍵を置かずに運用する場合は、Windows 1 の同じユーザーで以下を実行します。開発機には Python 3.11 以降、pywin32、64 ビット版 Git for Windows（OpenSSL 3 同梱）が必要です。使う鍵は TNote 専用の Ed25519 秘密鍵を PKCS#8 DER にして CurrentUser の DPAPI で暗号化したファイルです。リポジトリと共有フォルダーの外で保管してください。対応する公開鍵をアプリの `SUPublicEDKey` に設定します。

1. バージョン、ビルド番号、変更履歴を更新してコミットし、`candidate/` で始まるブランチへ push します。最終的にタグを付けるコミットで Actions の「Windows・macOS 自動リリース」が成功するまで待ちます。マージによってコミット番号が変わった場合は、マージ後のコミットでも候補ビルドを実行します。
2. GitHub の Actions で、その実行のページにある **Artifacts** から **macos-release** を選び、ZIP をリポジトリの外へ保存します。実行番号はアドレスの `/actions/runs/` の直後にあります。ZIP はそのまま使用します。
3. Windows 1 で同じコミットを開き、下記の3つの値を実際の実行番号、ZIP の場所、DPAPI 鍵の場所に置き換えて実行します。

```powershell
py -3.13 scripts/candidate_release.py prepare --run 123456789 --archive "D:\配布準備\macos-release.zip" --key "D:\署名管理\tnote-release.dpapi" --create-tag
```

このコマンドは候補のリポジトリ、ワークフロー、ブランチ、実行結果、コミット、実行回数、ZIP の SHA-256、アプリのビルド情報を照合してから署名します。タグには DMG、更新フィード、配布元の検証用署名が入ります。`--create-tag` を `--output "D:\配布準備\tag-message.txt"` に変更すると、タグ作成前に公開用の内容をファイルで確認できます。後で同じコミットで `git tag -a v1.5.1 --cleanup=verbatim -F "D:\配布準備\tag-message.txt"` として使えます。

4. ローカルのタグとコミットを確認し、公開する時点でタグを push します。次の例ではバージョンを `1.5.1` としています。

```powershell
git show --no-patch v1.5.1
git push origin v1.5.1
```

5. タグの Actions で Windows 版の再ビルドと「署名済み候補DMGを検証」の成功を確認します。CI は同じ候補 ZIP を GitHub から再取得し、SHA-256、コミット、ビルド番号、DMG とフィードの署名を再検証します。両方が通ると配布物一式が GitHub Releases に公開されます。候補の ZIP が期限切れになった場合は同じ最終コミットで新しく候補ビルドを実行し、公開前に新しい実行番号で署名します。公開済みの版を変更するときは次のバージョンとビルド番号を使用します。

通常のタグは「macOS更新に使う署名鍵」に記載した GitHub Secrets 経路を利用します。いずれの方式でも更新を受け取る Mac に開発用の鍵は不要です。[Sparkle 公式の更新配布手順](https://sparkle-project.org/documentation/publishing/)

GitHub CLI にログイン済みの Windows 1 では、ZIP の取得から署名、送信確認までを次の1コマンドで実行できます。実行番号と鍵のパスを置き換えてください。最後の問いに「はい」と入力するとタグを送信します。ブラウザーから取得した ZIP を使う場合は前述の `--archive` を使用できます。

```powershell
py -3.13 scripts/candidate_release.py prepare --run 123456789 --key "D:\署名管理\tnote-release.dpapi" --create-tag --push-tag
```
