#!/bin/bash
set -e

cd "$(dirname "$0")"

# ファイルが指定されているか確認
if [ -z "$1" ]; then
    echo "エラー: TeXファイルを指定してください．"
    echo "使用例: bash $0 title.tex"
    exit 1
fi

FILE_PATH="$1"

# 末尾の .tex は付いていても付いていなくてもよい
BASE="${FILE_PATH%.tex}"
TEX="${BASE}.tex"
MD="${BASE}.md"

# ---- ヘルパー ----
sep()  { printf '\e[90m%s\e[0m\n' "────────────────────────────────────────────────────────────" >&2; }
info() { printf '\e[36m[INFO]\e[0m  %s\n' "$*" >&2; }
warn() { printf '\e[33m[WARN]\e[0m  %s\n' "$*" >&2; }
err()  { printf '\e[31m[ERROR]\e[0m %s\n' "$*" >&2; }

# ---- 前提チェック ----
if ! command -v pandoc >/dev/null 2>&1; then
    err "pandoc が見つかりません．インストールしてください．"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    err "python3 が見つかりません．インストールしてください．"
    exit 1
fi
if [ ! -f "$TEX" ]; then
    err "TeXファイルが見つかりません: ${TEX}"
    exit 1
fi

# ---- bibファイルを収集 ----
# 仕様: $TEX 中の \bibliography{...} で指定された bib のみを使う．
#       (カレントの *.bib をすべて拾うと, .tex が参照していない bib も
#       入ってしまう．例: ref_JP.bib を指定していても main_JP.bib が拾われる)
BIB_ARGS=()
BIB_FOUND=()
mapfile -t BIB_NAMES < <(
    python3 - "$TEX" <<'PYBIB'
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
# コメントは除く
src = re.sub(r'(?<!\\)%[^\n]*', '', src)
seen = []
for m in re.finditer(r'\\bibliography\s*\{([^}]+)\}', src):
    for name in m.group(1).split(','):
        name = name.strip()
        if not name:
            continue
        if not name.endswith('.bib'):
            name += '.bib'
        if name not in seen:
            seen.append(name)
for n in seen:
    print(n)
PYBIB
)

for bib in "${BIB_NAMES[@]}"; do
    if [ -f "$bib" ]; then
        BIB_ARGS+=(--bibliography="$bib")
        BIB_FOUND+=("$bib")
    else
        warn "\\bibliography で指定された bib が見つかりません: ${bib}"
    fi
done

if [ "${#BIB_FOUND[@]}" -gt 0 ]; then
    info "bibファイル: ${BIB_FOUND[*]}"
else
    warn "bibファイルが見つかりません．参考文献は \\cite{key} のまま残ります．"
fi

# ---- pandoc 前処理 ----
# 仕様 (tex_to_md.md) で要求される:
#   - 表の p{...} 列指定は中央寄せ (c) に置換
#   - minipage は無視 (タグだけ除去して中身は残す)
# は，pandoc に渡す前の .tex で行う方が確実なため，先に前処理する．
# ($TEX 自体は触らず，一時ファイルに書き出してそれを pandoc に食わせる)
info "前処理: minipage 除去 / tabular の p{...} → c ..."

TEX_PREPROC="$(mktemp --suffix=.tex)"
PANDOC_LOG="$(mktemp)"
trap 'rm -f "$PANDOC_LOG" "$TEX_PREPROC"' EXIT

python3 - "$TEX" "$TEX_PREPROC" <<'PYPRE'
import re
import sys

src = open(sys.argv[1], encoding='utf-8').read()

# ---- minipage は無視 (タグだけ除去して中身は残す) ----
src = re.sub(r'\\begin\{minipage\}(?:\[[^\]]*\])?(?:\{[^}]*\})?', '', src)
src = re.sub(r'\\end\{minipage\}', '', src)

# ---- table / table* 環境タグを剥がす ----
# pandoc が "Unknown environment `table'" 警告を出すケースへの対策．
# 中の tabular はそのまま md 表に変換される．\caption{...} / \label{...} /
# \centering は不要なので併せて除去する (表番号は post-process 側で labels に
# 沿って付与する想定)．
src = re.sub(r'\\begin\{table\*?\}\s*(?:\[[^\]]*\])?\s*', '', src)
src = re.sub(r'\\end\{table\*?\}', '', src)
src = re.sub(r'\\centering\b\s*', '', src)

# ---- tabular / array の正規化 ----
#  (a) column spec の p{...}/m{...}/b{...} を c に
#  (b) 行末の \\ が抜けている行 ('&' を含むのに \\ で終わっていない行) に
#      \\ を付与する (pandoc が tabular を正しく解釈できるようにするため．
#      malformed なソース: "トマト & きゅうり & なす\n\hline\nhoge & ..." への対策)
def _normalize_tabular(m):
    env  = m.group(1)
    spec = m.group(2)
    body = m.group(3)

    # column spec
    spec = re.sub(r'[pmb]\s*\{[^{}]*\}', 'c', spec)

    # body の行末 \\ 補完
    fixed_lines = []
    for ln in body.split('\n'):
        s = ln.rstrip()
        if '&' in s and not re.search(r'\\\\\s*$', s):
            s = s + r' \\'
        fixed_lines.append(s)
    body = '\n'.join(fixed_lines)

    return f'\\begin{{{env}}}{{{spec}}}{body}\\end{{{env}}}'

src = re.sub(
    r'\\begin\{(tabular\*?|array)\}\s*\{((?:[^{}]|\{[^{}]*\})*)\}'
    r'(.*?)\\end\{\1\}',
    _normalize_tabular, src, flags=re.DOTALL,
)

open(sys.argv[2], 'w', encoding='utf-8').write(src)
PYPRE

# ---- pandoc 変換 ----
info "Converting ${TEX} -> ${MD} ..."

# - --from=latex+raw_tex   : LaTeX 入力（未対応コマンドはそのまま通す）
# - --to=markdown          : pandoc 拡張Markdown 出力
# - --wrap=preserve        : 改行をなるべく保持
# - --mathjax              : 数式は MathJax 互換 ($/$$) で出力（KaTeX では書かない）
PANDOC_ARGS=(
    "$TEX_PREPROC"
    --from=latex+raw_tex
    --to=markdown-simple_tables-multiline_tables-grid_tables
    --wrap=preserve
    --mathjax
)
if [ "${#BIB_FOUND[@]}" -gt 0 ]; then
    PANDOC_ARGS+=("${BIB_ARGS[@]}")
