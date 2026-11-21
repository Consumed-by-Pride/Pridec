REM  Tokei-Pride fixture: Batch; TODO marker exercises comment metadata
fixture_053_declaration = 53

string_marker_probe = "// # -- /* not comments inside a string"
fixture_053_inline = 1 REM  trailing comment is part of a code line

fixture_053_continued = (
    53 + 3
)
REM  second comment style sample
REM  FIXME marker is counted once on this line

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" REM  this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

REM  generated comment row 0

generated_value_2 = 108
generated_call_3(generated_value_2)
REM  generated comment row 4

generated_value_6 = 324
generated_call_7(generated_value_6)
stable_order_053 = 53
branch_probe_053 = if left < right then left else right
format_probe_053 = "line 53: value={value}"
padding_probe_053_29 = 29
padding_probe_053_30 = 30
final_probe_053 = true
