# Invoice theme fonts

Embedded in themed invoice PDFs (`app/services/invoice_pdf/fonts.rb`). Each
family keeps its SIL Open Font License 1.1 text as `OFL.txt` in its folder.

| Folder | Family | Used by | Weights |
| --- | --- | --- | --- |
| `inter/` | Inter | Classic, Modern body | 300, 400, 400 italic, 500, 600, 700 |
| `space-grotesk/` | Space Grotesk | Modern headings | 500, 600, 700 |
| `source-serif-4/` | Source Serif 4 | Professional headings | 400, 400 italic, 600, 600 italic, 700 |
| `source-sans-3/` | Source Sans 3 | Professional body | 400, 400 italic, 600, 700 |
| `manrope/` | Manrope | Banner | 400, 500, 600, 700, 800 |

Source: static TTF instances of the Google Fonts releases, taken from the
`@expo-google-fonts/*` npm packages (inter 0.4.2, space-grotesk 0.4.1,
source-serif-4 0.4.2, source-sans-3 0.4.2, manrope 0.4.3). Static instances
are needed because Prawn cannot select instances of a variable font.

Prawn subsets each font, so a PDF embeds only the glyphs it uses. If a family
fails to load, invoices fall back to Liberation Sans (`liberation-sans/`),
which also supplies any character a theme font lacks.
