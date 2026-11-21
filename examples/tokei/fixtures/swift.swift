// Tokei-Pride fixture: Swift; TODO marker exercises comment metadata
fixture_015_declaration = 15

string_marker_probe = "// # -- /* not comments inside a string"
fixture_015_inline = 1 // trailing comment is part of a code line

fixture_015_continued = (
    15 + 3
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

generated_value_2 = 32
generated_call_3(generated_value_2)
// generated comment row 4

generated_value_6 = 96
generated_call_7(generated_value_6)
stable_order_015 = 15
branch_probe_015 = if left < right then left else right
format_probe_015 = "line 15: value={value}"
padding_probe_015_30 = 30
final_probe_015 = true