fi

if ! pandoc "${PANDOC_ARGS[@]}" -o "$MD" 2> "$PANDOC_LOG"; then
    sep
    err "pandoc 変換に失敗しました．"
    sep
    sed 's/^/  /' "$PANDOC_LOG" >&2
    sep
    exit 1
fi

# 警告サマリ
if [ -s "$PANDOC_LOG" ]; then
    warn "pandoc から警告が出ています:"
    sed 's/^/  /' "$PANDOC_LOG" >&2
fi

# ---- 後処理 (Python) ----
# 仕様 (tex_to_md.md) に従い:
#   1. .tex を直接スキャンして label -> (type, 番号) のテーブルを作る
#      (.aux は使わない)
#   2. \title / \author を抽出して :::message タイトルブロックを生成
#   3. \appendix 以降の section / 定理 / 数式番号に "付録" プレフィックスを付与
#   4. minipage は無視 (タグだけ除去)
#   5. \begin{aligned}...\end{aligned} を $$\n\begin{align}...\end{align}\n$$ に整形
#   6. 数式中の \label{...} に \tag{番号} と HTML アンカーを付与
#   7. theorem 系 ::: ブロックを "> **定理 N**\n> ..." の blockquote に変換
#   8. proof ::: ブロックを "**証明**\n\n...\n\n<div style='text-align:right'>$\square$</div>" に
#   9. \Cref / \cref / \eqref / \ref を md 参照リンクに変換
#  10. \cite / \cites / \citet / \citep を md 参照リンクに変換
#  11. \textcolor / pandoc の [text]{style="color: ..."} を <span> に変換
#  12. 見出しに section 番号 ("# 1 タイトル", appendix なら "# 付録 1 タイトル") を付与
#  13. 先頭に :::message タイトルブロックを挿入 (\maketitle は除去)
info "後処理: title / heading / theorem / proof / refs / cite / textcolor / 数式 tag / minipage ..."

python3 - "$TEX" "$MD" "${BIB_FOUND[@]}" <<'PYEOF'
import re
import sys
from pathlib import Path

# ----- 環境名の日本語対応 -----
ENV_JA = {
    'theorem':     '定理',
    'lemma':       '補題',
    'definition':  '定義',
    'proposition': '命題',
    'corollary':   '系',
    'remark':      '注意',
    'example':     '例',
    'assumption':  '仮定',
}

REF_NAMES = {
    **ENV_JA,
    'equation':   '式',
    'figure':     '図',
    'table':      '表',
    'algorithm':  'アルゴリズム',
    'section':    '節',
    'subsection': '項',
    'appendix':   '付録',
}

THM_CLASSES = list(ENV_JA.keys())
THM_RE = '|'.join(THM_CLASSES)
MATH_BASES = ('align', 'equation', 'gather', 'multline')
MATH_RE = '|'.join(b + r'\*?' for b in MATH_BASES)

# ----- LaTeX 標準色名 -> RGB -----
COLOR_RGB = {
    'red':       (255,   0,   0),
    'green':     (  0, 255,   0),
    'blue':      (  0,   0, 255),
    'cyan':      (  0, 255, 255),
    'magenta':   (255,   0, 255),
    'yellow':    (255, 255,   0),
    'black':     (  0,   0,   0),
    'white':     (255, 255, 255),
    'orange':    (255, 128,   0),
    'gray':      (128, 128, 128),
    'darkgray':  ( 64,  64,  64),
    'lightgray': (192, 192, 192),
    'brown':     (139,  69,  19),
    'olive':     (128, 128,   0),
    'pink':      (255, 192, 203),
    'purple':    (128,   0, 128),
    'teal':      (  0, 128, 128),
    'violet':    (148,   0, 211),
    'lime':      (191, 255,   0),
}


# ====================================================================
# ヘルパー: バランス括弧の中身を取り出す
# ====================================================================
def _balanced_braces(text, brace_pos):
    """text[brace_pos] が '{' のとき，対応する '}' までの中身を返す."""
    if brace_pos >= len(text) or text[brace_pos] != '{':
        return ''
    depth = 1
    i = brace_pos + 1
    n = len(text)
    while i < n and depth > 0:
        ch = text[i]
        if ch == '\\' and i + 1 < n:
            i += 2
            continue
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return text[brace_pos + 1:i]
        i += 1
    return text[brace_pos + 1:i]


