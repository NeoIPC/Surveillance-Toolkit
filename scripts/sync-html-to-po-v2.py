#!/usr/bin/env python3
"""Sync translations from localized HTML files to .po files - enhanced version."""

import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import argparse


def extract_text_elements(html_content: str) -> List[Tuple[str, str, str]]:
    """
    Extract text elements from HTML with context.
    Returns list of (element_type, identifier, text) tuples.
    """
    elements = []
    
    # Title
    match = re.search(r'<title>([^<]+)</title>', html_content)
    if match:
        elements.append(('title', 'page_title', match.group(1).strip()))
    
    # H1 title
    match = re.search(r'<h1 class="title">([^<]+)</h1>', html_content)
    if match:
        elements.append(('h1_title', 'header_title', match.group(1).strip()))
    
    # DT labels (definition list terms) - preserve trailing colon
    for match in re.finditer(r'<dt>([^<]+)</dt>', html_content):
        label = match.group(1).strip()
        # Strip trailing colon for consistency across languages
        label_no_colon = label.rstrip(':')
        elements.append(('dt', label_no_colon.lower().replace(' ', '_'), label_no_colon))
    
    # H1 headings with IDs
    for match in re.finditer(r'<h1 id="([^"]+)">([^<]+)</h1>', html_content):
        elements.append(('h1', match.group(1), match.group(2).strip()))
    
    # H2 headings with IDs
    for match in re.finditer(r'<h2 id="([^"]+)">([^<]+)</h2>', html_content):
        elements.append(('h2', match.group(1), match.group(2).strip()))
    
    # Table captions (just the descriptive text) - handle multiple languages
    for match in re.finditer(r'(?:Table|Tabelle|Tabella|Tabla|Tabel|Πίνακας)&nbsp;\d+:\s*([^<\n]+)', html_content):
        text = match.group(1).strip()
        elements.append(('table_caption', f'tbl_{len(elements)}', text))
    
    # Table headers - extract text from th elements
    for match in re.finditer(r'<th[^>]*>(.*?)</th>', html_content, re.DOTALL):
        full_text = match.group(1)
        # Remove HTML tags (span, sup, etc.)
        clean_text = re.sub(r'<[^>]+>', '', full_text)
        # Normalize whitespace and nbsp
        clean_text = re.sub(r'&nbsp;', ' ', clean_text)
        clean_text = re.sub(r'\s+', ' ', clean_text).strip()
        # Remove footnote markers
        clean_text = re.sub(r'[‖†‡§¶*]+$', '', clean_text).strip()
        # Skip empty headers or very long ones (likely not translatable labels)
        if clean_text and len(clean_text) < 100:
            elements.append(('table_header', f'th_{len(elements)}', clean_text))
    
    # Table footnotes - extract text from gt_footnote td elements
    for match in re.finditer(r'<td[^>]*class="[^"]*gt_footnote[^"]*"[^>]*>(.*?)</td>', html_content, re.DOTALL):
        full_text = match.group(1)
        # Remove HTML tags (span, sup, etc.) but keep the content
        clean_text = re.sub(r'<[^>]+>', '', full_text)
        # Normalize whitespace and nbsp
        clean_text = re.sub(r'&nbsp;', ' ', clean_text)
        clean_text = re.sub(r'\s+', ' ', clean_text).strip()
        if clean_text:
            elements.append(('table_footnote', f'tbl_fn_{len(elements)}', clean_text))
    
    # LaTeX formula text - extract \text{...} content from math display spans
    # These appear in formulas like: $$\text{Surgical Procedure Rate} = \frac{\text{No of procedures}}{\text{No of Patients}} \times 100$$
    for match in re.finditer(r'<span class="math display">\$\$(.*?)\$\$</span>', html_content, re.DOTALL):
        formula = match.group(1)
        # Extract all \text{...} content
        for text_match in re.finditer(r'\\text\{([^}]+)\}', formula):
            text_content = text_match.group(1).strip()
            if text_content:
                elements.append(('latex_text', f'latex_{len(elements)}', text_content))
    
    # Paragraphs - extract text from <p> tags
    # These contain body text with inline R code results
    for match in re.finditer(r'<p>(.*?)</p>', html_content, re.DOTALL):
        full_text = match.group(1)
        # Replace cross-reference links with their IDs (matching msgid format)
        # <a href="#fig-bw" class="quarto-xref">Figure 1</a> -> @fig-bw
        # <a href="#tbl-infections" class="quarto-xref">Table 3</a> -> @tbl-infections
        clean_text = re.sub(
            r'<a href="#([^"]+)" class="quarto-xref">[^<]*</a>',
            r'@\1',
            full_text
        )
        # Remove remaining HTML tags (span, etc.)
        clean_text = re.sub(r'<[^>]+>', '', clean_text)
        # Normalize whitespace and nbsp
        clean_text = re.sub(r'&nbsp;', ' ', clean_text)
        clean_text = re.sub(r'\s+', ' ', clean_text).strip()
        # Only extract non-empty paragraphs
        if clean_text:
            elements.append(('paragraph', f'p_{len(elements)}', clean_text))
    
    # Figure captions - extract and split into sentences
    for match in re.finditer(r'<figcaption[^>]*>(.*?)</figcaption>', html_content, re.DOTALL):
        full_text = match.group(1)
        # Remove HTML tags
        clean_text = re.sub(r'<[^>]+>', '', full_text)
        # Normalize whitespace and nbsp
        clean_text = re.sub(r'&nbsp;', ' ', clean_text)
        clean_text = re.sub(r'\s+', ' ', clean_text).strip()
        
        # Split by ". " to get sentences (but keep the period)
        # First check if there's a "Figure X:" or "Table X:" prefix
        # Supported: Figure (EN), Figura (ES/IT), Joonis (ET), Σχήμα (GR), Abbildung (DE)
        #            Table (EN), Tabelle (DE), Tabla (ES), Tabella (IT), Tabel (ET), Πίνακας (GR)
        prefix_match = re.match(r'^((?:Figure|Figura|Joonis|Σχήμα|Abbildung|Πίνακας|Table|Tabelle|Tabla|Tabella|Tabel)\s*\d+:)\s*(.+)$', clean_text, re.IGNORECASE)
        if prefix_match:
            prefix = prefix_match.group(1)
            caption_body = prefix_match.group(2)
            
            # Add the first sentence (description) as one element
            first_sent_match = re.match(r'^([^.]+\.)', caption_body)
            if first_sent_match:
                first_sent = first_sent_match.group(1).strip()
                elements.append(('figcaption_first', f'fig_{len(elements)}', first_sent))
                
                # Get the rest
                rest = caption_body[len(first_sent):].strip()
                if rest:
                    # Split remaining by ". " followed by capital letter (including Greek uppercase)
                    remaining_sents = re.split(r'\.\s+(?=[A-ZΑ-Ω])', rest)
                    for i, sent in enumerate(remaining_sents):
                        if sent.strip():
                            if not sent.endswith('.'):
                                sent = sent + '.'
                            elements.append(('figcaption_sent', f'fig_{len(elements)}_{i}', sent.strip()))
            else:
                # No period found - treat entire caption body as single sentence
                # This handles table captions like "Tabella 1: Title without period"
                if caption_body.strip():
                    elements.append(('figcaption_first', f'fig_{len(elements)}', caption_body.strip()))
        else:
            # No figure/table prefix, just add as single element
            elements.append(('figcaption', f'fig_{len(elements)}', clean_text))
    
    return elements


