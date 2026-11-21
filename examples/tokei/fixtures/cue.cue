// Tokei-Pride fixture: CUE; TODO marker exercises comment metadata
fixture_084_declaration = 84

string_marker_probe = "// # -- /* not comments inside a string"
fixture_084_inline = 1 // trailing comment is part of a code line

fixture_084_continued = (
    84 + 3
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

generated_value_2 = 170
generated_call_3(generated_value_2)
// generated comment row 4

generated_value_6 = 510
generated_call_7(generated_value_6)
stable_order_084 = 84
branch_probe_084 = if left < right then left else right
format_probe_084 = "line 84: value={value}"
padding_probe_084_30 = 30
final_probe_084 = true
