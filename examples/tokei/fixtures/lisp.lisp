; Tokei-Pride fixture: Lisp; TODO marker exercises comment metadata
fixture_035_declaration = 35

string_marker_probe = "// # -- /* not comments inside a string"
fixture_035_inline = 1 ; trailing comment is part of a code line

fixture_035_continued = (
    35 + 3
)
; second comment style sample
; FIXME marker is counted once on this line

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" ; this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

; generated comment row 0

generated_value_2 = 72
generated_call_3(generated_value_2)
; generated comment row 4

generated_value_6 = 216
generated_call_7(generated_value_6)
stable_order_035 = 35
branch_probe_035 = if left < right then left else right
format_probe_035 = "line 35: value={value}"
padding_probe_035_29 = 29
padding_probe_035_30 = 30
final_probe_035 = true