def create_translation_map(en_html: str, target_html: str) -> Dict[str, str]:
    """
    Create a mapping from English text to translated text.
    Matches elements by their type and position within that type.
    """
    en_elements = extract_text_elements(en_html)
    target_elements = extract_text_elements(target_html)
    
    translation_map = {}
    
    # Group elements by type
    en_by_type = {}
    target_by_type = {}
    
    for typ, _, text in en_elements:
        if typ not in en_by_type:
            en_by_type[typ] = []
        en_by_type[typ].append(text.strip())
    
    for typ, _, text in target_elements:
        if typ not in target_by_type:
            target_by_type[typ] = []
        target_by_type[typ].append(text.strip())
    
    # Match elements of the same type by position within that type
    for typ in en_by_type:
        if typ in target_by_type:
            en_texts = en_by_type[typ]
            target_texts = target_by_type[typ]
            
            for i, en_text in enumerate(en_texts):
                if i < len(target_texts):
                    translation_map[en_text] = target_texts[i]
                    
                    # Also add without trailing punctuation
                    en_key_no_punct = en_text.rstrip('.:!?')
                    if en_key_no_punct != en_text:
                        translation_map[en_key_no_punct] = target_texts[i]
    
    # Special case: English table_caption might be figcaption_first in other languages
    # (e.g., Italian renders table captions in figcaption tags)
    if 'table_caption' in en_by_type and 'figcaption_first' in target_by_type:
        en_table_caps = en_by_type['table_caption']
        target_fig_firsts = target_by_type['figcaption_first']
        
        # Match any table captions that weren't matched to figcaption_first entries that start with Table/Tabella
        for en_text in en_table_caps:
            if en_text not in translation_map:
                # Look for a matching figcaption_first that looks like a table caption
                for target_text in target_fig_firsts:
                    if target_text not in translation_map.values():
                        # Check if target starts with table-like keyword
                        if re.match(r'^(?:Table|Tabelle|Tabella|Tabla|Πίνακας)', target_text, re.IGNORECASE):
                            translation_map[en_text] = target_text
                            break
    
    return translation_map


