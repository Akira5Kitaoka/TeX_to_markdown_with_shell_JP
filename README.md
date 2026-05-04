
# TeX ファイル を Markdown ファイル に変換するツール

## これは何？
LaTeX ファイルから Markdown ファイルを自動生成するシェルスクリプトです．
`pandoc` による LaTeX→Markdown 変換に加えて，定理環境・参照・引用・色指定・数式番号・参考文献などを Markdown 仕様に寄せて整形する後処理を行います．

できること：
- 定理 / 補題 / 定義などの環境を blockquote 形式に変換
- `\ref / \eqref / \cref / \Cref` を Markdown 内リンクに変換
- `\cite / \citet / \citep / \cites` を `[著者 西暦](#ref-key)` 形式のリンクに変換
- bib ファイルから参考文献節を自動生成
- `\appendix` 以降の見出し / 数式 / 定理番号に「付録」プレフィックスを付与

できないこと：
- `documentclass` / `package` / `cleveref` の設定変更（後処理が前提とする構造が崩れるため）
- 任意のフォーマットの LaTeX ファイル（`sample_JP.tex` のフォーマット準拠が前提）

## 前提ソフトウェア

以下が必要です．

- `pandoc`
- `python3`

インストール例：

```bash
# Ubuntu / Debian
sudo apt install pandoc python3

# macOS (Homebrew)
brew install pandoc python3
```

## 使い方

1. TeX ファイルと，それに付随する bib ファイル・画像ファイルを用意する．
    - TeX ファイルは `sample_JP.tex` のフォーマットで書くこと．
2. TeX ファイルのあるフォルダに `tex_to_md.sh` を配置する．
3. TeX のメインファイルを `hogehoge.tex` としたとき，TeX のメインファイルがあるディレクトリで以下を実行：

   ```bash
   bash tex_to_md.sh hogehoge.tex
   ```

   末尾の `.tex` は省略可（`bash tex_to_md.sh hogehoge` でも動く）．
4. `hogehoge.md` という Markdown ファイルが作成される．

## 具体例

### 入力ファイル
- `example_JP.tex` — TeX ファイル本体
- `example_ref_JP.bib` — `example_JP.tex` で参照する bib ファイル
- `haniwa-d-u.jpg` — `example_JP.tex` で使用する画像ファイル

### 出力ファイル
- `example_JP.md`

## 仕様

### 出力フォーマット
- GitHub Pages (MathJax 対応) での表示を想定．
    - 数式は MathJax 互換 (`$ ... $` / `$$ ... $$`) で出力．
    - 定理系は blockquote (`> **定理 N**`) として出力．
    - 数式アンカー / 参考文献アンカーは `<a id="...">` で埋め込み，`\ref` 等から内部リンクで参照可能．
    - 色指定は `<font color=#...>` として出力．
    - タイトル / 著者は `:::message` ブロックとして先頭に挿入．

### 対応する LaTeX 機能

| 種類 | コマンド / 環境 | 備考 |
|:---|:---|:---|
| 定理系環境 | `theorem` / `lemma` / `definition` / `proposition` / `corollary` / `remark` / `example` / `assumption` | それぞれ「定理 / 補題 / 定義 / 命題 / 系 / 注意 / 例 / 仮定」に変換 |
| 数式環境 | `align` / `equation` / `gather` / `multline` | `*` 付きは番号なし．`\notag` / `\nonumber` の行も番号なし |
| 証明 | `proof` 環境 | 末尾に右寄せの `$\square$` を自動付与 |
| 参照 | `\ref` / `\eqref` / `\cref` / `\Cref` | 番号と種別を自動推定して内部リンク化 |
| 引用 | `\cite` / `\citet` / `\citep` / `\cites` | `[著者 西暦](#ref-key)` 形式に変換 |
| 色 | `\textcolor{red!80!black}{...}` 等 | `red!80!black` のような色 mix にも対応．`<font color=#...>` として出力 |
| 付録 | `\appendix` | 以降の見出し / 数式 / 定理番号に「付録」プレフィックスを付与 |
| 表 | `tabular` | `p{...}` / `m{...}` / `b{...}` 列指定は `c` (中央揃え) に置換 |
| 無視 | `minipage` | タグだけ除去して中身は残す |
| タイトル | `\title` / `\author` / `\maketitle` | 先頭に `:::message` ブロックとして挿入 |

### bib ファイルの扱い
- カレントディレクトリの `*.bib` をすべて拾うのではなく，TeX ファイル中の `\bibliography{...}` で指定された bib のみを使用する．
- 引用された (`\cite` 等で参照された) キーのみ参考文献節に出力する．

## 変更可能箇所について

- 以下の改良は対応できる：
    - `\DeclareMathOperator` の追加
    - title と著者名
    - abstract の中身
    - main section
    - appendix の加筆，および削除
    - bib ファイルの引用
- 以下の部分は改良不可：
    - `documentclass`
    - `package`
    - `cleveref` の設定

## トラブルシューティング

- **`pandoc が見つかりません` / `python3 が見つかりません`**：前提ソフトウェアをインストールしてください．
- **`TeXファイルが見つかりません`**：スクリプトと同じディレクトリで実行しているか，ファイル名が正しいか確認してください．
- **`\bibliography で指定された bib が見つかりません`**：`\bibliography{...}` で指定したファイル名と実際の bib ファイル名が一致しているか確認してください．
- **`pandoc から警告が出ています`**：変換は成功しているが警告がある状態．多くの場合は無視して問題ないが，出力された md を確認してください．

## ライセンス
MIT License — 詳細は `LICENSE` を参照．

## その他
- このリポジトリは，著者の都合で改編される場合があります．
