-- Pandoc does not emit \phantomsection for unnumbered (starred) LaTeX
-- sections.  Without it hyperref's \@currentHref is stale, so every
-- \addcontentsline bookmark points to the last *numbered* heading.
-- Inserting \phantomsection just before the heading creates a fresh
-- PDF destination that the bookmark can target.

function Header(el)
  if el.classes:includes("unnumbered") and FORMAT:match("latex") then
    return {
      pandoc.RawBlock("latex", "\\phantomsection"),
      el
    }
  end
end
