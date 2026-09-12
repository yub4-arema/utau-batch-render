# UTAU Batch Render

複数の `.ust` を、本家UTAUでまとめてWAV化するWindows用PowerShellツールです。

## できること

- 複数USTをエクスプローラーから選択
- 「送る」から一括レンダリング
- 使用する単独音音源フォルダを選択
- 元USTと同じフォルダへ `xxx.wav` を出力
- 既存WAVはデフォルトでスキップ
- 複数USTを並列処理
- USTの元ファイルは変更しない
- UTAU側のresampler・wavtoolを使用

## 必要なもの

- Windows
- Windows PowerShell 5.1
- 本家UTAU
- `oto.ini` がある音源フォルダ

音源は `あ.wav` のような個別ファイルではなく、その親フォルダを選択してください。例えば `あ.wav` が `voice\yub4` にある場合は、`voice\yub4` を選びます。

## セットアップ

このリポジトリの3ファイルを同じフォルダに置き、`install.ps1` をPowerShellで実行します。

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1
```

その後、USTを複数選択して、エクスプローラーの「送る」から「UTAU 一括レンダリング」を実行します。初回は音源フォルダの選択ダイアログが開きます。選択した音源は次回以降も使用されます。

登録を解除する場合:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## 注意

UTAUのGUIを操作してレンダリングするため、UTAUの画面をユーザー操作で同時に操作しないでください。音源側の `oto.ini`、resampler、wavtoolの設定が正しくない場合は、UTAU本体の通常レンダリングと同じように失敗します。

このプロジェクトはUTAUの非公式ツールであり、UTAUおよび音源配布元とは無関係です。

## License

MIT License. 詳細は [LICENSE](LICENSE) を参照してください。
