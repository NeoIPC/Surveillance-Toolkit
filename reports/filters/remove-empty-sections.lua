-- Remove section headers (level 2) that have no content before the next header of same/higher level.
-- When a section is deemed empty, also drop the structural blocks (page breaks, raw blocks,
-- horizontal rules) between the empty header and the next level-2-or-higher header so we don't
-- leave orphaned blank pages / spacing behind.
function Pandoc(doc)
  local new_blocks = pandoc.List()
  local i = 1

  while i <= #doc.blocks do
    local block = doc.blocks[i]

    if block.t == "Header" and block.level == 2 then
      -- Scan forward for the next header of level <= 2, tracking whether any content appears.
      local has_content = false
      local next_header_idx = #doc.blocks + 1
      local j = i + 1

      while j <= #doc.blocks do
        local next_block = doc.blocks[j]

        if next_block.t == "Header" and next_block.level <= 2 then
          next_header_idx = j
          break
        end

        if next_block.t ~= "Null" and
           next_block.t ~= "HorizontalRule" and
           next_block.t ~= "RawBlock" and
           string.match(pandoc.utils.stringify(next_block), "%S") then
          has_content = true
        end

        j = j + 1
      end

      if has_content then
        new_blocks:insert(block)
        i = i + 1
      else
        i = next_header_idx
      end
    else
      new_blocks:insert(block)
      i = i + 1
    end
  end

  doc.blocks = new_blocks
  return doc
end