# ====================================================================
# 1. .tex を直接スキャンして label 番号テーブル / 見出し / タイトルを取得
# ====================================================================
def parse_tex(tex_path):
    """
    .tex を読み，下記を返す:
      {
        'labels':   {label: {'type': str, 'number': str}},
        'title':    str | None,
        'authors':  [str, ...],
        'headings': [{'level': 1|2, 'number': str, 'title_raw': str,
                      'is_appendix': bool, 'labels': [str, ...]}, ...],
      }

    - section / subsection を追跡 (番号付きのみ)
    - \\appendix 以降は section / 定理 / 数式番号に "付録" を付ける
    - theorem 系環境 (定理, 補題, …) は <section>.<thm_counter>
    - 数式環境 (align, equation, gather, multline) は <section>.<eq_counter>
      (\\notag / \\nonumber が無い行のみ番号付与)
    - figure / table の \\label は番号付与
    """
    result = {'labels': {}, 'title': None, 'authors': [], 'headings': []}
    if not tex_path.exists():
        return result

    text = tex_path.read_text(encoding='utf-8')
    # コメントを除去 (\% は残す)
    text = re.sub(r'(?<!\\)%[^\n]*', '', text)

    # ---- title / author ----
    tm = re.search(r'\\title\s*\{', text)
    if tm:
        result['title'] = _balanced_braces(text, tm.end() - 1).strip()

    am = re.search(r'\\author\s*\{', text)
    if am:
        raw = _balanced_braces(text, am.end() - 1)
        # \\thanks{...} は除去
        raw = re.sub(r'\\thanks\s*\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', '', raw)
        for piece in re.split(r'\\and\b', raw):
            piece = re.split(r'\\\\', piece)[0].strip()
            # 残った LaTeX コマンド (\\inst{1} など) を素朴に除去
            piece = re.sub(r'\\[A-Za-z]+\s*\*?\s*(?:\{[^{}]*\})?', '', piece).strip()
            piece = re.sub(r'\s+', ' ', piece)
            if piece:
                result['authors'].append(piece)

    token_re = re.compile(
        r'(?P<appendix>\\appendix\b)|'
        r'\\section(?P<sec_star>\*?)\s*\{|'
        r'\\subsection(?P<sub_star>\*?)\s*\{|'
        rf'\\begin\s*\{{(?P<thm>{THM_RE})\}}|'
        rf'\\end\s*\{{(?P<thm_end>{THM_RE})\}}|'
        r'(?P<figbeg>\\begin\s*\{figure\*?\})|'
        r'(?P<tblbeg>\\begin\s*\{table\*?\})|'
        rf'\\begin\s*\{{(?P<math>{MATH_RE})\}}'
            r'(?P<math_body>.*?)'
            r'\\end\s*\{(?P=math)\}|'
        r'\\label\s*\{(?P<label>[^}]+)\}',
        re.DOTALL,
    )

    labels = result['labels']
    headings = result['headings']
    section_num = 0
    subsection_num = 0
    thm_counter = 0
    eq_counter = 0
    fig_counter = 0
    tbl_counter = 0
    in_thm = None
    in_appendix = False
    last_kind = None

    def with_appendix(num):
        return f'付録 {num}' if in_appendix else num

    for m in token_re.finditer(text):
        if m.group('appendix'):
            in_appendix = True
            section_num = 0
            subsection_num = 0
            thm_counter = 0
            eq_counter = 0
            continue

        token0 = m.group(0)

        if m.group('sec_star') is not None and token0.startswith(r'\section'):
            if not m.group('sec_star'):
                section_num += 1
                subsection_num = 0
                thm_counter = 0
                eq_counter = 0
                title_raw = _balanced_braces(text, m.end() - 1)
                headings.append({
                    'level': 1,
                    'number': str(section_num),
                    'title_raw': title_raw,
                    'is_appendix': in_appendix,
                    'labels': [],
                })
                last_kind = 'section'
            continue

        if m.group('sub_star') is not None and token0.startswith(r'\subsection'):
            if not m.group('sub_star'):
                subsection_num += 1
                title_raw = _balanced_braces(text, m.end() - 1)
                headings.append({
                    'level': 2,
                    'number': f'{section_num}.{subsection_num}',
                    'title_raw': title_raw,
                    'is_appendix': in_appendix,
                    'labels': [],
                })
                last_kind = 'subsection'
            continue

        if m.group('figbeg'):
            fig_counter += 1
            last_kind = 'figure'
            continue

        if m.group('tblbeg'):
            tbl_counter += 1
            last_kind = 'table'
            continue

        if m.group('thm'):
            in_thm = m.group('thm')
            thm_counter += 1
            last_kind = 'theorem'
        elif m.group('thm_end'):
            in_thm = None
        elif m.group('math'):
            env = m.group('math')
            body = m.group('math_body')
            base = env.rstrip('*')
            starred = env.endswith('*')
            if starred:
                continue
            if base in ('equation', 'multline'):
                eq_counter += 1
                num = with_appendix(f'{section_num}.{eq_counter}')
                for lbl in re.findall(r'\\label\{([^}]+)\}', body):
                    labels[lbl] = {'type': 'equation', 'number': num}
            else:
                # \\ で行区切り (LaTeX ソース上の "\\" 二文字)
                segments = re.split(r'\\\\', body)
                for seg in segments:
                    if not seg.strip():
                        continue
                    if re.search(r'\\(?:notag|nonumber)\b', seg):
                        continue
                    eq_counter += 1
                    num = with_appendix(f'{section_num}.{eq_counter}')
                    for lbl in re.findall(r'\\label\{([^}]+)\}', seg):
                        labels[lbl] = {'type': 'equation', 'number': num}
        elif m.group('label'):
            lbl = m.group('label')
            if in_thm is not None:
                num = with_appendix(f'{section_num}.{thm_counter}')
                labels[lbl] = {'type': in_thm, 'number': num}
            elif last_kind == 'section' and headings:
                num = with_appendix(headings[-1]['number'])
                labels[lbl] = {'type': 'section', 'number': num}
                headings[-1]['labels'].append(lbl)
            elif last_kind == 'subsection' and headings:
                num = with_appendix(headings[-1]['number'])
                labels[lbl] = {'type': 'subsection', 'number': num}
                headings[-1]['labels'].append(lbl)
            elif last_kind == 'figure':
                labels[lbl] = {'type': 'figure', 'number': str(fig_counter)}
            elif last_kind == 'table':
                labels[lbl] = {'type': 'table', 'number': str(tbl_counter)}

    return result


# ====================================================================
# 2. 参照テキスト整形
# ====================================================================
def format_ref(label, labels):
    info = labels.get(label)
    if info is None:
        return f'[{label}](#{label})'
    typ, num = info['type'], info['number']
    name = REF_NAMES.get(typ, typ)
    is_app = num.startswith('付録')
    if typ == 'section':
        text = num if is_app else f'第{num}節'
    elif typ == 'subsection':
        text = num if is_app else f'第{num}項'
    elif typ == 'equation':
        # 仕様: appendix では "(付録 1.1)" / 通常は "式 (1.1)"
        text = f'({num})' if is_app else f'式 ({num})'
    else:
        # 定理 / 補題 / 図 / 表 など: "定理 1.1" / "定理 付録 1.1"
        text = f'{name} {num}'
    return f'[{text}](#{label})'


# ====================================================================
# 3. 色変換
# ====================================================================
def mix_colors(c1, p, c2):
    rgb1 = COLOR_RGB.get(c1.lower(), (0, 0, 0))
    rgb2 = COLOR_RGB.get(c2.lower(), (0, 0, 0))
    f = p / 100.0
    rgb = tuple(int(round(rgb1[i] * f + rgb2[i] * (1 - f))) for i in range(3))
    return f'#{rgb[0]:02x}{rgb[1]:02x}{rgb[2]:02x}'


def latex_color_to_css(color):
    color = color.strip()
    m = re.match(r'^([A-Za-z]+)!(\d+)!([A-Za-z]+)$', color)
    if m:
        return mix_colors(m.group(1), int(m.group(2)), m.group(3))
    m = re.match(r'^([A-Za-z]+)!(\d+)$', color)
    if m:
        return mix_colors(m.group(1), int(m.group(2)), 'white')
    if color.lower() in COLOR_RGB:
        r, g, b = COLOR_RGB[color.lower()]
        return f'#{r:02x}{g:02x}{b:02x}'
    return color


