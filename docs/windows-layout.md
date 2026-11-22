# Windowsの配置と運用

Windows 1ではTNote親フォルダ内の指定済み3領域を使います。開発領域の `tnote` がFlutterとGitのルートです。完成アプリ領域の `tnote\TNote` がインストール先、同階層の `distribution` がインストーラーの出力先です。端末固有の対応表は `app-layout.json` に記録し、ソース管理から除外します。

開発ルートから共通の `manager.py test` と `manager.py build --version <pubspecのバージョン>` を実行できます。Flutterの生成物は開発内、インストーラーは完成アプリに出力されます。

アプリの隣に `runtime.json` がある場合、Windows版はそのファイルの `data_relative` を実行ファイルからの相対パスとして解決します。`id` は `tnote`、`data_mode` は `portable` です。指定先へ既存の `shared_preferences.json`、`backups`、`recovery`、`locks` をアプリ停止中にコピーし、内容を照合してから切り替えます。インストール先の設定ファイルは、その場所への上書き更新で引き継ぎます。

通常の配布パッケージには端末専用の `runtime.json` を含めません。この場合は従来どおりOS標準の保存先を使います。OneDriveや任意のフォルダにある `.tnote` は元のパスで開きます。設定を切り替えるときは、元の保存先と新しい保存先に同時に書き込まないようTNoteを終了してください。
