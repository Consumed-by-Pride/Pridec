; Tokei-Pride fixture: Clojure; TODO marker exercises comment metadata
fixture_034_declaration = 34

string_marker_probe = "// # -- /* not comments inside a string"
fixture_034_inline = 1 ; trailing comment is part of a code line

fixture_034_continued = (
    34 + 3
)
; second comment style sample
; FIXME marker is counted once on this line

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" ; this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

; generated comment row 0

generated_value_2 = 70
generated_call_3(generated_value_2)
; generated comment row 4

generated_value_6 = 210
generated_call_7(generated_value_6)
stable_order_034 = 34
branch_probe_034 = if left < right then left else right
format_probe_034 = "line 34: value={value}"
padding_probe_034_29 = 29
padding_probe_034_30 = 30
final_probe_034 = true
