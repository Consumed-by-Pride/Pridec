// Tokei-Pride fixture: Scala; TODO marker exercises comment metadata
fixture_017_declaration = 17

string_marker_probe = "// # -- /* not comments inside a string"
fixture_017_inline = 1 // trailing comment is part of a code line

fixture_017_continued = (
    17 + 3
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

generated_value_2 = 36
generated_call_3(generated_value_2)
// generated comment row 4

generated_value_6 = 108
generated_call_7(generated_value_6)
stable_order_017 = 17
branch_probe_017 = if left < right then left else right
format_probe_017 = "line 17: value={value}"
padding_probe_017_30 = 30
final_probe_017 = true
