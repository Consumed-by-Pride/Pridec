' Tokei-Pride fixture: Basic; TODO marker exercises comment metadata
fixture_054_declaration = 54

string_marker_probe = "// # -- /* not comments inside a string"
fixture_054_inline = 1 ' trailing comment is part of a code line

fixture_054_continued = (
    54 + 3
)
' second comment style sample
' FIXME marker is counted once on this line

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" ' this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

' generated comment row 0

generated_value_2 = 110
generated_call_3(generated_value_2)
' generated comment row 4

generated_value_6 = 330
generated_call_7(generated_value_6)
stable_order_054 = 54
branch_probe_054 = if left < right then left else right
format_probe_054 = "line 54: value={value}"
padding_probe_054_29 = 29
padding_probe_054_30 = 30
final_probe_054 = true
