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

-- Only the LaTeX writer is affected; HTML and DOCX take the math as-is.
if not FORMAT:match("latex") then
  return {}
end

--- Insert `\leavevmode` before every `\\` that directly follows display math.
---
--- Applied to raw LaTeX only, so document prose written by an author is never
--- touched — the pattern exists in gt's generated footnote blocks.
---
--- @param text string raw LaTeX
--- @return string, integer the patched LaTeX and the number of substitutions
local function guard_display_math_breaks(text)
  -- `%$%$` matches the closing `$$`; `%s*` covers a line break between the
  -- math and the `\\` that gt may or may not emit.
  return text:gsub("(%$%$)(%s*)(\\\\)", "%1%2\\leavevmode%3")
end

function RawBlock(el)
  if el.format ~= "latex" and el.format ~= "tex" then
    return nil
  end
  local patched, count = guard_display_math_breaks(el.text)
  if count == 0 then
    return nil
  end
  return pandoc.RawBlock(el.format, patched)
end