def read_po_file(filepath: Path) -> List[Dict]:
    """Read and parse .po file."""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    entries = []
    # Split by double newline (entry separator)
    blocks = content.split('\n\n')
    
    for block in blocks:
        if not block.strip() or block.startswith('#, fuzzy'):
            continue
            
        lines = block.split('\n')
        entry = {
            'comments': [],
            'msgid': '',
            'msgstr': '',
            'original_block': block
        }
        
        i = 0
        while i < len(lines):
            line = lines[i]
            
            if line.startswith('#'):
                entry['comments'].append(line)
            elif line.startswith('msgid '):
                # Extract msgid (handle multiline)
                msgid_match = re.match(r'msgid\s+"(.*)"', line)
                if msgid_match:
                    msgid_text = msgid_match.group(1)
                    i += 1
                    while i < len(lines) and lines[i].startswith('"'):
                        msgid_text += '\n' + lines[i].strip('"')
                        i += 1
                    entry['msgid'] = msgid_text
                    continue
            elif line.startswith('msgstr '):
                # Extract msgstr (handle multiline)
                msgstr_match = re.match(r'msgstr\s+"(.*)"', line)
                if msgstr_match:
                    msgstr_text = msgstr_match.group(1)
                    i += 1
                    while i < len(lines) and lines[i].startswith('"'):
                        msgstr_text += '\n' + lines[i].strip('"')
                        i += 1
                    entry['msgstr'] = msgstr_text
                    continue
            
            i += 1
        
        if entry['msgid']:
            entries.append(entry)
    
    return entries


def unescape_string(s: str) -> str:
    """Unescape PO string."""
    s = s.replace('\\n', '\n')
    s = s.replace('\\t', '\t')
    s = s.replace('\\"', '"')
    s = s.replace('\\\\', '\\')
    return s


def escape_string(s: str) -> str:
    """Escape string for PO format."""
    s = s.replace('\\', '\\\\')
    s = s.replace('"', '\\"')
    s = s.replace('\n', '\\n')
    s = s.replace('\t', '\\t')
    return s


def normalize_for_matching(s: str) -> str:
    """Normalize string for fuzzy matching."""
    # Unescape first
    s = unescape_string(s)
    # Convert markdown links [text](url) to just text (to match HTML <a>text</a>)
    s = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', s)
    # Remove HTML tags (for comparison with source text that has markdown)
    s = re.sub(r'<a[^>]*>([^<]+)</a>', r'\1', s)
    # Remove multiple spaces
    s = re.sub(r'\s+', ' ', s)
    # Remove &nbsp;
    s = re.sub(r'&nbsp;', ' ', s)
    # Remove spaces between numbers and common units (g, kg, weeks, days, hours, etc.)
    # This handles differences like "1500 g" vs "1500g"
    s = re.sub(r'(\d+)\s*(g|kg|mg|μg|ml|l|%|weeks?|days?|hours?|minutes?|seconds?|months?|years?)\b', r'\1\2', s, flags=re.IGNORECASE)
    # Strip and lowercase
    return s.strip().lower()


def normalize_for_r_code_matching(s: str) -> str:
    """
    Normalize string for matching when inline R code is present.
    Replaces both R code placeholders and actual numbers with NUM placeholder.
    """
    s = normalize_for_matching(s)
    # Normalize quotes: curly quotes to straight quotes
    # Use chr() to ensure we get the actual Unicode characters
    s = s.replace(chr(8216), "'").replace(chr(8217), "'")  # ' and ' → '
    s = s.replace(chr(8220), '"').replace(chr(8221), '"')  # " and " → "
    # Replace R code patterns like `r dR$variableName` with NUM
    s = re.sub(r'`r\s+[^`]+`', 'NUM', s)
    # Replace standalone numbers (integers and decimals) with NUM
    # Use lookahead instead of \b at the end to handle cases like "39.2days"
    s = re.sub(r'\b\d+(?:[.,]\d+)?(?=\D|$)', 'NUM', s)
    # Remove spaces between NUM and units (after R code/number replacement)
    # This handles both "`r dR$var` days" → "NUM days" → "NUMdays"
    # and "39.2 days" → "39.2days" → "NUMdays"
    s = re.sub(r'NUM\s+(g|kg|mg|μg|ml|l|weeks?|days?|hours?|minutes?|seconds?|months?|years?)\b', r'NUM\1', s, flags=re.IGNORECASE)
    # Normalize NUM followed by % (percentage formatting varies)
    # "75.9 %" or "75.9%" both become "NUM"
    s = re.sub(r'NUM\s*[%]', 'NUM', s)
    return s


