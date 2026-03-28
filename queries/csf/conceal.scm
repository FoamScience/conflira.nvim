; Confluence Storage Format - Conceal Queries
;
; Rules for the merged highlights group:
; - NO child captures inside @conceal parents (causes icon fragmentation)
; - Use #match? on @conceal node text for filtering (no ^ $ anchors)
; - Split-tag on "<" leaf token for nerd font icons (headings, list items)

; ══════════════════════════════════════════════════════════════════════
; XHTML Headings: split-tag — nerd font icon on "<"
; ══════════════════════════════════════════════════════════════════════

(element (STag "<" @conceal (Name) @_n) (#eq? @_n "h1") (#set! conceal "󰲡"))
(element (STag (Name) @conceal) (#eq? @conceal "h1") (#set! conceal ""))
(element (STag (Name) @_n ">" @conceal) (#eq? @_n "h1") (#set! conceal " "))
(element (ETag) @conceal (#match? @conceal "h1") (#set! conceal ""))

(element (STag "<" @conceal (Name) @_n) (#eq? @_n "h2") (#set! conceal "󰲣"))
(element (STag (Name) @conceal) (#eq? @conceal "h2") (#set! conceal ""))
(element (STag (Name) @_n ">" @conceal) (#eq? @_n "h2") (#set! conceal " "))
(element (ETag) @conceal (#match? @conceal "h2") (#set! conceal ""))

(element (STag "<" @conceal (Name) @_n) (#eq? @_n "h3") (#set! conceal "󰲥"))
(element (STag (Name) @conceal) (#eq? @conceal "h3") (#set! conceal ""))
(element (STag (Name) @_n ">" @conceal) (#eq? @_n "h3") (#set! conceal " "))
(element (ETag) @conceal (#match? @conceal "h3") (#set! conceal ""))

(element (STag "<" @conceal (Name) @_n) (#eq? @_n "h4") (#set! conceal "󰲧"))
(element (STag (Name) @conceal) (#eq? @conceal "h4") (#set! conceal ""))
(element (STag (Name) @_n ">" @conceal) (#eq? @_n "h4") (#set! conceal " "))
(element (ETag) @conceal (#match? @conceal "h4") (#set! conceal ""))

(element (STag "<" @conceal (Name) @_n) (#eq? @_n "h5") (#set! conceal "󰲩"))
(element (STag (Name) @conceal) (#eq? @conceal "h5") (#set! conceal ""))
(element (STag (Name) @_n ">" @conceal) (#eq? @_n "h5") (#set! conceal " "))
(element (ETag) @conceal (#match? @conceal "h5") (#set! conceal ""))

(element (STag "<" @conceal (Name) @_n) (#eq? @_n "h6") (#set! conceal "󰲫"))
(element (STag (Name) @conceal) (#eq? @conceal "h6") (#set! conceal ""))
(element (STag (Name) @_n ">" @conceal) (#eq? @_n "h6") (#set! conceal " "))
(element (ETag) @conceal (#match? @conceal "h6") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; Inline formatting: tags hidden
; ══════════════════════════════════════════════════════════════════════

(element (STag) @conceal (#match? @conceal "<strong>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "strong") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<em>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "em") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<code>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "code") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<s>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "s") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; Invisible tags
; ══════════════════════════════════════════════════════════════════════

(element (STag) @conceal (#match? @conceal "<p>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "p") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<u>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "u") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<ul>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "ul") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<ol>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "ol") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<table>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "table") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<tr>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "tr") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<tbody>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "tbody") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<thead>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "thead") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<span") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "span") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<div") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "div") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<pre>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "pre") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<sup>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "sup") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<sub>") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "sub") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; List items: split-tag — bullet + space
; ══════════════════════════════════════════════════════════════════════

(element (STag "<" @conceal (Name) @_n) (#eq? @_n "li") (#set! conceal "●"))
(element (STag (Name) @conceal) (#eq? @conceal "li") (#set! conceal ""))
(element (STag (Name) @_n ">" @conceal) (#eq? @_n "li") (#set! conceal " "))
(element (ETag) @conceal (#match? @conceal "li") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; Block elements: split-tag for icon + space + color
; ══════════════════════════════════════════════════════════════════════

(element (STag "<" @markup.quote (Name) @_n) (#eq? @_n "blockquote") (#set! conceal "▎"))
(element (STag (Name) @conceal) (#eq? @conceal "blockquote") (#set! conceal ""))
(element (STag (Name) @_n ">" @conceal) (#eq? @_n "blockquote") (#set! conceal " "))
(element (ETag) @conceal (#match? @conceal "blockquote") (#set! conceal ""))
(element (EmptyElemTag) @conceal (#match? @conceal "<hr") (#set! conceal "━"))
(element (EmptyElemTag) @conceal (#match? @conceal "<br") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; Links & images
; ══════════════════════════════════════════════════════════════════════

(element (STag) @conceal (#match? @conceal "<a") (#set! conceal ""))
(element (ETag) @conceal (#match? @conceal "a") (#set! conceal ""))
(element (EmptyElemTag) @conceal (#match? @conceal "<img") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; Table cells
; ══════════════════════════════════════════════════════════════════════

(element (STag) @conceal (#match? @conceal "<td") (#set! conceal "│"))
(element (ETag) @conceal (#match? @conceal "td") (#set! conceal ""))
(element (STag) @conceal (#match? @conceal "<th") (#set! conceal "┃"))
(element (ETag) @conceal (#match? @conceal "th") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; Metadata comments
; ══════════════════════════════════════════════════════════════════════

(Comment) @conceal (#set! conceal "")

; ══════════════════════════════════════════════════════════════════════
; AC: Structured macros
; ══════════════════════════════════════════════════════════════════════

(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "info") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "warning") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "note") (#set! conceal "󰏫"))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "tip") (#set! conceal "󰌶"))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "code") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "status") (#set! conceal "󰀘"))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "expand") (#set! conceal "󰐊"))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "panel") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "anchor") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "toc") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "mathblock") (#set! conceal "∑"))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:structured-macro") (#match? @conceal "mathinline") (#set! conceal "∫"))
(ac_element (ac_end_tag) @conceal (#match? @conceal "ac:structured-macro") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; AC: Task elements
; ══════════════════════════════════════════════════════════════════════

(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:task-list") (#set! conceal ""))
(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:task-list") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:task>") (#set! conceal ""))
(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:task>") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:task-id") (#set! conceal ""))
(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:task-id") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:task-id") (content (CharData) @conceal) (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:task-status") (#set! conceal ""))
(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:task-status") (#set! conceal ""))
; Task checkbox: colored captures on CharData leaf — no parent capture needed
(ac_element (content (CharData) @markup.list.unchecked) (#eq? @markup.list.unchecked "incomplete") (#set! conceal ""))
(ac_element (content (CharData) @markup.list.checked) (#eq? @markup.list.checked "complete") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:task-body") (#set! conceal " "))
(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:task-body") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; AC: Body and parameter tags → hidden
; ══════════════════════════════════════════════════════════════════════

(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:rich-text-body") (#set! conceal ""))
(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:rich-text-body") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:plain-text-body") (#set! conceal ""))
(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:plain-text-body") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:parameter") (#set! conceal ""))
(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:parameter") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; AC: Links and images
; ══════════════════════════════════════════════════════════════════════

(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:link") (#set! conceal ""))
(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:link") (#set! conceal ""))
(ac_element (ac_start_tag) @conceal (#match? @conceal "ac:image") (#set! conceal ""))
(ac_element (ac_end_tag)   @conceal (#match? @conceal "ac:image") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; AC: Emoticon
; ══════════════════════════════════════════════════════════════════════

(ac_element (ac_empty_tag) @conceal (#match? @conceal "ac:emoticon") (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; CDATA delimiters → hidden
; ══════════════════════════════════════════════════════════════════════

(CDSect (CDStart) @conceal (#set! conceal ""))
(CDSect (CDEnd) @conceal (#set! conceal ""))

; ══════════════════════════════════════════════════════════════════════
; ri: namespace elements → hidden
; ══════════════════════════════════════════════════════════════════════

(ri_empty_tag) @conceal (#set! conceal "")
(ri_start_tag) @conceal (#set! conceal "")
(ri_end_tag) @conceal (#set! conceal "")