def transform_textcolor(content):
    # 仕様 (tex_to_md.md):
    #   \textcolor{red!80!black}{hogehoge}  ->  <font color=#cc0000>hogehoge</font>
    # pandoc が変換した形: [text]{style="color: COLOR"}
    pat_pandoc = re.compile(r'\[((?:[^\]\\]|\\.)*)\]\{style="color:\s*([^"]+?)\s*"\}')

    def repl_pandoc(m):
        text, color = m.group(1), m.group(2)
        css = latex_color_to_css(color)
        return f'<font color={css}>{text}</font>'

    content = pat_pandoc.sub(repl_pandoc, content)

    # 生 LaTeX として残った場合: \textcolor{color}{text}
    return _replace_raw_textcolor(content)


def _replace_raw_textcolor(text):
    out, i, n = [], 0, len(text)
    needle = r'\textcolor{'
    while i < n:
        idx = text.find(needle, i)
        if idx < 0:
            out.append(text[i:])
            break
        out.append(text[i:idx])
        # {color}
        j = idx + len(needle)
        depth, k = 1, j
        while k < n and depth > 0:
            ch = text[k]
            if ch == '\\' and k + 1 < n:
                k += 2
                continue
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
            k += 1
        if depth != 0:
            out.append(text[idx:])
            break
        color = text[j:k - 1]
        # {content}
        m = k
        while m < n and text[m] in ' \t':
            m += 1
        if m >= n or text[m] != '{':
            out.append(text[idx:k])
            i = k
            continue
        cs = m + 1
        depth, ce = 1, cs
        while ce < n and depth > 0:
            ch = text[ce]
            if ch == '\\' and ce + 1 < n:
                ce += 2
                continue
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
            ce += 1
        if depth != 0:
            out.append(text[idx:])
            break
        content = text[cs:ce - 1]
        css = latex_color_to_css(color)
        out.append(f'<font color={css}>{content}</font>')
        i = ce
    return ''.join(out)


# ====================================================================
# 4. align 整形
# ====================================================================
def fix_align_aligned(content):
    """
    pandoc が出す $$\\begin{aligned} ... \\end{aligned}$$ を
    仕様の整形版:
        $$
        \\begin{align}
            ...
        \\end{align}
        $$
    に書き直す.
    """
    pat = re.compile(
        r'\$\$\s*\\begin\{aligned\}'
        r'(?P<body>.*?)'
        r'\\end\{aligned\}\s*\$\$',
        re.DOTALL,
    )

    def repl(m):
        body = m.group('body').strip('\n').rstrip()
        return f'$$\n\\begin{{align}}\n{body}\n\\end{{align}}\n$$'

    return pat.sub(repl, content)


# ====================================================================
# 4b. 数式ブロック ($$...$$) 内の TeX コメント / 空白行を除去
#   `%` から行末までは TeX コメント．align 等の中に裸の `%` 行や
#   空白だけの行が残っていると MathJax レンダラによっては行の連結に
#   失敗し "Missing \\end{align}" を出すことがあるので,
#   pre-render で:
#     1. 各行の `%` 以降を削除 (`\\%` のリテラル `%` は保持)
#     2. 結果として空白だけになった行は削除
#   ただし `$$` 直後・直前の改行 (数式ブロック全体を複数行で書く形式) は
#   見た目のため残す．
# ====================================================================
def strip_tex_comments_in_math(content):
    pat = re.compile(r'\$\$(.*?)\$\$', re.DOTALL)

    def _strip_line(ln):
        # `\\%` をプレースホルダで退避してから `%` 以降を除去
        SENT = '\x00ESC_PCT\x00'
        ln2 = ln.replace(r'\%', SENT)
        ln2 = re.sub(r'%.*$', '', ln2)
        return ln2.replace(SENT, r'\%')

    def repl(m):
        body = m.group(1)
        # 数式ブロックの先頭・末尾の改行構造を保持する
        has_leading_nl  = body.startswith('\n')
        has_trailing_nl = body.endswith('\n')

        new_lines = []
        for ln in body.split('\n'):
            stripped = _strip_line(ln)
            # 結果として空白だけになった行は (元の状態によらず) 削除する．
            # コメント除去で生じた空行も, 元から空白だけだった行も,
            # MathJax の段落区切りや行連結を壊すリスクがあるため落とす．
            if stripped.strip() == '':
                continue
            new_lines.append(stripped)

        body_new = '\n'.join(new_lines)
        if has_leading_nl:
            body_new = '\n' + body_new
        if has_trailing_nl:
            body_new = body_new + '\n'
        return '$$' + body_new + '$$'

    return pat.sub(repl, content)


# ====================================================================
# 5. 数式 label に \tag{番号} と HTML アンカーを付与
# ====================================================================
def add_equation_anchors_and_tags(content, labels):
    label_re = re.compile(r'\\label\{([^}]+)\}')
    pat = re.compile(r'\$\$(?P<body>.*?)\$\$', re.DOTALL)

    def repl(m):
        block = m.group('body')
        block_labels = label_re.findall(block)
        if not block_labels:
            return m.group(0)
        anchors = '\n'.join(f'<a id="{lab}"></a>' for lab in block_labels)

        def label_repl(lm):
            lab = lm.group(1)
            if lab in labels:
                num = labels[lab]['number']
                return f'\\tag{{{num}}}\\label{{{lab}}}'
            return lm.group(0)

        new_block = label_re.sub(label_repl, block)
        return f'{anchors}\n\n$${new_block}$$'

    return pat.sub(repl, content)


# ====================================================================
# 6. ::: ブロック (theorem / proof) を仕様の形式に変換
# ====================================================================
def parse_div_attrs(attrs):
    ids, classes = [], []
    for tok in attrs.split():
        if tok.startswith('#'):
            ids.append(tok[1:])
        elif tok.startswith('.'):
            classes.append(tok[1:])
    return ids, classes


def quote_lines(text):
    """各行に '> ' プレフィックスを付ける (空行は '>' のみ)．"""
    out = []
    for ln in text.split('\n'):
        out.append('> ' + ln if ln.strip() else '>')
    return '\n'.join(out)


def finalize_blocks(content, labels):
    """
    ::: {.proof} ブロック  -> **証明** ... <div ...>$\\square$</div>
    ::: {.theorem 等} ブロック -> blockquote 形式
    """
    pat = re.compile(
        r'^::: \{(?P<attrs>[^}]+)\}\n(?P<body>.*?)\n^:::\s*$',
        re.MULTILINE | re.DOTALL,
    )

    def repl(m):
        attrs = m.group('attrs')
        body = m.group('body').strip('\n')
        ids, classes = parse_div_attrs(attrs)

        if 'proof' in classes:
            return _finalize_proof(body)

        cls = next((c for c in classes if c in THM_CLASSES), None)
        if cls is not None:
            return _finalize_theorem(body, ids, cls, labels)

        return m.group(0)

    return pat.sub(repl, content)