def reconstruct_with_r_code(msgid: str, en_html: str, trans_html: str) -> str:
    """
    Reconstruct translated msgstr by replacing numbers in trans_html with R code from msgid.
    
    Args:
        msgid: Source text with R code like `r dR$variable`
        en_html: English HTML with rendered values (e.g., 592, 2099, 0.28)
        trans_html: Translated HTML with same rendered values (e.g., 592, 2099, 0,28)
    
    Returns:
        Translated text with R code restored
    """
    # Extract R code blocks from msgid in order
    r_code_blocks = re.findall(r'`r\s+[^`]+`', msgid)
    
    if not r_code_blocks:
        return trans_html
    
    # Normalize quotes in trans_html
    result = trans_html.replace(''', "'").replace(''', "'").replace('"', '"').replace('"', '"')
    
    # Find numbers in English HTML (in order), excluding those in cross-references
    # Pattern to detect numbers: integers (including 4-digit like 2099) and decimals with comma or period
    en_numbers = []
    for match in re.finditer(r'\b\d+(?:[,.]\d+)?\b', en_html):
        num_text = match.group(0)
        pos = match.start()
        
        # Check if this number is inside a cross-reference link
        # Look backwards for <a and forwards for </a>
        before = en_html[:pos]
        after = en_html[pos:]
        
        # Find the last < before this position
        last_open_tag_pos = before.rfind('<')
        if last_open_tag_pos != -1:
            # Check if it's an <a> tag that hasn't been closed yet
            tag_content = en_html[last_open_tag_pos:pos]
            if '<a ' in tag_content and '</a>' not in tag_content:
                # This number is inside an <a> tag - skip it
                continue
        
        en_numbers.append((num_text, match.start(), match.end()))
    
    # Find corresponding numbers in translated HTML (excluding cross-references)
    trans_numbers = []
    for match in re.finditer(r'\b\d+(?:[,.]\d+)?\b', result):
        num_text = match.group(0)
        pos = match.start()
        
        # Check if this number is inside a cross-reference link
        before = result[:pos]
        after = result[pos:]
        
        last_open_tag_pos = before.rfind('<')
        if last_open_tag_pos != -1:
            tag_content = result[last_open_tag_pos:pos]
            if '<a ' in tag_content and '</a>' not in tag_content:
                continue
        
        trans_numbers.append((num_text, match.start(), match.end()))
    
    # We need to match R code blocks to number positions
    # The assumption is that numbers appear in the same order in both HTML versions
    # and that there's one R code block for each number
    
    if len(r_code_blocks) != len(en_numbers):
        # Mismatch - can't reliably reconstruct
        return result
    
    if len(trans_numbers) < len(r_code_blocks):
        # Missing numbers in translation
        return result
    
    # Replace numbers in translated HTML with R code blocks (in reverse order to preserve indices)
    for i in range(len(r_code_blocks) - 1, -1, -1):
        if i < len(trans_numbers):
            r_code = r_code_blocks[i]
            num_text, start, end = trans_numbers[i]
            result = result[:start] + r_code + result[end:]
    
    return result


def extract_from_list(msgid: str, translation_map: Dict[str, str]) -> Optional[str]:
    """
    Try to extract translation from comma-separated lists.
    E.g., msgid="Germany", EN list="Estonia, Germany, Greece", ES list="Estonia, Alemania, Grecia"
    Should return "Alemania".
    """
    msgid_normalized = normalize_for_matching(msgid)
    
    for en_text, trans_text in translation_map.items():
        # Check if both are comma-separated lists
        if ',' in en_text and ',' in trans_text:
            en_items = [item.strip() for item in en_text.split(',')]
            trans_items = [item.strip() for item in trans_text.split(',')]
            
            # Lists should have same length
            if len(en_items) != len(trans_items):
                continue
            
            # Try to find msgid in English list
            for i, en_item in enumerate(en_items):
                if normalize_for_matching(en_item) == msgid_normalized:
                    # Found it! Return corresponding translated item
                    return trans_items[i]
    
    return None


