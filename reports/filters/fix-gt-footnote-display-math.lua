-- gt renders a table's footnote block as raw LaTeX, joining the individual
-- footnote lines with `\\`.  Where a footnote is a rate formula it is display
-- math (`$$...$$`), so the block contains `$$\\` — and display math ends the
-- paragraph, leaving that `\\` with no line to end.
--
-- Untagged LaTeX tolerates this silently.  Under the `\DocumentMetadata`
-- tagging that PDF/UA requires, latex-lab tracks paragraph structure strictly
-- and the same input aborts the compile with "There's no line here to end".
--
-- `\leavevmode` starts a horizontal line so the following `\\` has one to end.
-- Inserting it is additive: gt's line break is preserved rather than dropped,
-- and the typeset result is unchanged (verified by comparing the extracted
-- text layout of both forms).

-- Only the LaTeX writer reaches this construct. The HTML path is unaffected
-- because MathJax/KaTeX consumes the delimiters in the rendered DOM; the DOCX
-- path has its own, separate defect (the same footnotes reach Word as literal
-- LaTeX because gt's text is never parsed into a Math node) which this filter
-- does not address.
if not FORMAT:match("latex") then
  return {}
end

--- Insert `\leavevmode` before a `\\` that directly follows display math.
---
--- Scoped to gt's footnote block rather than to raw LaTeX generally: a
--- ```{=latex} fence written by an author is also a RawBlock, so matching on
--- the construct alone would rewrite hand-written LaTeX too. gt wraps the
--- footnote block in a `\begin{minipage}` immediately after the table, which is
--- the anchor used here.
---
--- @param text string raw LaTeX
--- @return string, integer the patched LaTeX and the number of substitutions
local function guard_display_math_breaks(text)
  -- `%$%$` matches the closing `$$`; `[ \t]*` covers optional spacing before
  -- the `\\`. Deliberately not `%s*`, which would span blank lines and let the
  -- match jump from a formula into an unrelated later line.
  return text:gsub("(%$%$)([ \t]*)(\\\\)", "%1%2\\leavevmode%3")
end

function RawBlock(el)
  if el.format ~= "latex" and el.format ~= "tex" then
    return nil
  end
  -- gt emits its footnotes inside a minipage; without this the filter would
  -- also rewrite author-written raw-LaTeX blocks.
  if not el.text:find("\\begin{minipage}", 1, true) then
    return nil
  end
  local patched, count = guard_display_math_breaks(el.text)
  if count == 0 then
    return nil
  end
  return pandoc.RawBlock(el.format, patched)
end
