-- Remove section headers (level 2) that have no content before the next header of same/higher level
function Pandoc(doc)
  local new_blocks = pandoc.List()
  local i = 1
  
  while i <= #doc.blocks do
    local block = doc.blocks[i]
    
    -- Check if this is a level 2 header
    if block.t == "Header" and block.level == 2 then
      -- Look ahead to see if there's any content before next header
      local has_content = false
      local j = i + 1
      
      while j <= #doc.blocks do
        local next_block = doc.blocks[j]
        
        -- Stop at next header of level 2 or higher
        if next_block.t == "Header" and next_block.level <= 2 then
          break
        end
        
        -- Check for actual content (not just PageBreak or other structural elements)
        if next_block.t ~= "Null" and 
           next_block.t ~= "HorizontalRule" and
           next_block.t ~= "RawBlock" and
           string.match(pandoc.utils.stringify(next_block), "%S") then
          has_content = true
          break
        end
        
        j = j + 1
      end
      
      -- Only include header if it has content
      if has_content then
        new_blocks:insert(block)
      end
    else
      new_blocks:insert(block)
    end
    
    i = i + 1
  end
  
  doc.blocks = new_blocks
  return doc
end