def _finalize_theorem(body, ids, cls, labels):
    """pandoc 出力の "**Title** (optional). 内容..." から
    optional / 内容 を取り出す．optional は括弧の入れ子に対応するため
    手書きでバランスを取る (\\begin{theorem}[Foo (cf. \\cite{...})] のような
    入れ子括弧があってもよいようにする)．"""
    body = body.lstrip('\n')
    opt = None
    inner = body

    m = re.match(r'^\*\*([^*]+)\*\*', body)
    if m:
        rest = body[m.end():]
        ws = re.match(r'\s*', rest)
        rest = rest[ws.end():]
        if rest.startswith('('):
            depth, i, n = 1, 1, len(rest)
            while i < n and depth > 0:
                ch = rest[i]
                if ch == '\\' and i + 1 < n:
                    i += 2
                    continue
                if ch == '(':
                    depth += 1
                elif ch == ')':
                    depth -= 1
                    if depth == 0:
                        opt = rest[1:i]
                        rest = rest[i + 1:]
                        break
                i += 1
            else:
                # 括弧が閉じない場合は optional 無しとして扱う
                opt = None
        rest = rest.lstrip()
        if rest.startswith('.'):
            rest = rest[1:]
        inner = rest.lstrip()

    label = ids[0] if ids else None
    num = labels[label]['number'] if (label and label in labels) else ''
    title = f'{ENV_JA[cls]} {num}'.strip()
    suffix = f' ({opt})' if opt else ''

    # 仕様 (tex_to_md.md):
    #   label がある場合は <a id="label">**定理 XX**</a> のように
    #   タイトル全体を <a> で囲む．
    if label:
        title_md = f'<a id="{label}">**{title}**</a>'
    else:
        title_md = f'**{title}**'

    return f'\n> {title_md}{suffix}\n{quote_lines(inner)}\n'


def _finalize_proof(body):
    # pandoc の出力: "*Title.* 内容 ◻"
    title = '証明'
    tm = re.match(r'^\*([^*]+?)\.\*\s*', body)
    if tm:
        ptitle = tm.group(1).strip()
        title = ptitle if ptitle.lower() != 'proof' else '証明'
        body = body[tm.end():]

    # 末尾の QED 記号 (◻ U+25FB / ∎ U+220E) と末尾空白を除去
    body = re.sub(r'[\s◻∎□⦰]+\Z', '', body)

    # 仕様: \square は右寄せ
    return (f'**{title}**\n\n{body}\n\n'
            f'<div style="text-align: right">$\\square$</div>\n')


# ====================================================================
# 7. \Cref / \cref / \eqref / \ref を md 参照に
# ====================================================================
def convert_refs(content, labels):
    def repl(m):
        keys = [k.strip() for k in m.group(1).split(',') if k.strip()]
        refs = [format_ref(k, labels) for k in keys]
        if len(refs) == 1:
            return refs[0]
        if len(refs) == 2:
            return refs[0] + 'と' + refs[1]
        return '，'.join(refs[:-1]) + '，および' + refs[-1]

    # pandoc が raw_tex として残した形: `\Cref{key}`{=latex}
    content = re.sub(r'`\\[Cc]ref\{([^}]+)\}`\{=latex\}', repl, content)
    content = re.sub(r'`\\eqref\{([^}]+)\}`\{=latex\}',   repl, content)
    content = re.sub(r'`\\ref\{([^}]+)\}`\{=latex\}',     repl, content)
    # 念のため素のままの形にも対応
    content = re.sub(r'\\[Cc]ref\{([^}]+)\}', repl, content)
    content = re.sub(r'\\eqref\{([^}]+)\}',   repl, content)
    content = re.sub(r'\\ref\{([^}]+)\}',     repl, content)
    return content


# ====================================================================
# 8. \cite / \cites / \citet / \citep を md 参照リンクに
#    - 仕様 (tex_to_md.md): [Kitaoka 2025](#ref-kitaoka2025minimization) のように
#      "著者姓 西暦" をリンクテキストとする．
#    - \cite, \citet : 括弧なし
#    - \citep, \cites: 括弧付き ((Author1 Year1, Author2 Year2))
# ====================================================================
def _cite_last_name(author_raw):
    """bib の author 文字列から先頭著者の姓を取り出す."""
    a = re.split(r'\s+and\s+', author_raw.strip(), maxsplit=1)[0].strip()
    if not a:
        return ''
    if ',' in a:
        return a.split(',', 1)[0].strip()
    toks = a.split()
    return toks[-1] if toks else ''


def _cite_display(key, bib_entries):
    """単一キーに対する表示テキスト ("Kitaoka 2025" など) を組み立てる."""
    entry = bib_entries.get(key)
    if not entry:
        return key
    raw = entry.get('author', '')
    authors = [a.strip() for a in re.split(r'\s+and\s+', raw) if a.strip()]
    if not authors:
        name = ''
    elif len(authors) == 1:
        name = _cite_last_name(authors[0])
    elif len(authors) == 2:
        name = f'{_cite_last_name(authors[0])} and {_cite_last_name(authors[1])}'
    else:
        name = f'{_cite_last_name(authors[0])} et al.'
    year = entry.get('year', '').strip()
    if name and year:
        return f'{name} {year}'
    return name or year or key


