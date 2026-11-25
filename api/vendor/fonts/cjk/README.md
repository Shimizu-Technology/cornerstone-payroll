# Payroll CJK

Payroll CJK is derived from [Noto Sans CJK SC 2.004](https://github.com/notofonts/noto-cjk/tree/Sans2.004/Sans).
The upstream font covers Han ideographs, Japanese kana, Korean Hangul and
CJK punctuation. Simplified Chinese glyph shapes are used for shared Han
characters. See [OFL.txt](OFL.txt) for the SIL Open Font License 1.1.

This single regular TrueType face covers all three scripts without shipping
separate regional faces or weights. Liberation Sans and the invoice theme
fonts remain the primary faces. Prawn embeds only the glyph subsets used
in a PDF.

The font was built with fontTools by instantiating the upstream
`Sans/Variable/TTF/NotoSansCJKsc-VF.ttf` at `wght=400`, then running
`pyftsubset` with `--no-hinting --layout-features=''` and these Unicode
ranges. The derived face was renamed Payroll CJK.

```text
U+2E80-2FFF,U+3000-33FF,U+3400-4DBF,U+4E00-9FFF,U+A960-A97F,U+AC00-D7FF,U+1100-11FF,U+F900-FAFF,U+FE10-FE6F,U+FF00-FFEF,U+1B000-1B16F,U+20000-323AF
```
