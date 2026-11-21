// Tokei-Pride fixture: Go; TODO marker exercises comment metadata
fixture_007_declaration = 7

string_marker_probe = "// # -- /* not comments inside a string"
fixture_007_inline = 1 // trailing comment is part of a code line

fixture_007_continued = (
    7 + 3
)
/* TODO block begins
block continuation remains a comment
block closes here */

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" // this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

// generated comment row 0

generated_value_2 = 16
generated_call_3(generated_value_2)
// generated comment row 4

generated_value_6 = 48
generated_call_7(generated_value_6)
stable_order_007 = 7
branch_probe_007 = if left < right then left else right
format_probe_007 = "line 7: value={value}"
padding_probe_007_30 = 30
final_probe_007 = true