def convert_citations(content, bib_entries):
    """\\cite{a,b} / \\citet{a} / \\citep{a} / \\cites{a}{b} を
    [Author Year](#ref-a) 形式に."""

    def keys_to_links(keys_text):
        keys = [k.strip() for k in keys_text.split(',') if k.strip()]
        return [f'[{_cite_display(k, bib_entries)}](#ref-{k})' for k in keys]

    def repl_cite(m):
        return ', '.join(keys_to_links(m.group(1)))

    def repl_citet(m):
        return ', '.join(keys_to_links(m.group(1)))

    def repl_citep(m):
        return '(' + ', '.join(keys_to_links(m.group(1))) + ')'

    def repl_cites(m):
        text = m.group(1)
        groups = re.findall(r'\{([^}]+)\}', text)
        links = []
        for grp in groups:
            links.extend(keys_to_links(grp))
        return '(' + ', '.join(links) + ')'

    # \cites{a}{b}{c}  (引数を複数取る形) — \cite より先に処理する
    content = re.sub(r'`\\cites((?:\{[^}]+\})+)`\{=latex\}', repl_cites, content)
    content = re.sub(r'\\cites((?:\{[^}]+\})+)',             repl_cites, content)

    # 単一引数の cite 系 (citep, citet を先に処理して末尾の cite と取り違えない)
    for cmd, fn in (('citep', repl_citep),
                    ('citet', repl_citet),
                    ('cite',  repl_cite)):
        content = re.sub(rf'`\\{cmd}\{{([^}}]+)\}}`\{{=latex\}}', fn, content)
        content = re.sub(rf'\\{cmd}\b\s*\{{([^}}]+)\}}',          fn, content)

    # pandoc が \cite / \citep / \citealp などを下記形式に変換した場合への対策:
    #   [@key]                            -- そのままの引用
    #   [@key §1.2, p. 3]                 -- locator 付き
    #   [Cf. @key 命題 4.21]               -- prefix 付き
    #   [@key1; @key2 loc; ...]           -- 複数引用
    # ブラケット内の各 "@key" を [Author Year](#ref-key) に置換し，
    # prefix / locator はそのまま残す．brackets 全体は (...) で囲む．
    at_re = re.compile(r'(?<![A-Za-z0-9_@\\])@([A-Za-z][A-Za-z0-9_:.\-]*)')

    def _replace_at_keys(text):
        return at_re.sub(
            lambda mm: f'[{_cite_display(mm.group(1), bib_entries)}]'
                       f'(#ref-{mm.group(1)})',
            text,
        )

    def repl_pandoc_bracket(m):
        inner = m.group(1)
        if not at_re.search(inner):
            return m.group(0)
        # bracket 内の各 @key を [Author Year](#ref-key) に置換し,
        # prefix / locator / 区切り文字 (";", ",") はそのまま残す．
        # 外側の "[]" は除去して裸の参照にする (仕様書の例に合わせる)．
        return _replace_at_keys(inner)

    # ブラケットには通常 [ や ] を含まない (pandoc 引用の典型形)．
    content = re.sub(r'\[([^\[\]]*?@[A-Za-z][^\[\]]*?)\]',
                     repl_pandoc_bracket, content)

    # bare の "@key" (in-text 引用 / \citet 相当)
    content = at_re.sub(
        lambda mm: f'[{_cite_display(mm.group(1), bib_entries)}]'
                   f'(#ref-{mm.group(1)})',
        content,
    )
    return content


# ====================================================================
# 8-bib. .bib をパースして apalike 形式で参考文献を組み立てる
# ====================================================================
def parse_bib(path):
    """{key: {'_type': str, field: value, ...}} を返す．"""
    try:
        text = Path(path).read_text(encoding='utf-8')
    except OSError:
        return {}

    entries = {}
    i, n = 0, len(text)
    while i < n:
        at = text.find('@', i)
        if at < 0:
            break
        j = text.find('{', at)
        if j < 0:
            break
        entry_type = text[at + 1:j].strip().lower()
        # @comment / @string / @preamble はスキップ
        if entry_type in ('comment', 'string', 'preamble'):
            i = j + 1
            continue
        # 対応する '}' まで
        depth, k = 1, j + 1
        while k < n and depth > 0:
            ch = text[k]
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    break
            k += 1
        body = text[j + 1:k]
        i = k + 1

        comma = body.find(',')
        if comma < 0:
            continue
        key = body[:comma].strip()
        ft = body[comma + 1:]
        fields = {'_type': entry_type}
        pos, m = 0, len(ft)
        while pos < m:
            eq = ft.find('=', pos)
            if eq < 0:
                break
            name = ft[pos:eq].strip().lower()
            vp = eq + 1
            while vp < m and ft[vp] in ' \t\n\r':
                vp += 1
            if vp >= m:
                break
            if ft[vp] == '{':
                d, vk = 1, vp + 1
                while vk < m and d > 0:
                    if ft[vk] == '{':
                        d += 1
                    elif ft[vk] == '}':
                        d -= 1
                        if d == 0:
                            break
                    vk += 1
                value = ft[vp + 1:vk]
                pos = vk + 1
            elif ft[vp] == '"':
                vk = vp + 1
                while vk < m and ft[vk] != '"':
                    vk += 1
                value = ft[vp + 1:vk]
                pos = vk + 1
            else:
                vk = vp
                while vk < m and ft[vk] != ',':
                    vk += 1
                value = ft[vp:vk].strip()
                pos = vk
            while pos < m and ft[pos] in ', \t\n\r':
                pos += 1
            if name:
                fields[name] = _clean_bib_value(value)
        if key:
            entries[key] = fields
    return entries


def _clean_bib_value(s):
    s = s.strip()
    while s.startswith('{') and s.endswith('}'):
        s = s[1:-1].strip()
    s = re.sub(r'\{([^{}]*)\}', r'\1', s)
    s = s.replace('--', '–')
    s = re.sub(r'\s+', ' ', s)
    return s


def _format_authors_apa(raw):
    if not raw:
        return ''
    authors = []
    for a in re.split(r'\s+and\s+', raw):
        a = a.strip()
        if not a:
            continue
        if ',' in a:
            last, _, first = a.partition(',')
            last, first = last.strip(), first.strip()
        else:
            toks = a.split()
            last = toks[-1] if toks else ''
            first = ' '.join(toks[:-1])
        initials = ' '.join(f'{p[0]}.' for p in first.split() if p and p[0].isalpha())
        authors.append(f'{last}, {initials}'.rstrip(', ').rstrip() if initials else last)
    if not authors:
        return ''
    if len(authors) == 1:
        return authors[0]
    if len(authors) == 2:
        return f'{authors[0]}, & {authors[1]}'
    return ', '.join(authors[:-1]) + ', & ' + authors[-1]