def find_translation(msgid: str, translation_map: Dict[str, str], en_translation_map: Dict[str, str],
                    include_fallback: bool = False) -> Optional[str]:
    """Find translation for a msgid string.
    
    Args:
        msgid: The source string to find translation for
        translation_map: EN -> Target language map
        en_translation_map: EN -> EN map (for %s placeholder matching)
        include_fallback: If True, accept EN=Target matches (fallback strings)
    
    Returns:
        Translation string or None
    """
    msgid_clean = unescape_string(msgid)
    
    # Detect and preserve trailing special characters
    trailing = ''
    msgid_for_matching = msgid_clean
    
    # Check for trailing \n
    if msgid_clean.endswith('\n'):
        trailing = '\n'
        msgid_for_matching = msgid_clean[:-1]  # Remove \n for matching
    
    # Try exact match first
    if msgid_for_matching in translation_map:
        result = translation_map[msgid_for_matching]
        # Preserve trailing punctuation that's in msgid but might not be in HTML
        return result + trailing
    
    # Try normalized match
    msgid_norm = normalize_for_matching(msgid_for_matching)
    
    for en_text, trans_text in translation_map.items():
        en_norm = normalize_for_matching(en_text)
        
        if msgid_norm == en_norm:
            # Preserve trailing colon or period if present in msgid but not in translation
            if msgid_for_matching.endswith(':') and not trans_text.endswith(':'):
                return trans_text + ':' + trailing
            return trans_text + trailing
        
        # Try without trailing punctuation
        msgid_no_punct = msgid_norm.rstrip('.:!?')
        en_no_punct = en_norm.rstrip('.:!?')
        
        if msgid_no_punct == en_no_punct and msgid_no_punct:
            # Check if msgid has trailing punctuation
            if msgid_for_matching.endswith(':') and not trans_text.endswith(':'):
                return trans_text + ':' + trailing
            elif msgid_for_matching.endswith('.') and not trans_text.endswith('.'):
                return trans_text + '.' + trailing
            return trans_text + trailing
    
    # For paragraphs with inline R code: msgid has `r dR$var` but HTML has actual numbers
    # Check if msgid contains R code backticks
    if '`r ' in msgid_for_matching:
        # Strip leading ': ' from msgid if present (definition list format)
        # In .Rmd definition lists use ":   value" but HTML just has "value"
        msgid_for_r_matching = msgid_for_matching
        is_def_list = False
        if msgid_for_matching.startswith(':'):
            msgid_for_r_matching = re.sub(r'^:\s+', '', msgid_for_matching)
            is_def_list = True
        
        msgid_r_norm = normalize_for_r_code_matching(msgid_for_r_matching)
        
        # Search in translation_map (keys are English HTML, values are translated HTML)
        for en_text, trans_text in translation_map.items():
            en_r_norm = normalize_for_r_code_matching(en_text)
            
            if msgid_r_norm == en_r_norm:
                # Found matching English HTML - now reconstruct with R code
                reconstructed = reconstruct_with_r_code(msgid_for_r_matching, en_text, trans_text)
                # Re-add the definition list prefix if it was present
                if is_def_list:
                    reconstructed = ':   ' + reconstructed
                return reconstructed + trailing
    
    # For strings with %s placeholders where HTML has actual values
    if '%s' in msgid_for_matching:
        # SKIP composite format strings like "%s: Combines..." - those are handled separately
        # Only handle complex multi-placeholder cases like "Q₁, Q₂, Q₃: The quartiles (%s, %s and %s quantiles)"
        if not msgid_for_matching.startswith('%s:'):
            # Try to find the English template with actual values substituted
            # E.g., msgid has "the %s, %s and %s quantiles" 
            # but HTML has "the 25%, 50% and 75% quantiles"
            # Or: "%s, %s, %s: The quartiles (%s, %s and %s quantiles)" 
            # becomes "Q₁, Q₂, Q₃: The quartiles (25%, 50% and 75% quantiles)"
            
            # First, try to find in en_translation_map (English -> English)
            # to see if we can find the actual English text
            for en_text, _ in en_translation_map.items():
                # Build pattern from msgid where %s matches various value types:
                # - Numbers with optional %: 25%, 50
                # - Subscript characters: Q₁, Q₂, Q₃
                # - Other short values: any non-comma, non-colon sequence
                msgid_pattern = re.escape(msgid_for_matching)
                
                # Replace %s with a flexible pattern that matches:
                # - Multi-word values like "50 g", "7 day", "25%"
                # - Unicode subscript digits: Q₁, Q₂, Q₃
                # - Numbers with units, possibly multi-word: "50 g", "100 g"
                # Pattern: one or more words (non-whitespace), allowing spaces between words
                # But stop at sentence punctuation or structural delimiters
                value_pattern = r'[^\s:,()]+(?:\s+[^\s:,().]+)*'
                msgid_pattern = msgid_pattern.replace(r'%s', value_pattern)
                
                match = re.search(msgid_pattern, en_text, re.IGNORECASE)
                if match:
                    # Found the English version with actual values
                    # Now find its translation
                    if en_text in translation_map:
                        trans_text = translation_map[en_text]
                        
                        # Extract the actual values that were matched in English
                        # Split the msgid by %s to get the static parts
                        static_parts = msgid_for_matching.split('%s')
                        
                        # Build pattern to extract values from English text
                        extract_pattern = ''
                        for i, part in enumerate(static_parts):
                            if part:
                                extract_pattern += re.escape(part)
                            if i < len(static_parts) - 1:
                                # Add capturing group for the value
                                extract_pattern += r'([^\s:,()]+(?:\s+[^\s:,().]+)*)'
                        
                        en_match = re.search(extract_pattern, en_text, re.IGNORECASE)
                        if en_match:
                            en_values = en_match.groups()
                            
                            # Now replace corresponding values in translation with %s
                            # Strategy: find and replace the actual values one by one
                            result = trans_text
                            
                            # Remove footnote markers from the beginning
                            result = re.sub(r'^[‖†‡§¶*]+\s*', '', result)
                            
                            # For each English value, try to find and replace it in translation
                            # Some values might be the same (Q₁, Q₂, Q₃) or numbers (25%, 50%, 75%)
                            for en_val in en_values:
                                if en_val:
                                    # Try direct replacement first (works for most cases)
                                    if en_val in result:
                                        result = result.replace(en_val, '%s', 1)
                                    # Handle subscript numbers - they typically stay the same
                                    elif re.search(r'[₀-₉]', en_val):
                                        # Replace first occurrence of this subscript value
                                        result = result.replace(en_val, '%s', 1)
                                    # Handle numbers with possible different formatting (space, no space, etc.)
                                    elif re.search(r'\d+', en_val):
                                        # Try to match number + optional unit pattern
                                        # e.g., "50 g" or "50g" or "7 day" or "7day"
                                        num_match = re.search(r'(\d+)\s*(.+)?', en_val)
                                        if num_match:
                                            num = num_match.group(1)
                                            unit = num_match.group(2) if num_match.group(2) else ''
                                            # Try matching with optional space between number and unit
                                            if unit:
                                                pattern = rf'\b{num}\s*{re.escape(unit)}\b'
                                            else:
                                                pattern = rf'\b{num}\b'
                                            result = re.sub(pattern, '%s', result, count=1)
                                    else:
                                        # Generic replacement for other values
                                        result = result.replace(en_val, '%s', 1)
                            
                            return result + trailing
            
            # Fallback: try existing logic for when English HTML has values
            # Common patterns to look for in HTML: "50 g", "7 day", "50-g", "7-Tage"
            # The msgid has "%s" where these values appear
            
            for en_text, trans_text in translation_map.items():
                # Try to match the structure
                msgid_parts = msgid_for_matching.split('%s')
                
                if len(msgid_parts) < 2:
                    continue
                
                # Check if all non-%s parts of msgid appear in en_text in order
                en_lower = en_text.lower()
                msgid_lower = msgid_for_matching.lower()
                
                # Build a regex pattern from msgid with %s as wildcard
                pattern_parts = [re.escape(part.lower().strip()) for part in msgid_parts]
                pattern = r'\s*'.join(pattern_parts)
                # Replace empty parts at start/end
                pattern = pattern.strip(r'\s*')
                
                if re.search(pattern, en_lower):
                    # Found a match! Now extract what filled the %s positions
                    # and replace corresponding parts in trans_text
                    
                    # Find the actual values that match %s positions
                    remaining = en_text
                    actual_values_en = []
                    
                    for i, part in enumerate(msgid_parts[:-1]):  # All but last
                        part_stripped = part.strip()
                        if part_stripped:
                            idx = remaining.lower().find(part_stripped.lower())
                            if idx >= 0:
                                remaining = remaining[idx + len(part_stripped):]
                                # Extract until next part
                                if i + 1 < len(msgid_parts):
                                    next_part = msgid_parts[i + 1].strip()
                                    if next_part:
                                        next_idx = remaining.lower().find(next_part.lower())
                                        if next_idx >= 0:
                                            value = remaining[:next_idx].strip()
                                            actual_values_en.append(value)
                                            remaining = remaining[next_idx:]
                    
                    # Now find corresponding values in trans_text and replace with %s
                    if actual_values_en:
                        result = trans_text
                        
                        # For each English value, try to find the corresponding translated value
                        # Common patterns:
                        # "50 g" (en) -> "50 g" or "50-g" (de)
                        # "7 day" (en) -> "7-Tage" or "7 Tag" (de)
                        
                        for en_val in actual_values_en:
                            # Extract number and unit
                            val_match = re.match(r'(\d+)\s*([a-zA-Z]+)', en_val.strip())
                            if val_match:
                                number = val_match.group(1)
                                unit = val_match.group(2)
                                
                                # Look for this number in the translation
                                # It might be "50 g" or "50-g-Schritten" or similar
                                # Replace the first occurrence of a pattern with this number
                                number_pattern = rf'{number}[\s-]*[a-zA-Zäöüß-]*'
                                result = re.sub(number_pattern, '%s', result, count=1)
                        
                        # Clean up spacing
                        result = re.sub(r'\s+%s', ' %s', result)
                        result = re.sub(r'%s\s+', '%s ', result)
                        
                        if '%s' in result:
                            return result + trailing
    
    # Try to extract from comma-separated lists (e.g., country names)
    list_translation = extract_from_list(msgid_for_matching, translation_map)
    if list_translation:
        return list_translation + trailing
    
    # Fallback string handling: if include_fallback is True, check if msgid exists
    # in translation_map with the SAME value (untranslated/fallback string)
    if include_fallback:
        # Check exact match in translation_map
        if msgid_for_matching in translation_map.values():
            # Find if this value is a fallback (EN == Target)
            for en_text, trans_text in translation_map.items():
                if trans_text == msgid_for_matching and en_text == msgid_for_matching:
                    # It's a fallback string - return it to populate the .po file
                    return msgid_for_matching + trailing
    
    return None


