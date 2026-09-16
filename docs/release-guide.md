# TNote リリース手順

Windows版とmacOS版は、同じ`main`と`pubspec.yaml`のバージョンを使用します。OS別のソースやバージョンファイルは作りません。

## 自動生成されるファイル

`v1.3.3`のタグをpushすると、GitHub Actionsが次を同じReleaseへ公開します。

- `TNote-Setup-1.3.3.exe`：Windowsインストーラー
- `TNote-Windows-Portable-1.3.3.zip`：Windowsポータブル版
- `TNote-1.3.3.dmg`：macOSインストール用DMG
- `release-info.json`：両OSが参照する更新情報

WindowsはEXE、macOSはDMGのURLを`release-info.json`から選びます。WindowsインストーラーのAppIdとインストール先は既存版を維持するため、上書き更新でもユーザーの`.tnote`、設定、履歴、バックアップを削除しません。

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
9. GitHub ReleasesでEXE、Windows ZIP、DMG、`release-info.json`が揃っていることを確認します。

Macでは`./scripts/release.sh 1.3.4`、Windowsでは`powershell -ExecutionPolicy Bypass -File .\scripts\release.ps1 1.3.4`でも、バージョン更新、検査、commit、タグ作成をまとめて実行できます。

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