def format_bib_body(entry):
    """新仕様 (tex_to_md.md) の参考文献本文を組み立てる.
    出力例:
        Kitaoka, Akira, Minimization of ... real coordinate space, 2025, arXiv preprint arXiv:2504.15566

    フィールドはカンマ区切り (空のフィールドはスキップ).
    著者名の "and" は ", " に置換して列挙形式にする．
    末尾のピリオドは付けない．
    """
    author_raw = entry.get('author', '').strip()
    # "A and B and C" -> "A, B, C"
    author = re.sub(r'\s+and\s+', ', ', author_raw) if author_raw else ''
    year   = entry.get('year', '').strip()
    title  = entry.get('title', '').strip()
    source_field = (entry.get('journal') or entry.get('booktitle')
                    or entry.get('institution') or entry.get('publisher')
                    or '').strip()

    # ソース (ジャーナル等) に volume / number / pages を付加
    src_segments = []
    if source_field:
        src_segments.append(source_field)
    vol   = entry.get('volume', '').strip()
    num   = entry.get('number', '').strip()
    pages = entry.get('pages', '').strip()
    if vol and num:
        src_segments.append(f'{vol}({num})')
    elif vol:
        src_segments.append(vol)
    if pages:
        src_segments.append(pages)
    source = ', '.join(src_segments)

    parts = []
    if author: parts.append(author)
    if title:  parts.append(title)
    if year:   parts.append(year)
    if source: parts.append(source)
    return ', '.join(parts)


def collect_cited_keys(content):
    """convert_citations 通過後の content から (#ref-KEY) を抜き出す．"""
    return set(re.findall(r'\(#ref-([^)\s]+)\)', content))


# ====================================================================
# 8-app. \appendix の文字 / \bibliographystyle / \bibliography を md から消す
# ====================================================================
def remove_appendix_marker(content):
    """\\appendix というコマンドは md に書かない．"""
    content = re.sub(
        r'```\{=latex\}\s*\n\\appendix\s*\n```\s*\n?',
        '', content,
    )
    content = re.sub(r'`\\appendix`\{=latex\}', '', content)
    content = re.sub(r'\\appendix\b\s*', '', content)
    return content


def replace_bibliography(content, cited_keys, bib_entries):
    """\\bibliographystyle / \\bibliography を md から消し,
    cited_keys に対応する文献を apalike 形式の "# 参考文献" として挿入する．"""

    # \bibliographystyle{...} は md に書かない
    content = re.sub(
        r'```\{=latex\}\s*\n\\bibliographystyle\s*\{[^}]*\}\s*\n```\s*\n?',
        '', content,
    )
    content = re.sub(r'`\\bibliographystyle\{[^}]*\}`\{=latex\}\s*', '', content)
    content = re.sub(r'\\bibliographystyle\s*\{[^}]*\}\s*', '', content)

    # 参考文献ブロック組み立て (cited のみ / 無ければ全件)
    if bib_entries:
        keys = sorted(k for k in cited_keys if k in bib_entries) \
               if cited_keys else sorted(bib_entries.keys())
    else:
        keys = []

    if keys:
        # 仕様 (tex_to_md.md):
        #   [<a id="ref-kitaoka2025minimization">Kitaoka 2025</a>] Kitaoka, Akira, Minimization ..., 2025, arXiv preprint arXiv:2504.15566
        # の形式で参考文献を組み立てる．
        # - <a> の中身は引用時の表示と同じ "著者姓 西暦"
        # - <a> の後ろの本文はカンマ区切り (著者, タイトル, 年, ソース)
        # - リスト bullet ('- ') は付けない
        lines = ['# 参考文献', '']
        for k in keys:
            display = _cite_display(k, bib_entries)
            body    = format_bib_body(bib_entries[k])
            if body:
                lines.append(f'[<a id="ref-{k}">{display}</a>] {body}')
            else:
                lines.append(f'[<a id="ref-{k}">{display}</a>]')
            lines.append('')
        bib_block = '\n'.join(lines).rstrip() + '\n'
    else:
        bib_block = ''

    # \bibliography{...} の位置を bib_block で置き換える
    pat_raw = re.compile(
        r'```\{=latex\}\s*\n\\bibliography\s*\{[^}]*\}\s*\n```'
    )
    pat_inline = re.compile(r'`\\bibliography\{[^}]*\}`\{=latex\}')
    pat_plain  = re.compile(r'\\bibliography\s*\{[^}]*\}')

    if pat_raw.search(content):
        content = pat_raw.sub(bib_block, content, count=1)
    elif pat_inline.search(content):
        content = pat_inline.sub(bib_block, content, count=1)
    elif pat_plain.search(content):
        content = pat_plain.sub(bib_block, content, count=1)
    elif bib_block:
        content = content.rstrip() + '\n\n' + bib_block + '\n'

    # 念のため残骸も消す
    content = pat_raw.sub('', content)
    content = pat_inline.sub('', content)
    content = pat_plain.sub('', content)
    return content


# ====================================================================
# 9-pre. パイプテーブルをコンパクト形式に整形
#   pandoc は cell をスペースで pad して横幅をそろえた pipe table を出すが,
#   仕様 (tex_to_md.md) の出力例は
#       |トマト|きゅうり|なす|
#       |:---|:---:|---:|
#       |hoge|hoge|hoge|
#   のように pad 無し / 区切り行は :--- / :---: / ---: で固定．
#   ここで pandoc の表をその形式に揃える．
# ====================================================================
_TABLE_SEP_RE = re.compile(
    r'^\s*\|?\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)+\|?\s*$'
)


def _compact_table_block(block):
    def split_row(line):
        s = line.strip()
        if s.startswith('|'):
            s = s[1:]
        if s.endswith('|'):
            s = s[:-1]
        return [c.strip() for c in s.split('|')]

    if len(block) < 2:
        return block

    header   = split_row(block[0])
    sep      = split_row(block[1])
    body     = [split_row(ln) for ln in block[2:]]
    n_cols   = len(header)

    aligns = []
    for cell in sep:
        c = cell.strip()
        left  = c.startswith(':')
        right = c.endswith(':')
        if left and right:
            aligns.append(':---:')
        elif right:
            aligns.append('---:')
        elif left:
            aligns.append(':---')
        else:
            aligns.append('---')
    # ヘッダ列数に合わせる
    while len(aligns) < n_cols:
        aligns.append('---')
    aligns = aligns[:n_cols]

    def pad(row):
        if len(row) < n_cols:
            row = row + [''] * (n_cols - len(row))
        return row[:n_cols]

    out = ['|' + '|'.join(header) + '|',
           '|' + '|'.join(aligns) + '|']
    for row in body:
        # 全セル空の行はスキップ (LaTeX ソースの単独 "\\" による空行など)
        if not any(cell.strip() for cell in row):
            continue
        out.append('|' + '|'.join(pad(row)) + '|')
    return out


