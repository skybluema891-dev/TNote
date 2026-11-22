# Windowsの配置と運用

Windows 1ではTNote親フォルダ内の指定済み3領域を使います。開発領域の `tnote` がFlutterとGitのルートです。完成アプリ領域の `tnote\TNote` がインストール先、同階層の `distribution\TNoteSetup.exe` が正式公開版の保管先です。端末固有の対応表は `app-layout.json` に記録し、ソース管理から除外します。

開発ルートから共通の `manager.py test` と `manager.py build --version <pubspecのバージョン>` を実行できます。公開前のローカルビルドとセットアップは開発領域の `build` と `artifacts\installer\<版>` に出力されます。正式リリースではGitHub Actionsが同じ版のWindowsセットアップとmacOS配布物を検証・生成し、両方が揃ってから公開します。

アプリの隣に `runtime.json` がある場合、Windows版はそのファイルの `data_relative` を実行ファイルからの相対パスとして解決します。`id` は `tnote`、`data_mode` は `portable` です。指定先へ既存の `shared_preferences.json`、`backups`、`recovery`、`locks` をアプリ停止中にコピーし、内容を照合してから切り替えます。インストール先の設定ファイルは、その場所への上書き更新で引き継ぎます。

通常の配布パッケージには端末専用の `runtime.json` を含めません。この場合は従来どおりOS標準の保存先を使います。OneDriveや任意のフォルダにある `.tnote` は元のパスで開きます。設定を切り替えるときは、元の保存先と新しい保存先に同時に書き込まないようTNoteを終了してください。

Windows 1の `runtime.json` では `setup_relative` に `../distribution/TNoteSetup.exe` を指定します。TNoteは起動時と起動中は2時間おきに正式リリースを確認します。配布ファイルを同じドライブ上へ一時取得し、照合後に保管用セットアップを置き換えます。保存済みの通常終了後は、元のアプリが終了してから既存と同じインストール先を更新します。次に正常起動した時点で旧実行ファイルの退避を整理します。途中で更新に失敗した場合は、正式配布先のセットアップを再実行できます。自動復旧できない場合の旧実行ファイルはインストール先の `.tnote-update-rollback` に残ります。
