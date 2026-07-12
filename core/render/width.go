package render

import "unicode/utf8"

// displayWidth approximates Neovim's strdisplaywidth: the terminal cell width of
// a string. ASCII and most text count one cell per rune; East-Asian wide and
// fullwidth ranges count two. (Used only for table column alignment.)
func displayWidth(s string) int {
	w := 0
	for len(s) > 0 {
		r, size := utf8.DecodeRuneInString(s)
		s = s[size:]
		if isWide(r) {
			w += 2
		} else {
			w++
		}
	}
	return w
}

func isWide(r rune) bool {
	switch {
	case r >= 0x1100 && r <= 0x115F, // Hangul Jamo
		r >= 0x2E80 && r <= 0x303E, // CJK radicals, Kangxi
		r >= 0x3041 && r <= 0x33FF, // Hiragana..CJK symbols
		r >= 0x3400 && r <= 0x4DBF, // CJK Ext A
		r >= 0x4E00 && r <= 0x9FFF, // CJK Unified
		r >= 0xA000 && r <= 0xA4CF, // Yi
		r >= 0xAC00 && r <= 0xD7A3, // Hangul syllables
		r >= 0xF900 && r <= 0xFAFF, // CJK compat
		r >= 0xFF00 && r <= 0xFF60, // fullwidth forms
		r >= 0xFFE0 && r <= 0xFFE6,
		r >= 0x20000 && r <= 0x3FFFD: // CJK Ext B+
		return true
	}
	return false
}