def compact_tables(content):
    lines = content.split('\n')
    out, i, n = [], 0, len(lines)
    while i < n:
        if (i + 1 < n
                and lines[i].lstrip().startswith('|')
                and _TABLE_SEP_RE.match(lines[i + 1])):
            j = i + 1
            while j < n and lines[j].lstrip().startswith('|'):
                j += 1
            out.extend(_compact_table_block(lines[i:j]))
            i = j
        else:
            out.append(lines[i])
            i += 1
    return '\n'.join(out)


# ====================================================================
# 9. minipage は無視 (タグだけ除去して中身は残す)
# ====================================================================
def strip_minipage(content):
    patterns = [
        r'`\\begin\{minipage\}(?:\[[^\]]*\])?(?:\{[^}]*\})?`\{=latex\}',
        r'`\\end\{minipage\}`\{=latex\}',
        r'\\begin\{minipage\}(?:\[[^\]]*\])?(?:\{[^}]*\})?',
        r'\\end\{minipage\}',
    ]
    for p in patterns:
        content = re.sub(p, '', content)
    return content


# ====================================================================
# 10. 見出しに section 番号を付ける
#     "# タイトル"   -> "# 1 タイトル"  (appendix なら "# 付録 1 タイトル")
#     "## タイトル"  -> "## 1.1 タイトル"
# ====================================================================
def apply_heading_numbers(content, headings):
    if not headings:
        return content

    lines = content.split('\n')
    out = []
    in_comment = False
    in_code = False
    h_idx = 0

    for line in lines:
        stripped = line.strip()
        if stripped.startswith('```'):
            in_code = not in_code
            out.append(line)
            continue
        if in_code:
            out.append(line)
            continue
        # HTML コメント (<!-- ... -->) 内は heading として扱わない
        # (タイトルブロックの "# title name" に節番号が付かないようにする)
        if not in_comment and stripped.startswith('<!--'):
            in_comment = True
            out.append(line)
            if '-->' in stripped[4:]:
                in_comment = False
            continue
        if in_comment:
            out.append(line)
            if '-->' in line:
                in_comment = False
            continue

        m = re.match(r'^(#{1,2})\s+(.*)$', line)
        if m and h_idx < len(headings):
            h = headings[h_idx]
            hashes = m.group(1)
            title = m.group(2).rstrip()
            if h['level'] == len(hashes):
                if h['level'] == 1:
                    prefix = f'付録 {h["number"]}' if h['is_appendix'] else h['number']
                else:
                    prefix = h['number']
                anchors = ''.join(f' <a id="{lab}"></a>' for lab in h.get('labels', []))
                out.append(f'{hashes} {prefix} {title}{anchors}')
                h_idx += 1
                continue
        out.append(line)

    return '\n'.join(out)


# ====================================================================
# 10b. 空の raw_tex フェンスを除去する
#   pandoc は \maketitle 等のスタンドアロンコマンドを
#       ```{=latex}
#       \maketitle
#       ```
#   のような fenced raw_tex として出すことがある．\maketitle を文字列として
#   除去するだけだと
#       ```{=latex}
#
#       ```
#   が残ってしまうので, 空 (空白行のみ) のフェンスはまとめて消す．
# ====================================================================
def remove_empty_raw_tex(content):
    # fenced 形式: ```{=latex}\n<空白のみ>\n```
    content = re.sub(
        r'```\{=latex\}\s*\n[ \t]*\n```\s*(?:\n|$)',
        '', content, flags=re.MULTILINE,
    )
    # fenced で内容が完全に空 (改行のみ) のケース
    content = re.sub(r'```\{=latex\}\s*```\s*(?:\n|$)', '', content)
    # inline 空: ``{=latex}
    content = re.sub(r'``\{=latex\}', '', content)
    return content


# ====================================================================
# 11. タイトルブロック (:::message) を先頭に挿入
# ====================================================================
def insert_title_block(content, title, authors):
    # \maketitle / \title / \author の残骸を除去
    content = re.sub(r'`\\maketitle`\{=latex\}', '', content)
    content = re.sub(r'\\maketitle\b',           '', content)
    content = re.sub(r'`\\title\{[^}]*\}`\{=latex\}',  '', content)
    content = re.sub(r'`\\author\{[^}]*\}`\{=latex\}', '', content)

    if title is None:
        return content

    # 仕様 (tex_to_md.md):
    #   <!--
    #   # title name
    #   - author name1, author name2, ...
    #   -->
    block = ['<!--', f'# {title}']
    if authors:
        block.append('- ' + ', '.join(authors))
    block.append('-->')
    return '\n'.join(block) + '\n\n' + content.lstrip('\n')


# ====================================================================
# main
# ====================================================================
def main():
    tex_path  = Path(sys.argv[1])
    md_path   = Path(sys.argv[2])
    bib_paths = [Path(p) for p in sys.argv[3:]]

    parsed = parse_tex(tex_path)
    labels = parsed['labels']
    bib_entries = {}
    for bp in bib_paths:
        bib_entries.update(parse_bib(bp))

    content = md_path.read_text(encoding='utf-8')

    # 順序が重要:
    #  0. minipage は最初に除去．
    #  1. align 整形は素の文字列置換なので前段．
    #  2. 数式アンカー / tag は ::: ブロックを引用符化する前に．
    #  3. ::: ブロック確定．
    #  4. \Cref 等の参照変換．
    #  5. \cite 系を md 参照リンクに → cited_keys 収集．
    #  6. 色．
    #  7. 見出しに section 番号 (\appendix 除去 / 参考文献挿入の前に行う:
    #     参考文献の "# 参考文献" 見出しに番号がつかないようにするため)．
    #  8. \appendix の文字を md から削除．
    #  9. \bibliographystyle / \bibliography を 参考文献セクションに置換．
    # 10. タイトルブロックを先頭に挿入．
    content = strip_minipage(content)
    content = compact_tables(content)
    content = fix_align_aligned(content)
    content = strip_tex_comments_in_math(content)
    content = add_equation_anchors_and_tags(content, labels)
    content = finalize_blocks(content, labels)
    content = convert_refs(content, labels)
    content = convert_citations(content, bib_entries)
    cited_keys = collect_cited_keys(content)
    content = transform_textcolor(content)
    content = apply_heading_numbers(content, parsed['headings'])
    content = remove_appendix_marker(content)
    content = replace_bibliography(content, cited_keys, bib_entries)
    content = insert_title_block(content, parsed['title'], parsed['authors'])
    content = remove_empty_raw_tex(content)

    md_path.write_text(content, encoding='utf-8')


main()
PYEOF

# ---- 完了 ----
info "完了: ${MD}"
