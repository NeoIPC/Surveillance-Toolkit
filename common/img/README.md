# Shared images

## The NeoIPC logo

| file | lockup | provenance |
|---|---|---|
| `NeoIPC-Logo.svg` | vertical — mark above wordmark | converted from the Illustrator master, then reduced to 18 paths, two brand colours and one stylesheet |
| `NeoIPC-Logo-Horizontal.svg` | horizontal — mark left, wordmark right | the same vector components, recomposed |

Both are used by **inlining**, not by reference. prawn-svg — which draws every SVG in the published PDF —
resolves an `<image>` href relative to *the SVG file* rather than to the document embedding it, so a
referenced logo binds each figure to the directory it happens to sit in. Inlining also keeps a generated
sheet entirely vector, at any print size.

Colours are the brand's two primaries from the visual guideline, **`#0083c1`** (PANTONE 7460 C) and
**`#ff9015`** (PANTONE 1495 C), applied through the classes `brand-blue` and `brand-orange`. The
converted artwork carried `#0083c2` / `#ff9016`, a rounding artifact of the colour conversion, and those
are normalised to the guideline's values rather than kept.

**A consumer must define those two classes.** The inlined paths carry the class names and no fill of
their own, so a document that inlines the artwork without the rules renders the logo in the default
fill — black — and says nothing about it. That is not hypothetical; it happened the first time.

### The horizontal lockup is reconstructed, and nothing about it was chosen

There is no vector source for the horizontal lockup; the official artwork for it is the raster
`doc/protocol/img/LOGO_NEOIPC_2.png`. So the SVG is composed from the vertical lockup's own vector
components, and the only two values that composition adds — the gap between the mark and the wordmark,
and the wordmark's vertical offset — are **measured off that official raster**: `0.2096` and `0.2222`,
each as a fraction of the mark's width. The visual guideline forbids altering the spacing between the
elements or their proportions, so neither figure is a design decision.

The reconstruction is checkable, and it checks out: the components' own aspect ratios agree with the
official raster (mark 1.135 against 1.125, wordmark 4.29 against 4.29), and the composed lockup comes to
3.519 against the raster's 3.507 — a third of a percent, which is the antialiasing.

### Size

The guideline sets a minimum of **40 mm** for the horizontal lockup and **30 mm** for the vertical one,
below which it is not legible. Generated sheets place the horizontal lockup at 42 mm.
