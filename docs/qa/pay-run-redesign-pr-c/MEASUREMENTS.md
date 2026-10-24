# Measurements

Before is d3b150b8; after is application source after the lead/CodeRabbit review fixes (includes ce12d1da). The comparison includes #385: between d3b150b8 and the PR base ce12d1da, draft-gross.ts changed to round each wage line to cents before summing. Draft worksheet estimates can therefore differ by cents; this pair does not isolate C. Saved historical payroll values are not recomputed by this presentation. Same copied fixtures and rendered-style probes as the original audit. Scroll height is the Payroll tab only, in the main scroll container. Results y is the visible table on desktop and Employee payroll heading on phone. Collapsed steps intentionally exclude their contents from visible counts.

| State / width | Scroll px (screens), before → C | Totals y | Results y | Cards | Buttons | Callouts |
| --- | --- | --- | --- | --- | --- | --- |
| connected-committed-1280-work | 2255 (2.82) → 1358 (1.7) | 164 → 164 | 1116 → 582 | 7 → 5 | 46 → 57 | 3 → 0 |
| connected-draft-1280-work | 3263 (4.08) → 2102 (2.63) | 164 → 164 | — → — | 6 → 4 | 14 → 24 | 4 → 1 |
| adjustment-1280-work | 1891 (2.36) → 1358 (1.7) | 164 → 164 | 1015 → 582 | 4 → 4 | 6 → 12 | 2 → 0 |
| manual-committed-1280-work | 1646 (2.06) → 1358 (1.7) | 164 → 164 | 647 → 582 | 4 → 4 | 8 → 15 | 3 → 0 |
| fresh-draft-1280-work | 1109 (1.39) → 1388 (1.74) | 164 → 164 | — → — | 3 → 3 | 6 → 12 | 0 → 0 |
| fresh-calculated-1280-work | 2194 (2.74) → 1270 (1.59) | 164 → 164 | 569 → 582 | 5 → 5 | 9 → 17 | 2 → 0 |
| fresh-approved-1280-work | 1742 (2.18) → 800 (1) | 164 → 164 | 569 → — | 4 → 4 | 5 → 12 | 2 → 0 |
| connected-committed-390-work | 4558 (5.4) → 1892 (2.24) | 284 → 284 | 1483 → 706 | 7 → 5 | 46 → 62 | 3 → 0 |
| connected-draft-390-work | 7421 (8.79) → 4533 (5.37) | 240 → 240 | — → — | 6 → 4 | 14 → 24 | 4 → 1 |
| adjustment-390-work | 2748 (3.26) → 1329 (1.57) | 240 → 240 | 1138 → 662 | 4 → 4 | 6 → 14 | 2 → 0 |
| manual-committed-390-work | 2687 (3.18) → 1482 (1.76) | 220 → 220 | 690 → 642 | 4 → 4 | 8 → 18 | 3 → 0 |
| fresh-draft-390-work | 1900 (2.25) → 2127 (2.52) | 220 → 220 | — → — | 3 → 3 | 6 → 12 | 0 → 0 |
| fresh-calculated-390-work | 3273 (3.88) → 1201 (1.42) | 220 → 220 | 781 → 642 | 5 → 5 | 9 → 19 | 2 → 0 |
| fresh-approved-390-work | 2419 (2.87) → 867 (1.03) | 220 → 220 | 781 → — | 4 → 4 | 5 → 14 | 2 → 0 |

The JSON includes the original c-design-capture measurements for the four matching historic fixtures. Those captures predate A/B and use the old all-in-one page. The d3b150b8 pair also includes the #385 calculator change described above.