def update_po_file_content(content: str, entries: List[Dict], translation_map: Dict[str, str],
                          en_translation_map: Dict[str, str], replace_existing: bool = False,
                          include_fallback: bool = False) -> Tuple[str, int]:
    """Update PO file content with translations."""
    updated_content = content
    updates_made = 0
    
    # Build index of msgids for composite string handling
    msgid_index = {entry['msgid']: entry for entry in entries}
    
    for entry in entries:
        msgid = entry['msgid']
        msgstr = entry['msgstr']
        
        # Skip if already translated and not replacing
        if msgstr and not replace_existing:
            continue
        
        # Find translation
        translation = find_translation(msgid, translation_map, en_translation_map, include_fallback)
        
        # Handle R code-only entries (definition list values, etc.)
        # These are entries like ":   `r dR$variable`\n" that contain only R code
        # The R code should be the same in all languages, so we can just copy it
        if not translation:
            # Check if msgid is pure R code (contains `r ` and backticks, no other text except whitespace/colon)
            # Note: msgid contains escaped sequences like \\n, so we need to handle that
            msgid_clean = msgid.replace('\\n', '').strip()
            if re.match(r'^:\s*`r\s+[^`]+`\s*$', msgid_clean):
                # It's a pure R code entry - use it as-is
                translation = msgid
            # Note: We do NOT handle entries with trailing words like "days" here,
            # because those words need translation (e.g., "days" -> "giorni" in Italian)
        
        # Handle composite strings: msgid with %s where HTML has full concatenated text
        # E.g., msgid "%s: Combines..." and msgid "Severe infection" 
        # HTML has "Severe infection: Combines..." or "‖ Severe infection: Combines..."
        if not translation and msgid.startswith('%s:'):
            # Try to find composite translation in HTML
            # Look for text matching the pattern where %s is filled in
            pattern_suffix = msgid[3:].strip()  # Remove "%s: " prefix
            
            for html_text, trans_text in translation_map.items():
                # Check if HTML text ends with the pattern suffix
                if ':' in html_text:
                    # Split on the first colon
                    parts = html_text.split(':', 1)
                    if len(parts) == 2:
                        prefix, suffix = parts
                        suffix = suffix.strip()
                        
                        # Remove footnote markers and clean prefix
                        prefix = re.sub(r'^[‖†‡§¶*]+\s*', '', prefix).strip()
                        
                        # Check if suffix matches the pattern
                        if suffix.lower() == pattern_suffix.lower() or \
                           normalize_for_matching(suffix) == normalize_for_matching(pattern_suffix):
                            # Found it! Extract the translated suffix
                            trans_parts = trans_text.split(':', 1)
                            if len(trans_parts) == 2:
                                trans_prefix, trans_suffix = trans_parts
                                trans_prefix = re.sub(r'^[‖†‡§¶*]+\s*', '', trans_prefix).strip()
                                translation = '%s:' + trans_suffix
                                
                                # Also try to update the prefix msgid if it exists and is empty
                                # Look for msgid matching the English prefix
                                if prefix in msgid_index:
                                    prefix_entry = msgid_index[prefix]
                                    if not prefix_entry['msgstr'] or replace_existing:
                                        # Update the prefix entry too
                                        prefix_translation = trans_prefix
                                        escaped_prefix = escape_string(prefix_translation)
                                        old_prefix_block = prefix_entry['original_block']
                                        replacement_prefix_text = 'msgstr "' + escaped_prefix + '"'
                                        new_prefix_block = re.sub(
                                            r'msgstr\s+"(?:[^"\\]|\\.)*"',
                                            lambda m: replacement_prefix_text,
                                            old_prefix_block
                                        )
                                        updated_content = updated_content.replace(old_prefix_block, new_prefix_block)
                                        updates_made += 1
                                break
        
        if translation:
            # CRITICAL: Ensure trailing \n is preserved if msgid has it
            # This is a .po file syntax requirement
            # msgid contains the escaped form (\\n), so check for that
            # translation contains the actual character, so add \n (newline char) if needed
            if msgid.endswith('\\n') and not translation.endswith('\n'):
                translation += '\n'
            
            # Escape for PO format
            escaped_translation = escape_string(translation)
            
            # Replace in content
            old_block = entry['original_block']
            
            # Replace the msgstr line(s) - handle both single and multi-line msgstr
            # Match msgstr "..." including escaped characters
            # Pattern: msgstr followed by quoted string (possibly with escaped quotes)
            # Use lambda to prevent re.sub from interpreting backslashes in replacement
            replacement_text = 'msgstr "' + escaped_translation + '"'
            new_block = re.sub(
                r'msgstr\s+"(?:[^"\\]|\\.)*"',
                lambda m: replacement_text,  # Use lambda to avoid escape sequence interpretation
                old_block
            )
            
            updated_content = updated_content.replace(old_block, new_block)
            updates_made += 1
        else:
            # No translation found, but check if existing msgstr needs trailing \n fix
            # This handles entries that aren't in the HTML but already have translations
            if msgstr and msgid.endswith('\\n') and not msgstr.endswith('\\n'):
                # msgid ends with \n but msgstr doesn't - fix the syntax error
                # msgstr in the entry is already unescaped, so we need to:
                # 1. Check if it ends with actual newline character
                unescaped_msgstr = unescape_string(msgstr)
                if not unescaped_msgstr.endswith('\n'):
                    # Add the newline and re-escape
                    fixed_msgstr = unescaped_msgstr + '\n'
                    escaped_fixed = escape_string(fixed_msgstr)
                    
                    # Replace in content
                    old_block = entry['original_block']
                    replacement_text = 'msgstr "' + escaped_fixed + '"'
                    new_block = re.sub(
                        r'msgstr\s+"(?:[^"\\]|\\.)*"',
                        lambda m: replacement_text,
                        old_block
                    )
                    
                    updated_content = updated_content.replace(old_block, new_block)
                    updates_made += 1
    
    return updated_content, updates_made


