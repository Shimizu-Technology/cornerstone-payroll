# Liberation Sans 2.1.5

Embedded in every generated PDF so employee and contractor names print with
their real characters (for example "Wiśniewska", "Hagåtña", "Nguyễn").
Prawn's built-in Helvetica only covers Windows-1252.

- Source: https://github.com/liberationfonts/liberation-fonts/releases/tag/2.1.5
  (`liberation-fonts-ttf-2.1.5.tar.gz`)
- License: SIL Open Font License 1.1 (`LICENSE`)
- Metric-compatible with Arial/Helvetica, so existing check, stub and form
  layouts keep their measurements.
- Covers Latin (including Latin Extended and Vietnamese), Greek and Cyrillic.
  It has no CJK or Hangul glyphs; those characters print as empty boxes
  instead of failing the PDF.

Prawn subsets the font, so each PDF embeds only the glyphs it uses.