def main():
    parser = argparse.ArgumentParser(description='Sync HTML translations to PO files')
    parser.add_argument('--html-dir', required=True, help='Directory containing HTML files')
    parser.add_argument('--po-dir', required=True, help='Directory containing PO files')
    parser.add_argument('--locales', nargs='+', default=['de', 'es', 'et', 'gr', 'it'],
                       help='Locales to process')
    parser.add_argument('--replace-de', action='store_true',
                       help='Replace existing German translations')
    parser.add_argument('--replace-all', action='store_true',
                       help='Replace existing translations for all locales')
    parser.add_argument('--include-fallback', action='store_true',
                       help='Include fallback strings (where EN and target are identical)')
    args = parser.parse_args()
    
    html_dir = Path(args.html_dir)
    po_dir = Path(args.po_dir)
    
    # Load English HTML
    en_html_files = list(html_dir.glob('*.Reference-Report.en.html'))
    if not en_html_files:
        print("ERROR: English HTML file not found!")
        return 1
    
    with open(en_html_files[0], 'r', encoding='utf-8') as f:
        en_html_content = f.read()
    
    print(f"English HTML: {en_html_files[0].name}")
    en_elements = extract_text_elements(en_html_content)
    print(f"  Extracted {len(en_elements)} English elements\n")
    
    for locale in args.locales:
        print(f"Processing locale: {locale}")
        
        # Find HTML file
        html_files = list(html_dir.glob(f'*.Reference-Report.{locale}.html'))
        if not html_files:
            print(f"  No HTML file found for {locale}\n")
            continue
            
        html_file = html_files[0]
        print(f"  HTML: {html_file.name}")
        
        # Load target HTML
        with open(html_file, 'r', encoding='utf-8') as f:
            target_html_content = f.read()
        
        # Create translation map
        translation_map = create_translation_map(en_html_content, target_html_content)
        en_translation_map = create_translation_map(en_html_content, en_html_content)
        print(f"  Created translation map with {len(translation_map)} entries")
        
        # Update PO file
        po_file = po_dir / f'reports.{locale}.po'
        if not po_file.exists():
            print(f"  PO file not found: {po_file}\n")
            continue
        
        # Read PO file
        with open(po_file, 'r', encoding='utf-8') as f:
            po_content = f.read()
        
        entries = read_po_file(po_file)
        print(f"  Loaded {len(entries)} PO entries")
        
        replace_existing = args.replace_all or (locale == 'de' and args.replace_de)
        updated_content, updates_made = update_po_file_content(
            po_content, entries, translation_map, en_translation_map, replace_existing, args.include_fallback
        )
        
        # Write back
        with open(po_file, 'w', encoding='utf-8') as f:
            f.write(updated_content)
        
        print(f"  Updated {updates_made} entries in {po_file.name}\n")
    
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
